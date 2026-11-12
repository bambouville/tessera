import Foundation

/// Claude's Edit, MultiEdit and Write calls carry their change in the call's
/// input, and Claude writes no separate edit record, so the core derives one:
/// the thread's edit card, its open-as-a-tab action and the browser's unseen
/// mark all need it. The transcript gives no line numbers for Edit, so its
/// hunks start at 0, which no real hunk with lines does; the viewers draw
/// such a hunk's lines unnumbered.
enum AgentClaudeEdit {
    static let toolNames: Set<String> = ["Edit", "MultiEdit", "Write"]

    /// Nil unless the input is complete and names a file: the projector cuts
    /// long previews short, and such a call stays a plain tool call.
    static func edit(name: String, preview: String, recordID: String) -> AgentEditRecord? {
        guard toolNames.contains(name),
              let input = try? JSONDecoder().decode(AgentJSONValue.self, from: Data(preview.utf8)).objectValue,
              let path = input["file_path"]?.stringValue, !path.isEmpty else { return nil }
        var hunks: [Hunk] = []
        switch name {
        case "Write":
            guard let content = input["content"]?.stringValue else { return nil }
            hunks = [Hunk(removed: [], added: lines(content), newStart: 1)]
        case "MultiEdit":
            guard let edits = input["edits"]?.arrayValue, !edits.isEmpty else { return nil }
            for edit in edits {
                guard let object = edit.objectValue, let old = object["old_string"]?.stringValue,
                      let new = object["new_string"]?.stringValue else { return nil }
                hunks.append(Hunk(removed: lines(old), added: lines(new), newStart: 0))
            }
        default:
            guard let old = input["old_string"]?.stringValue, let new = input["new_string"]?.stringValue else { return nil }
            hunks = [Hunk(removed: lines(old), added: lines(new), newStart: 0)]
        }
        return AgentEditRecord(
            id: recordID, path: path,
            additions: hunks.reduce(0) { $0 + $1.added.count },
            deletions: hunks.reduce(0) { $0 + $1.removed.count },
            diff: hunks.map(\.text).joined()
        )
    }

    private struct Hunk {
        let removed: [Substring]
        let added: [Substring]
        /// A whole-file write starts at the file's first line.
        let newStart: Int

        var text: String {
            let newStart = added.isEmpty ? 0 : self.newStart
            var text = "@@ -0,\(removed.count) +\(newStart),\(added.count) @@\n"
            for line in removed { text += "-\(line)\n" }
            for line in added { text += "+\(line)\n" }
            return text
        }
    }

    /// CRLF is one Character in Swift, so split on either ending.
    private static func lines(_ text: String) -> [Substring] {
        guard !text.isEmpty else { return [] }
        var lines = text.split(omittingEmptySubsequences: false) { $0 == "\n" || $0 == "\r\n" }
        if lines.last?.isEmpty == true { lines.removeLast() }
        return lines
    }
}
