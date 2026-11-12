import Foundation
import SwiftUI

struct ArtifactDiffLine: Identifiable, Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case fileHeader, metadata, hunk, context, added, removed, notice
    }

    let id: Int
    let kind: Kind
    /// The diff marker is separate so code indentation stays intact.
    let text: String
    let oldLineNumber: Int?
    let newLineNumber: Int?
}

struct ArtifactParsedDiff: Equatable, Sendable {
    let lines: [ArtifactDiffLine]
    let addedLineCount: Int
    let removedLineCount: Int
    let lineNumberDigits: Int
}

/// AgentEditCard currently renders raw Text(diff), without a parser. This
/// module-visible parser can also be used there when that surface is wired.
/// Metadata never consumes a line number, and every file/hunk resets ranges.
enum ArtifactDiffParser {
    static func parse(_ diff: String) -> ArtifactParsedDiff {
        var source = diff.split(omittingEmptySubsequences: false) { $0 == "\n" || $0 == "\r\n" }
        if source.last?.isEmpty == true { source.removeLast() }
        if diff.isEmpty { source.removeAll() }
        var rows: [ArtifactDiffLine] = []
        rows.reserveCapacity(source.count)
        var oldLine: Int?
        var newLine: Int?
        var oldRemaining = 0
        var newRemaining = 0
        var added = 0
        var removed = 0
        var largestNumber = 1

        for (offset, raw) in source.enumerated() {
            var text = String(raw)
            if text.hasSuffix("\r") { text.removeLast() }
            let kind: ArtifactDiffLine.Kind
            var oldNumber: Int?
            var newNumber: Int?
            if text.hasPrefix("@@") {
                if let range = hunkRange(text) {
                    // A start of 0 with lines is no position: an agent's edit
                    // known only by its old and new text. Its lines go unnumbered,
                    // and its header, which names no lines, shows as a break.
                    oldLine = range.oldStart == 0 && range.oldCount > 0 ? nil : range.oldStart
                    newLine = range.newStart == 0 && range.newCount > 0 ? nil : range.newStart
                    if (range.oldStart == 0 && range.oldCount > 0) || (range.newStart == 0 && range.newCount > 0) { text = "⋯" }
                    oldRemaining = range.oldCount
                    newRemaining = range.newCount
                    kind = .hunk
                } else {
                    oldLine = nil; newLine = nil
                    oldRemaining = 0; newRemaining = 0
                    kind = .metadata
                }
            } else if text.hasPrefix("\\ No newline at end of file") {
                kind = .notice
            } else if oldRemaining > 0 || newRemaining > 0 {
                switch text.first {
                case "+" where newRemaining > 0:
                    kind = .added
                    newNumber = newLine
                    newLine = newLine.map { $0 + 1 }
                    newRemaining -= 1
                    added += 1
                    text.removeFirst()
                case "-" where oldRemaining > 0:
                    kind = .removed
                    oldNumber = oldLine
                    oldLine = oldLine.map { $0 + 1 }
                    oldRemaining -= 1
                    removed += 1
                    text.removeFirst()
                case " " where oldRemaining > 0 && newRemaining > 0:
                    kind = .context
                    oldNumber = oldLine
                    newNumber = newLine
                    oldLine = oldLine.map { $0 + 1 }
                    newLine = newLine.map { $0 + 1 }
                    oldRemaining -= 1
                    newRemaining -= 1
                    text.removeFirst()
                default:
                    // Truncated/malformed patches remain readable; do not
                    // assign invented numbers to the following metadata.
                    kind = text.hasPrefix("diff ") || text.hasPrefix("--- ") || text.hasPrefix("+++ ") ? .fileHeader : .metadata
                    oldLine = nil; newLine = nil
                    oldRemaining = 0; newRemaining = 0
                }
            } else {
                kind = text.hasPrefix("diff ") || text.hasPrefix("--- ") || text.hasPrefix("+++ ") ? .fileHeader : .metadata
                oldLine = nil; newLine = nil
            }
            largestNumber = max(largestNumber, max(oldNumber ?? 0, newNumber ?? 0))
            rows.append(ArtifactDiffLine(id: offset, kind: kind, text: text,
                                         oldLineNumber: oldNumber, newLineNumber: newNumber))
        }
        return ArtifactParsedDiff(lines: rows, addedLineCount: added, removedLineCount: removed,
                                  lineNumberDigits: String(largestNumber).count)
    }

    private struct Range {
        let oldStart: Int
        let oldCount: Int
        let newStart: Int
        let newCount: Int
    }

    private static func hunkRange(_ header: String) -> Range? {
        // Unified diffs omit ,1, and use ,0 for a new/deleted file. Combined
        // diffs (@@@) and malformed/overflowing ranges are left as metadata.
        let fields = header.split(separator: " ", omittingEmptySubsequences: true)
        guard fields.count >= 4, fields[0] == "@@", fields[3] == "@@",
              let old = range(fields[1], marker: "-"), let new = range(fields[2], marker: "+") else { return nil }
        return Range(oldStart: old.0, oldCount: old.1, newStart: new.0, newCount: new.1)
    }

    private static func range(_ source: Substring, marker: Character) -> (Int, Int)? {
        guard source.first == marker else { return nil }
        let numbers = source.dropFirst().split(separator: ",", omittingEmptySubsequences: false)
        guard numbers.count == 1 || numbers.count == 2,
              numbers.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy { $0 >= 48 && $0 <= 57 } }),
              let start = Int(numbers[0]), let count = numbers.count == 2 ? Int(numbers[1]) : 1,
              !start.addingReportingOverflow(count).overflow else { return nil }
        return (start, count)
    }
}

@MainActor
struct ArtifactDiffView: View {
    let path: String
    let diff: String
    @Environment(\.designTokens) private var T
    @State private var parsed: ArtifactParsedDiff?

    init(path: String, diff: String) {
        self.path = path
        self.diff = diff
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "pencil.line").foregroundStyle(T.fgMuted)
                Text(verbatim: path)
                    .foregroundStyle(T.fgMuted)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                if let parsed {
                    // The same semantic colors as AgentChangesView and the
                    // agent thread row's authoritative edit totals.
                    Text(verbatim: "+\(parsed.addedLineCount)").foregroundStyle(T.green)
                    Text(verbatim: "−\(parsed.removedLineCount)").foregroundStyle(T.red)
                }
            }
            .font(Typography.tesseraMono(size: 11))
            .padding(12)
            .background(T.inputBg)
            .overlay(alignment: .bottom) { Rectangle().fill(T.border).frame(height: 1) }
            if let parsed {
                if parsed.lines.isEmpty {
                    ContentUnavailableView("no changes", systemImage: "doc.text")
                } else {
                    GeometryReader { geometry in
                        ScrollView([.horizontal, .vertical]) {
                            LazyVStack(alignment: .leading, spacing: 0) {
                                ForEach(parsed.lines) { line in
                                    row(line, digits: parsed.lineNumberDigits)
                                }
                            }
                            .padding(.vertical, 8)
                            // A two-axis scroll view centres content smaller than
                            // itself; a short diff starts at the top instead.
                            .frame(minWidth: geometry.size.width, minHeight: geometry.size.height,
                                   alignment: .topLeading)
                        }
                        .textSelection(.enabled)
                    }
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(T.panelBg)
        .task(id: diff) {
            parsed = nil
            let source = diff
            let task = Task.detached(priority: .userInitiated) { ArtifactDiffParser.parse(source) }
            let result = await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
            guard !Task.isCancelled else { return }
            parsed = result
        }
    }

    private func row(_ line: ArtifactDiffLine, digits: Int) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            number(line.oldLineNumber, digits: digits)
            number(line.newLineNumber, digits: digits)
            Text(verbatim: marker(line.kind))
                .foregroundStyle(lineColor(line.kind))
                .frame(width: 20)
            Text(verbatim: line.text.isEmpty ? " " : line.text)
                .foregroundStyle(lineColor(line.kind))
                .fixedSize(horizontal: true, vertical: false)
                .padding(.trailing, 16)
            Spacer(minLength: 0)
        }
        .font(Typography.tesseraMono(size: 11))
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(lineBackground(line.kind))
        .accessibilityElement(children: .combine)
    }

    private func number(_ number: Int?, digits: Int) -> some View {
        Text(verbatim: number.map(String.init) ?? "")
            .foregroundStyle(T.fgDim)
            .frame(width: CGFloat(max(3, digits)) * 8 + 8, alignment: .trailing)
            .padding(.trailing, 4)
    }

    private func marker(_ kind: ArtifactDiffLine.Kind) -> String {
        switch kind {
        case .added: return "+"
        case .removed: return "−"
        default: return " "
        }
    }

    private func lineColor(_ kind: ArtifactDiffLine.Kind) -> Color {
        switch kind {
        case .added: return T.green
        case .removed: return T.red
        case .hunk, .notice: return T.fgDim
        default: return T.fgMuted
        }
    }

    private func lineBackground(_ kind: ArtifactDiffLine.Kind) -> Color {
        switch kind {
        case .added: return T.green.opacity(0.10)
        case .removed: return T.red.opacity(0.10)
        case .hunk, .fileHeader: return T.inputBg
        default: return .clear
        }
    }
}
