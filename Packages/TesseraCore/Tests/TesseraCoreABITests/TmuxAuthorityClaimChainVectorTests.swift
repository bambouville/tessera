import Foundation
import XCTest
import TmuxControlCore

/// `ProtocolVectors/tmux/authority-claim-chain-v1.json` is the bare reducer's
/// conformance record. Its version labels the vector format, not a live ABI.
/// These cases exercise `TmuxGridAuthorityLifecycleReducer` directly; Android
/// exercises the reducer inside the version 2 session instead.
///
/// After a reducer change, regenerate the file and commit it with the change:
///
///     TESSERA_REGENERATE_AUTHORITY_VECTORS=1 swift test \
///         --package-path Packages/TesseraCore \
///         --filter TmuxAuthorityClaimChainVectorTests
final class TmuxAuthorityClaimChainVectorTests: XCTestCase {
    func testTheCheckedInVectorsAreTheReducersAnswers() throws {
        let generated = try generatedDocument()
        if ProcessInfo.processInfo.environment["TESSERA_REGENERATE_AUTHORITY_VECTORS"] == "1" {
            let data = try JSONSerialization.data(
                withJSONObject: generated,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            )
            try (data + Data("\n".utf8)).write(to: Self.vectorURL)
            return
        }
        let checkedIn = try Self.checkedInDocument()
        XCTAssertEqual(
            NSDictionary(dictionary: generated),
            NSDictionary(dictionary: checkedIn),
            "the vectors drifted from the reducer; regenerate them (see the class comment)"
        )
    }

    // MARK: - Cases

    private static let ipad: [String: Any] = [
        "authorityKind": "peer", "authorityDeviceID": "ipad",
        "authorityDisplayName": "iPad", "authorityGeneration": 4,
    ]

    private static func peer(_ deviceID: String, _ displayName: String, _ generation: Int) -> [String: Any] {
        [
            "authorityKind": "peer", "authorityDeviceID": deviceID,
            "authorityDisplayName": displayName, "authorityGeneration": generation,
        ]
    }

    private static func event(_ name: String, generation: Int? = nil, _ fields: [String: Any] = [:]) -> [String: Any] {
        var request = fields
        request["version"] = 1
        request["event"] = name
        if let generation { request["generation"] = generation }
        return request
    }

    /// The claim's grid as the adapter advertised it (§6.10 rule 3).
    private static func advertised(_ columns: Int, _ rows: Int) -> [String: Any] {
        event("claimAdvertisedGeometry", generation: 1, ["columns": columns, "rows": rows])
    }

    /// The claimed window seen at `columns`×`rows`: a layout notification,
    /// or the settle probe's answer (§6.10 rule 5).
    private static func observed(_ columns: Int, _ rows: Int, probe: Bool = false) -> [String: Any] {
        var fields: [String: Any] = ["columns": columns, "rows": rows]
        if probe { fields["settleProbe"] = true }
        return event("claimObservedGeometry", generation: 1, fields)
    }

    /// Yielded to the iPad (stamp generation 4) and tapped: claim 1, a take-back contesting it.
    private static let tapSetup = [
        event("attached"),
        event("receivedAuthorityQuery", ipad.merging(["geometry": "foreignSize"]) { _, new in new }),
        event("requestTakeBack", ["channelLive": true]),
    ]

    /// Shown with no stamp on the session: claim 1, a show contesting nobody.
    private static let showSetup = [
        event("attached"),
        event("shown", ["source": "show"]),
        event("receivedAuthorityQuery", ["authorityKind": "unknown", "geometry": "unknown"]),
    ]

    private static let cases: [(name: String, setup: [[String: Any]], steps: [[String: Any]])] = [
        ("a-take-back-settles", tapSetup, [
            event("fenceSucceeded", generation: 1),
            event("repaintSucceeded", generation: 1),
            event("stampCommitSucceeded", generation: 1),
            event("settle", generation: 1),
        ]),
        ("other-generations-and-phases-are-no-ops", tapSetup, [
            event("fenceSucceeded", generation: 2),
            event("repaintSucceeded", generation: 1),
            event("stampCommitSucceeded", generation: 1),
            event("settle", generation: 1),
            event("claimGeometryLost", generation: 1),
            event("presentationTimedOut", generation: 2),
            event("abort", generation: 2),
            event("fenceSucceeded", generation: 1),
            event("fenceSucceeded", generation: 1),
            event("stampCommitSucceeded", generation: 1),
        ]),
        ("one-refence-per-generation-and-a-second-loss-aborts", tapSetup, [
            event("fenceSucceeded", generation: 1),
            event("claimGeometryLost", generation: 1),
            event("fenceSucceeded", generation: 1),
            event("claimGeometryLost", generation: 1),
            event("fenceSucceeded", generation: 1),
            event("repaintSucceeded", generation: 1),
        ]),
        ("a-loss-after-the-presentation-timed-out-aborts", tapSetup, [
            event("fenceSucceeded", generation: 1),
            event("presentationTimedOut", generation: 1),
            event("claimGeometryLost", generation: 1),
            event("fenceSucceeded", generation: 1),
        ]),
        ("a-timeout-after-a-spent-refence-only-hides-and-the-claim-settles-late", tapSetup, [
            event("fenceSucceeded", generation: 1),
            event("claimGeometryLost", generation: 1),
            event("presentationTimedOut", generation: 1),
            event("fenceSucceeded", generation: 1),
            event("repaintSucceeded", generation: 1),
            event("stampCommitSucceeded", generation: 1),
            event("settle", generation: 1),
        ]),
        ("a-timeout-awaiting-the-fence-only-hides", tapSetup, [
            event("presentationTimedOut", generation: 1),
            event("presentationTimedOut", generation: 1),
            event("fenceSucceeded", generation: 1),
            event("repaintSucceeded", generation: 1),
        ]),
        ("a-timeout-with-the-stamp-out-only-hides", tapSetup, [
            event("fenceSucceeded", generation: 1),
            event("repaintSucceeded", generation: 1),
            event("claimGeometryLost", generation: 1),
            event("presentationTimedOut", generation: 1),
            event("stampCommitSucceeded", generation: 1),
            event("settle", generation: 1),
        ]),
        ("a-newer-stamp-contests", tapSetup, [
            event("fenceSucceeded", generation: 1),
            event("observedAuthority", peer("ipad", "iPad", 5)),
            event("repaintSucceeded", generation: 1),
        ]),
        ("the-contested-stamp-and-own-echoes-do-not", tapSetup, [
            event("observedAuthority", ipad),
            event("observedAuthority", ["authorityKind": "mine", "authorityGeneration": 1]),
            event("observedAuthority", ["authorityKind": "unknown"]),
            event("fenceSucceeded", generation: 1),
            event("observedAuthority", peer("iphone", "iPhone", 4)),
        ]),
        ("a-show-claim-is-contested-by-any-stamp", showSetup, [
            event("fenceSucceeded", generation: 1),
            event("observedAuthority", ipad),
        ]),
        ("an-adapter-abort-ends-the-claim", tapSetup, [
            event("fenceSucceeded", generation: 1),
            event("abort", generation: 1),
            event("fenceSucceeded", generation: 1),
            event("observedAuthority", ipad),
        ]),
        ("own-advertised-grids-retarget-and-are-never-losses", tapSetup, [
            advertised(80, 24),
            observed(100, 30),
            observed(80, 24, probe: true),
            event("fenceSucceeded", generation: 1),
            advertised(80, 20),
            observed(80, 24),
            observed(80, 20, probe: true),
            event("fenceSucceeded", generation: 1),
            observed(80, 24),
            observed(80, 20),
            event("fenceSucceeded", generation: 1),
            event("repaintSucceeded", generation: 1),
            advertised(90, 30),
            observed(100, 30),
            event("stampCommitSucceeded", generation: 1),
            event("settle", generation: 1),
        ]),
        ("a-foreign-size-before-landing-is-unsettled-and-after-it-a-loss", tapSetup, [
            advertised(80, 24),
            event("fenceSucceeded", generation: 1),
            observed(100, 30),
            observed(80, 24, probe: true),
            event("fenceSucceeded", generation: 1),
            observed(100, 30),
            observed(100, 30),
            observed(100, 30, probe: true),
            observed(80, 24),
            event("fenceSucceeded", generation: 1),
            observed(100, 30),
            event("fenceSucceeded", generation: 1),
        ]),
        ("a-late-claim-advertises-nothing-and-a-late-loss-aborts", tapSetup, [
            advertised(80, 24),
            observed(80, 24, probe: true),
            event("fenceSucceeded", generation: 1),
            event("presentationTimedOut", generation: 1),
            advertised(80, 20),
            observed(80, 20),
            event("fenceSucceeded", generation: 1),
            observed(100, 30),
            event("repaintSucceeded", generation: 1),
        ]),
        ("a-visible-stall-fences-again-and-a-late-one-aborts", tapSetup, [
            advertised(80, 24),
            event("fenceSucceeded", generation: 1),
            event("claimStalled", generation: 1, ["canProgress": true]),
            event("fenceSucceeded", generation: 1),
            event("presentationTimedOut", generation: 1),
            event("claimStalled", generation: 1, ["canProgress": true]),
            event("fenceSucceeded", generation: 1),
        ]),
        ("a-stall-that-cannot-progress-aborts-and-stamp-phases-ignore-stalls", tapSetup, [
            advertised(80, 24),
            event("fenceSucceeded", generation: 1),
            event("repaintSucceeded", generation: 1),
            event("claimStalled", generation: 1, ["canProgress": false]),
            event("stampCommitSucceeded", generation: 1),
            event("claimStalled", generation: 1, ["canProgress": false]),
            event("settle", generation: 1),
        ]),
        ("an-unprogressable-stall-awaiting-the-fence-aborts", showSetup, [
            advertised(80, 24),
            event("claimStalled", generation: 1, ["canProgress": false]),
            advertised(80, 20),
        ]),
        ("advertised-grids-keep-the-target-and-the-newest", tapSetup, [
            advertised(80, 24),
            event("fenceSucceeded", generation: 1),
            event("repaintSucceeded", generation: 1),
        ] + (1...17).map { advertised(80 + $0, 24) } + [
            advertised(81, 24),
            event("stampCommitSucceeded", generation: 1),
        ]),
        ("after-settlement-stamps-project", showSetup, [
            event("fenceSucceeded", generation: 1),
            event("repaintSucceeded", generation: 1),
            event("stampCommitSucceeded", generation: 1),
            event("settle", generation: 1),
            event("observedAuthority", ["authorityKind": "unknown"]),
            event("observedAuthority", ["authorityKind": "mine", "authorityGeneration": 1]),
            event("observedAuthority", ipad),
            event("observedAuthority", ["authorityKind": "unknown"]),
            event("observedAuthority", ["authorityKind": "mine", "authorityGeneration": 2]),
        ]),
    ]

    // MARK: - Generation

    private func generatedDocument() throws -> [String: Any] {
        var cases: [[String: Any]] = []
        for vector in Self.cases {
            var reducer = TmuxGridAuthorityLifecycleReducer()
            for request in vector.setup {
                _ = try reduce(&reducer, request)
            }
            let initial = try reduce(&reducer, Self.event("snapshot"))
            var steps: [[String: Any]] = []
            for request in vector.steps {
                steps.append(["request": request, "expected": try reduce(&reducer, request)])
            }
            cases.append([
                "name": vector.name,
                "setup": vector.setup,
                "initial": initial,
                "steps": steps,
            ])
        }
        return ["version": 1, "cases": cases]
    }

    /// Applies a recorded event directly and projects the reducer's answer
    /// into the checked-in vector format, without the lifecycle ABI.
    private func reduce(
        _ reducer: inout TmuxGridAuthorityLifecycleReducer,
        _ request: [String: Any]
    ) throws -> [String: Any] {
        let event = try XCTUnwrap(request["event"] as? String)
        let generation = (request["generation"] as? NSNumber)?.uint64Value ?? 0
        func authority() throws -> TmuxGridAuthoritySnapshot {
            switch request["authorityKind"] as? String {
            case "unknown": return .unknown
            case "mine": return .mine(generation: try XCTUnwrap((request["authorityGeneration"] as? NSNumber)?.uint64Value))
            case "peer": return .peer(
                deviceID: try XCTUnwrap(request["authorityDeviceID"] as? String),
                displayName: try XCTUnwrap(request["authorityDisplayName"] as? String),
                generation: try XCTUnwrap((request["authorityGeneration"] as? NSNumber)?.uint64Value)
            )
            default: throw VectorError.unmappedAuthority
            }
        }
        let effects: [TmuxGridAuthorityLifecycleReducer.Effect]
        switch event {
        case "attached": effects = reducer.attached()
        case "receivedAuthorityQuery":
            let geometry = try XCTUnwrap((request["geometry"] as? String).flatMap(TmuxGridAuthorityLifecycleReducer.QueryGeometry.init(rawValue:)))
            effects = reducer.receivedAuthorityQuery(try authority(), geometry: geometry)
        case "requestTakeBack": effects = reducer.requestTakeBack(channelLive: request["channelLive"] as? Bool ?? true)
        case "shown":
            let source = try XCTUnwrap((request["source"] as? String).flatMap(TmuxGridAuthorityLifecycleReducer.ShowSource.init(rawValue:)))
            effects = reducer.shown(source: source)
        case "fenceSucceeded": effects = reducer.fenceSucceeded(generation: generation)
        case "claimGeometryLost": effects = reducer.claimGeometryLost(generation: generation)
        case "claimAdvertisedGeometry": effects = reducer.claimAdvertisedGeometry(
            generation: generation, columns: try XCTUnwrap(request["columns"] as? Int), rows: try XCTUnwrap(request["rows"] as? Int)
        )
        case "claimObservedGeometry": effects = reducer.claimObservedGeometry(
            generation: generation, columns: try XCTUnwrap(request["columns"] as? Int), rows: try XCTUnwrap(request["rows"] as? Int),
            settleProbe: request["settleProbe"] as? Bool ?? false
        )
        case "claimStalled": effects = reducer.claimStalled(generation: generation, canProgress: try XCTUnwrap(request["canProgress"] as? Bool))
        case "repaintSucceeded": effects = reducer.repaintSucceeded(generation: generation)
        case "stampCommitSucceeded": effects = reducer.stampCommitSucceeded(generation: generation)
        case "settle": effects = reducer.settleClaim(generation: generation)
        case "abort": effects = reducer.abortClaim(generation: generation)
        case "presentationTimedOut": effects = reducer.presentationTimedOut(generation: generation)
        case "observedAuthority": effects = reducer.observedAuthority(try authority())
        case "snapshot": effects = []
        default: throw VectorError.unmappedEvent(event)
        }
        let snapshot = reducer.snapshot
        var response = authorityFields(snapshot.authority)
        response["version"] = 1
        response["hasAttached"] = snapshot.hasAttached
        response["channelAttached"] = snapshot.channelAttached
        response["nextGeneration"] = snapshot.nextGeneration
        response["claimMayAdvertiseGeometry"] = reducer.claimMayAdvertiseGeometry
        if let claim = snapshot.claim { response["claim"] = try document(claim) }
        if let intent = snapshot.pendingIntent { response["pendingIntent"] = try document(intent) }
        response["effects"] = effects.map(effectFields)
        return response
    }

    private enum VectorError: Error {
        case unmappedAuthority
        case unmappedEvent(String)
    }

    private func document<T: Encodable>(_ value: T) throws -> Any {
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(value))
    }

    private func authorityFields(_ authority: TmuxGridAuthoritySnapshot) -> [String: Any] {
        switch authority {
        case .unknown: return ["authorityKind": "unknown"]
        case .mine(let generation): return ["authorityKind": "mine", "authorityGeneration": generation]
        case .peer(let deviceID, let displayName, let generation): return [
            "authorityKind": "peer", "authorityDeviceID": deviceID,
            "authorityDisplayName": displayName, "authorityGeneration": generation,
        ]
        }
    }

    private func effectFields(_ effect: TmuxGridAuthorityLifecycleReducer.Effect) -> [String: Any] {
        switch effect {
        case .queryAuthority: return ["kind": "queryAuthority"]
        case .beginClaim(let claim): return [
            "kind": "beginClaim", "generation": claim.generation,
            "reason": claim.reason.rawValue, "presentationVisible": claim.presentationVisible,
        ]
        case .requestRepaint(let generation): return ["kind": "requestRepaint", "generation": generation]
        case .commitAuthorityStamp(let generation): return ["kind": "commitAuthorityStamp", "generation": generation]
        case .refenceClaim(let generation): return ["kind": "refenceClaim", "generation": generation]
        case .claimSettled(let generation): return ["kind": "claimSettled", "generation": generation]
        case .authorityChanged(let authority): return authorityFields(authority).merging(["kind": "authorityChanged"]) { _, new in new }
        case .hideReclaimPresentation: return ["kind": "hideReclaimPresentation"]
        case .replayOwnedGeometry: return ["kind": "replayOwnedGeometry"]
        case .claimAborted(let reason):
            var fields: [String: Any] = ["kind": "claimAborted", "reason": reason.wireName]
            if case .contestedByPeer(let peer) = reason {
                fields.merge(authorityFields(.peer(deviceID: peer.deviceID, displayName: peer.displayName, generation: peer.generation))) { _, new in new }
            }
            return fields
        }
    }

    private static var vectorURL: URL {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { root.deleteLastPathComponent() }
        return root.appendingPathComponent("ProtocolVectors/tmux/authority-claim-chain-v1.json")
    }

    private static func checkedInDocument() throws -> [String: Any] {
        let data = try Data(contentsOf: vectorURL)
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
