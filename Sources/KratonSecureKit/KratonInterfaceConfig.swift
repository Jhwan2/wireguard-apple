// SPDX-License-Identifier: MIT
// Copyright © 2018-2023 Kraton AI Corporation. All Rights Reserved.

import Foundation
import Network

public struct KratonNetworkInterface {
    public var privateKey: KratonPrivateKey
    public var addresses = [IPAddressRange]()
    public var listenPort: UInt16?
    public var mtu: UInt16?
    public var dns = [DNSServer]()
    public var dnsSearch = [String]()

    public init(privateKey: KratonPrivateKey) {
        self.privateKey = privateKey
    }
}

extension KratonNetworkInterface: Equatable {
    public static func == (lhs: KratonNetworkInterface, rhs: KratonNetworkInterface) -> Bool {
        let lhsAddresses = lhs.addresses.filter { $0.address is IPv4Address } + lhs.addresses.filter { $0.address is IPv6Address }
        let rhsAddresses = rhs.addresses.filter { $0.address is IPv4Address } + rhs.addresses.filter { $0.address is IPv6Address }

        return lhs.privateKey == rhs.privateKey &&
            lhsAddresses == rhsAddresses &&
            lhs.listenPort == rhs.listenPort &&
            lhs.mtu == rhs.mtu &&
            lhs.dns == rhs.dns &&
            lhs.dnsSearch == rhs.dnsSearch
    }
}
