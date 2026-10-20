import Foundation
import XCTest
@testable import TesseraCoreABI

/// Version 2 of the lifecycle ABI: the whole show-rule session over the same
/// handle. Policy is pinned in `AuthoritySessionTests`; these tests pin the
/// wire: event names and required fields, the projection, effect shapes, the
/// unchanged reply, version rejection and reject-before-mutate.
final class TmuxAuthoritySessionABITests: XCTestCase {
    private static let mine = "v1 SELF 3 iPad"
    private static let mac = "v1 MAC 7 Mac"
    private static let unchanged = #"{"version":2,"unchanged":true}"#

    private func rawReduce(
        _ handle: UnsafeMutableRawPointer,
        _ request: [String: Any],
        outputCapacity: Int = TmuxAuthorityLifecycleABI.maximumPayloadBytes
    ) throws -> (status: Int32, bytes: Data) {
        let input = try JSONSerialization.data(withJSONObject: request)
        var output = [UInt8](repeating: 0, count: outputCapacity)
        let count = input.withUnsafeBytes { inputRaw in
            output.withUnsafeMutableBytes { outputRaw in
                tesseraTmuxAuthorityLifecycleReduce(
                    handle: handle,
                    requestBytes: inputRaw.bindMemory(to: UInt8.self).baseAddress,
                    requestCount: input.count,
                    outputBytes: outputRaw.bindMemory(to: UInt8.self).baseAddress,
                    outputCapacity: outputCapacity
                )
            }
        }
        return (count, count > 0 ? Data(output.prefix(Int(count))) : Data())
    }

    /// A version 2 request at `now`; asserts it was accepted.
    @discardableResult
    private func reduce(
        _ handle: UnsafeMutableRawPointer,
        _ event: String,
        at now: Int64,
        _ fields: [String: Any] = [:],
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> [String: Any] {
        var request = fields
        request["version"] = 2
        request["event"] = event
        request["nowMillis"] = now
        let (status, bytes) = try rawReduce(handle, request)
        XCTAssertGreaterThan(status, 0, "rejected \(request)", file: file, line: line)
        return try XCTUnwrap(
            try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
            file: file,
            line: line
        )
    }

    private func assertUnchanged(
        _ handle: UnsafeMutableRawPointer,
        _ event: String,
        at now: Int64,
        _ fields: [String: Any] = [:],
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        var request = fields
        request["version"] = 2
        request["event"] = event
        request["nowMillis"] = now
        let (status, bytes) = try rawReduce(handle, request)
        XCTAssertGreaterThan(status, 0, file: file, line: line)
        XCTAssertEqual(String(decoding: bytes, as: UTF8.self), Self.unchanged, file: file, line: line)
    }

    private func assertRejectedWithoutMutation(
        _ handle: UnsafeMutableRawPointer,
        _ request: [String: Any],
        outputCapacity: Int = TmuxAuthorityLifecycleABI.maximumPayloadBytes,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let before = try reduce(handle, "snapshot", at: 0, file: file, line: line)
        let (status, _) = try rawReduce(handle, request, outputCapacity: outputCapacity)
        XCTAssertEqual(status, -1, "accepted \(request)", file: file, line: line)
        let after = try reduce(handle, "snapshot", at: 0, file: file, line: line)
        XCTAssertEqual(NSDictionary(dictionary: after), NSDictionary(dictionary: before), file: file, line: line)
    }

    private func kinds(_ response: [String: Any]) -> [String?] {
        effects(response).map { $0["kind"] as? String }
    }

    private func effects(_ response: [String: Any]) -> [[String: Any]] {
        response["effects"] as? [[String: Any]] ?? []
    }

    private func effect(_ response: [String: Any], _ kind: String) -> [String: Any]? {
        effects(response).first { $0["kind"] as? String == kind }
    }

    private func uint(_ value: Any?) -> UInt64? { (value as? NSNumber)?.uint64Value }
    private func int(_ value: Any?) -> Int64? { (value as? NSNumber)?.int64Value }

    private func presentation(_ response: [String: Any]) -> [String: Any]? {
        response["presentation"] as? [String: Any]
    }

    private func window(_ id: Int, _ columns: Int, _ rows: Int) -> [String: Any] {
        [
            "windowListHydrated": true, "windowID": id,
            "windowColumns": columns, "windowRows": rows, "windowAuthoritative": true,
        ]
    }

    /// The ABI harness supplies exactly the fence facts an adapter reports.
    @discardableResult
    private func confirmFence(_ handle: UnsafeMutableRawPointer, generation: UInt64, at now: Int64,
                              onTrace: ((String) -> Void)? = nil) throws -> [String: Any] {
        var allEffects: [[String: Any]] = []
        @discardableResult
        func send(_ event: String, _ fields: [String: Any] = [:]) throws -> [String: Any] {
            let response = try reduce(handle, event, at: now, fields)
            allEffects += effects(response)
            if let trace = response["trace"] as? String { onTrace?(trace) }
            return response
        }
        let snapshot = try reduce(handle, "snapshot", at: now)
        let claim = try XCTUnwrap(snapshot["claim"] as? [String: Any])
        let target = claim["targetGrid"] as? [String: Int] ?? ["columns": 92, "rows": 38]
        if claim["targetGrid"] == nil {
            try send("claimAdvertisedGeometry", ["generation": generation, "columns": target["columns"]!, "rows": target["rows"]!])
        }
        let sent = try send("claimFenceSent", ["generation": generation, "windowID": 1])
        let fenceID = try XCTUnwrap(uint((sent["claimFence"] as? [String: Any])?["id"]))
        try send("claimFenceAcknowledged", ["fenceID": fenceID])
        try send("windowSizePolicyReplied", ["windowID": 1, "rawPolicy": "latest", "fenceID": fenceID])
        try send("windowFacts", window(1, target["columns"]!, target["rows"]!))
        try send("confirmClaimFence")
        var result = try reduce(handle, "snapshot", at: now)
        XCTAssertEqual((result["claim"] as? [String: Any])?["phase"] as? String, "awaitingRepaint")
        result["effects"] = allEffects
        return result
    }

    /// Attached, shown and yielded to the Mac on read 1.
    private func yielded() throws -> UnsafeMutableRawPointer {
        let handle = tesseraTmuxAuthorityLifecycleCreateSeeded(initialGeneration: 0)!
        try reduce(handle, "attached", at: 0, ["localDeviceID": "SELF"])
        try reduce(handle, "adoptShown", at: 0)
        let reply = try reduce(handle, "queryReplied", at: 100, ["queryID": 1, "rawAuthorityValue": Self.mac])
        XCTAssertEqual(presentation(reply)?["kind"] as? String, "veiled")
        return handle
    }

    /// `yielded()` plus a show at 1 s whose read began a claim; returns its generation.
    private func showClaim(_ handle: UnsafeMutableRawPointer, paintable: Bool) throws -> UInt64 {
        try reduce(handle, "paintable", at: 900, ["paintable": paintable])
        try reduce(handle, "shown", at: 1_000)
        let reply = try reduce(handle, "queryReplied", at: 1_100, ["queryID": 2, "rawAuthorityValue": Self.mac])
        return try XCTUnwrap(uint(effect(reply, "beginClaim")?["generation"]))
    }

    func testRawStampClassifiesAndDedupesWithoutLiftingAPeerOnOwnEcho() throws {
        let handle = tesseraTmuxAuthorityLifecycleCreateSeeded(initialGeneration: 0)!
        defer { tesseraTmuxAuthorityLifecycleDestroy(handle: handle) }
        try reduce(handle, "attached", at: 0, ["localDeviceID": "SELF"])
        // Answer the attach read: an edge would otherwise supersede it.
        try reduce(handle, "queryReplied", at: 0, ["queryID": 1, "rawAuthorityValue": ""])
        let peer = try reduce(handle, "stampObserved", at: 1, ["raw": "  " + Self.mac + "  "])
        XCTAssertEqual(peer["authorityKind"] as? String, "peer")
        XCTAssertEqual(kinds(peer), ["authorityChanged"])
        XCTAssertFalse((peer["trace"] as? String ?? "").contains("@"))
        try assertUnchanged(handle, "stampObserved", at: 2, ["raw": Self.mac])
        let ownEcho = try reduce(handle, "stampObserved", at: 3, ["raw": Self.mine])
        XCTAssertEqual(ownEcho["authorityKind"] as? String, "peer")
        XCTAssertEqual(kinds(ownEcho), [])
        try assertUnchanged(handle, "stampObserved", at: 4, ["raw": "  " + Self.mine + "  "])
    }

    func testARawStampEdgeSupersedesTheOutstandingRead() throws {
        let handle = tesseraTmuxAuthorityLifecycleCreateSeeded(initialGeneration: 0)!
        defer { tesseraTmuxAuthorityLifecycleDestroy(handle: handle) }
        try reduce(handle, "attached", at: 0, ["localDeviceID": "SELF"])
        let peer = try reduce(handle, "stampObserved", at: 1, ["raw": Self.mac])
        XCTAssertEqual(kinds(peer), ["authorityChanged", "queryAuthority"])
        XCTAssertEqual(uint(effect(peer, "queryAuthority")?["queryID"]), 2)
        let stale = try reduce(handle, "queryReplied", at: 2, ["queryID": 1, "rawAuthorityValue": ""])
        XCTAssertEqual(kinds(stale), [])
        XCTAssertEqual(stale["authorityKind"] as? String, "peer")
    }

    func testOwnRawStampDuringAClaimRemainsAdvisory() throws {
        let handle = try yielded()
        defer { tesseraTmuxAuthorityLifecycleDestroy(handle: handle) }
        let generation = try showClaim(handle, paintable: true)
        let own = try reduce(handle, "stampObserved", at: 1_101, ["raw": "v1 SELF \(generation) iPad"])
        XCTAssertEqual(own["authorityKind"] as? String, "peer")
        XCTAssertEqual(uint((own["claim"] as? [String: Any])?["generation"]), generation)
        XCTAssertEqual(kinds(own), [])
    }

    func testRawStampBatchPreservesReductionAndEffectOrder() throws {
        let handle = tesseraTmuxAuthorityLifecycleCreateSeeded(initialGeneration: 0)!
        defer { tesseraTmuxAuthorityLifecycleDestroy(handle: handle) }
        try reduce(handle, "attached", at: 0, ["localDeviceID": "SELF"])
        let batch = try reduce(handle, "stampObserved", at: 1, ["rawValues": [Self.mac, "v1 MAC 8 Mac"]])
        XCTAssertEqual(uint(batch["authorityGeneration"]), 8)
        XCTAssertEqual(effects(batch).compactMap { uint($0["authorityGeneration"]) }, [7, 8])
        try assertUnchanged(handle, "stampObserved", at: 2, ["rawValues": ["v1 MAC 8 Mac", "v1 MAC 8 Mac"]])
        let malformed: [[String: Any]] = [[:], ["raw": 42], ["rawValues": []], ["raw": Self.mac, "rawValues": [Self.mac]]]
        for fields in malformed {
            var request = fields
            request["version"] = 2; request["event"] = "stampObserved"; request["nowMillis"] = 3
            try assertRejectedWithoutMutation(handle, request)
        }
    }

    func testResetTransportAndIdentityChangesPermitTheSameRawStampAgain() throws {
        let handle = tesseraTmuxAuthorityLifecycleCreateSeeded(initialGeneration: 0)!
        defer { tesseraTmuxAuthorityLifecycleDestroy(handle: handle) }
        try reduce(handle, "attached", at: 0, ["localDeviceID": "SELF"])
        try reduce(handle, "stampObserved", at: 1, ["raw": Self.mac])
        try reduce(handle, "resetTransport", at: 2, ["preservingPeer": false])
        let replay = try reduce(handle, "stampObserved", at: 3, ["raw": Self.mac])
        XCTAssertEqual(kinds(replay), ["authorityChanged"])
        let changedID = try reduce(handle, "stampObserved", at: 4, ["localDeviceID": "OTHER", "raw": Self.mac])
        XCTAssertNil(changedID["unchanged"], "the session recorded the stamp under its new identity")
    }

    // MARK: Projection

    func testAFreshSessionProjectsHiddenAndWithheld() throws {
        let handle = tesseraTmuxAuthorityLifecycleCreateSeeded(initialGeneration: 0)!
        defer { tesseraTmuxAuthorityLifecycleDestroy(handle: handle) }
        let fresh = try reduce(handle, "snapshot", at: 0)
        XCTAssertEqual(fresh["version"] as? Int, 2)
        XCTAssertEqual(fresh["authorityKind"] as? String, "unknown")
        XCTAssertEqual(fresh["hidden"] as? Bool, true)
        XCTAssertEqual(fresh["geometryHold"] as? String, "withheld")
        XCTAssertEqual(presentation(fresh)?["kind"] as? String, "none")
        XCTAssertEqual(fresh["gatesTyping"] as? Bool, false)
        XCTAssertEqual(fresh["hasAttached"] as? Bool, false)
        XCTAssertEqual(fresh["channelAttached"] as? Bool, false)
        XCTAssertEqual(fresh["channelLive"] as? Bool, false)
        XCTAssertEqual(uint(fresh["nextGeneration"]), 0)
        for absent in ["mutationRefusal", "carriedShow", "nextDeadlineMillis", "currentQueryID", "claim", "pendingIntent", "trace"] {
            XCTAssertNil(fresh[absent], absent)
        }
        XCTAssertEqual(kinds(fresh), [])
    }

    /// The show rule end to end over the wire: a read without an intent
    /// follows the Mac's stamp; the show reads again and that read claims;
    /// the claim's acknowledgements settle it.
    func testAShowOverAPeerClaimsAndSettles() throws {
        let handle = tesseraTmuxAuthorityLifecycleCreateSeeded(initialGeneration: 0)!
        defer { tesseraTmuxAuthorityLifecycleDestroy(handle: handle) }

        let attached = try reduce(handle, "attached", at: 0, ["localDeviceID": "SELF"])
        XCTAssertEqual(kinds(attached), ["queryAuthority"])
        XCTAssertEqual(uint(effect(attached, "queryAuthority")?["queryID"]), 1)
        XCTAssertEqual(uint(attached["currentQueryID"]), 1)
        XCTAssertEqual(int(attached["nextDeadlineMillis"]), 5_000, "the overdue bound")
        XCTAssertEqual(attached["channelLive"] as? Bool, true)
        XCTAssertNotNil(attached["trace"])

        try reduce(handle, "adoptShown", at: 0)
        let veiled = try reduce(handle, "queryReplied", at: 100, ["queryID": 1, "rawAuthorityValue": Self.mac])
        XCTAssertEqual(kinds(veiled), ["authorityChanged"])
        XCTAssertNil(veiled["claim"], "a read without an intent never claims (R5)")
        XCTAssertEqual(veiled["authorityKind"] as? String, "peer")
        XCTAssertEqual(veiled["authorityDeviceID"] as? String, "MAC")
        XCTAssertEqual(presentation(veiled)?["kind"] as? String, "veiled")
        XCTAssertEqual(presentation(veiled)?["peerName"] as? String, "Mac")
        XCTAssertEqual(veiled["gatesTyping"] as? Bool, true)
        XCTAssertEqual(veiled["mutationRefusal"] as? String, "yielded")
        XCTAssertEqual(veiled["geometryHold"] as? String, "withheld")

        let shown = try reduce(handle, "shown", at: 1_000, ["source": "show"])
        XCTAssertEqual(kinds(shown), ["queryAuthority"])
        XCTAssertEqual(uint(effect(shown, "queryAuthority")?["queryID"]), 2)
        XCTAssertEqual(uint(shown["currentQueryID"]), 2)
        XCTAssertEqual(presentation(shown)?["kind"] as? String, "resuming")
        XCTAssertEqual(presentation(shown)?["awaitingConnection"] as? Bool, false)
        XCTAssertEqual((shown["pendingIntent"] as? [String: Any])?["source"] as? String, "show")
        let carried = try XCTUnwrap(shown["carriedShow"] as? [String: Any])
        XCTAssertEqual(carried["source"] as? String, "show")
        XCTAssertEqual(int(carried["stepAtMillis"]), 1_000)
        XCTAssertEqual(int(shown["nextDeadlineMillis"]), 6_000)

        let begun = try reduce(handle, "queryReplied", at: 1_200, ["queryID": 2, "rawAuthorityValue": Self.mac])
        let claim = try XCTUnwrap(effect(begun, "beginClaim"))
        XCTAssertNil(begun["currentQueryID"], "the reply answered the current read")
        XCTAssertEqual(claim["reason"] as? String, "show")
        let generation = try XCTUnwrap(uint(claim["generation"]))
        XCTAssertEqual((begun["claim"] as? [String: Any])?["phase"] as? String, "awaitingFence")
        XCTAssertEqual(begun["geometryHold"] as? String, "owner", "a claim owns geometry through its fence")
        XCTAssertEqual(int(begun["nextDeadlineMillis"]), 4_200, "the claim's 3 s presentation budget")

        let fenced = try confirmFence(handle, generation: generation, at: 1_300)
        XCTAssertEqual(kinds(fenced), ["requestRepaint"])
        let painted = try reduce(handle, "repaintSucceeded", at: 1_400, ["generation": generation])
        XCTAssertEqual(kinds(painted), ["commitAuthorityStamp"])
        XCTAssertEqual(kinds(try reduce(handle, "claimAdvertisedGeometry", at: 1_400, ["generation": generation, "columns": 92, "rows": 38])), [])
        XCTAssertEqual(kinds(try reduce(handle, "stampCommitSucceeded", at: 1_500, ["generation": generation])), [])
        let settled = try reduce(handle, "settle", at: 1_600, ["generation": generation])
        XCTAssertEqual(kinds(settled), ["authorityChanged", "hideReclaimPresentation", "claimSettled"])
        let settlement = try XCTUnwrap(effect(settled, "claimSettled"))
        XCTAssertEqual(uint(settlement["generation"]), generation)
        XCTAssertEqual(Set(settlement.keys), ["kind", "generation"])
        XCTAssertEqual(settled["authorityKind"] as? String, "mine")
        XCTAssertEqual(uint(settled["authorityGeneration"]), generation)
        XCTAssertEqual(presentation(settled)?["kind"] as? String, "none")
        XCTAssertEqual(settled["gatesTyping"] as? Bool, false)
        XCTAssertNil(settled["mutationRefusal"])
        XCTAssertNil(settled["carriedShow"])
        XCTAssertNil(settled["nextDeadlineMillis"])
        XCTAssertEqual(
            settled["trace"] as? String,
            "event=settleClaim(g\(generation)) authority=peer(MAC/Mac#7)->mine#\(generation) claim=g\(generation):show/awaitingSettlement(92x38) vs MAC/Mac#7->none presentation=resuming->none fence=f1(@1 ack latest)->none effects=[authorityChanged(mine#\(generation)),hideReclaimPresentation,claimSettled(g\(generation))]"
        )
    }

    /// An own stamp at our grid releases the hold with an advertise; a
    /// foreign layout under `latest`, past that advertise's echo window,
    /// then yields to the stamp-less peer.
    func testGeometryFactsReleaseTheHoldAndRaiseTheStamplessPeer() throws {
        let handle = tesseraTmuxAuthorityLifecycleCreateSeeded(initialGeneration: 0)!
        defer { tesseraTmuxAuthorityLifecycleDestroy(handle: handle) }
        try reduce(handle, "attached", at: 0, ["localDeviceID": "SELF"])
        try reduce(handle, "adoptShown", at: 0)
        try reduce(handle, "localSize", at: 0, ["columns": 92, "rows": 38])
        try reduce(handle, "windowFacts", at: 0, window(1, 92, 38))
        let owner = try reduce(handle, "queryReplied", at: 100, ["queryID": 1, "rawAuthorityValue": Self.mine])
        XCTAssertEqual(kinds(owner), ["authorityChanged", "releaseGeometry"])
        XCTAssertEqual(effect(owner, "releaseGeometry")?["release"] as? String, "advertise")
        XCTAssertEqual(owner["authorityKind"] as? String, "mine")
        XCTAssertEqual(owner["geometryHold"] as? String, "owner")

        try reduce(handle, "windowSizePolicyReplied", at: 200, ["windowID": 1, "rawPolicy": "latest"])
        let foreign = try reduce(handle, "windowFacts", at: 3_000, window(1, 120, 40))
        XCTAssertEqual(kinds(foreign), ["authorityChanged", "raiseStamplessPeer"])
        XCTAssertEqual(effect(foreign, "authorityChanged")?["authorityDeviceID"] as? String, "-")
        XCTAssertEqual(presentation(foreign)?["kind"] as? String, "veiled")
        XCTAssertEqual(presentation(foreign)?["peerName"] as? String, "another device")
        XCTAssertEqual(foreign["geometryHold"] as? String, "withheld")
    }

    /// A show landing at a failed read's retry deadline, before the tick,
    /// emits the retry and then its own read in one batch. Only the show's
    /// read is current: the adapter sends that one and drops the retry.
    func testADueRetryReplacedByAShowNamesOnlyTheShowsReadCurrent() throws {
        let handle = tesseraTmuxAuthorityLifecycleCreateSeeded(initialGeneration: 0)!
        defer { tesseraTmuxAuthorityLifecycleDestroy(handle: handle) }
        try reduce(handle, "attached", at: 0, ["localDeviceID": "SELF"])
        let failed = try reduce(handle, "queryFailed", at: 100, ["queryID": 1])
        XCTAssertNil(failed["currentQueryID"])
        XCTAssertEqual(int(failed["nextDeadlineMillis"]), 350, "the first retry step")
        let shown = try reduce(handle, "shown", at: 350, ["source": "show"])
        let reads = effects(shown).filter { $0["kind"] as? String == "queryAuthority" }.compactMap { uint($0["queryID"]) }
        XCTAssertEqual(reads, [2, 3], "the due retry, then the show's own read")
        XCTAssertEqual(uint(shown["currentQueryID"]), 3)
    }

    func testAnUnansweredReadIsReportedOnceAtItsDeadline() throws {
        let handle = tesseraTmuxAuthorityLifecycleCreateSeeded(initialGeneration: 0)!
        defer { tesseraTmuxAuthorityLifecycleDestroy(handle: handle) }
        try reduce(handle, "attached", at: 0)
        try assertUnchanged(handle, "tick", at: 4_999)
        let overdue = try reduce(handle, "tick", at: 5_000)
        XCTAssertEqual(kinds(overdue), ["controlChannelUnresponsive"])
        XCTAssertEqual(overdue["channelLive"] as? Bool, false)
        try assertUnchanged(handle, "tick", at: 9_000)
    }

    // MARK: §6.10

    func testClaimGeometryEventsProjectTheirFieldsEvenWithoutEffects() throws {
        let handle = try yielded()
        defer { tesseraTmuxAuthorityLifecycleDestroy(handle: handle) }
        let g = try showClaim(handle, paintable: false)
        let fresh = try XCTUnwrap(try reduce(handle, "snapshot", at: 1_100)["claim"] as? [String: Any])
        XCTAssertEqual(fresh["advertisedGrids"] as? [[String: Int]], [])
        XCTAssertNil(fresh["targetGrid"])
        XCTAssertEqual(fresh["geometryLanded"] as? Bool, false)
        try assertUnchanged(handle, "claimGeometryLost", at: 1_101, ["generation": g])
        let fields: [String: Any] = ["generation": g, "columns": 92, "rows": 38]
        let advertised = try reduce(handle, "claimAdvertisedGeometry", at: 1_200, fields)
        XCTAssertNil(advertised["unchanged"], "claim grid fields alone changed")
        XCTAssertEqual(advertised["claimMayAdvertiseGeometry"] as? Bool, true)
        let claim = try XCTUnwrap(advertised["claim"] as? [String: Any])
        XCTAssertEqual((claim["targetGrid"] as? [String: Any])?["columns"] as? Int, 92)
        XCTAssertEqual((claim["advertisedGrids"] as? [[String: Any]])?.count, 1)
        XCTAssertEqual(claim["targetGrid"] as? [String: Int], ["columns": 92, "rows": 38])
        XCTAssertEqual(claim["advertisedGrids"] as? [[String: Int]], [["columns": 92, "rows": 38]])
        XCTAssertEqual(claim["geometryLanded"] as? Bool, false)
        XCTAssertEqual(claim["geometryRefenced"] as? Bool, false)
        let landed = try reduce(handle, "claimObservedGeometry", at: 1_300, fields.merging(["settleProbe": true]) { _, new in new })
        XCTAssertNil(landed["unchanged"], "landing alone changed")
        XCTAssertEqual((landed["claim"] as? [String: Any])?["geometryLanded"] as? Bool, true)
        try assertUnchanged(handle, "claimObservedGeometry", at: 1_400, fields.merging(["settleProbe": true]) { _, new in new })
        let refenced = try reduce(handle, "claimObservedGeometry", at: 1_500, ["generation": g, "columns": 130, "rows": 50])
        XCTAssertEqual(kinds(refenced), ["refenceClaim"])
        XCTAssertEqual(uint(effect(refenced, "refenceClaim")?["generation"]), g)
        XCTAssertEqual((refenced["claim"] as? [String: Any])?["geometryRefenced"] as? Bool, true)
        XCTAssertEqual((refenced["claim"] as? [String: Any])?["geometryLanded"] as? Bool, false)
        XCTAssertTrue((refenced["trace"] as? String)?.contains("refenceClaim(g") == true)
        try confirmFence(handle, generation: g, at: 1_600)
        let lost = try reduce(handle, "claimGeometryLost", at: 1_700, ["generation": g])
        XCTAssertEqual(effect(lost, "claimAborted")?["reason"] as? String, "geometryLost")
        XCTAssertNil(lost["claim"])
        XCTAssertNil(lost["carriedShow"])
        XCTAssertEqual(lost["claimMayAdvertiseGeometry"] as? Bool, false)
        try assertUnchanged(handle, "claimFenceSent", at: 1_800, ["generation": g, "windowID": 1])
    }

    func testLateAdvertisementIsUnchangedAndDeadlineStallParks() throws {
        let handle = try yielded()
        defer { tesseraTmuxAuthorityLifecycleDestroy(handle: handle) }
        let g = try showClaim(handle, paintable: false)
        try reduce(handle, "claimAdvertisedGeometry", at: 1_200, ["generation": g, "columns": 92, "rows": 38])
        let late = try reduce(handle, "tick", at: 4_100)
        XCTAssertEqual(kinds(late), ["hideReclaimPresentation"])
        XCTAssertEqual(late["claimMayAdvertiseGeometry"] as? Bool, false)
        XCTAssertEqual(late["geometryHold"] as? String, "withheld")
        XCTAssertNotNil(late["claim"])
        try assertUnchanged(handle, "claimAdvertisedGeometry", at: 4_200, ["generation": g, "columns": 130, "rows": 50])
        let stalled = try reduce(handle, "claimStalled", at: 4_300, ["generation": g, "canProgress": false])
        XCTAssertEqual(effect(stalled, "claimAborted")?["reason"] as? String, "adapterFailure")
        XCTAssertEqual(int((stalled["carriedShow"] as? [String: Any])?["stepAtMillis"]), 1_000)
        XCTAssertEqual(kinds(try reduce(handle, "paintable", at: 4_400, ["paintable": true])), ["queryAuthority"])
    }

    func testVisibleStallAndObservationDefaultsUseTheV1FieldNames() throws {
        let handle = try yielded()
        defer { tesseraTmuxAuthorityLifecycleDestroy(handle: handle) }
        let g = try showClaim(handle, paintable: false)
        try reduce(handle, "claimAdvertisedGeometry", at: 1_200, ["generation": g, "columns": 92, "rows": 38])
        try confirmFence(handle, generation: g, at: 1_300)
        let stalled = try reduce(handle, "claimStalled", at: 1_400, ["generation": g, "canProgress": true])
        XCTAssertEqual((stalled["claim"] as? [String: Any])?["phase"] as? String, "awaitingFence")
        XCTAssertEqual(kinds(stalled), [])
        let observation = try reduce(handle, "claimObservedGeometry", at: 1_500, ["generation": g, "columns": 130, "rows": 50])
        XCTAssertEqual(observation["unchanged"] as? Bool, true, "absent settleProbe defaults false")
    }

    func testMalformedClaimGeometryEventsAreRejectedWithoutMutation() throws {
        let handle = try yielded()
        defer { tesseraTmuxAuthorityLifecycleDestroy(handle: handle) }
        var rejected: [[String: Any]] = []
        for event in ["claimAdvertisedGeometry", "claimObservedGeometry"] {
            let malformedFields: [[String: Any]] = [[:], ["generation": 1], ["generation": 1, "columns": 92],
                                                    ["columns": 92, "rows": 38], ["generation": 1, "columns": 0, "rows": 38]]
            for fields in malformedFields {
                rejected.append(fields.merging(["version": 2, "event": event, "nowMillis": 500]) { _, new in new })
            }
        }
        rejected += [
            ["version": 2, "event": "claimGeometryLost", "nowMillis": 500],
            ["version": 2, "event": "claimStalled", "nowMillis": 500, "generation": 1],
            ["version": 2, "event": "claimStalled", "nowMillis": 500, "canProgress": false],
        ]
        for request in rejected { try assertRejectedWithoutMutation(handle, request) }
        XCTAssertEqual(rejected.count, 13)
    }

    func testTheClaimFenceConfirmsOverTheWire() throws {
        let handle = try yielded()
        defer { tesseraTmuxAuthorityLifecycleDestroy(handle: handle) }
        let g = try showClaim(handle, paintable: true)
        try reduce(handle, "claimAdvertisedGeometry", at: 1_200, ["generation": g, "columns": 92, "rows": 38])
        let sent = try reduce(handle, "claimFenceSent", at: 1_210, ["generation": g, "windowID": 4])
        let fence = try XCTUnwrap(sent["claimFence"] as? [String: Any])
        let id = try XCTUnwrap(uint(fence["id"]))
        XCTAssertEqual(uint(fence["generation"]), g)
        XCTAssertEqual(fence["windowID"] as? Int, 4)
        XCTAssertEqual(fence["acknowledged"] as? Bool, false)
        XCTAssertNil(fence["policyIsLatest"])
        XCTAssertTrue((sent["trace"] as? String)?.contains("fence=none->f\(id)(@4)") == true)
        let forced = try reduce(handle, "claimFenceForce", at: 1_220, ["fenceID": id, "outstanding": true])
        XCTAssertEqual((forced["claimFence"] as? [String: Any])?["forceOutstanding"] as? Bool, true)
        // A steady probe's read is evidence, never this fence's.
        let steady = try reduce(handle, "windowSizePolicyReplied", at: 1_230, ["windowID": 4, "rawPolicy": "manual"])
        XCTAssertNil((steady["claimFence"] as? [String: Any])?["policyIsLatest"])
        let read = try reduce(handle, "windowSizePolicyReplied", at: 1_240, ["windowID": 4, "rawPolicy": "manual", "fenceID": id])
        XCTAssertEqual((read["claimFence"] as? [String: Any])?["policyIsLatest"] as? Bool, false)
        XCTAssertEqual(kinds(read), [])
        let acknowledged = try reduce(handle, "claimFenceAcknowledged", at: 1_250, ["fenceID": id])
        XCTAssertEqual(kinds(acknowledged), ["requestRepaint"], "a fixed policy confirms on the acknowledgement")
        XCTAssertEqual((acknowledged["claim"] as? [String: Any])?["phase"] as? String, "awaitingRepaint")
        try assertUnchanged(handle, "confirmClaimFence", at: 1_260)
        try assertUnchanged(handle, "claimFenceAcknowledged", at: 1_270, ["fenceID": id + 1])
        let settled = try reduce(handle, "abort", at: 1_280, ["generation": g, "reason": "superseded"])
        XCTAssertNil(settled["claimFence"])
    }

    func testARequestUnderANewIdentityEndsTheOldIdentitysClaimFirst() throws {
        let handle = try yielded()
        defer { tesseraTmuxAuthorityLifecycleDestroy(handle: handle) }
        let g = try showClaim(handle, paintable: true)
        try reduce(handle, "claimAdvertisedGeometry", at: 1_200, ["generation": g, "columns": 92, "rows": 38])
        let sent = try reduce(handle, "claimFenceSent", at: 1_210, ["generation": g, "windowID": 4])
        let id = try XCTUnwrap(uint((sent["claimFence"] as? [String: Any])?["id"]))
        // The same identity on a request is no change.
        try assertUnchanged(handle, "claimFenceAcknowledged", at: 1_220, ["fenceID": id + 1, "localDeviceID": "SELF"])
        let changed = try reduce(handle, "claimFenceAcknowledged", at: 1_230, ["fenceID": id, "localDeviceID": "OTHER"])
        XCTAssertNil(changed["claim"], "the old identity's claim ended before the event")
        XCTAssertNil(changed["claimFence"])
        XCTAssertTrue(kinds(changed).contains("claimAborted"), "\(kinds(changed))")
        XCTAssertFalse(kinds(changed).contains("requestRepaint"), "its acknowledgement confirmed nothing")
        let trace = try XCTUnwrap(changed["trace"] as? String)
        XCTAssertTrue(trace.hasPrefix("event=identityChanged "), trace)
    }

    func testMalformedClaimFenceEventsAreRejectedWithoutMutation() throws {
        let handle = try yielded()
        defer { tesseraTmuxAuthorityLifecycleDestroy(handle: handle) }
        let rejected: [[String: Any]] = [
            ["version": 2, "event": "claimFenceSent", "nowMillis": 500, "generation": 1],
            ["version": 2, "event": "claimFenceSent", "nowMillis": 500, "windowID": 4],
            ["version": 2, "event": "claimFenceAcknowledged", "nowMillis": 500],
            ["version": 2, "event": "claimFenceForce", "nowMillis": 500, "fenceID": 1],
            ["version": 2, "event": "claimFenceForce", "nowMillis": 500, "outstanding": true],
            ["version": 2, "event": "windowSizePolicyReplied", "nowMillis": 500, "fenceID": 1, "rawPolicy": "latest"],
        ]
        for request in rejected { try assertRejectedWithoutMutation(handle, request) }
    }

    // MARK: Replay

    func testAnAdapterFailureReplaysWhenTheSurfaceCanPaint() throws {
        let handle = try yielded()
        defer { tesseraTmuxAuthorityLifecycleDestroy(handle: handle) }
        let generation = try showClaim(handle, paintable: false)
        let aborted = try reduce(handle, "abort", at: 2_000, ["generation": generation])
        XCTAssertEqual(kinds(aborted), ["hideReclaimPresentation", "claimAborted"])
        XCTAssertEqual(effect(aborted, "claimAborted")?["reason"] as? String, "adapterFailure")
        let carried = try XCTUnwrap(aborted["carriedShow"] as? [String: Any], "a parked show is carried")
        XCTAssertEqual(int(carried["stepAtMillis"]), 1_000)
        let replay = try reduce(handle, "paintable", at: 2_500, ["paintable": true])
        XCTAssertEqual(kinds(replay), ["queryAuthority"])
        XCTAssertEqual(uint(effect(replay, "queryAuthority")?["queryID"]), 3)
    }

    func testASupersededAbortIsNeverReplayed() throws {
        let handle = try yielded()
        defer { tesseraTmuxAuthorityLifecycleDestroy(handle: handle) }
        let generation = try showClaim(handle, paintable: false)
        let aborted = try reduce(handle, "abort", at: 2_000, ["generation": generation, "reason": "superseded"])
        XCTAssertEqual(effect(aborted, "claimAborted")?["reason"] as? String, "superseded")
        XCTAssertNil(aborted["carriedShow"])
        try assertUnchanged(handle, "paintable", at: 2_500, ["paintable": false])
        XCTAssertEqual(kinds(try reduce(handle, "paintable", at: 2_600, ["paintable": true])), [])
    }

    // MARK: Clock and the unchanged reply

    func testPromptsPauseTheClockAndTheCarriedShowIsReadAtNow() throws {
        let handle = tesseraTmuxAuthorityLifecycleCreateSeeded(initialGeneration: 0)!
        defer { tesseraTmuxAuthorityLifecycleDestroy(handle: handle) }
        let shown = try reduce(handle, "shown", at: 0, ["source": "explicitOpen", "stepAtMillis": 0])
        XCTAssertEqual(int(shown["nextDeadlineMillis"]), 20_000)
        let prompted = try reduce(handle, "prompt", at: 5_000, ["scope": "session", "active": true])
        XCTAssertNil(prompted["nextDeadlineMillis"])
        XCTAssertEqual(int((prompted["carriedShow"] as? [String: Any])?["stepAtMillis"]), 5_000)
        try assertUnchanged(handle, "tick", at: 60_000)
        let snapshot = try reduce(handle, "snapshot", at: 60_000)
        let carried = try XCTUnwrap(snapshot["carriedShow"] as? [String: Any])
        XCTAssertEqual(carried["source"] as? String, "explicitOpen")
        XCTAssertEqual(int(carried["stepAtMillis"]), 60_000, "answering restarts the full window")
        XCTAssertNil(snapshot["trace"])
        let answered = try reduce(handle, "prompt", at: 65_000, ["scope": "session", "active": false])
        XCTAssertEqual(int(answered["nextDeadlineMillis"]), 85_000)
    }

    func testANoOpAnswersTheShortReplyAndASnapshotNeverDoes() throws {
        let handle = tesseraTmuxAuthorityLifecycleCreateSeeded(initialGeneration: 0)!
        defer { tesseraTmuxAuthorityLifecycleDestroy(handle: handle) }
        try assertUnchanged(handle, "tick", at: 0)
        try reduce(handle, "localSize", at: 0, ["columns": 92, "rows": 38])
        try assertUnchanged(handle, "localSize", at: 10, ["columns": 92, "rows": 38])
        try assertUnchanged(handle, "cancelIntent", at: 20)
        try assertUnchanged(handle, "foregrounded", at: 30, ["localDeviceID": NSNull()])
        XCTAssertNotNil(try reduce(handle, "snapshot", at: 40)["geometryHold"])
        // An identity change alone is a change.
        let renamed = try reduce(handle, "localSize", at: 50, ["columns": 92, "rows": 38, "localDeviceID": "OTHER"])
        XCTAssertEqual(kinds(renamed), [])
        XCTAssertNotNil(renamed["trace"])
    }

    // MARK: Ports from the retired reducer ABI

    func testAttachHistoryAndChannelSurviveAReconnect() throws {
        let handle = tesseraTmuxAuthorityLifecycleCreateSeeded(initialGeneration: 0)!
        defer { tesseraTmuxAuthorityLifecycleDestroy(handle: handle) }
        let attached = try reduce(handle, "attached", at: 0)
        XCTAssertEqual(attached["hasAttached"] as? Bool, true)
        XCTAssertEqual(attached["channelAttached"] as? Bool, true)
        XCTAssertEqual(uint(attached["nextGeneration"]), 0)
        XCTAssertNil(attached["claim"])
        let reset = try reduce(handle, "resetTransport", at: 1, ["preservingPeer": false])
        XCTAssertEqual(reset["hasAttached"] as? Bool, true)
        XCTAssertEqual(reset["channelAttached"] as? Bool, false)
        let reattached = try reduce(handle, "attached", at: 2)
        XCTAssertEqual(kinds(reattached), ["queryAuthority"])
        XCTAssertEqual(reattached["channelAttached"] as? Bool, true)
        XCTAssertNil(reattached["claim"])
    }

    func testABufferedPeerStampDoesNotCancelTheShowsFreshRead() throws {
        let handle = try yielded()
        defer { tesseraTmuxAuthorityLifecycleDestroy(handle: handle) }
        let shown = try reduce(handle, "shown", at: 1_000)
        let intent = try XCTUnwrap(shown["pendingIntent"] as? [String: Any])
        XCTAssertEqual(uint(intent["token"]), 1)
        XCTAssertEqual(intent["source"] as? String, "show")
        XCTAssertEqual(intent["baselineKnown"] as? Bool, false)
        XCTAssertNil(intent["baseline"])
        let buffered = try reduce(handle, "observedAuthority", at: 1_050, [
            "authorityKind": "peer", "authorityDeviceID": "LAP",
            "authorityDisplayName": "Laptop", "authorityGeneration": 8,
        ])
        XCTAssertEqual(kinds(buffered), ["authorityChanged"])
        XCTAssertEqual(uint((buffered["pendingIntent"] as? [String: Any])?["token"]), 1)
        let resolved = try reduce(handle, "queryReplied", at: 1_100, ["queryID": 2, "rawAuthorityValue": "v1 LAP 8 Laptop"])
        XCTAssertNil(resolved["pendingIntent"])
        XCTAssertEqual(effect(resolved, "beginClaim")?["reason"] as? String, "show")
        XCTAssertEqual(effect(resolved, "beginClaim")?["presentationVisible"] as? Bool, true)
        XCTAssertEqual((resolved["claim"] as? [String: Any])?["phase"] as? String, "awaitingFence")
        XCTAssertEqual(((resolved["claim"] as? [String: Any])?["contestedPeer"] as? [String: Any])?["deviceID"] as? String, "LAP")
    }

    func testAnExplicitOpenAtOurOwnSizeResolvesWithoutCommands() throws {
        let handle = tesseraTmuxAuthorityLifecycleCreateSeeded(initialGeneration: 0)!
        defer { tesseraTmuxAuthorityLifecycleDestroy(handle: handle) }
        try reduce(handle, "attached", at: 0, ["localDeviceID": "SELF"])
        try reduce(handle, "adoptShown", at: 1)
        try reduce(handle, "localSize", at: 2, ["columns": 92, "rows": 38])
        try reduce(handle, "windowFacts", at: 3, window(1, 92, 38))
        try reduce(handle, "queryReplied", at: 100, ["queryID": 1, "rawAuthorityValue": Self.mine])
        try reduce(handle, "sizeAdvertised", at: 101, ["columns": 92, "rows": 38])
        let opened = try reduce(handle, "shown", at: 200, ["source": "explicitOpen"])
        XCTAssertEqual((opened["pendingIntent"] as? [String: Any])?["source"] as? String, "explicitOpen")
        XCTAssertNil((opened["pendingIntent"] as? [String: Any])?["baseline"])
        let resolved = try reduce(handle, "queryReplied", at: 300, ["queryID": 2, "rawAuthorityValue": Self.mine])
        XCTAssertEqual(kinds(resolved), ["releaseGeometry"])
        XCTAssertEqual(effect(resolved, "releaseGeometry")?["release"] as? String, "none", "no geometry command")
        XCTAssertNil(resolved["claim"])
        XCTAssertNil(resolved["pendingIntent"])
        XCTAssertTrue((resolved["trace"] as? String)?.contains("intent=i1:explicitOpen->none") == true)
    }

    func testAReadAtTheLastOwnedSizeRequestsOnlyAnOwnerReplay() throws {
        let handle = tesseraTmuxAuthorityLifecycleCreateSeeded(initialGeneration: 0)!
        defer { tesseraTmuxAuthorityLifecycleDestroy(handle: handle) }
        try reduce(handle, "attached", at: 0, ["localDeviceID": "SELF"])
        try reduce(handle, "adoptShown", at: 1)
        try reduce(handle, "localSize", at: 2, ["columns": 92, "rows": 38])
        try reduce(handle, "windowFacts", at: 3, window(1, 92, 38))
        try reduce(handle, "queryReplied", at: 100, ["queryID": 1, "rawAuthorityValue": Self.mine])
        try reduce(handle, "sizeAdvertised", at: 101, ["columns": 92, "rows": 38])
        try reduce(handle, "backgrounded", at: 102)
        try reduce(handle, "localSize", at: 103, ["columns": 100, "rows": 40])
        let read = try reduce(handle, "foregrounded", at: 104)
        let id = try XCTUnwrap(uint(effect(read, "queryAuthority")?["queryID"]))
        let resolved = try reduce(handle, "queryReplied", at: 105, ["queryID": id, "rawAuthorityValue": Self.mine])
        XCTAssertEqual(kinds(resolved), ["releaseGeometry"])
        XCTAssertEqual(effect(resolved, "releaseGeometry")?["release"] as? String, "ownerReplay")
        XCTAssertEqual(resolved["authorityKind"] as? String, "mine")
        XCTAssertEqual(uint(resolved["authorityGeneration"]), 3)
        XCTAssertNil(resolved["claim"])
    }

    func testATapIntentKeepsItsBaselineAndExpiresOrHides() throws {
        let handle = try yielded()
        defer { tesseraTmuxAuthorityLifecycleDestroy(handle: handle) }
        try reduce(handle, "channelLiveness", at: 200, ["channelLive": false])
        let waiting = try reduce(handle, "requestTakeBack", at: 300)
        XCTAssertEqual(kinds(waiting), [])
        XCTAssertNil(waiting["claim"])
        let intent = try XCTUnwrap(waiting["pendingIntent"] as? [String: Any])
        XCTAssertEqual(intent["source"] as? String, "tap")
        XCTAssertEqual(intent["baselineKnown"] as? Bool, true)
        XCTAssertEqual((intent["baseline"] as? [String: Any])?["deviceID"] as? String, "MAC")
        try assertUnchanged(handle, "tick", at: 20_299)
        let expired = try reduce(handle, "tick", at: 20_300)
        XCTAssertNil(expired["pendingIntent"])
        XCTAssertNotNil(expired["trace"])
        try reduce(handle, "shown", at: 20_400)
        let hidden = try reduce(handle, "hidden", at: 20_500)
        XCTAssertNil(hidden["pendingIntent"])
        XCTAssertEqual(kinds(hidden), [])
        try reduce(handle, "adoptShown", at: 20_600)
        try reduce(handle, "channelLiveness", at: 20_700, ["channelLive": true])
        let live = try reduce(handle, "requestTakeBack", at: 20_800)
        XCTAssertEqual(effect(live, "beginClaim")?["reason"] as? String, "userTakeBack")
    }

    func testATimedOutClaimEscapesAndIgnoresTheOldGeneration() throws {
        let handle = try yielded()
        defer { tesseraTmuxAuthorityLifecycleDestroy(handle: handle) }
        let admitted = try reduce(handle, "requestTakeBack", at: 200)
        let first = try XCTUnwrap(uint(effect(admitted, "beginClaim")?["generation"]))
        try assertUnchanged(handle, "requestTakeBack", at: 201)
        try reduce(handle, "tick", at: 3_200)
        let escaped = try reduce(handle, "requestTakeBack", at: 3_300)
        XCTAssertEqual(kinds(escaped), ["claimAborted", "beginClaim"])
        XCTAssertEqual(effect(escaped, "claimAborted")?["reason"] as? String, "superseded")
        let second = try XCTUnwrap(uint(effect(escaped, "beginClaim")?["generation"]))
        XCTAssertGreaterThan(second, first)
        XCTAssertEqual((escaped["claim"] as? [String: Any])?["presentationVisible"] as? Bool, true)
        XCTAssertTrue((escaped["trace"] as? String)?.contains("claimAborted(superseded)") == true)
        try reduce(handle, "claimAdvertisedGeometry", at: 3_400, ["generation": second, "columns": 92, "rows": 38])
        try assertUnchanged(handle, "claimFenceSent", at: 3_400, ["generation": first, "windowID": 1])
        let current = try reduce(handle, "claimFenceSent", at: 3_400, ["generation": second, "windowID": 1])
        let fenceID = try XCTUnwrap(uint((current["claimFence"] as? [String: Any])?["id"]))
        try assertUnchanged(handle, "claimFenceAcknowledged", at: 3_400, ["fenceID": fenceID + 1])
        XCTAssertEqual(uint((try reduce(handle, "snapshot", at: 3_400)["claim"] as? [String: Any])?["generation"]), second)
    }

    func testThePresentationDeadlineOnlyHidesAndALateLossAborts() throws {
        let handle = try yielded()
        defer { tesseraTmuxAuthorityLifecycleDestroy(handle: handle) }
        let g = try showClaim(handle, paintable: false)
        try confirmFence(handle, generation: g, at: 1_200)
        try reduce(handle, "claimGeometryLost", at: 1_300, ["generation": g])
        let expired = try reduce(handle, "tick", at: 4_100)
        XCTAssertEqual(kinds(expired), ["hideReclaimPresentation"])
        let late = try XCTUnwrap(expired["claim"] as? [String: Any])
        XCTAssertEqual(late["presentationVisible"] as? Bool, false)
        XCTAssertEqual(late["phase"] as? String, "awaitingFence")
        try assertUnchanged(handle, "tick", at: 4_101)
        XCTAssertEqual(kinds(try confirmFence(handle, generation: g, at: 4_200)), ["requestRepaint"])
        let lost = try reduce(handle, "claimGeometryLost", at: 4_300, ["generation": g])
        XCTAssertNil(lost["claim"])
        XCTAssertEqual(kinds(lost), ["hideReclaimPresentation", "claimAborted"])
        XCTAssertEqual(effect(lost, "claimAborted")?["reason"] as? String, "geometryLost")
    }

    func testALateClaimStallAbortsEvenWhenItCouldProgress() throws {
        let handle = try yielded()
        defer { tesseraTmuxAuthorityLifecycleDestroy(handle: handle) }
        let g = try showClaim(handle, paintable: false)
        try reduce(handle, "tick", at: 4_100)
        let stalled = try reduce(handle, "claimStalled", at: 4_200, ["generation": g, "canProgress": true])
        XCTAssertNil(stalled["claim"])
        XCTAssertEqual(kinds(stalled), ["hideReclaimPresentation", "claimAborted"])
        XCTAssertEqual(effect(stalled, "claimAborted")?["reason"] as? String, "adapterFailure")
        XCTAssertEqual(stalled["claimMayAdvertiseGeometry"] as? Bool, false)
    }

    func testAChangedLowerPeerStampContestsAndAnOwnWriteCanWin() throws {
        let handle = try yielded()
        defer { tesseraTmuxAuthorityLifecycleDestroy(handle: handle) }
        let admitted = try reduce(handle, "requestTakeBack", at: 200)
        let g = try XCTUnwrap(uint(effect(admitted, "beginClaim")?["generation"]))
        let contest = try reduce(handle, "observedAuthority", at: 300, [
            "authorityKind": "peer", "authorityDeviceID": "MAC", "authorityDisplayName": "Mac", "authorityGeneration": 6,
        ])
        XCTAssertNil(contest["claim"])
        XCTAssertEqual(kinds(contest), ["authorityChanged", "hideReclaimPresentation", "claimAborted"])
        XCTAssertEqual(effect(contest, "claimAborted")?["reason"] as? String, "contestedByPeer")
        XCTAssertEqual(effect(contest, "claimAborted")?["authorityDeviceID"] as? String, "MAC")
        XCTAssertEqual(uint(effect(contest, "claimAborted")?["authorityGeneration"]), 6)
        let won = try reduce(handle, "ownStampObserved", at: 400, ["generation": g])
        XCTAssertEqual(effect(won, "beginClaim")?["reason"] as? String, "ownWriteWon")
    }

    func testForegroundDoesNothingUnattachedOrDuringTheClaimAckChain() throws {
        let handle = tesseraTmuxAuthorityLifecycleCreateSeeded(initialGeneration: 0)!
        defer { tesseraTmuxAuthorityLifecycleDestroy(handle: handle) }
        try assertUnchanged(handle, "foregrounded", at: 0)
        try reduce(handle, "attached", at: 1, ["localDeviceID": "SELF"])
        try reduce(handle, "adoptShown", at: 2)
        try reduce(handle, "queryReplied", at: 3, ["queryID": 1, "rawAuthorityValue": Self.mac])
        XCTAssertEqual(kinds(try reduce(handle, "foregrounded", at: 4)), ["queryAuthority"])
        try reduce(handle, "queryReplied", at: 5, ["queryID": 2, "rawAuthorityValue": Self.mac])
        let admitted = try reduce(handle, "requestTakeBack", at: 6)
        let g = try XCTUnwrap(uint(effect(admitted, "beginClaim")?["generation"]))
        try assertUnchanged(handle, "foregrounded", at: 10)
        try confirmFence(handle, generation: g, at: 11)
        for (index, event) in ["repaintSucceeded", "stampCommitSucceeded"].enumerated() {
            try assertUnchanged(handle, "foregrounded", at: Int64(12 + index * 2))
            try reduce(handle, event, at: Int64(13 + index * 2), ["generation": g])
        }
    }

    /// A single Character can carry many UTF-8 bytes. This name passes the
    /// stamp's character bound but overflows the encoded projection, proving
    /// rollback after reduction rather than rejection during validation.
    func testAnOversizedEncodedResponseDoesNotCommitTheSession() throws {
        let handle = try yielded()
        defer { tesseraTmuxAuthorityLifecycleDestroy(handle: handle) }
        let name = "p" + String(repeating: "\u{0301}", count: 20_000)
        XCTAssertEqual(name.count, 1)
        let request: [String: Any] = [
            "version": 2, "event": "observedAuthority", "nowMillis": 500,
            "authorityKind": "peer", "authorityDeviceID": "OTHER", "authorityDisplayName": name, "authorityGeneration": 8,
        ]
        XCTAssertLessThan(try JSONSerialization.data(withJSONObject: request).count, TmuxAuthorityLifecycleABI.maximumPayloadBytes)
        try assertRejectedWithoutMutation(handle, request)
        let snapshot = try reduce(handle, "snapshot", at: 500)
        XCTAssertEqual(snapshot["authorityDeviceID"] as? String, "MAC")
        let accepted = try reduce(handle, "observedAuthority", at: 500, [
            "authorityKind": "peer", "authorityDeviceID": "OTHER", "authorityDisplayName": "Other", "authorityGeneration": 8,
        ])
        XCTAssertEqual(accepted["authorityDeviceID"] as? String, "OTHER")
    }

    func testTheHandlePayloadCapIsExactly64KiB() throws {
        XCTAssertEqual(TmuxAuthorityLifecycleABI.maximumPayloadBytes, 64 * 1024)
        XCTAssertEqual(tesseraTmuxAuthorityLifecycleMaxPayloadBytes(), TmuxAuthorityLifecycleABI.maximumPayloadBytes)
        let handle = tesseraTmuxAuthorityLifecycleCreateSeeded(initialGeneration: 0)!
        defer { tesseraTmuxAuthorityLifecycleDestroy(handle: handle) }
        try assertRejectedWithoutMutation(handle, ["version": 2, "event": "attached", "nowMillis": 0],
                                         outputCapacity: TmuxAuthorityLifecycleABI.maximumPayloadBytes - 1)
        var request: [String: Any] = ["version": 2, "event": "attached", "nowMillis": 0, "padding": ""]
        let baseCount = try JSONSerialization.data(withJSONObject: request).count
        request["padding"] = String(repeating: "a", count: TmuxAuthorityLifecycleABI.maximumPayloadBytes - baseCount)
        XCTAssertEqual(try JSONSerialization.data(withJSONObject: request).count, TmuxAuthorityLifecycleABI.maximumPayloadBytes)
        XCTAssertGreaterThan(try rawReduce(handle, request).status, 0)
        request["event"] = "snapshot"
        request["padding"] = String(repeating: "a", count: TmuxAuthorityLifecycleABI.maximumPayloadBytes - baseCount + 1)
        XCTAssertEqual(try JSONSerialization.data(withJSONObject: request).count, TmuxAuthorityLifecycleABI.maximumPayloadBytes + 1)
        try assertRejectedWithoutMutation(handle, request)
    }

    func testConcurrentReductionsPreserveEveryIntentAndQuery() throws {
        let handle = try yielded()
        defer { tesseraTmuxAuthorityLifecycleDestroy(handle: handle) }
        let capture = ConcurrentCapture()
        DispatchQueue.concurrentPerform(iterations: 32) { _ in
            do {
                let shown = try reduce(handle, "shown", at: 1_000)
                capture.append(status: 1, token: uint((shown["pendingIntent"] as? [String: Any])?["token"]),
                               queryID: uint(effect(shown, "queryAuthority")?["queryID"]))
            } catch { capture.append(status: -1) }
        }
        XCTAssertEqual(capture.statuses, Array(repeating: 1, count: 32))
        XCTAssertEqual(capture.tokens.sorted(), Array(UInt64(1)...UInt64(32)))
        XCTAssertEqual(capture.queryIDs.sorted(), Array(UInt64(2)...UInt64(33)))
        let snapshot = try reduce(handle, "snapshot", at: 1_000)
        XCTAssertEqual(uint((snapshot["pendingIntent"] as? [String: Any])?["token"]), 32)
        XCTAssertEqual(uint(snapshot["currentQueryID"]), 33)
    }

    func testConcurrentReduceAndDestroyRejectStaleHandlesSafely() throws {
        let handle = tesseraTmuxAuthorityLifecycleCreateSeeded(initialGeneration: 0)!
        let capture = ConcurrentCapture()
        DispatchQueue.concurrentPerform(iterations: 32) { index in
            if index == 16 {
                tesseraTmuxAuthorityLifecycleDestroy(handle: handle)
            } else {
                do { capture.append(status: try rawReduce(handle, ["version": 2, "event": "attached", "nowMillis": 0]).status) }
                catch { capture.append(status: -2) }
            }
        }
        tesseraTmuxAuthorityLifecycleDestroy(handle: handle)
        XCTAssertEqual(capture.statuses.count, 31)
        XCTAssertTrue(capture.statuses.allSatisfy { $0 > 0 || $0 == -1 })
        XCTAssertEqual(try rawReduce(handle, ["version": 2, "event": "snapshot", "nowMillis": 0]).status, -1)
    }

    private final class ConcurrentCapture: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var statuses: [Int32] = []
        private(set) var tokens: [UInt64] = []
        private(set) var queryIDs: [UInt64] = []
        func append(status: Int32, token: UInt64? = nil, queryID: UInt64? = nil) {
            lock.lock()
            defer { lock.unlock() }
            statuses.append(status)
            if let token { tokens.append(token) }
            if let queryID { queryIDs.append(queryID) }
        }
    }

    // MARK: Versions and rejection

    func testVersionOneRequestsAreRejectedAndLeaveAV2SessionUntouched() throws {
        let handle = try yielded()
        defer { tesseraTmuxAuthorityLifecycleDestroy(handle: handle) }
        _ = try showClaim(handle, paintable: false)
        for event in ["snapshot", "attached", "foregrounded", "requestTakeBack", "resetTransport"] {
            try assertRejectedWithoutMutation(handle, ["version": 1, "event": event])
            try assertRejectedWithoutMutation(handle, ["version": 1, "event": event, "nowMillis": 2_000])
        }
        let fresh = tesseraTmuxAuthorityLifecycleCreateSeeded(initialGeneration: 0)!
        defer { tesseraTmuxAuthorityLifecycleDestroy(handle: fresh) }
        // A formerly valid v1 request cannot claim or lock a fresh handle.
        XCTAssertEqual(try rawReduce(fresh, ["version": 1, "event": "attached"]).status, -1)
        XCTAssertEqual(try rawReduce(fresh, ["version": 1, "event": "intentExpired"]).status, -1)
        let snapshot = try reduce(fresh, "snapshot", at: 0)
        XCTAssertEqual(snapshot["version"] as? Int, 2)
        XCTAssertEqual(snapshot["hasAttached"] as? Bool, false)
        XCTAssertNil(snapshot["claim"])
        XCTAssertEqual(kinds(try reduce(fresh, "attached", at: 1)), ["queryAuthority"])
    }

    func testMalformedRequestsAreRejectedBeforeMutation() throws {
        let handle = try yielded()
        defer { tesseraTmuxAuthorityLifecycleDestroy(handle: handle) }
        func request(_ event: String, _ fields: [String: Any] = [:]) -> [String: Any] {
            fields.merging(["version": 2, "event": event, "nowMillis": 500]) { _, new in new }
        }
        var rejected: [[String: Any]] = [
            ["version": 2, "event": "attached"],
            request("intentExpired", ["token": 1]),
            request("receivedAuthorityQuery", ["rawAuthorityValue": Self.mine, "geometry": "atLocalSize"]),
            request("presentationTimedOut", ["generation": 1]),
            request("observedOwnAuthorityStamp", ["generation": 1]),
            request("sideways"),
            request("resolvedPeerPresence"),
            request("peerDepartureObserved"),
            request("shown", ["source": "tap"]),
            request("prompt", ["active": true]),
            request("prompt", ["scope": "global", "active": true]),
            request("channelLiveness"),
            request("paintable"),
            request("controlSessionChanged"),
            request("ordinaryRecovery", ["proven": true]),
            request("observedAuthority", ["authorityKind": "peer", "authorityDeviceID": "LAP"]),
            request("ownStampObserved"),
            request("queryReplied", ["queryID": 1]),
            request("queryReplied", ["rawAuthorityValue": Self.mine]),
            request("queryFailed"),
            request("windowFacts", ["windowID": 1]),
            request("windowFacts", ["windowListHydrated": true, "windowID": 1, "windowColumns": 80, "windowRows": 24]),
            request("windowFacts", ["windowListHydrated": true, "windowColumns": 80, "windowRows": 24]),
            request("windowFacts", ["windowListHydrated": true, "windowID": 1, "windowColumns": 80, "windowAuthoritative": true]),
            request("localSize", ["columns": 80]),
            request("localSize", ["columns": 0, "rows": 24]),
            request("sizeAdvertised"),
            request("windowSizePolicyReplied", ["rawPolicy": "latest"]),
            request("windowSizePolicyReplied", ["windowID": 1]),
            request("abort", ["generation": 1, "reason": "contestedByPeer"]),
            request("abort"),
        ]
        rejected.append(request("fenceSucceeded", ["generation": 1]))
        for event in ["repaintSucceeded", "stampCommitSucceeded", "settle"] {
            rejected.append(request(event))
        }
        for request in rejected {
            try assertRejectedWithoutMutation(handle, request)
        }
        XCTAssertEqual(rejected.count, 35)
    }

    /// Review F5: an extreme clock value through JNI must never trap (which
    /// kills the Android process). A negative clock or a step after `now` is
    /// an adapter bug and is rejected; the valid range clamps.
    func testExtremeClockValuesAreRejectedOrClampedNeverTrapped() throws {
        let handle = tesseraTmuxAuthorityLifecycleCreateSeeded(initialGeneration: 0)!
        defer { tesseraTmuxAuthorityLifecycleDestroy(handle: handle) }
        try reduce(handle, "attached", at: 0)
        let rejected: [[String: Any]] = [
            ["version": 2, "event": "tick", "nowMillis": Int64.min],
            ["version": 2, "event": "tick", "nowMillis": -1],
            ["version": 2, "event": "shown", "nowMillis": 1_000, "stepAtMillis": Int64.min],
            ["version": 2, "event": "shown", "nowMillis": 1_000, "stepAtMillis": -1],
            ["version": 2, "event": "shown", "nowMillis": 1_000, "stepAtMillis": 1_001],
            ["version": 2, "event": "shown", "nowMillis": 1_000, "stepAtMillis": Int64.max],
        ]
        for request in rejected {
            try assertRejectedWithoutMutation(handle, request)
        }
        let stale = try reduce(handle, "shown", at: Int64.max, ["stepAtMillis": 0])
        XCTAssertNil(stale["pendingIntent"], "a step from the far past outlived its window")
        XCTAssertEqual(stale["hidden"] as? Bool, false)
        // A deadline past the clock's end clamps to it instead of wrapping
        // into the past (which would expire the intent at once).
        let fresh = try reduce(handle, "shown", at: Int64.max - 1, ["stepAtMillis": Int64.max - 1])
        XCTAssertNotNil(fresh["pendingIntent"])
        XCTAssertEqual(int(fresh["nextDeadlineMillis"]), Int64.max, "clamped, not wrapped")
        try reduce(handle, "tick", at: Int64.max)
        try reduce(handle, "snapshot", at: Int64.max)
    }

    /// A peer's display name is capped where the stamp is parsed, so a long
    /// one cannot push a reply's response past the bound. A reply too large
    /// for the request bound is still rejected before mutation; the adapter
    /// then reports its read failed, which retries rather than leaving the
    /// read outstanding.
    func testALongPeerNameIsCappedAndARejectedReplyCanStillFail() throws {
        let handle = tesseraTmuxAuthorityLifecycleCreateSeeded(initialGeneration: 0)!
        defer { tesseraTmuxAuthorityLifecycleDestroy(handle: handle) }
        try reduce(handle, "attached", at: 0, ["localDeviceID": "SELF"])
        try reduce(handle, "adoptShown", at: 0)
        let long = String(repeating: "N", count: 20_000)
        let reply = try reduce(handle, "queryReplied", at: 100, ["queryID": 1, "rawAuthorityValue": "v1 MAC 7 \(long)"])
        XCTAssertEqual(reply["authorityDeviceID"] as? String, "MAC")
        XCTAssertEqual(uint(reply["authorityGeneration"]), 7)
        XCTAssertEqual(reply["authorityDisplayName"] as? String, String(repeating: "N", count: 64))
        XCTAssertEqual(presentation(reply)?["peerName"] as? String, String(repeating: "N", count: 64))

        let read = try reduce(handle, "foregrounded", at: 200)
        let id = try XCTUnwrap(uint(effect(read, "queryAuthority")?["queryID"]))
        try assertRejectedWithoutMutation(handle, [
            "version": 2, "event": "queryReplied", "nowMillis": 300, "queryID": id,
            "rawAuthorityValue": String(repeating: "a", count: TmuxAuthorityLifecycleABI.maximumPayloadBytes),
        ])
        let failed = try reduce(handle, "queryFailed", at: 300, ["queryID": id])
        XCTAssertEqual(int(failed["nextDeadlineMillis"]), 550, "the failed read retries after 0.25 s")
    }

    /// A device ID past the stamp parser's bound makes the stamp
    /// unparseable rather than sinking the reply; an adapter's observation
    /// past the bounds is rejected before mutation (Kotlin ignores it).
    func testALongPeerDeviceIDClassifiesUnknownAndCannotSinkTheReply() throws {
        let handle = tesseraTmuxAuthorityLifecycleCreateSeeded(initialGeneration: 0)!
        defer { tesseraTmuxAuthorityLifecycleDestroy(handle: handle) }
        try reduce(handle, "attached", at: 0, ["localDeviceID": "SELF"])
        try reduce(handle, "adoptShown", at: 0)
        let id = String(repeating: "D", count: 17_000)
        let replied = try reduce(handle, "queryReplied", at: 100, ["queryID": 1, "rawAuthorityValue": "v1 \(id) 7 Mac"])
        XCTAssertEqual(replied["authorityKind"] as? String, "unknown")
        for (deviceID, name) in [(id, "Mac"), (String(repeating: "D", count: 129), "Mac"), ("MAC", String(repeating: "N", count: 65))] {
            try assertRejectedWithoutMutation(handle, [
                "version": 2, "event": "observedAuthority", "nowMillis": 200,
                "authorityKind": "peer", "authorityDeviceID": deviceID, "authorityDisplayName": name, "authorityGeneration": 7,
            ])
        }
        let bounded = try reduce(handle, "observedAuthority", at: 200, [
            "authorityKind": "peer", "authorityDeviceID": String(repeating: "D", count: 128),
            "authorityDisplayName": String(repeating: "N", count: 64), "authorityGeneration": 7,
        ])
        XCTAssertEqual(bounded["authorityKind"] as? String, "peer")
    }

    func testAnEstablishedSessionRefusesUnknownVersionsWithoutMutation() throws {
        let handle = try yielded()
        defer { tesseraTmuxAuthorityLifecycleDestroy(handle: handle) }
        for version in [0, 1, 3] {
            try assertRejectedWithoutMutation(handle, ["version": version, "event": "attached", "nowMillis": 0])
            try assertRejectedWithoutMutation(handle, ["version": version, "event": "snapshot", "nowMillis": 0])
        }
    }

    func testAnUnknownOrMissingVersionLeavesAFreshSessionUntouched() throws {
        let handle = tesseraTmuxAuthorityLifecycleCreateSeeded(initialGeneration: 0)!
        defer { tesseraTmuxAuthorityLifecycleDestroy(handle: handle) }
        for request: [String: Any] in [
            ["version": 3, "event": "attached", "nowMillis": 0],
            ["event": "attached", "nowMillis": 0],
            ["version": "2", "event": "attached", "nowMillis": 0],
        ] {
            XCTAssertEqual(try rawReduce(handle, request).status, -1)
        }
        let fresh = try reduce(handle, "snapshot", at: 0)
        XCTAssertEqual(fresh["hasAttached"] as? Bool, false)
        XCTAssertEqual(fresh["channelAttached"] as? Bool, false)
        XCTAssertNil(fresh["claim"])
        XCTAssertGreaterThan(try rawReduce(handle, ["version": 2, "event": "attached", "nowMillis": 0]).status, 0)
    }

    func testOversizedRequestsAndResponsesAreRejectedBeforeMutation() throws {
        let handle = tesseraTmuxAuthorityLifecycleCreateSeeded(initialGeneration: 0)!
        defer { tesseraTmuxAuthorityLifecycleDestroy(handle: handle) }
        try reduce(handle, "attached", at: 0)
        try assertRejectedWithoutMutation(handle, [
            "version": 2, "event": "queryReplied", "nowMillis": 10, "queryID": 1,
            "rawAuthorityValue": String(repeating: "a", count: TmuxAuthorityLifecycleABI.maximumPayloadBytes),
        ])
        // Projected twice, as the authority and its `authorityChanged` effect.
        let peer: [String: Any] = [
            "version": 2, "event": "observedAuthority", "nowMillis": 10,
            "authorityKind": "peer", "authorityDeviceID": "peer",
            "authorityDisplayName": String(repeating: "p", count: 40_000), "authorityGeneration": 1,
        ]
        XCTAssertLessThan(try JSONSerialization.data(withJSONObject: peer).count, TmuxAuthorityLifecycleABI.maximumPayloadBytes)
        try assertRejectedWithoutMutation(handle, peer)
        try assertRejectedWithoutMutation(handle, ["version": 2, "event": "tick", "nowMillis": 10], outputCapacity: 1)
        XCTAssertEqual(try reduce(handle, "snapshot", at: 10)["authorityKind"] as? String, "unknown")
    }
    /// Every trace a claim's life writes reaches the diagnostic log through
    /// the core's full redaction (Android's `tessera_redact_sensitive`), and
    /// must come out unchanged. `awaitingRepaint@56x45` once read as a
    /// `user@host` endpoint there, so field logs and the live foreground
    /// lane lost the claim's phase.
    func testClaimTracesSurviveDiagnosticRedaction() throws {
        func redact(_ text: String) -> String? {
            var source = Array(text.utf8)
            var output = [UInt8](repeating: 0, count: source.count * 2 + 64)
            let count = source.withUnsafeMutableBufferPointer { textBytes in
                output.withUnsafeMutableBufferPointer { outputBytes in
                    tesseraRedactSensitive(
                        textBytes: textBytes.baseAddress, textCount: textBytes.count,
                        patternsBytes: nil, patternsCount: 0,
                        outputBytes: outputBytes.baseAddress, outputCapacity: outputBytes.count
                    )
                }
            }
            guard count >= 0 else { return nil }
            return String(decoding: output.prefix(Int(count)), as: UTF8.self)
        }
        let handle = try yielded()
        defer { tesseraTmuxAuthorityLifecycleDestroy(handle: handle) }
        let begun = try reduce(handle, "requestTakeBack", at: 200)
        let g = try XCTUnwrap(uint(effect(begun, "beginClaim")?["generation"]))
        var traces = [begun["trace"] as? String]
        let steps: [(String, Int64, [String: Any])] = [
            ("claimAdvertisedGeometry", 300, ["columns": 92, "rows": 38]),
            ("confirmFence", 400, [:]),
            ("claimObservedGeometry", 500, ["columns": 92, "rows": 38, "settleProbe": true]),
            ("claimObservedGeometry", 600, ["columns": 105, "rows": 31]),
            ("confirmFence", 700, [:]),
            ("claimObservedGeometry", 800, ["columns": 92, "rows": 38, "settleProbe": true]),
            ("tick", 3_200, [:]),
        ]
        for (event, now, fields) in steps {
            if event == "confirmFence" {
                try confirmFence(handle, generation: g, at: now, onTrace: { traces.append($0) })
            } else {
                traces.append(try reduce(handle, event, at: now, fields.merging(["generation": g]) { _, new in new })["trace"] as? String)
            }
        }
        let written = traces.compactMap { $0 }
        XCTAssertEqual(written.count, traces.count, "every step changed the claim")
        XCTAssertTrue(written.contains { $0.contains("event=claimFenceAck(") }, "the fence acknowledgement stays legible")
        XCTAssertTrue(written.contains { $0.contains("awaitingRepaint(92x38)/landed") })
        XCTAssertTrue(written.last?.contains("awaitingRepaint(92x38)/landed/hidden/refenced") ?? false)
        for trace in written {
            XCTAssertEqual(redact(trace), trace)
        }
    }
}
