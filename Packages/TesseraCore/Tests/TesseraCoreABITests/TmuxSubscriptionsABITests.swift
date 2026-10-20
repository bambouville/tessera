import Foundation
import XCTest
@testable import TesseraCoreABI
import TmuxControlCore

private final class SubscriptionEvents {
    var values: [[String: Any]] = []
}

private let receiveSubscriptionEvent: TesseraCoreABIEventCallback = { bytes, count, context in
    guard let bytes, let context,
          let event = try? JSONSerialization.jsonObject(with: Data(bytes: bytes, count: count)) as? [String: Any]
    else { return }
    Unmanaged<SubscriptionEvents>.fromOpaque(context).takeUnretainedValue().values.append(event)
}

/// The runtime registers every `refresh-client -B` feed per pane or on one
/// window: tmux 3.2 through 3.6a crash the server when a client holding a
/// `%*`, `@*` or session subscription outlives its session.
final class TmuxSubscriptionsABITests: XCTestCase {
    private let all: UInt32 = 0b1111

    func testFeedsFollowTheTopologyPerPaneThroughEvents() throws {
        let events = SubscriptionEvents()
        let context = Unmanaged.passRetained(events).toOpaque()
        let handle = tesseraTmuxRuntimeCreate(callback: receiveSubscriptionEvent, context: context)
        defer {
            tesseraTmuxRuntimeDestroy(handle: handle)
            Unmanaged<SubscriptionEvents>.fromOpaque(context).release()
        }
        func feed(_ text: String) {
            XCTAssertEqual(Array(text.utf8).withUnsafeBufferPointer {
                tesseraTmuxRuntimeFeed(handle: handle, bytes: $0.baseAddress, count: $0.count)
            }, 0)
        }
        func taken() -> [String] {
            defer { events.values.removeAll() }
            return events.values.flatMap { $0["subscriptionCommands"] as? [String] ?? [] }
        }

        XCTAssertEqual(tesseraTmuxRuntimeSetSubscriptions(handle: handle, feeds: all, authorityOwnerSessionID: -1), 0)
        XCTAssertEqual(taken(), [], "no pane is known before the window list answers")

        feed("%session-changed $1 work\r\n%begin 1 1 1\r\n"
                + "__tessera_windows__\t@1\t0\t%10\taa01,80x24,0,0{40x24,0,0,10,39x24,41,0,11}\taa01,80x24,0,0{40x24,0,0,10,39x24,41,0,11}\t0\tzsh\r\n"
                + "%end 1 1 1\r\n%begin 1 2 1\r\n__tessera_active_window__\t@1\t3.4\r\n%end 1 2 1\r\n")
        let registered = taken()
        XCTAssertEqual(registered, [
            "refresh-client -B 'tessera-authority:@1:#{@tessera_authority}'"
                + " -B 'tessera-window-order:@1:\(TmuxWindowOrderSubscription.format)'",
            "refresh-client -B 'tessera-pane-meta.10:%10:\(TmuxPaneMetadataSubscription.format)'"
                + " -B 'tessera-bell.10:%10:#{window_bell_flag}'",
            "refresh-client -B 'tessera-pane-meta.11:%11:\(TmuxPaneMetadataSubscription.format)'"
                + " -B 'tessera-bell.11:%11:#{window_bell_flag}'",
        ])
        for command in registered {
            XCTAssertFalse(command.contains(":%*:") || command.contains(":@*:") || command.contains("::"), command)
        }

        feed("%layout-change @1 aa01,80x24,0,0,11 aa01,80x24,0,0,11 *\r\n")
        XCTAssertEqual(taken(), ["refresh-client -B 'tessera-bell.10' -B 'tessera-pane-meta.10'"])

        XCTAssertEqual(tesseraTmuxRuntimeSetSubscriptions(handle: handle, feeds: 8, authorityOwnerSessionID: 42), 0)
        XCTAssertEqual(taken(), [
            "refresh-client -B 'tessera-bell.11' -B 'tessera-pane-meta.11' -B 'tessera-window-order'",
            "refresh-client -B 'tessera-authority:@1:\(TmuxGridAuthority.subscriptionFormat(.owner(SessionId(42))))'",
        ])
        XCTAssertEqual(tesseraTmuxRuntimeSetSubscriptions(handle: handle, feeds: 8, authorityOwnerSessionID: 42), 0)
        XCTAssertEqual(events.values.count, 0, "an unchanged request emits nothing")
    }

    /// Registrations grow with the pane count; a large topology's must not
    /// push one callback past its ceiling. They continue in further events,
    /// in order, and a reentrant request issued from the first event's
    /// callback lands after them.
    func testALargeTopologyRegistersAcrossSeveralEventsInOrder() throws {
        final class Box { var handle: UnsafeMutableRawPointer?; var events: [[String: Any]] = []; var reentered = false }
        let box = Box()
        let context = Unmanaged.passRetained(box).toOpaque()
        let handle = tesseraTmuxRuntimeCreate(callback: { bytes, count, context in
            guard let bytes, let context,
                  let event = try? JSONSerialization.jsonObject(with: Data(bytes: bytes, count: count)) as? [String: Any]
            else { return }
            let box = Unmanaged<Box>.fromOpaque(context).takeUnretainedValue()
            box.events.append(event)
            if !box.reentered, event["subscriptionCommands"] != nil {
                box.reentered = true
                _ = tesseraTmuxRuntimeSetSubscriptions(handle: box.handle, feeds: 2, authorityOwnerSessionID: -1)
            }
        }, context: context)
        box.handle = handle
        defer {
            tesseraTmuxRuntimeDestroy(handle: handle)
            Unmanaged<Box>.fromOpaque(context).release()
        }
        XCTAssertEqual(tesseraTmuxRuntimeSetSubscriptions(handle: handle, feeds: 3, authorityOwnerSessionID: -1), 0)
        let rows = (0..<400).map { "__tessera_windows__\t@\($0)\t\($0)\t%\($0)\taa01,80x24,0,0,\($0)\taa01,80x24,0,0,\($0)\t0\tw" }
        let wire = "%session-changed $1 work\r\n%begin 1 1 1\r\n" + rows.joined(separator: "\r\n") + "\r\n%end 1 1 1\r\n"
        XCTAssertEqual(Array(wire.utf8).withUnsafeBufferPointer {
            tesseraTmuxRuntimeFeed(handle: handle, bytes: $0.baseAddress, count: $0.count)
        }, 0)
        let carrying = box.events.compactMap { $0["subscriptionCommands"] as? [String] }
        XCTAssertGreaterThan(carrying.count, 2, "split across events")
        let commands = carrying.flatMap { $0 }
        let registrations = commands.filter { $0.contains("tessera-bell.") && $0.contains(":%") }
        XCTAssertEqual(registrations.count, 400)
        XCTAssertEqual(registrations, (0..<400).map {
            "refresh-client -B 'tessera-pane-meta.\($0):%\($0):\(TmuxPaneMetadataSubscription.format)'"
                + " -B 'tessera-bell.\($0):%\($0):#{window_bell_flag}'"
        })
        let firstRemoval = try XCTUnwrap(commands.firstIndex { !$0.contains(":") })
        XCTAssertGreaterThan(firstRemoval, try XCTUnwrap(commands.lastIndex { $0.contains("tessera-bell.399:") }),
                             "the reentrant request's removals follow every queued registration")
        XCTAssertEqual(commands.filter { !$0.contains(":") }.joined().components(separatedBy: " -B ").count - 1, 400)
    }

    func testMalformedRequestsAreRefused() {
        let handle = tesseraTmuxRuntimeCreate(callback: receiveSubscriptionEvent, context: nil)
        defer { tesseraTmuxRuntimeDestroy(handle: handle) }
        XCTAssertEqual(tesseraTmuxRuntimeSetSubscriptions(handle: handle, feeds: 16, authorityOwnerSessionID: -1), -1)
        XCTAssertEqual(tesseraTmuxRuntimeSetSubscriptions(handle: handle, feeds: all, authorityOwnerSessionID: -2), -1)
        XCTAssertEqual(tesseraTmuxRuntimeSetSubscriptions(handle: nil, feeds: all, authorityOwnerSessionID: -1), -2)
    }
}
