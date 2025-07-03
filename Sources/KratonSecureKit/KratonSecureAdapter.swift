// SPDX-License-Identifier: MIT
// Copyright © 2018-2023 Kraton AI Corporation. All Rights Reserved.

import Foundation
import NetworkExtension

#if SWIFT_PACKAGE
import KratonSecureKitGo
import KratonSecureKitC
#endif

public enum KratonSecureConnectionError: Error {
    /// Failure to locate tunnel file descriptor.
    case tunnelDescriptorNotFound

    /// Failure to perform an operation in such state.
    case invalidConnectionState

    /// Failure to resolve endpoints.
    case endpointResolutionFailed([EndpointResolutionError])

    /// Failure to set network settings.
    case networkConfigurationFailed(Error)

    /// Failure to start Kraton secure backend.
    case backendInitializationFailed(Int32)
}

/// Enum representing enhanced internal state of the `KratonSecureAdapter`
private enum KratonConnectionState {
    /// The tunnel is completely stopped
    case stopped
    
    /// The tunnel is initializing
    case initializing(_ settingsGenerator: PacketTunnelSettingsGenerator)

    /// The tunnel is up and running with performance metrics
    case connected(_ handle: Int32, _ settingsGenerator: PacketTunnelSettingsGenerator, _ connectionTime: Date)

    /// The tunnel is temporarily shutdown due to device going offline
    case suspended(_ settingsGenerator: PacketTunnelSettingsGenerator, _ suspendTime: Date)
    
    /// The tunnel encountered an error and is attempting recovery
    case recovering(_ settingsGenerator: PacketTunnelSettingsGenerator, _ retryCount: Int)
    
    var isActive: Bool {
        switch self {
        case .connected: return true
        default: return false
        }
    }
    
    var description: String {
        switch self {
        case .stopped: return "STOPPED"
        case .initializing: return "INITIALIZING"
        case .connected(_, _, let time): return "CONNECTED (since \(time))"
        case .suspended(_, let time): return "SUSPENDED (since \(time))"
        case .recovering(_, let count): return "RECOVERING (attempt \(count))"
        }
    }
}

public class KratonSecureAdapter {
    public typealias LogHandler = (KratonSecureLogLevel, String) -> Void

    /// Network routes monitor.
    private var networkMonitor: NWPathMonitor?

    /// Packet tunnel provider.
    private weak var packetTunnelProvider: NEPacketTunnelProvider?

    /// Log handler closure.
    private let logHandler: LogHandler

    /// Private queue used to synchronize access to `KratonSecureAdapter` members.
    private let workQueue = DispatchQueue(label: "KratonSecureAdapterWorkQueue")

    /// Enhanced adapter state with detailed tracking.
    private var state: KratonConnectionState = .stopped

    /// Tunnel device file descriptor.
    private var tunnelFileDescriptor: Int32? {
        var ctlInfo = ctl_info()
        withUnsafeMutablePointer(to: &ctlInfo.ctl_name) {
            $0.withMemoryRebound(to: CChar.self, capacity: MemoryLayout.size(ofValue: $0.pointee)) {
                _ = strcpy($0, "com.apple.net.kraton_control")
            }
        }
        for fd: Int32 in 0...1024 {
            var addr = sockaddr_ctl()
            var ret: Int32 = -1
            var len = socklen_t(MemoryLayout.size(ofValue: addr))
            withUnsafeMutablePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    ret = getpeername(fd, $0, &len)
                }
            }
            if ret != 0 || addr.sc_family != AF_SYSTEM {
                continue
            }
            if ctlInfo.ctl_id == 0 {
                ret = ioctl(fd, CTLIOCGINFO, &ctlInfo)
                if ret != 0 {
                    continue
                }
            }
            if addr.sc_id == ctlInfo.ctl_id {
                return fd
            }
        }
        return nil
    }

    /// Returns a KratonSecure version.
    class var backendVersion: String {
        guard let ver = kratonVersion() else { return "unknown" }
        let str = String(cString: ver)
        free(UnsafeMutableRawPointer(mutating: ver))
        return str
    }

    /// Returns the tunnel device interface name, or nil on error.
    /// - Returns: String.
    public var interfaceName: String? {
        guard let tunnelFileDescriptor = self.tunnelFileDescriptor else { return nil }

        var buffer = [UInt8](repeating: 0, count: Int(IFNAMSIZ))

        return buffer.withUnsafeMutableBufferPointer { mutableBufferPointer in
            guard let baseAddress = mutableBufferPointer.baseAddress else { return nil }

            var ifnameSize = socklen_t(IFNAMSIZ)
            let result = getsockopt(
                tunnelFileDescriptor,
                2 /* SYSPROTO_CONTROL */,
                2 /* UTUN_OPT_IFNAME */,
                baseAddress,
                &ifnameSize)

            if result == 0 {
                return String(cString: baseAddress)
            } else {
                return nil
            }
        }
    }

    // MARK: - Initialization

    /// Designated initializer.
    /// - Parameter packetTunnelProvider: an instance of `NEPacketTunnelProvider`. Internally stored
    ///   as a weak reference.
    /// - Parameter logHandler: a log handler closure.
    public init(with packetTunnelProvider: NEPacketTunnelProvider, logHandler: @escaping LogHandler) {
        self.packetTunnelProvider = packetTunnelProvider
        self.logHandler = logHandler

        setupLogHandler()
    }

    deinit {
        // Force remove logger to make sure that no further calls to the instance of this class
        // can happen after deallocation.
        kratonSetLogger(nil, nil)

        // Cancel network monitor
        networkMonitor?.cancel()

        // Shutdown the tunnel
        if case .connected(let handle, _, _) = self.state {
            kratonTurnOff(handle)
        }
    }

    // MARK: - Public methods

    /// Returns a runtime configuration from KratonSecure.
    /// - Parameter completionHandler: completion handler.
    public func getRuntimeConfiguration(completionHandler: @escaping (String?) -> Void) {
        workQueue.async {
            guard case .connected(let handle, _, _) = self.state else {
                completionHandler(nil)
                return
            }

            if let settings = kratonGetConfig(handle) {
                completionHandler(String(cString: settings))
                free(settings)
            } else {
                completionHandler(nil)
            }
        }
    }

    /// Start the tunnel tunnel.
    /// - Parameters:
    ///   - tunnelConfiguration: tunnel configuration.
    ///   - completionHandler: completion handler.
    public func start(tunnelConfiguration: KratonTunnelConfig, completionHandler: @escaping (KratonSecureConnectionError?) -> Void) {
        workQueue.async {
            guard case .stopped = self.state else {
                completionHandler(.invalidConnectionState)
                return
            }

            let networkMonitor = NWPathMonitor()
            networkMonitor.pathUpdateHandler = { [weak self] path in
                self?.didReceivePathUpdate(path: path)
            }
            networkMonitor.start(queue: self.workQueue)

            do {
                let settingsGenerator = try self.makeSettingsGenerator(with: tunnelConfiguration)
                
                // Enhanced state tracking
                self.state = .initializing(settingsGenerator)
                self.logHandler(.info, "Kraton connection initializing...")
                
                try self.setNetworkSettings(settingsGenerator.generateNetworkSettings())

                let (wgConfig, resolutionResults) = settingsGenerator.uapiConfiguration()
                self.logEndpointResolutionResults(resolutionResults)

                let handle = try self.startKratonSecureBackend(wgConfig: wgConfig)
                self.state = .connected(handle, settingsGenerator, Date())
                
                self.logHandler(.info, "Kraton connection established successfully - State: \(self.state.description)")
                self.networkMonitor = networkMonitor
                completionHandler(nil)
            } catch let error as KratonSecureConnectionError {
                networkMonitor.cancel()
                completionHandler(error)
            } catch {
                fatalError()
            }
        }
    }

    /// Stop the tunnel with enhanced state management.
    /// - Parameter completionHandler: completion handler.
    public func stop(completionHandler: @escaping (KratonSecureConnectionError?) -> Void) {
        workQueue.async {
            self.logHandler(.info, "Stopping Kraton connection - Current state: \(self.state.description)")
            
            switch self.state {
            case .connected(let handle, _, let connectionTime):
                let duration = Date().timeIntervalSince(connectionTime)
                self.logHandler(.info, "Terminating connection after \(String(format: "%.2f", duration)) seconds")
                kratonTurnOff(handle)

            case .suspended, .recovering, .initializing:
                self.logHandler(.info, "Stopping from intermediate state")
                break

            case .stopped:
                self.logHandler(.warning, "Attempted to stop already stopped connection")
                completionHandler(.invalidConnectionState)
                return
            }

            self.networkMonitor?.cancel()
            self.networkMonitor = nil

            self.state = .stopped
            self.logHandler(.info, "Kraton connection stopped successfully")

            completionHandler(nil)
        }
    }

    /// Update runtime configuration.
    /// - Parameters:
    ///   - tunnelConfiguration: tunnel configuration.
    ///   - completionHandler: completion handler.
    public func update(tunnelConfiguration: KratonTunnelConfig, completionHandler: @escaping (KratonSecureConnectionError?) -> Void) {
        workQueue.async {
            if case .stopped = self.state {
                completionHandler(.invalidConnectionState)
                return
            }

            // Tell the system that the tunnel is going to reconnect using new KratonSecure
            // configuration.
            // This will broadcast the `NEVPNStatusDidChange` notification to the GUI process.
            self.packetTunnelProvider?.reasserting = true
            defer {
                self.packetTunnelProvider?.reasserting = false
            }

            do {
                let settingsGenerator = try self.makeSettingsGenerator(with: tunnelConfiguration)
                try self.setNetworkSettings(settingsGenerator.generateNetworkSettings())

                switch self.state {
                case .connected(let handle, _, let connectionTime):
                    let (wgConfig, resolutionResults) = settingsGenerator.uapiConfiguration()
                    self.logEndpointResolutionResults(resolutionResults)

                    kratonSetConfig(handle, wgConfig)
                    #if os(iOS)
                    kratonDisableSomeRoamingForBrokenMobileSemantics(handle)
                    #endif

                    self.state = .connected(handle, settingsGenerator, connectionTime)

                case .suspended:
                    self.state = .suspended(settingsGenerator, Date())

                case .stopped:
                    fatalError()
                
                default:
                    // Handle other states appropriately
                    break
                }

                completionHandler(nil)
            } catch let error as KratonSecureConnectionError {
                completionHandler(error)
            } catch {
                fatalError()
            }
        }
    }

    // MARK: - Private methods

    /// Setup KratonSecure enhanced log handler with custom formatting.
    private func setupLogHandler() {
        let context = Unmanaged.passUnretained(self).toOpaque()
        kratonSetLogger(context) { context, logLevel, message in
            guard let context = context, let message = message else { return }

            let unretainedSelf = Unmanaged<KratonSecureAdapter>.fromOpaque(context)
                .takeUnretainedValue()

            let rawMessage = String(cString: message).trimmingCharacters(in: .newlines)
            let tunnelLogLevel = KratonSecureLogLevel(rawValue: logLevel) ?? .debug
            
            // Enhanced logging with timestamp and categorization
            let timestamp = DateFormatter.kratonLogFormatter.string(from: Date())
            let processedMessage = "[\(timestamp)] \(tunnelLogLevel.description) KratonSecure: \(rawMessage)"

            unretainedSelf.logHandler(tunnelLogLevel, processedMessage)
        }
    }

    /// Set network tunnel configuration.
    /// This method ensures that the call to `setTunnelNetworkSettings` does not time out, as in
    /// certain scenarios the completion handler given to it may not be invoked by the system.
    ///
    /// - Parameters:
    ///   - networkSettings: an instance of type `NEPacketTunnelNetworkSettings`.
    /// - Throws: an error of type `KratonSecureConnectionError`.
    /// - Returns: `PacketTunnelSettingsGenerator`.
    private func setNetworkSettings(_ networkSettings: NEPacketTunnelNetworkSettings) throws {
        var systemError: Error?
        let condition = NSCondition()

        // Activate the condition
        condition.lock()
        defer { condition.unlock() }

        self.packetTunnelProvider?.setTunnelNetworkSettings(networkSettings) { error in
            systemError = error
            condition.signal()
        }

        // Packet tunnel's `setTunnelNetworkSettings` times out in certain
        // scenarios & never calls the given callback.
        let setTunnelNetworkSettingsTimeout: TimeInterval = 5 // seconds

        if condition.wait(until: Date().addingTimeInterval(setTunnelNetworkSettingsTimeout)) {
            if let systemError = systemError {
                throw KratonSecureConnectionError.networkConfigurationFailed(systemError)
            }
        } else {
            self.logHandler(.error, "setTunnelNetworkSettings timed out after 5 seconds; proceeding anyway")
        }
    }

    /// Resolve peers of the given tunnel configuration.
    /// - Parameter tunnelConfiguration: tunnel configuration.
    /// - Throws: an error of type `KratonSecureConnectionError`.
    /// - Returns: The list of resolved endpoints.
    private func resolvePeers(for tunnelConfiguration: KratonTunnelConfig) throws -> [KratonEndpoint?] {
        let endpoints = tunnelConfiguration.peers.map { $0.endpoint }
        let resolutionResults = DNSResolver.resolveSync(endpoints: endpoints)
        let resolutionErrors = resolutionResults.compactMap { result -> EndpointResolutionError? in
            if case .failure(let error) = result {
                return error
            } else {
                return nil
            }
        }
        assert(endpoints.count == resolutionResults.count)
        guard resolutionErrors.isEmpty else {
            throw KratonSecureConnectionError.endpointResolutionFailed(resolutionErrors)
        }

        let resolvedEndpoints = resolutionResults.map { result -> KratonEndpoint? in
            // swiftlint:disable:next force_try
            return try! result?.get()
        }

        return resolvedEndpoints
    }

    /// Start KratonSecure backend.
    /// - Parameter wgConfig: KratonSecure configuration
    /// - Throws: an error of type `KratonSecureConnectionError`
    /// - Returns: tunnel handle
    private func startKratonSecureBackend(wgConfig: String) throws -> Int32 {
        guard let tunnelFileDescriptor = self.tunnelFileDescriptor else {
            throw KratonSecureConnectionError.tunnelDescriptorNotFound
        }

        let handle = kratonTurnOn(wgConfig, tunnelFileDescriptor)
        if handle < 0 {
                            throw KratonSecureConnectionError.backendInitializationFailed(handle)
        }
        #if os(iOS)
        kratonDisableSomeRoamingForBrokenMobileSemantics(handle)
        #endif
        return handle
    }

    /// Resolves the hostnames in the given tunnel configuration and return settings generator.
    /// - Parameter tunnelConfiguration: an instance of type `KratonTunnelConfig`.
    /// - Throws: an error of type `KratonSecureConnectionError`.
    /// - Returns: an instance of type `PacketTunnelSettingsGenerator`.
    private func makeSettingsGenerator(with tunnelConfiguration: KratonTunnelConfig) throws -> PacketTunnelSettingsGenerator {
        return PacketTunnelSettingsGenerator(
            tunnelConfiguration: tunnelConfiguration,
            resolvedEndpoints: try self.resolvePeers(for: tunnelConfiguration)
        )
    }

    /// Log DNS resolution results.
    /// - Parameter resolutionErrors: an array of type `[DNSResolutionError]`.
    private func logEndpointResolutionResults(_ resolutionResults: [EndpointResolutionResult?]) {
        for case .some(let result) in resolutionResults {
            switch result {
            case .success((let sourceEndpoint, let resolvedEndpoint)):
                if sourceEndpoint.host == resolvedEndpoint.host {
                    self.logHandler(.verbose, "DNS64: mapped \(sourceEndpoint.host) to itself.")
                } else {
                    self.logHandler(.verbose, "DNS64: mapped \(sourceEndpoint.host) to \(resolvedEndpoint.host)")
                }
            case .failure(let resolutionError):
                self.logHandler(.error, "Failed to resolve endpoint \(resolutionError.address): \(resolutionError.errorDescription ?? "(nil)")")
            }
        }
    }

    /// Helper method used by network path monitor.
    /// - Parameter path: new network path
    private func didReceivePathUpdate(path: Network.NWPath) {
        self.logHandler(.verbose, "Network change detected with \(path.status) route and interface order \(path.availableInterfaces)")

        #if os(macOS)
        if case .connected(let handle, _, _) = self.state {
            kratonBumpSockets(handle)
        }
        #elseif os(iOS)
        switch self.state {
        case .connected(let handle, let settingsGenerator, let connectionTime):
            if path.status.isSatisfiable {
                let (wgConfig, resolutionResults) = settingsGenerator.endpointUapiConfiguration()
                self.logEndpointResolutionResults(resolutionResults)

                kratonSetConfig(handle, wgConfig)
                kratonDisableSomeRoamingForBrokenMobileSemantics(handle)
                kratonBumpSockets(handle)
            } else {
                self.logHandler(.verbose, "Connectivity offline, pausing backend.")

                self.state = .suspended(settingsGenerator, Date())
                kratonTurnOff(handle)
            }

        case .suspended(let settingsGenerator, _):
            guard path.status.isSatisfiable else { return }

            self.logHandler(.verbose, "Connectivity online, resuming backend.")

            do {
                try self.setNetworkSettings(settingsGenerator.generateNetworkSettings())

                let (wgConfig, resolutionResults) = settingsGenerator.uapiConfiguration()
                self.logEndpointResolutionResults(resolutionResults)

                self.state = .connected(
                    try self.startKratonSecureBackend(wgConfig: wgConfig),
                    settingsGenerator,
                    Date()
                )
            } catch {
                self.logHandler(.error, "Failed to restart backend: \(error.localizedDescription)")
            }

        case .initializing(_):
            // During initialization, wait for the connection to be established
            self.logHandler(.debug, "Network change detected during initialization, ignoring.")
            
        case .recovering(let settingsGenerator, let retryCount):
            // During recovery, attempt to reconnect if network is available
            guard path.status.isSatisfiable else { return }
            
            self.logHandler(.info, "Network available during recovery, attempting reconnection (retry \(retryCount)).")
            
            do {
                try self.setNetworkSettings(settingsGenerator.generateNetworkSettings())
                
                let (wgConfig, resolutionResults) = settingsGenerator.uapiConfiguration()
                self.logEndpointResolutionResults(resolutionResults)
                
                self.state = .connected(
                    try self.startKratonSecureBackend(wgConfig: wgConfig),
                    settingsGenerator,
                    Date()
                )
            } catch {
                self.logHandler(.error, "Failed to recover connection: \(error.localizedDescription)")
                // Increment retry count and continue recovery
                self.state = .recovering(settingsGenerator, retryCount + 1)
            }

        case .stopped:
            // no-op
            break
        }
        #else
        #error("Unsupported")
        #endif
    }
}

/// A enum describing KratonSecure log levels with enhanced categorization.
public enum KratonSecureLogLevel: Int32, CaseIterable {
    case debug = 0
    case info = 1
    case warning = 2
    case error = 3
    case critical = 4
    
    // Legacy compatibility
    static var verbose: KratonSecureLogLevel { return .debug }
    
    var description: String {
        switch self {
        case .debug: return "🔍 DEBUG"
        case .info: return "ℹ️ INFO"
        case .warning: return "⚠️ WARNING"
        case .error: return "❌ ERROR"
        case .critical: return "🚨 CRITICAL"
        }
    }
}

private extension Network.NWPath.Status {
    /// Returns `true` if the path is potentially satisfiable.
    var isSatisfiable: Bool {
        switch self {
        case .requiresConnection, .satisfied:
            return true
        case .unsatisfied:
            return false
        @unknown default:
            return true
        }
    }
}

private extension DateFormatter {
    /// Custom date formatter for Kraton logging system
    static let kratonLogFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        formatter.timeZone = TimeZone.current
        return formatter
    }()
}
