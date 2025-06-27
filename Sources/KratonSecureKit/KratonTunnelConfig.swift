// SPDX-License-Identifier: MIT
// Copyright © 2018-2023 Kraton AI Corporation. All Rights Reserved.

import Foundation

public final class KratonTunnelConfig {
    public var name: String?
    public var interface: KratonInterfaceConfig
    public let peers: [KratonPeerConfig]

    public init(name: String?, interface: KratonInterfaceConfig, peers: [KratonPeerConfig]) {
        self.interface = interface
        self.peers = peers
        self.name = name

        let peerPublicKeysArray = peers.map { $0.publicKey }
        let peerPublicKeysSet = Set<KratonPublicKey>(peerPublicKeysArray)
        if peerPublicKeysArray.count != peerPublicKeysSet.count {
            fatalError("Two or more peers cannot have the same public key")
        }
    }
}

extension KratonTunnelConfig: Equatable {
    public static func == (lhs: KratonTunnelConfig, rhs: KratonTunnelConfig) -> Bool {
        return lhs.name == rhs.name &&
            lhs.interface == rhs.interface &&
            Set(lhs.peers) == Set(rhs.peers)
    }
}
