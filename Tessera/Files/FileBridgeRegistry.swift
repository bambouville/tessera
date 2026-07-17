// Tessera/Files/FileBridgeRegistry.swift
// Remote Files feature - bridge registry.
// Contracts: Tessera/Files/FilesContracts.swift

import Foundation
import Observation

@MainActor
@Observable
final class FileBridgeRegistry {
    private(set) var bridges: [FileBridgeKey: FileBridge] = [:]
    /// One transfer queue per bridge (host endpoint), shared by every
    /// session's panel to that host — transfers ride the bridge, so
    /// their queue has the bridge's lifetime, not a session's.
    @ObservationIgnored private var transferQueues: [FileBridgeKey: TransferQueue] = [:]

    func transferQueue(for bridge: FileBridge) -> TransferQueue {
        if let queue = transferQueues[bridge.key] { return queue }
        let queue = TransferQueue(bridge: bridge)
        transferQueues[bridge.key] = queue
        return queue
    }

    /// The bridge key deliberately strips terminal transport: SSH and mosh
    /// sessions for the same managed host + route share one SFTP bridge.
    func bridge(
        for host: Host,
        requireBiometric: Bool,
        isSecureEnclave: Bool
    ) -> FileBridge {
        let key = FileBridgeKey(host: host)
        if let bridge = bridges[key] {
            // Host freezes credentials at construction — refresh the
            // cached bridge's snapshot so a rotated password/key or a
            // changed biometric flag is used on its next connect.
            bridge.updateCredentials(
                host: host,
                requireBiometric: requireBiometric,
                isSecureEnclave: isSecureEnclave
            )
            return bridge
        }

        let bridge = FileBridge(
            host: host,
            requireBiometric: requireBiometric,
            isSecureEnclave: isSecureEnclave
        )
        bridges[key] = bridge
        return bridge
    }

    func release(_ key: FileBridgeKey) async {
        transferQueues.removeValue(forKey: key)
        guard let bridge = bridges.removeValue(forKey: key) else {
            return
        }
        await bridge.disconnect()
    }

    func disconnectAll() async {
        let activeBridges = Array(bridges.values)
        bridges.removeAll()
        transferQueues.removeAll()
        for bridge in activeBridges {
            await bridge.disconnect()
        }
    }
}
