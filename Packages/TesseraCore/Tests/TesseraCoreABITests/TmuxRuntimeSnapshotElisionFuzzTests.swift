import Foundation
import XCTest
import TmuxControlCore
@testable import TesseraCoreABI

/// Seeds per fuzz run. Each seed is a fresh handle driven through random
/// feeds, facts, queued commands, claims, transport losses and re-entrant
/// operations from inside callbacks. Raise it (3000 found nothing new in
/// review) for a deep run; the default keeps a debug run to a few seconds.
private let snapshotElisionFuzzSeedCount: UInt64 = 60
private let snapshotElisionFuzzOperationsPerSeed = 120

private struct SplitMix {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func int(_ bound: Int) -> Int { Int(next() % UInt64(bound)) }
    mutating func chance(_ probability: Double) -> Bool {
        Double(next() % 10_000) / 10_000 < probability
    }
}

private final class FuzzBridge: @unchecked Sendable {
    var model = TmuxSnapshotStreamModel()
    var handle: UnsafeMutableRawPointer?
    var depth = 0
    var failures: [String] = []
    /// The outcome and oracle check of the last payload the decoder saw.
    var lastOutcome: TmuxSnapshotStreamModel.Outcome?
    var lastMatchedOracle = false
    var statePayloads = 0
    var elided = 0
    var stale = 0
    var lost = 0
    var failed = 0
    var resyncs = 0
    /// Decides, per payload, whether it never reaches the decoder (a JNI
    /// drop) or reaches it and fails to decode.
    var injection: (() -> Injection)?
    var onEvent: (() -> Void)?

    enum Injection { case none, lose, fail }
}

private let fuzzCallback: TesseraCoreABIEventCallback = { bytes, count, context in
    guard let bytes, let context else { return }
    let bridge = Unmanaged<FuzzBridge>.fromOpaque(context).takeUnretainedValue()
    bridge.depth += 1
    defer { bridge.depth -= 1 }
    guard let envelope = try? JSONDecoder().decode(
        TmuxSnapshotStreamModel.Envelope.self,
        from: Data(bytes: bytes, count: count)
    ) else {
        bridge.failures.append("undecodable payload")
        return
    }
    guard envelope.version == 3, let oracle = envelope.testOracleSnapshot, envelope.snapshotKey != nil else {
        bridge.failures.append("envelope without version 3, oracle or key")
        return
    }
    if envelope.platformWireCommands == nil {
        bridge.statePayloads += 1
        if envelope.snapshot == nil { bridge.elided += 1 }
    }

    func requestResync() {
        bridge.resyncs += 1
        if tesseraTmuxRuntimeResyncSnapshot(handle: bridge.handle) != 0 {
            bridge.model.resyncRefused()
        }
    }

    switch bridge.injection?() ?? .none {
    case .lose:
        bridge.lost += 1
        bridge.lastOutcome = nil
    case .fail:
        bridge.failed += 1
        bridge.lastOutcome = nil
        if bridge.model.failed(key: envelope.snapshotKey) { requestResync() }
    case .none:
        let outcome = bridge.model.decode(envelope)
        bridge.lastOutcome = outcome
        bridge.lastMatchedOracle = bridge.model.held == oracle
        if outcome == .current, bridge.model.held != oracle {
            bridge.failures.append(
                "stale snapshot delivered as current: held rev \(bridge.model.held.revision) "
                    + "auth \(bridge.model.held.authority) windows \(bridge.model.held.windows.map(\.id)) "
                    + "vs oracle rev \(oracle.revision) auth \(oracle.authority) "
                    + "windows \(oracle.windows.map(\.id)) key \(envelope.snapshotKey.map(String.init(describing:)) ?? "-")"
            )
        }
        if case .stale(let requestsResync) = outcome {
            bridge.stale += 1
            if requestsResync { requestResync() }
        }
    }
    bridge.onEvent?()
}

/// The ABI elides unchanged snapshots; a bridge that keeps the last one must
/// reproduce, for every state event, exactly the snapshot a v2 event carried
/// (the handle embeds it as `testOracleSnapshot`). Lossless streams must never
/// look stale. Lossy streams, where payloads vanish before or fail inside the
/// decoder, may deliver a stale snapshot only flagged as such, and one more
/// event must always bring the bridge back in step.
final class TmuxRuntimeSnapshotElisionFuzzTests: XCTestCase {
    private var bridge: FuzzBridge!
    private var handle: UnsafeMutableRawPointer!
    private var context: UnsafeMutableRawPointer!
    private var rng = SplitMix(state: 1)
    private var queuedTags: [UInt64] = []
    private var replySequence = 100
    private var stampGeneration: UInt64 = 1
    private var operations: [String] = []

    private func makeHandle() {
        bridge = FuzzBridge()
        context = Unmanaged.passRetained(bridge).toOpaque()
        handle = tesseraTmuxRuntimeCreate(
            callback: fuzzCallback,
            context: context
        )
        bridge.handle = handle
        XCTAssertTrue(tesseraTmuxRuntimeEmbedTestOracleSnapshot(handle: handle))
    }

    private func destroyHandle() {
        tesseraTmuxRuntimeDestroy(handle: handle)
        Unmanaged<FuzzBridge>.fromOpaque(context).release()
    }

    @discardableResult
    private func feed(_ text: String) -> Int32 {
        operations.append("feed \(text.debugDescription)")
        return Array(text.utf8).withUnsafeBytes { raw in
            tesseraTmuxRuntimeFeed(
                handle: handle,
                bytes: raw.bindMemory(to: UInt8.self).baseAddress,
                count: raw.count
            )
        }
    }

    @discardableResult
    private func submit(_ fact: RenderFact) -> Int32 {
        operations.append("submit \(fact)")
        guard let data = try? SharedABI.encoder.encode(fact) else { return -1 }
        return data.withUnsafeBytes { raw in
            tesseraTmuxRuntimeSubmitFact(
                handle: handle,
                json: raw.bindMemory(to: UInt8.self).baseAddress,
                count: raw.count
            )
        }
    }

    private func queue(_ command: String) -> Int64 {
        operations.append("queue \(command)")
        return Array(command.utf8).withUnsafeBytes { raw in
            tesseraTmuxRuntimeQueueCommand(
                handle: handle,
                text: raw.bindMemory(to: UInt8.self).baseAddress,
                count: raw.count
            )
        }
    }

    private func randomLine() -> String {
        let window = 1 + rng.int(4)
        let pane = 1 + rng.int(6)
        switch rng.int(16) {
        case 0: return "%session-changed $1 work\r\n"
        case 1: return "%window-add @\(window)\r\n"
        case 2: return "%unlinked-window-close @\(window)\r\n"
        case 3: return "%window-renamed @\(window) n\(rng.int(5))\r\n"
        case 4:
            return "%layout-change @\(window) abcd,80x24,0,0,\(pane) abcd,80x24,0,0,\(pane) *\r\n"
        case 5: return "%session-window-changed $1 @\(window)\r\n"
        case 6: return "%window-pane-changed @\(window) %\(pane)\r\n"
        case 7:
            stampGeneration += UInt64(rng.int(2))
            let device = rng.chance(0.5) ? "dev0" : "peer\(rng.int(2))"
            return "%subscription-changed tessera-authority $1 @\(window) 0 %\(pane) : "
                + "v1 \(device) \(stampGeneration) Name\r\n"
        case 8:
            replySequence += 1
            let rows = (1...(1 + rng.int(3))).map { index in
                "__tessera_windows__\t@\(index)\t\(index - 1)\t%\(index)\t\t\t0\tw\(index)\r\n"
            }.joined()
            return "%begin 1 \(replySequence) 1\r\n\(rows)%end 1 \(replySequence) 1\r\n"
        case 9:
            replySequence += 1
            return "%begin 1 \(replySequence) 1\r\n__tessera_active_window__\t@\(window)\t3.\(rng.int(5))\r\n"
                + "%end 1 \(replySequence) 1\r\n"
        case 10: return "%client-detached /dev/pts/\(rng.int(3))\r\n"
        case 11: return "%subscription-changed tessera-window-order $1 - - - : 0=@1* 1=@2 \r\n"
        default: return "%output %\(pane) hello \(rng.int(100))\r\n"
        }
    }

    private func randomOperation(reentrant: Bool) {
        switch rng.int(reentrant ? 14 : 12) {
        case 0, 1, 2, 3, 4:
            var text = randomLine()
            if rng.chance(0.3) { text += randomLine() }
            feed(text)
        case 5:
            submit(.userInput)
        case 6:
            let order = [WindowId(2), WindowId(1)]
            submit(.reorderBegan(
                token: UInt64(1 + rng.int(4)),
                order: rng.chance(0.5) ? order : order.reversed()
            ))
        case 7:
            let token = UInt64(1 + rng.int(4))
            submit(rng.chance(0.5) ? .reorderConfirmed(token: token) : .reorderAbandoned(token: token))
        case 8:
            if rng.chance(0.25) {
                submit(.transportLost)
                if rng.chance(0.7) {
                    submit(.transportAttached(rng.chance(0.5) ? .inline : .sideChannel))
                }
            } else {
                submit(.userInput)
            }
        case 9:
            let tag = queue("display-message -p q\(rng.int(100))")
            if tag > 0 { queuedTags.append(UInt64(tag)) }
        case 10:
            let authority: TmuxGridAuthoritySnapshot
            switch rng.int(4) {
            case 0: authority = .mine(generation: UInt64(rng.int(50)))
            case 1: authority = .peer(deviceID: "-", displayName: "another device", generation: 0)
            case 2: authority = .peer(deviceID: "peer", displayName: "iPad", generation: UInt64(rng.int(50)))
            default: authority = .unknown
            }
            operations.append("project \(authority)")
            _ = projectRuntimeAuthority(handle: handle, authority: authority)
        case 11:
            if !reentrant, rng.chance(0.04) {
                feedPartitionedEvent()
            } else {
                submit(.appForeground)
            }
        default:
            // Only meaningful while a queued wire event is still pending.
            if let tag = queuedTags.popLast() { submit(.unwrittenCommandsCancelled(tags: [tag])) }
        }
    }

    /// Many command replies in one read: an event split across envelopes.
    private func feedPartitionedEvent() {
        let count = 1_800
        let command = Array("display-message -p x".utf8)
        for _ in 0..<count {
            _ = command.withUnsafeBytes { raw in
                tesseraTmuxRuntimeSendCommand(
                    handle: handle,
                    text: raw.bindMemory(to: UInt8.self).baseAddress,
                    count: raw.count
                )
            }
        }
        let filler = String(repeating: "y", count: 500)
        var text = randomLine() + randomLine()
        for _ in 0..<count {
            replySequence += 1
            text += "%begin 1 \(replySequence) 1\r\n\(filler)\r\n%end 1 \(replySequence) 1\r\n"
        }
        text += randomLine()
        operations.append("partitioned feed")
        _ = Array(text.utf8).withUnsafeBytes { raw in
            tesseraTmuxRuntimeFeed(
                handle: handle,
                bytes: raw.bindMemory(to: UInt8.self).baseAddress,
                count: raw.count
            )
        }
    }

    /// One more state event, delivered intact, must leave the bridge holding
    /// exactly the snapshot that event stands for.
    private func probeLiveness(seed: UInt64) -> String? {
        let injection = bridge.injection
        let onEvent = bridge.onEvent
        bridge.injection = nil
        bridge.onEvent = nil
        defer {
            bridge.injection = injection
            bridge.onEvent = onEvent
        }
        bridge.lastOutcome = nil
        _ = submit(.userInput)
        // Rejected before any callback (bounded backpressure): nothing to see.
        guard let outcome = bridge.lastOutcome else { return nil }
        guard outcome == .current, bridge.lastMatchedOracle else {
            return "seed \(seed): still out of step after a probe event "
                + "(last outcome \(String(describing: bridge.lastOutcome)))"
        }
        return nil
    }

    private func run(seed: UInt64, lossy: Bool) -> String? {
        rng = SplitMix(state: seed)
        queuedTags = []
        operations = []
        makeHandle()
        defer { destroyHandle() }
        if lossy {
            var injectionRNG = SplitMix(state: seed ^ 0x5DEE_CE66)
            bridge.injection = {
                if injectionRNG.chance(0.04) { return .lose }
                if injectionRNG.chance(0.02) { return .fail }
                return .none
            }
        }
        var reentrantBudget = 0
        bridge.onEvent = { [unowned self] in
            guard self.bridge.depth <= 3, reentrantBudget < 400, self.rng.chance(0.35) else { return }
            for _ in 0..<(1 + self.rng.int(3)) {
                reentrantBudget += 1
                self.randomOperation(reentrant: true)
            }
        }
        for _ in 0..<snapshotElisionFuzzOperationsPerSeed {
            randomOperation(reentrant: false)
            if let failure = bridge.failures.first {
                return "seed \(seed) lossy=\(lossy): \(failure)"
            }
            if !lossy, bridge.stale > 0 {
                return "seed \(seed): a lossless stream looked stale"
            }
            if lossy, let failure = probeLiveness(seed: seed) {
                return failure
            }
        }
        return nil
    }

    private func report(_ failure: String) -> String {
        failure + "\n  last operations:\n    " + operations.suffix(25).joined(separator: "\n    ")
    }

    func testLosslessStreamsAlwaysReproduceTheV2Snapshot() {
        var failures: [String] = []
        var statePayloads = 0
        var elided = 0
        for seed in 1...snapshotElisionFuzzSeedCount {
            if let failure = run(seed: seed, lossy: false) { failures.append(report(failure)) }
            statePayloads += bridge.statePayloads
            elided += bridge.elided
            XCTAssertEqual(bridge.resyncs, 0, "seed \(seed): a lossless stream asked for a resync")
            if failures.count >= 3 { break }
        }
        XCTAssertTrue(failures.isEmpty, failures.joined(separator: "\n\n"))
        // The elision must actually be exercised, or this proves nothing.
        XCTAssertGreaterThan(elided, statePayloads / 4)
    }

    func testLossyStreamsAreFlaggedAndHealedByTheNextEvent() {
        var failures: [String] = []
        var lost = 0
        var failed = 0
        var resyncs = 0
        for seed in 1...snapshotElisionFuzzSeedCount {
            if let failure = run(seed: seed, lossy: true) { failures.append(report(failure)) }
            lost += bridge.lost
            failed += bridge.failed
            resyncs += bridge.resyncs
            if failures.count >= 3 { break }
        }
        XCTAssertTrue(failures.isEmpty, failures.joined(separator: "\n\n"))
        XCTAssertGreaterThan(lost, 50)
        XCTAssertGreaterThan(failed, 25)
        XCTAssertGreaterThan(resyncs, 25)
    }
}
