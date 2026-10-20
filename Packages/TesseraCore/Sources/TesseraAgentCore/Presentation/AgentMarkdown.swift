import Foundation
import Markdown

/// A platform-neutral, non-executing representation of an agent Markdown response.
public struct AgentMarkdownDocument: Codable, Equatable, Sendable {
    public var blocks: [AgentMarkdownNode]
    public var truncated: Bool

    public init(blocks: [AgentMarkdownNode], truncated: Bool = false) {
        self.blocks = blocks
        self.truncated = truncated
    }

    /// A shared sample suitable for verifying the iOS and Android renderers.
    public static let verificationSample = """
    # Deployment summary

    The **migration** completed with `0` failures.

    - [x] Back up state
    - [ ] Verify the remote host

    | Check | Result |
    | :--- | ---: |
    | Tests | passing |

    ```sh
    tessera status
    ```
    """

    /// Parses CommonMark with GFM extensions into a bounded display-only tree.
    public static func parse(_ source: String) -> Self {
        let input = boundedInput(source)
        if let cached = markdownCache.value(for: input.value) {
            return Self(blocks: cached.blocks, truncated: cached.truncated || input.truncated)
        }
        var mapper = Mapper(initiallyTruncated: false)
        let document = Markdown.Document(parsing: input.value, options: [.disableSmartOpts])
        let parsed = Self(blocks: mapper.nodes(from: document), truncated: mapper.truncated)
        markdownCache.insert(parsed, for: input.value)
        return Self(blocks: parsed.blocks, truncated: parsed.truncated || input.truncated)
    }

    /// Parsed trees are reconstructible; memory pressure and disabling
    /// Agent Center drop them with the transcript content they came from.
    public static func purgeCache() { markdownCache.purge() }

    static func sizeCache(for budget: AgentContentBudget) { markdownCache.size(for: budget) }
    static func cachedForTesting(_ source: String) -> Bool { markdownCache.value(for: source) != nil }
    static var cacheLimitsForTesting: (count: Int, cost: Int) { markdownCache.limits }
}

/// Bounded and thread-safe on both platforms. Native view reconstruction and
/// the JNI required-size/copy calls must not repeatedly parse unchanged prose.
private final class AgentMarkdownCache: @unchecked Sendable {
    private final class Entry {
        let document: AgentMarkdownDocument
        init(_ document: AgentMarkdownDocument) { self.document = document }
    }
    private let entries = NSCache<NSString, Entry>()
    init() { size(for: .compact) }
    /// Sized for the rows of a rendered transcript range (one conversation's
    /// retained budget), so re-rendering on scroll hits the cache instead of
    /// re-parsing every visible row. Android's view layer keeps its own LRU
    /// in front of this one, which then only spans a JNI size/copy pair.
    func size(for budget: AgentContentBudget) {
        #if os(Android)
        entries.countLimit = 64
        entries.totalCostLimit = 1 << 20
        #else
        entries.countLimit = budget.perThreadBytes >> 14
        entries.totalCostLimit = budget.perThreadBytes
        #endif
    }
    func purge() { entries.removeAllObjects() }
    var limits: (count: Int, cost: Int) { (entries.countLimit, entries.totalCostLimit) }
    func value(for source: String) -> AgentMarkdownDocument? {
        entries.object(forKey: source as NSString)?.document
    }
    func insert(_ document: AgentMarkdownDocument, for source: String) {
        func cost(_ nodes: [AgentMarkdownNode]) -> Int {
            nodes.reduce(0) { $0 + 128 + ($1.text?.utf8.count ?? 0) + ($1.destination?.utf8.count ?? 0) + cost($1.children) }
        }
        entries.setObject(Entry(document), forKey: source as NSString, cost: source.utf8.count + cost(document.blocks))
    }
}

private let markdownCache = AgentMarkdownCache()

public enum AgentMarkdownKind: String, Codable, Equatable, Sendable {
    case paragraph
    case heading
    case quote
    case unorderedList
    case orderedList
    case listItem
    case codeBlock
    case thematicBreak
    case table
    case tableRow
    case tableCell
    case text
    case strong
    case emphasis
    case strikethrough
    case inlineCode
    case link
    case softBreak
    case lineBreak
    case image
}

public struct AgentMarkdownNode: Codable, Equatable, Sendable {
    public var kind: AgentMarkdownKind
    public var text: String?
    public var children: [AgentMarkdownNode]
    public var level: Int?
    public var start: Int?
    public var checked: Bool?
    public var destination: String?
    public var language: String?
    public var alignment: String?

    public init(
        kind: AgentMarkdownKind,
        text: String? = nil,
        children: [AgentMarkdownNode] = [],
        level: Int? = nil,
        start: Int? = nil,
        checked: Bool? = nil,
        destination: String? = nil,
        language: String? = nil,
        alignment: String? = nil
    ) {
        self.kind = kind
        self.text = text
        self.children = children
        self.level = level
        self.start = start
        self.checked = checked
        self.destination = destination
        self.language = language
        self.alignment = alignment
    }
}

private extension AgentMarkdownDocument {
    static let maximumInputBytes = 128 * 1024
    static let maximumDepth = 24
    static let maximumNodes = 8_192
    static let maximumOutputBytes = 256 * 1024

    static func boundedInput(_ source: String) -> (value: String, truncated: Bool) {
        let bytes = source.utf8
        guard bytes.count > maximumInputBytes else {
            return (source, false)
        }
        var prefix = Array(bytes.prefix(maximumInputBytes))
        while String(bytes: prefix, encoding: .utf8) == nil { prefix.removeLast() }
        return (String(decoding: prefix, as: UTF8.self), true)
    }

    struct Mapper {
        var truncated: Bool
        private var nodeCount = 0
        private var outputBytes = 0

        init(initiallyTruncated: Bool) {
            truncated = initiallyTruncated
        }

        mutating func nodes(from document: Markdown.Document) -> [AgentMarkdownNode] {
            document.children.compactMap { node(from: $0, depth: 1) }
        }

        private mutating func node(from markup: any Markdown.Markup, depth: Int) -> AgentMarkdownNode? {
            guard reserveNode() else { return nil }
            guard depth <= AgentMarkdownDocument.maximumDepth else {
                truncated = true
                return AgentMarkdownNode(kind: .text, text: limited("…"))
            }

            if let paragraph = markup as? Markdown.Paragraph {
                return AgentMarkdownNode(kind: .paragraph, children: children(of: paragraph, depth: depth + 1))
            }
            if let heading = markup as? Markdown.Heading {
                return AgentMarkdownNode(kind: .heading, children: children(of: heading, depth: depth + 1), level: heading.level)
            }
            if let quote = markup as? Markdown.BlockQuote {
                return AgentMarkdownNode(kind: .quote, children: children(of: quote, depth: depth + 1))
            }
            if let list = markup as? Markdown.UnorderedList {
                return AgentMarkdownNode(kind: .unorderedList, children: children(of: list, depth: depth + 1))
            }
            if let list = markup as? Markdown.OrderedList {
                return AgentMarkdownNode(kind: .orderedList, children: children(of: list, depth: depth + 1), start: Int(exactly: list.startIndex))
            }
            if let item = markup as? Markdown.ListItem {
                let checked: Bool?
                switch item.checkbox {
                case .some(.checked): checked = true
                case .some(.unchecked): checked = false
                case nil: checked = nil
                }
                return AgentMarkdownNode(kind: .listItem, children: children(of: item, depth: depth + 1), checked: checked)
            }
            if let code = markup as? Markdown.CodeBlock {
                // A fence's closing newline is delimiter, not content. Both
                // renderers would otherwise paint an empty last line.
                var text = code.code
                if text.hasSuffix("\n") { text.removeLast() }
                return AgentMarkdownNode(kind: .codeBlock, text: limited(text), language: limited(code.language))
            }
            if markup is Markdown.ThematicBreak {
                return AgentMarkdownNode(kind: .thematicBreak)
            }
            if let table = markup as? Markdown.Table {
                return AgentMarkdownNode(kind: .table, children: tableRows(from: table, depth: depth + 1))
            }
            if let text = markup as? Markdown.Text {
                return AgentMarkdownNode(kind: .text, text: limited(text.string))
            }
            if let strong = markup as? Markdown.Strong {
                return AgentMarkdownNode(kind: .strong, children: children(of: strong, depth: depth + 1))
            }
            if let emphasis = markup as? Markdown.Emphasis {
                return AgentMarkdownNode(kind: .emphasis, children: children(of: emphasis, depth: depth + 1))
            }
            if let strike = markup as? Markdown.Strikethrough {
                return AgentMarkdownNode(kind: .strikethrough, children: children(of: strike, depth: depth + 1))
            }
            if let code = markup as? Markdown.InlineCode {
                return AgentMarkdownNode(kind: .inlineCode, text: limited(code.code))
            }
            if let link = markup as? Markdown.Link {
                return AgentMarkdownNode(kind: .link, children: children(of: link, depth: depth + 1), destination: safeDestination(link.destination))
            }
            if markup is Markdown.SoftBreak {
                return AgentMarkdownNode(kind: .softBreak)
            }
            if markup is Markdown.LineBreak {
                return AgentMarkdownNode(kind: .lineBreak)
            }
            if let image = markup as? Markdown.Image {
                // Local destinations are inert metadata. Only Files Quick Look
                // supplies staged image content; agent transcripts stay alt-only.
                return AgentMarkdownNode(
                    kind: .image, children: children(of: image, depth: depth + 1),
                    destination: MarkdownLocalImage.path(image.source) == nil ? nil : limited(image.source, destination: true)
                )
            }
            if let html = markup as? Markdown.HTMLBlock {
                return AgentMarkdownNode(kind: .text, text: limited(html.rawHTML))
            }
            if let html = markup as? Markdown.InlineHTML {
                return AgentMarkdownNode(kind: .text, text: limited(html.rawHTML))
            }

            let nested = children(of: markup, depth: depth + 1)
            if !nested.isEmpty {
                return AgentMarkdownNode(kind: .paragraph, children: nested)
            }
            return AgentMarkdownNode(kind: .text, text: limited("Unsupported Markdown"))
        }

        private mutating func children(of markup: any Markdown.Markup, depth: Int) -> [AgentMarkdownNode] {
            markup.children.compactMap { node(from: $0, depth: depth) }
        }

        private mutating func tableRows(from table: Markdown.Table, depth: Int) -> [AgentMarkdownNode] {
            var rows: [AgentMarkdownNode] = []
            if let header = tableRow(from: table.head, header: true, alignments: table.columnAlignments, depth: depth) {
                rows.append(header)
            }
            for row in table.body.rows {
                guard let node = tableRow(from: row, header: false, alignments: table.columnAlignments, depth: depth) else { break }
                rows.append(node)
            }
            return rows
        }

        private mutating func tableRow(
            from markup: any Markdown.Markup,
            header: Bool,
            alignments: [Markdown.Table.ColumnAlignment?],
            depth: Int
        ) -> AgentMarkdownNode? {
            guard reserveNode() else { return nil }
            guard depth <= AgentMarkdownDocument.maximumDepth else {
                truncated = true
                return AgentMarkdownNode(kind: .text, text: limited("…"))
            }
            var cells: [AgentMarkdownNode] = []
            for (index, child) in markup.children.enumerated() {
                guard let cell = child as? Markdown.Table.Cell else { continue }
                let alignment = index < alignments.count ? alignments[index] : nil
                guard let node = tableCell(cell, header: header, alignment: alignmentName(alignment), depth: depth + 1) else { break }
                cells.append(node)
            }
            return AgentMarkdownNode(kind: .tableRow, children: cells)
        }

        private mutating func tableCell(
            _ cell: Markdown.Table.Cell,
            header: Bool,
            alignment: String?,
            depth: Int
        ) -> AgentMarkdownNode? {
            guard reserveNode() else { return nil }
            guard depth <= AgentMarkdownDocument.maximumDepth else {
                truncated = true
                return AgentMarkdownNode(kind: .text, text: limited("…"))
            }
            return AgentMarkdownNode(
                kind: .tableCell,
                children: children(of: cell, depth: depth + 1),
                level: header ? 1 : nil,
                alignment: alignment
            )
        }

        private func alignmentName(_ alignment: Markdown.Table.ColumnAlignment?) -> String? {
            switch alignment {
            case .some(.left): return "left"
            case .some(.center): return "center"
            case .some(.right): return "right"
            case nil: return nil
            }
        }

        private mutating func reserveNode() -> Bool {
            guard nodeCount < AgentMarkdownDocument.maximumNodes else {
                truncated = true
                return false
            }
            nodeCount += 1
            return true
        }

        private mutating func limited(_ value: String?, destination: Bool = false) -> String? {
            guard let original = value else { return nil }
            let value = AgentDisplayText.sanitize(original)
            if destination && value != original { return nil }
            let bytes = value.utf8
            let remaining = AgentMarkdownDocument.maximumOutputBytes - outputBytes
            guard remaining > 0 else {
                truncated = true
                return ""
            }
            guard bytes.count <= remaining else {
                outputBytes = AgentMarkdownDocument.maximumOutputBytes
                truncated = true
                return String(decoding: bytes.prefix(remaining), as: UTF8.self)
            }
            outputBytes += bytes.count
            return value
        }

        private mutating func safeDestination(_ destination: String?) -> String? {
            guard let destination, let scheme = URL(string: destination)?.scheme?.lowercased(), ["http", "https", "mailto"].contains(scheme) else {
                return nil
            }
            return limited(destination, destination: true)
        }
    }
}

/// A Markdown image path refers to the document's remote host, never the
/// device filesystem. Decode URI escapes once, reject authorities and schemes
/// that could turn a file preview into an unrelated network request.
public enum MarkdownLocalImage {
    public static func path(_ destination: String?) -> String? {
        guard let destination, !destination.isEmpty,
              let url = URLComponents(string: destination),
              url.host == nil || url.host == "", url.user == nil, url.password == nil,
              url.port == nil, url.scheme == nil || url.scheme?.lowercased() == "file",
              let path = url.percentEncodedPath.removingPercentEncoding,
              !path.isEmpty, !path.hasPrefix("//"),
              !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              url.scheme == nil || path.hasPrefix("/") else { return nil }
        return path
    }

    public static func remotePath(_ destination: String, documentPath: String) -> String? {
        guard documentPath.hasPrefix("/"), let path = path(destination) else { return nil }
        if path.hasPrefix("/") { return path }
        let parent = (documentPath as NSString).deletingLastPathComponent
        // Leave dot components to SFTP: lexical normalization changes the
        // meaning of paths whose parent components are symlinks.
        return (parent == "/" ? "" : parent) + "/" + path
    }
}

/// Foundation loses imageURL for images nested inside links. Replace image
/// nodes with opaque text before its presentation-intent pass, then restore
/// image attributes in the Apple renderer. Source ranges come from CommonMark,
/// so references, nested parentheses, Unicode, and code fences remain correct.
public struct MarkdownImagePlaceholders: Sendable {
    public struct Reference: Sendable {
        public let token: String
        public let destination: String
        public let alt: String
    }
    public let source: String
    public let prefix: String
    public let references: [Reference]

    public init(_ source: String) {
        let prefix = ":TESSERAIMAGE" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        guard source.contains("![") else {
            self.source = source
            self.prefix = prefix
            self.references = []
            return
        }
        let bytes = Array(source.utf8)
        var lineStarts = [0]
        for (index, byte) in bytes.enumerated() {
            if byte == 10 || (byte == 13 && (index + 1 == bytes.count || bytes[index + 1] != 10)) {
                lineStarts.append(index + 1)
            }
        }
        var found: [(range: Range<Int>, reference: Reference)] = []
        func visit(_ node: any Markup) {
            if let image = node as? Markdown.Image, let range = image.range,
               lineStarts.indices.contains(range.lowerBound.line - 1),
               lineStarts.indices.contains(range.upperBound.line - 1) {
                let start = lineStarts[range.lowerBound.line - 1] + range.lowerBound.column - 1
                let end = lineStarts[range.upperBound.line - 1] + range.upperBound.column - 1
                guard start >= 0, end <= bytes.count, start < end else { return }
                let reference = Reference(token: prefix + String(found.count) + "END:", destination: image.source ?? "", alt: image.plainText)
                found.append((start..<end, reference))
            } else {
                for child in node.children { visit(child) }
            }
        }
        visit(Markdown.Document(parsing: source, options: [.disableSmartOpts]))
        var replaced: [UInt8] = []
        var cursor = 0
        for item in found {
            guard item.range.lowerBound >= cursor else { continue }
            replaced.append(contentsOf: bytes[cursor..<item.range.lowerBound])
            replaced.append(contentsOf: item.reference.token.utf8)
            cursor = item.range.upperBound
        }
        replaced.append(contentsOf: bytes[cursor...])
        self.source = String(decoding: replaced, as: UTF8.self)
        self.prefix = prefix
        self.references = found.map(\.reference)
    }
}
