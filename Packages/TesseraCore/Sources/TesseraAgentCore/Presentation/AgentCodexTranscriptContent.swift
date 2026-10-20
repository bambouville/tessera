import Foundation

/// Provider-owned presentation artifacts, not an HTML sanitizer. User text and
/// quoted examples must keep their literal bytes.
enum AgentCodexTranscriptContent {
    static func assistantText(_ text: String, truncated: Bool = false) -> String {
        let lines = text.components(separatedBy: "\n")
        var fence: Character?
        var fenceLength = 0
        for (index, line) in lines.enumerated() {
            // Four spaces or a tab is an indented Markdown code block, not
            // provider metadata. Do not turn literal code into a fence either.
            var indentation = 0
            for character in line {
                if character == " " { indentation += 1 }
                else if character == "\t" { indentation += 4 - indentation % 4 }
                else { break }
                if indentation >= 4 { break }
            }
            if indentation >= 4 { continue }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let first = trimmed.first, first == "`" || first == "~" {
                let count = trimmed.prefix(while: { $0 == first }).count
                if count >= 3 {
                    if fence == nil { fence = first; fenceLength = count }
                    else if fence == first && count >= fenceLength && trimmed.dropFirst(count).isEmpty { fence = nil }
                    continue
                }
            }
            guard fence == nil, trimmed == "<oai-mem-citation>" else { continue }
            let tail = lines[(index + 1)...].map { $0.trimmingCharacters(in: .whitespaces) }
            if truncated, tail.first == "<citation_entries>", !tail.contains("</oai-mem-citation>") {
                return lines[..<index].joined(separator: "\n").trimmingCharacters(in: .newlines)
            }
            // Strip only the provider's complete, trailing citation envelope.
            // A mention, fenced example, or malformed element stays readable.
            guard let close = tail.firstIndex(of: "</oai-mem-citation>"),
                  tail[tail.index(after: close)...].allSatisfy(\.isEmpty),
                  tail.first == "<citation_entries>",
                  let entriesEnd = tail.firstIndex(of: "</citation_entries>"),
                  let rolloutStart = tail.firstIndex(of: "<rollout_ids>"),
                  let rolloutEnd = tail.firstIndex(of: "</rollout_ids>"),
                  entriesEnd < rolloutStart, rolloutStart < rolloutEnd, rolloutEnd < close
            else { continue }
            return lines[..<index].joined(separator: "\n").trimmingCharacters(in: .newlines)
        }
        return text
    }

    static func subagent(_ text: String, recordID: String) -> AgentSubagentSummary? {
        let lines = text.components(separatedBy: "\n")
        guard lines.count >= 5,
              ["Message Type: MESSAGE", "Message Type: FINAL_ANSWER"].contains(lines[0]),
              lines[1].hasPrefix("Task name: /"), lines[2].hasPrefix("Sender: /"), lines[3] == "Payload:"
        else { return nil }
        let sender = String(lines[2].dropFirst("Sender: ".count))
        guard sender.count <= 512, !sender.contains(where: \.isWhitespace) else { return nil }
        let body = assistantText(lines.dropFirst(4).joined(separator: "\n"))
        guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return .init(id: recordID, type: sender, summary: body,
                     status: lines[0] == "Message Type: FINAL_ANSWER" ? .finished : .working)
    }

    /// Completion events repeat the final answer. Keep the completion marker,
    /// but only suppress its body when the adjacent visible answer proves it is
    /// a duplicate. Recompute from retained messages so backward paging works.
    static func presentationMessages(_ messages: [AgentMessage]) -> [AgentMessage] {
        var precedingAnswer: String?
        return messages.map { message in
            var blocks = message.blocks
            if blocks.count == 1, case .completion(let summary) = blocks[0] {
                // response_item retains citations; task_complete may already
                // remove them but leave their preceding blank lines. Compare
                // boundary newlines only; never rewrite the answer's Markdown.
                if let summary, let precedingAnswer,
                   summary.trimmingCharacters(in: .newlines) == precedingAnswer.trimmingCharacters(in: .newlines) {
                    blocks = [.completion(nil)]
                }
                precedingAnswer = nil
            } else {
                let prose = blocks.compactMap { block -> String? in
                    if case .text(let value) = block { return value }
                    return nil
                }
                precedingAnswer = message.role == .assistant && prose.count == blocks.count && !prose.isEmpty
                    ? prose.joined(separator: "\n") : nil
            }
            return .init(recordID: message.recordID, role: message.role, displayTime: message.displayTime, blocks: blocks)
        }
    }
}
