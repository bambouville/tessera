import Foundation
import XCTest
import TmuxControlCore
@testable import TesseraCoreABI

final class GridReleaseABITrace: @unchecked Sendable {
    var events: [[String: Any]] = []
    var errors: [String] = []
}

private let receiveGridReleaseABIEvent: TesseraCoreABIEventCallback = { bytes, count, context in
    guard let bytes, let context else { return }
    let trace = Unmanaged<GridReleaseABITrace>.fromOpaque(context).takeUnretainedValue()
    guard let event = try? JSONSerialization.jsonObject(with: Data(bytes: bytes, count: count))
        as? [String: Any] else {
        trace.errors.append("callback was not a JSON object")
        return
    }
    trace.events.append(event)
}

/// One inline runtime handle driven through the ABI exactly as the Android
/// adapter drives it, with a minimal tmux on the other end: every command is
/// answered in FIFO order (metadata for a pane query, rows for a capture),
/// every surface-state request at the pane's current width, and every
/// queue-wait timer once nothing is outstanding.
final class GridReleaseABIWire {
    let trace = GridReleaseABITrace()
    let handle: UnsafeMutableRawPointer
    private let context: UnsafeMutableRawPointer
    private var nextReply = 1
    private var absorbedEvents = 0
    private var outstanding: [String] = []
    private var timers: [UInt64] = []
    private(set) var sent: [String] = []
    private(set) var bound: [String] = []
    /// Pane widths of the window's current layout, for surface-state answers.
    var paneWidths: [String: Int] = [:]

    init() {
        let context = Unmanaged.passRetained(trace).toOpaque()
        self.context = context
        handle = tesseraTmuxRuntimeCreate(
            callback: receiveGridReleaseABIEvent,
            context: context
        )
    }

    deinit {
        tesseraTmuxRuntimeDestroy(handle: handle)
        Unmanaged<GridReleaseABITrace>.fromOpaque(context).release()
    }

    func submit(_ fact: RenderFact, file: StaticString = #filePath, line: UInt = #line) {
        let encoded = try! SharedABI.encoder.encode(fact)
        let result = encoded.withUnsafeBytes { raw in
            tesseraTmuxRuntimeSubmitFact(
                handle: handle,
                json: raw.bindMemory(to: UInt8.self).baseAddress,
                count: raw.count
            )
        }
        XCTAssertEqual(result, 0, "\(fact)", file: file, line: line)
        absorbEvents()
    }

    /// With `nowMillis`, fed as Android feeds a runtime with an authority
    /// session attached (`tessera_tmux_runtime_feed_at`).
    func feed(_ text: String, at nowMillis: Int64? = nil, file: StaticString = #filePath, line: UInt = #line) {
        let result = Array(text.utf8).withUnsafeBytes { raw in
            if let nowMillis {
                return tesseraTmuxRuntimeFeedAt(
                    handle: handle,
                    bytes: raw.bindMemory(to: UInt8.self).baseAddress,
                    count: raw.count,
                    nowMillis: nowMillis
                )
            }
            return tesseraTmuxRuntimeFeed(
                handle: handle,
                bytes: raw.bindMemory(to: UInt8.self).baseAddress,
                count: raw.count
            )
        }
        // 1: accepted, with the attached session's result in its event.
        XCTAssertTrue(result == 0 || result == 1, "feed returned \(result)", file: file, line: line)
        absorbEvents()
    }

    func setOptions(_ options: TmuxABIRenderLedgerOptions) {
        XCTAssertEqual(tesseraTmuxRuntimeSetRenderLedgerOptions(handle: handle, options: options.rawValue), 0)
    }

    /// The returned projection work is applied as a callback's effects would be.
    func settleReleasing(generation: UInt64) throws {
        let released = projectRuntimeAuthority(handle: handle, authority: .mine(generation: generation))
        XCTAssertGreaterThan(released.result, 0)
        let document = try XCTUnwrap(JSONSerialization.jsonObject(with: released.document) as? [String: Any])
        XCTAssertEqual(Set(document.keys), ["renderEffects"])
        absorbEvents()
        absorb(try XCTUnwrap(document["renderEffects"] as? [[String: Any]]))
    }

    var deepCaptures: [String] {
        sent.filter { $0.hasPrefix("capture-pane") && $0.contains(" -S ") }
    }

    func resetObservations() {
        sent.removeAll()
        bound.removeAll()
    }

    /// Answer the wire until the ledger goes quiet.
    func drain(file: StaticString = #filePath, line: UInt = #line) {
        for _ in 0..<128 {
            if !outstanding.isEmpty {
                let command = outstanding.removeFirst()
                var lines: [String] = []
                let metadataPrefix = "display-message -p -t %"
                if command.hasPrefix(metadataPrefix),
                   let pane = Int(command.dropFirst(metadataPrefix.count).prefix { $0.isNumber }) {
                    lines = [Self.metadata(pane: pane)]
                } else if command.hasPrefix("capture-pane") {
                    lines = ["rows"]
                }
                reply(lines)
            } else if !timers.isEmpty {
                submit(.timerFired(token: timers.removeFirst()))
            } else {
                return
            }
        }
        XCTFail("the ledger never went quiet: \(outstanding) \(timers)", file: file, line: line)
    }

    private func reply(_ lines: [String]) {
        let sequence = nextReply
        nextReply += 1
        feed(
            "%begin 1 \(sequence) 1\r\n"
                + lines.map { $0 + "\r\n" }.joined()
                + "%end 1 \(sequence) 1\r\n"
        )
    }

    private func absorbEvents() {
        while absorbedEvents < trace.events.count {
            let event = trace.events[absorbedEvents]
            absorbedEvents += 1
            absorb(event["renderEffects"] as? [[String: Any]] ?? [])
        }
    }

    private func absorb(_ effects: [[String: Any]]) {
        var stateRequests: [(String, UInt64)] = []
        for effect in effects {
            switch effect["kind"] as? String {
            case "sendCommand":
                guard let command = effect["command"] as? String else { continue }
                outstanding.append(command)
                sent.append(command)
            case "armTimer":
                if let token = (effect["token"] as? NSNumber)?.uint64Value { timers.append(token) }
            case "cancelTimer":
                if let token = (effect["token"] as? NSNumber)?.uint64Value { timers.removeAll { $0 == token } }
            case "bindSurface":
                if let surface = effect["surfaceID"] as? String { bound.append(surface) }
            case "resolveSurfaceState":
                if let surface = effect["surfaceID"] as? String,
                   let request = (effect["request"] as? NSNumber)?.uint64Value {
                    stateRequests.append((surface, request))
                }
            default:
                break
            }
        }
        for (surface, request) in stateRequests {
            submit(.surfaceState(
                SurfaceId(surface),
                request: request,
                altScreen: false,
                mouseMode: .off,
                columns: paneWidths[surface] ?? 40,
                rows: 24
            ))
        }
    }

    private static func metadata(pane: Int) -> String {
        [
            "%\(pane)", "0", "0", "pane", "window", "host", "0",
            "30", "0", "23", "1", "0", "0", "0", "1", "0", "0", "0", "0", "0", "0", "0",
        ].joined(separator: "\t")
    }
}

/// F6, at the deepest seam Android reaches host-free (its JVM tests cannot
/// load the core): a split window's grid panes regain their history after a
/// relayout they skipped while a peer held the grid, on both release paths
/// the Android adapter has. The ledger's own rules are
/// `RenderLedgerYieldedRepaintTests` (597f9e4a, a3f6bd96); this drives them
/// through the runtime handle, the surface ids, the correlated visible-rows
/// take-back request and the releasing settlement Android uses.
final class TmuxRuntimeGridHistoryReleaseABITests: XCTestCase {
    private let paneOne = "pane:1"
    private let paneTwo = "pane:2"
    private let deepOne = RenderCommands.deepPrimary(target: PaneId(1), depth: 2_000)
    private let deepTwo = RenderCommands.deepPrimary(target: PaneId(2), depth: 2_000)

    private func layout(firstWidth: Int) -> String {
        "abcd,80x24,0,0{\(firstWidth)x24,0,0,1,\(79 - firstWidth)x24,\(firstWidth + 1),0,2}"
    }

    private func relayout(_ wire: GridReleaseABIWire, firstWidth: Int) {
        wire.paneWidths = [paneOne: firstWidth, paneTwo: 79 - firstWidth]
        wire.feed("%layout-change @1 \(layout(firstWidth: firstWidth)) \(layout(firstWidth: firstWidth)) *\r\n")
    }

    /// A split window whose two grid panes were painted by a deep first fill,
    /// then a peer that took the grid and relaid the window out.
    private func gridYieldedAcrossAPeerRelayout() -> GridReleaseABIWire {
        let wire = GridReleaseABIWire()
        // What the adapter sets when it publishes the runtime (no claim yet).
        wire.setOptions([.suppressesUnchangedClientSizeReplay, .pipelinesVisibleCapture])
        wire.submit(.transportAttached(.inline))
        wire.feed("%session-changed $0 work\r\n%window-add @1\r\n%session-window-changed $0 @1\r\n"
            + "%window-pane-changed @1 %1\r\n")
        relayout(wire, firstWidth: 40)
        wire.submit(.surfacesDeclared([
            .init(surfaceID: SurfaceId(paneOne), presentation: .grid, windowID: WindowId(1), paneID: PaneId(1)),
            .init(surfaceID: SurfaceId(paneTwo), presentation: .grid, windowID: WindowId(1), paneID: PaneId(2)),
        ]))
        wire.drain()
        for surface in [paneOne, paneTwo] {
            wire.submit(.refreshRequested(SurfaceId(surface), stage: .deep, reason: "mount"))
            wire.drain()
        }
        XCTAssertEqual(Set(wire.deepCaptures), [deepOne, deepTwo], "precondition: both panes painted deep \(wire.sent)")

        // A stamp-less peer takes the grid and relays the window out.
        XCTAssertGreaterThan(projectRuntimeAuthority(handle: wire.handle, authority: .peer(deviceID: "-", displayName: "another device", generation: 0)).result, 0)
        wire.resetObservations()
        relayout(wire, firstWidth: 30)
        wire.drain()
        XCTAssertEqual(wire.sent, [], "a peer's relayout costs this device no capture")
        return wire
    }

    /// The take-back path: Android repaints each painted pane at visible rows
    /// under the claim's correlation, and the claim's releasing settlement
    /// hands back each pane's history capture.
    func testGridTakeBackAfterAPeerRelayoutDeepensEachPaneAtSettlement() throws {
        let wire = gridYieldedAcrossAPeerRelayout()
        wire.setOptions([
            .suppressesUnchangedClientSizeReplay, .inlineClientSizeReplayBelongsToClaim, .pipelinesVisibleCapture,
        ])
        for surface in [paneOne, paneTwo] {
            wire.submit(.correlatedRefreshRequested(
                SurfaceId(surface), stage: .viewportOnly, reason: "authority-reclaim", correlation: 8
            ))
        }
        wire.drain()
        XCTAssertEqual(wire.deepCaptures, [], "no history while the peer holds the grid")
        XCTAssertEqual(Set(wire.bound), [paneOne, paneTwo], "both panes rebuilt under fresh owners")

        wire.resetObservations()
        try wire.settleReleasing(generation: 8)
        wire.drain()
        XCTAssertEqual(Set(wire.deepCaptures), [deepOne, deepTwo], "\(wire.sent)")
        XCTAssertTrue(wire.trace.errors.isEmpty, "\(wire.trace.errors)")
    }

    /// A fresh own read with no claim projects mine into the runtime, which
    /// pays the relayout debt at once: a visible rebuild of each pane, then
    /// its history.
    func testGridOwnProjectionAfterARelayoutRebuildsAndDeepensEachPane() throws {
        let wire = gridYieldedAcrossAPeerRelayout()
        try wire.settleReleasing(generation: 9)
        wire.drain()
        XCTAssertEqual(Set(wire.bound), [paneOne, paneTwo], "rebuilt under fresh owners")
        XCTAssertEqual(Set(wire.deepCaptures), [deepOne, deepTwo], "\(wire.sent)")
        XCTAssertTrue(wire.trace.errors.isEmpty, "\(wire.trace.errors)")
    }
}
