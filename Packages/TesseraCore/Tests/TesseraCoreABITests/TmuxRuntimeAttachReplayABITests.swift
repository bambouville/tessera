import Foundation
import XCTest
import TmuxControlCore
@testable import TesseraCoreABI

private final class TmuxABIReplayCapture: @unchecked Sendable {
    var events: [Data] = []
}

private let receiveTmuxABIReplayEvent: TesseraCoreABIEventCallback = { bytes, count, context in
    guard let bytes, let context else { return }
    let capture = Unmanaged<TmuxABIReplayCapture>.fromOpaque(context).takeUnretainedValue()
    capture.events.append(Data(bytes: bytes, count: count))
}

/// Byte-exact replay of a Pixel attach against a macOS host whose pty was
/// still cooked when the first commands went out, so their echo preceded the
/// control-mode DCS. Reconstructed from the on-device wire trace of
/// 2026-09-06 03:28:53 (tags 1-9, chunks 1-5).
final class TmuxRuntimeAttachReplayABITests: XCTestCase {
    private let commands = [
        "display-message -p '#{window_id}'",
        "list-windows -F '__tessera_windows__\t#{window_id}\t#{window_index}\t#{pane_id}\t#{window_layout}\t#{window_visible_layout}\t#{window_zoomed_flag}\t#{s/\t/ /:window_name}'",
        "list-panes -s -F '__tessera_panes__\t#{window_id}\t#{pane_id}\t#{pane_active}\t#{pane_left}\t#{pane_top}\t#{pane_width}\t#{pane_height}\t#{s/\t/ /:pane_title}\t#{s/\t/ /:pane_current_path}\t#{host}'",
        "display-message -p '__tessera_active_window__\t#{window_id}'",
        "refresh-client -f pause-after=5",
        "refresh-client -B 'tessera-authority:%*:#{@tessera_authority}'",
        "refresh-client -B 'tessera-bell:%*:#{window_bell_flag}'",
        "refresh-client -B 'tessera-pane-meta:%*:#{window_id}\t#{pane_id}\t#{pane_active}\t#{pane_left}\t#{pane_top}\t#{pane_width}\t#{pane_height}\t#{s/\t/ /:pane_current_command}\t#{s/\t/ /:pane_title}\t#{s/\t/ /:window_name}\t#{host}\t#{s/\t/ /:pane_current_path}\t#{s/\t/ /:pane_current_path}'",
        "display-message -p '#{client_flags}'",
    ]

    private func feed(_ text: String, to handle: UnsafeMutableRawPointer) -> Int32 {
        let bytes = Array(text.utf8)
        return bytes.withUnsafeBytes { raw in
            tesseraTmuxRuntimeFeed(handle: handle, bytes: raw.bindMemory(to: UInt8.self).baseAddress, count: raw.count)
        }
    }

    private func submit(_ fact: RenderFact, to handle: UnsafeMutableRawPointer) throws -> Int32 {
        let encoded = try SharedABI.encoder.encode(fact)
        return encoded.withUnsafeBytes { raw in
            tesseraTmuxRuntimeSubmitFact(handle: handle, json: raw.bindMemory(to: UInt8.self).baseAddress, count: raw.count)
        }
    }

    private func send(_ command: String, to handle: UnsafeMutableRawPointer) -> Int64 {
        let bytes = Array(command.utf8)
        return bytes.withUnsafeBytes { raw in
            tesseraTmuxRuntimeSendCommand(handle: handle, text: raw.bindMemory(to: UInt8.self).baseAddress, count: raw.count)
        }
    }

    private func effects(_ capture: TmuxABIReplayCapture) throws -> [[String: Any]] {
        try capture.events.flatMap { data -> [[String: Any]] in
            let event = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            return event["renderEffects"] as? [[String: Any]] ?? []
        }
    }

    func testCookedPtyEchoBeforeDCSLeavesEveryPlatformReplyAttributed() throws {
        let capture = TmuxABIReplayCapture()
        let context = Unmanaged.passRetained(capture).toOpaque()
        let handle = tesseraTmuxRuntimeCreate(
            callback: receiveTmuxABIReplayEvent, context: context
        )
        defer {
            tesseraTmuxRuntimeDestroy(handle: handle)
            Unmanaged<TmuxABIReplayCapture>.fromOpaque(context).release()
        }

        XCTAssertEqual(try submit(.transportAttached(.inline), to: handle), 0)
        var tags: [Int64] = []
        for command in commands { tags.append(send(command, to: handle)) }
        XCTAssertEqual(tags, Array(1...9).map(Int64.init))

        // Chunks 1-3: the cooked pty echoes the commands back, `\r\n` ended.
        XCTAssertEqual(feed(commands[0] + "\r\n", to: handle), 0)
        XCTAssertEqual(feed(commands[1...6].map { $0 + "\r\n" }.joined(), to: handle), 0)
        XCTAssertEqual(feed(commands[7...8].map { $0 + "\r\n" }.joined(), to: handle), 0)
        // Chunk 4: DCS, the attach frame (flags 0) and the session notification.
        XCTAssertEqual(feed(
            "\u{1B}P1000p%begin 1788665331 1586689 0\r\n%end 1788665331 1586689 0\r\n"
                + "%session-changed $0 tessera-6d7ab28a\r\n",
            to: handle
        ), 0)
        // Chunk 5: the nine client-originated replies, then the first output.
        let chunk5 = [
            "%begin 1788665331 1586693 1", "@3", "%end 1788665331 1586693 1",
            "%begin 1788665331 1586694 1",
            "__tessera_windows__\t@5\t0\t%5\tb702,105x33,0,0,5\tb702,105x33,0,0,5\t0\tzsh",
            "__tessera_windows__\t@3\t1\t%3\tb700,105x33,0,0,3\tb700,105x33,0,0,3\t0\t✳ Android app tmux window creation display issue",
            "__tessera_windows__\t@7\t2\t%7\tb704,105x33,0,0,7\tb704,105x33,0,0,7\t0\tzsh",
            "%end 1788665331 1586694 1",
            "%begin 1788665331 1586695 1",
            "__tessera_panes__\t@5\t%5\t1\t0\t0\t105\t33\tzsh\t/Users/avery/projects/tessera/scripts\tAverys-Mac-mini.local",
            "__tessera_panes__\t@3\t%3\t1\t0\t0\t105\t33\t✳ Android app tmux window creation display issue\t/Users/avery/projects/tessera\tAverys-Mac-mini.local",
            "__tessera_panes__\t@7\t%7\t1\t0\t0\t105\t33\tzsh\t/Users/avery\tAverys-Mac-mini.local",
            "%end 1788665331 1586695 1",
            "%begin 1788665331 1586696 1", "__tessera_active_window__\t@3", "%end 1788665331 1586696 1",
            "%begin 1788665331 1586697 1", "%end 1788665331 1586697 1",
            "%begin 1788665331 1586698 1", "%end 1788665331 1586698 1",
            "%begin 1788665331 1586699 1", "%end 1788665331 1586699 1",
            "%begin 1788665331 1586700 1", "%end 1788665331 1586700 1",
            "%begin 1788665331 1586701 1", "attached,focused,control-mode,pause-after=5,UTF-8", "%end 1788665331 1586701 1",
            "%extended-output %3 0 : \\033[?25l\\033[?12l\\033[?25h",
        ].map { $0 + "\r\n" }.joined()
        XCTAssertEqual(feed(chunk5, to: handle), 0)

        let all = try effects(capture)
        let replies = all.filter { $0["kind"] as? String == "commandReply" }
        let replyTags = replies.compactMap { ($0["tag"] as? NSNumber)?.int64Value }
        let diagnostics = all.filter { $0["kind"] as? String == "diagnostic" }
        let dump = all.map { "\($0)" }.joined(separator: "\n")
        XCTAssertEqual(replyTags, Array(1...9).map(Int64.init), "every platform command must be answered once, in order\n\(dump)")
        XCTAssertEqual(replies.first?["lines"] as? [String], ["@3"])
        XCTAssertEqual(replies.last?["lines"] as? [String], ["attached,focused,control-mode,pause-after=5,UTF-8"])
        for diagnostic in diagnostics {
            let text = "\(diagnostic)"
            XCTAssertFalse(text.contains("queue=1"), "the FIFO must be drained when output arrives: \(text)")
            XCTAssertFalse(text.contains("unmatched-reply") || text.contains("torn-frame"), text)
        }
        print("REPLAY EFFECTS\n\(dump)")
    }
}
