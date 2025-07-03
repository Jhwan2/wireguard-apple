// SPDX-License-Identifier: MIT
// Copyright © 2018-2023 Kraton AI Corporation. All Rights Reserved.

import Foundation

public struct KratonSecurePeer {
    public var publicKey: KratonPublicKey
    public var preSharedKey: KratonPreSharedKey?
    public var allowedIPs = [IPAddressRange]()
    public var endpoint: KratonEndpoint?
    public var persistentKeepAlive: UInt16?
    public var rxBytes: UInt64?
    public var txBytes: UInt64?
    public var lastHandshakeTime: Date?

    public init(publicKey: KratonPublicKey) {
        self.publicKey = publicKey
    }
}

extension KratonSecurePeer: Equatable {
    public static func == (lhs: KratonSecurePeer, rhs: KratonSecurePeer) -> Bool {
        return lhs.publicKey == rhs.publicKey &&
            lhs.preSharedKey == rhs.preSharedKey &&
            Set(lhs.allowedIPs) == Set(rhs.allowedIPs) &&
            lhs.endpoint == rhs.endpoint &&
            lhs.persistentKeepAlive == rhs.persistentKeepAlive
    }
}

extension KratonSecurePeer: Hashable {
    public func hash(into hasher: inout Hasher) {
        hasher.combine(publicKey)
        hasher.combine(preSharedKey)
        hasher.combine(Set(allowedIPs))
        hasher.combine(endpoint)
        hasher.combine(persistentKeepAlive)

    }
}
