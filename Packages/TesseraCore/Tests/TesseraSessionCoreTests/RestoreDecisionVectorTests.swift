import XCTest
@testable import TesseraSessionCore

/// Pins `ProtocolVectors/session/v1/restore-decisions.json` to the core.
///
/// The vectors exist for the other side of the ABI: Android reaches these same
/// decisions over JNI, where seconds become milliseconds, enums become wire
/// strings, an absent optional becomes a missing key rather than a null, and
/// `-1` means three different things. None of that is visible from a Swift
/// test, and a JVM test cannot reach the core at all — it cannot dlopen it. So
/// the expectations are written down once, here against the authority and on
/// the device against the bridge, and a rule that changes on one side without
/// the other fails on both.
///
/// This file is therefore not a second opinion about the rules. If a rule
/// legitimately changes, the vector file changes with it and the Android test
/// picks the change up automatically.
final class RestoreDecisionVectorTests: XCTestCase {
    private static let hostA = UUID(uuidString: "aaaaaaaa-1111-4111-8111-cafebabe1111")!
    private static let hostB = UUID(uuidString: "bbbbbbbb-2222-4222-8222-cafebabe2222")!

    private func host(_ symbol: String?) -> UUID? {
        switch symbol {
        case "A": return Self.hostA
        case "B": return Self.hostB
        default: return nil
        }
    }

    func test_verdictVectorsMatchTheCore() throws {
        for vector in try load().verdict {
            let candidate = ForegroundRestoreCandidate(
                liveSessionID: UUID(),
                persistedHostID: host(vector.candidateHost)
            )
            let live = vector.live.map {
                ForegroundRestoreLiveState(
                    liveSessionID: candidate.liveSessionID,
                    persistedHostID: host($0.host),
                    state: RestoreLiveState(rawValue: $0.state)!,
                    transportConfirmed: $0.transportConfirmed
                )
            }
            XCTAssertEqual(
                ForegroundRestoreCohort.verdict(
                    for: candidate,
                    live: live,
                    elapsedSinceWindowOpened: vector.elapsedSeconds,
                    aliveFloorSeconds: vector.aliveFloorSeconds
                ).rawValue,
                vector.expected,
                vector.name
            )
        }
    }

    func test_windowClosureVectorsMatchTheCore() throws {
        for vector in try load().windowClosure {
            XCTAssertEqual(
                ForegroundRestoreCohort.windowClosure(
                    remainingCohortCount: vector.remainingCohortCount,
                    elapsedSinceWindowOpened: vector.elapsedSeconds,
                    maxWindowSeconds: vector.maxWindowSeconds,
                    hasUnansweredPrompt: vector.hasUnansweredPrompt
                ).rawValue,
                vector.expected,
                vector.name
            )
        }
    }

    func test_chargeDeltaVectorsMatchTheCore() throws {
        for vector in try load().chargeDelta {
            XCTAssertEqual(
                ForegroundRestoreCohort.chargeDelta(
                    nowSeconds: vector.nowSeconds,
                    lastChargeAtSeconds: vector.lastChargeAtSeconds,
                    isPrompting: vector.isPrompting,
                    maxTickSeconds: vector.maxTickSeconds
                ),
                vector.expected,
                accuracy: 0.0001,
                vector.name
            )
        }
    }

    func test_persistModeVectorsMatchTheCore() throws {
        for vector in try load().persistMode {
            XCTAssertEqual(
                ForegroundRestoreCohort.persistMode(
                    isActive: vector.isActive,
                    hasPreservedSnapshots: vector.hasPreservedSnapshots,
                    isWindowOpen: vector.isWindowOpen,
                    hasCohortEntries: vector.hasCohortEntries
                ).rawValue,
                vector.expected,
                vector.name
            )
        }
    }

    func test_startupActionVectorsMatchTheCore() throws {
        for vector in try load().startupAction {
            let sessions = Self.sessionIdentifiers(for: vector)
            let action = ForegroundRestoreStartup.action(
                candidates: vector.candidates.map {
                    ForegroundRestoreStartupCandidate(
                        sessionID: sessions[$0.session]!,
                        hostID: host($0.host)!
                    )
                },
                hasDocument: vector.hasDocument,
                hostsLoaded: vector.hostsLoaded,
                availableHostIDs: Set(vector.availableHosts.compactMap { host($0) }),
                liveHostIDs: Set(vector.liveHosts.compactMap { host($0) }),
                selectedSessionID: vector.selectedSession.flatMap { sessions[$0] },
                policy: ForegroundRestorePolicy(rawValue: vector.policy)!
            )
            let expected = vector.expected
            switch action {
            case let .wait(reason):
                XCTAssertEqual("wait", expected.action, vector.name)
                XCTAssertEqual(reason.rawValue, expected.reason, vector.name)
            case let .skip(reason):
                XCTAssertEqual("skip", expected.action, vector.name)
                XCTAssertEqual(reason.rawValue, expected.reason, vector.name)
            case let .restore(plan):
                XCTAssertEqual("restore", expected.action, vector.name)
                assert(plan, matches: expected, sessions: sessions, vector.name)
            case let .offer(plan):
                XCTAssertEqual("offer", expected.action, vector.name)
                assert(plan, matches: expected, sessions: sessions, vector.name)
            }
        }
    }

    func test_effectivePolicyVectorsMatchTheCore() throws {
        for vector in try load().effectivePolicy {
            XCTAssertEqual(
                ForegroundRestorePresentation.effectivePolicy(
                    stored: ForegroundRestorePolicy(rawValue: vector.stored)!,
                    usesCompactShell: vector.usesCompactShell
                ).rawValue,
                vector.expected,
                vector.name
            )
        }
    }

    func test_persistPlanVectorsMatchTheCore() throws {
        for vector in try load().persistPlan {
            let sessions = Self.sessionIdentifiers(
                for: vector.current + vector.cohort + vector.stored
                    + [vector.preferredSelection, vector.storedSelection].compactMap { $0 }
                    + vector.expected.entries.map(\.session)
            )
            let mode = ForegroundRestoreCohort.PersistMode(rawValue: vector.mode)!
            let entries = ForegroundRestorePersistPlan.entries(
                mode: mode,
                currentSessionIDs: vector.current.map { sessions[$0]! },
                cohortSessionIDs: vector.cohort.map { sessions[$0]! },
                storedSessionIDs: vector.stored.map { sessions[$0]! },
                maxSnapshots: vector.maxSnapshots
            )
            XCTAssertEqual(
                entries.map { ($0.sessionID, $0.source.rawValue) }.map { "\($0.0) \($0.1)" },
                vector.expected.entries.map { "\(sessions[$0.session]!) \($0.source)" },
                vector.name
            )
            XCTAssertEqual(
                ForegroundRestorePersistPlan.selection(
                    mode: mode,
                    preferred: vector.preferredSelection.flatMap { sessions[$0] },
                    writtenSessionIDs: entries.map(\.sessionID),
                    storedSelection: vector.storedSelection.flatMap { sessions[$0] }
                ),
                vector.expected.selectedSession.flatMap { sessions[$0] },
                vector.name
            )
        }
    }

    private func assert(
        _ plan: ForegroundRestoreStartupPlan,
        matches expected: RestoreDecisionVectors.StartupAction.Expected,
        sessions: [String: UUID],
        _ name: String
    ) {
        XCTAssertEqual(plan.sessionIDs, (expected.sessions ?? []).map { sessions[$0]! }, name)
        XCTAssertEqual(plan.selectedSessionID, expected.selectedSession.flatMap { sessions[$0] }, name)
        XCTAssertEqual(plan.skippedCount, expected.skippedCount ?? 0, name)
    }

    /// Symbolic session names get fixed identifiers, so a vector that states an
    /// order is testing the order and not a dictionary's.
    private static func sessionIdentifiers(for vector: RestoreDecisionVectors.StartupAction) -> [String: UUID] {
        sessionIdentifiers(
            for: vector.candidates.map(\.session)
                + [vector.selectedSession].compactMap { $0 }
                + (vector.expected.sessions ?? [])
        )
    }

    private static func sessionIdentifiers(for names: [String]) -> [String: UUID] {
        var identifiers: [String: UUID] = [:]
        for name in names where identifiers[name] == nil {
            // Deliberately lower case, with hex letters: identifiers make the
            // round trip through Swift's `UUID`, which re-renders in UPPER
            // case, and a platform that compares the answer with its own
            // stored spelling silently matches nothing. All-digit ids cannot
            // show that.
            identifiers[name] = UUID(
                uuidString: "abcdef0\(identifiers.count)-dead-4bee-8fad-0123456789ab"
            )!
        }
        return identifiers
    }

    /// Every rule the vectors state must still exist. A rule quietly deleted
    /// from the file would otherwise pass by being absent.
    func test_theVectorFileCoversEveryDecision() throws {
        let vectors = try load()
        XCTAssertEqual(vectors.version, 1)
        XCTAssertGreaterThanOrEqual(vectors.verdict.count, ForegroundRestoreVerdict.allCases.count)
        XCTAssertGreaterThanOrEqual(
            vectors.windowClosure.count,
            ForegroundRestoreCohort.WindowClosure.allCases.count
        )
        XCTAssertGreaterThanOrEqual(
            vectors.persistMode.count,
            ForegroundRestoreCohort.PersistMode.allCases.count
        )
        for verdict in ForegroundRestoreVerdict.allCases {
            XCTAssertTrue(
                vectors.verdict.contains { $0.expected == verdict.rawValue },
                "no vector produces the verdict \(verdict.rawValue)"
            )
        }
        for mode in ForegroundRestoreCohort.PersistMode.allCases {
            XCTAssertTrue(
                vectors.persistMode.contains { $0.expected == mode.rawValue },
                "no vector produces the persist mode \(mode.rawValue)"
            )
        }
        for closure in ForegroundRestoreCohort.WindowClosure.allCases {
            XCTAssertTrue(
                vectors.windowClosure.contains { $0.expected == closure.rawValue },
                "no vector produces the closure \(closure.rawValue)"
            )
        }
        for reason in ForegroundRestoreStartupAction.Reason.allCases {
            XCTAssertTrue(
                vectors.startupAction.contains { $0.expected.reason == reason.rawValue },
                "no vector produces the startup reason \(reason.rawValue)"
            )
        }
        for action in ["wait", "skip", "restore", "offer"] {
            XCTAssertTrue(
                vectors.startupAction.contains { $0.expected.action == action },
                "no vector produces the startup action \(action)"
            )
        }
        for policy in ForegroundRestorePolicy.allCases {
            XCTAssertTrue(
                vectors.effectivePolicy.contains { $0.expected == policy.rawValue },
                "no vector produces the effective policy \(policy.rawValue)"
            )
        }
        for source in ForegroundRestorePersistSource.allCases {
            XCTAssertTrue(
                vectors.persistPlan.contains { plan in
                    plan.expected.entries.contains { $0.source == source.rawValue }
                },
                "no vector writes an entry from \(source.rawValue)"
            )
        }
    }

    private func load() throws -> RestoreDecisionVectors {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { root.deleteLastPathComponent() }
        let url = root.appendingPathComponent("ProtocolVectors/session/v1/restore-decisions.json")
        return try JSONDecoder().decode(
            RestoreDecisionVectors.self,
            from: Data(contentsOf: url)
        )
    }
}

private struct RestoreDecisionVectors: Decodable {
    let version: Int
    let verdict: [Verdict]
    let windowClosure: [WindowClosure]
    let chargeDelta: [ChargeDelta]
    let persistMode: [PersistMode]
    let startupAction: [StartupAction]
    let effectivePolicy: [EffectivePolicy]
    let persistPlan: [PersistPlan]

    struct Verdict: Decodable {
        let name: String
        let candidateHost: String?
        let live: Live?
        let elapsedSeconds: TimeInterval
        let aliveFloorSeconds: TimeInterval
        let expected: String

        struct Live: Decodable {
            let host: String?
            let state: String
            let transportConfirmed: Bool?
        }
    }

    struct WindowClosure: Decodable {
        let name: String
        let remainingCohortCount: Int
        let elapsedSeconds: TimeInterval
        let maxWindowSeconds: TimeInterval
        let hasUnansweredPrompt: Bool
        let expected: String
    }

    struct ChargeDelta: Decodable {
        let name: String
        let nowSeconds: TimeInterval
        let lastChargeAtSeconds: TimeInterval?
        let isPrompting: Bool
        let maxTickSeconds: TimeInterval
        let expected: TimeInterval
    }

    struct PersistMode: Decodable {
        let name: String
        let isActive: Bool
        let hasPreservedSnapshots: Bool
        let isWindowOpen: Bool
        let hasCohortEntries: Bool
        let expected: String
    }

    struct StartupAction: Decodable {
        let name: String
        let candidates: [Candidate]
        let hasDocument: Bool
        let hostsLoaded: Bool
        let availableHosts: [String]
        let liveHosts: [String]
        let selectedSession: String?
        let policy: String
        let expected: Expected

        struct Candidate: Decodable {
            let session: String
            let host: String
        }

        struct Expected: Decodable {
            let action: String
            let reason: String?
            let sessions: [String]?
            let selectedSession: String?
            let skippedCount: Int?
        }
    }

    struct EffectivePolicy: Decodable {
        let name: String
        let stored: String
        let usesCompactShell: Bool
        let expected: String
    }

    struct PersistPlan: Decodable {
        let name: String
        let mode: String
        let current: [String]
        let cohort: [String]
        let stored: [String]
        let preferredSelection: String?
        let storedSelection: String?
        let maxSnapshots: Int
        let expected: Expected

        struct Expected: Decodable {
            let entries: [Entry]
            let selectedSession: String?

            struct Entry: Decodable {
                let session: String
                let source: String
            }
        }
    }
}
