#if DEBUG
import Foundation
import SwiftData

/// Seeds a deterministic restore document so the restore machinery's *wiring*
/// can be driven from a UI test.
///
/// The decisions restore makes are the shared core's and are already pinned by
/// `ForegroundRestoreCohortTests`. What has never been covered on iOS is the
/// layer above — the guard order, the latch, which lifecycle edge writes what —
/// and it cannot be reached from a unit test: that state is SwiftUI `@State` on
/// `ContentView`, so there is nothing a test can construct and drive. Widening
/// `private` would not help. A UI test can drive it, and this is what gives one
/// a known starting point.
///
/// **Offline by construction.** Fixture hosts point at a closed loopback port,
/// so a restore reconnect refuses immediately: no DNS, no network, and no
/// connection to anything the user owns.
///
/// Drive it with `scripts/uitest/run-restore-lifecycle-gate.sh`; the cases live
/// in `TesseraUITests/SessionRestoreLifecycleProbe.swift`.
struct SessionRestoreHarnessConfiguration: Codable {
    /// Names this run in the log so one report can carry several cases.
    var caseName: String
    /// Whether this launch seeds at all. A relaunch case needs the second
    /// launch to find what the first one left, so it passes `false`.
    var seedsFixtures: Bool
    /// How many fixture hosts to seed, each with a stored session.
    var hostCount: Int
    /// Snapshots naming hosts this device does not have. One unrestorable
    /// entry must not condemn the rest of the document.
    var orphanSnapshotCount: Int
    /// Whether to leave a restore document behind for the launch to find.
    var seedsDocument: Bool
    /// Fixture hosts to hand the first composition as already open, before
    /// restore evaluates — the share-target / notification-tap / continuity-
    /// handoff shape. Optional so an older encoded payload still decodes.
    ///
    /// The live session deliberately carries its own id rather than the
    /// snapshot's: that is what a launch which opens a host actually produces,
    /// and it is why matching on session id cannot see it.
    var preopensHostCount: Int?

    static let environmentKey = "TESSERA_RESTORE_HARNESS"

    static func load() -> Self? {
        guard let raw = ProcessInfo.processInfo.environment[environmentKey],
              let data = Data(base64Encoded: raw)
        else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }
}

enum SessionRestoreDebugHarness {
    static let hostAddress = "127.0.0.1"
    static let hostPort = 1
    static let namePrefix = "restore-fixture-"

    private static let configuration = SessionRestoreHarnessConfiguration.load()

    static var isActive: Bool { configuration != nil }

    /// Sessions the first composition should start with. Read by
    /// `TesseraApp.mainContent` and handed to `ContentView`'s debug seam, so
    /// `attemptStartupRestoreIfReady` sees them the way it would see a host
    /// opened by a share target.
    @MainActor private(set) static var preopenedSessions: [LiveSession] = []

    /// Mirror a restore diagnostic to the system log.
    ///
    /// A UI test runs out of process and cannot read the app container, so the
    /// report it would otherwise assert against is out of reach. `log show` is
    /// how everything else host-free in this repo is verified, so the harness
    /// puts the same lines there and the runner script reads them.
    static func mirror(_ message: String) {
        guard isActive else { return }
        NSLog("[Tessera][RestoreDiag] %@", message)
    }

    static func note(_ message: String) {
        guard let configuration else { return }
        NSLog("[Tessera][RestoreHarness] case=%@ %@", configuration.caseName, message)
    }

    /// Wipe anything a previous case left, then seed this one.
    ///
    /// Runs before the first composition so `attemptStartupRestoreIfReady` sees
    /// a settled world rather than one being built underneath it.
    @MainActor
    static func applyIfRequested(into container: ModelContainer) {
        guard let configuration else { return }
        guard configuration.seedsFixtures else {
            note("reusing what the previous launch left")
            return
        }
        let context = container.mainContext
        let store = SessionRestoreStore()
        store.clear()
        removeFixtures(from: context)

        guard configuration.hostCount > 0 else {
            note("seeded hosts=0 document=none")
            return
        }

        var snapshots: [SessionRestoreSnapshot] = []
        var seeded: [PersistedHost] = []
        for index in 0..<configuration.hostCount {
            let identity = Identity(
                name: "\(namePrefix)identity-\(index)",
                user: "fixture",
                credentialMode: .password
            )
            // Restore refuses a host whose credentials are gone, so the fixture
            // needs real material: `SessionRestoreEligibility` rejects
            // `.none` outright and that would make every case vacuous.
            try? KeychainHelper.setPassword("fixture", forIdentityID: identity.id)
            let host = PersistedHost(
                name: "\(namePrefix)\(index)",
                address: hostAddress,
                port: hostPort,
                autoTmux: false,
                transport: .ssh,
                launchMode: .customCommand,
                launchCommand: "true",
                identity: identity
            )
            context.insert(identity)
            context.insert(host)
            seeded.append(host)
            snapshots.append(
                SessionRestoreSnapshot(
                    liveSessionID: UUID(),
                    persistedHostID: host.id,
                    displayName: host.name,
                    createdAt: Date(),
                    effectiveLaunchMode: .customCommand
                )
            )
        }
        try? context.save()

        preopenedSessions = seeded
            .prefix(max(0, configuration.preopensHostCount ?? 0))
            .map { host in
                let target = Host(
                    id: host.id,
                    name: host.name,
                    address: hostAddress,
                    port: hostPort,
                    user: "fixture",
                    autoTmux: false,
                    launchMode: .customCommand,
                    launchCommand: "true"
                )
                return LiveSession(
                    session: .ssh(SSHSession(host: target)),
                    hostName: host.name,
                    persistedHostID: host.id,
                    hostKey: "ssh:fixture@\(hostAddress):\(hostPort)",
                    launchMode: .customCommand
                )
            }
        if !preopenedSessions.isEmpty {
            note("preopened hosts=\(preopenedSessions.count)")
        }

        for index in 0..<max(0, configuration.orphanSnapshotCount) {
            snapshots.append(
                SessionRestoreSnapshot(
                    liveSessionID: UUID(),
                    persistedHostID: UUID(),
                    displayName: "\(namePrefix)orphan-\(index)",
                    createdAt: Date(),
                    effectiveLaunchMode: .customCommand
                )
            )
        }

        if configuration.seedsDocument {
            store.save(
                sessions: snapshots,
                selectedSessionID: snapshots.first?.liveSessionID
            )
        }
        note("seeded hosts=\(configuration.hostCount) orphans=\(configuration.orphanSnapshotCount) document=\(configuration.seedsDocument)")
    }

    @MainActor
    private static func removeFixtures(from context: ModelContext) {
        let hosts = (try? context.fetch(FetchDescriptor<PersistedHost>())) ?? []
        for host in hosts where host.name.hasPrefix(namePrefix) {
            if let identity = host.identity {
                _ = try? KeychainHelper.deletePassword(forIdentityID: identity.id)
                context.delete(identity)
            }
            context.delete(host)
        }
        try? context.save()
    }
}
#endif
