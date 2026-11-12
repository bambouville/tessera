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
    public static func parse(_ source: String) -> Self { parse(source, keepsLinks: false, cache: markdownCache) }

    /// A document shown in Artifacts keeps every link destination as written,
    /// since its viewer resolves each against the document's host and refuses
    /// what must not open. Agent output keeps only web and mail links, so the
    /// two never share a cache.
    public static func parseDocument(_ source: String) -> Self { parse(source, keepsLinks: true, cache: documentMarkdownCache) }

    private static func parse(_ source: String, keepsLinks: Bool, cache: AgentMarkdownCache) -> Self {
        let input = boundedInput(source)
        if let cached = cache.value(for: input.value) {
            return Self(blocks: cached.blocks, truncated: cached.truncated || input.truncated)
        }
        var mapper = Mapper(initiallyTruncated: false, keepsLinks: keepsLinks)
        let document = Markdown.Document(parsing: input.value, options: [.disableSmartOpts])
        let parsed = Self(blocks: mapper.nodes(from: document), truncated: mapper.truncated)
        cache.insert(parsed, for: input.value)
        return Self(blocks: parsed.blocks, truncated: parsed.truncated || input.truncated)
    }

    /// Parsed trees are reconstructible; memory pressure and disabling
    /// Agent Center drop them with the transcript content they came from.
    public static func purgeCache() {
        markdownCache.purge()
        documentMarkdownCache.purge()
    }

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
    /// A document's viewer keeps its own cache in front of this one, which
    /// then only needs to span one document's JNI size/copy calls.
    init(documents: Int, bytes: Int) {
        entries.countLimit = documents
        entries.totalCostLimit = bytes
    }
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
private let documentMarkdownCache = AgentMarkdownCache(documents: 2, bytes: 2 << 20)

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
        private let keepsLinks: Bool
        private var nodeCount = 0
        private var outputBytes = 0
        /// Text inside a link or an image's alt is already a label, never a link of its own.
        private var labelDepth = 0

        init(initiallyTruncated: Bool, keepsLinks: Bool = false) {
            truncated = initiallyTruncated
            self.keepsLinks = keepsLinks
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
                labelDepth += 1
                defer { labelDepth -= 1 }
                return AgentMarkdownNode(kind: .link, children: children(of: link, depth: depth + 1), destination: safeDestination(link.destination))
            }
            if markup is Markdown.SoftBreak {
                return AgentMarkdownNode(kind: .softBreak)
            }
            if markup is Markdown.LineBreak {
                return AgentMarkdownNode(kind: .lineBreak)
            }
            if let image = markup as? Markdown.Image {
                labelDepth += 1
                defer { labelDepth -= 1 }
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
            let children = Array(markup.children)
            var nodes: [AgentMarkdownNode] = []
            var index = 0
            while index < children.count {
                // swift-markdown leaves GFM's autolink extension off, which
                // Apple's own parser (iOS documents) has on. cmark splits text
                // where emphasis might have opened, so a URL can span several
                // text siblings: each run is scanned whole.
                guard labelDepth == 0, children[index] is Markdown.Text else {
                    if let node = node(from: children[index], depth: depth) { nodes.append(node) }
                    index += 1
                    continue
                }
                var end = index + 1
                while end < children.count, children[end] is Markdown.Text { end += 1 }
                let run = children[index..<end].compactMap { ($0 as? Markdown.Text)?.string }.joined()
                let next = end < children.count ? children[end] : nil
                let continues = next is Markdown.Strong || next is Markdown.Emphasis || next is Markdown.Strikethrough
                if let linked = autolinked(run, depth: depth, continuesIntoNext: continues) {
                    nodes += linked
                } else {
                    nodes += children[index..<end].compactMap { node(from: $0, depth: depth) }
                }
                index = end
            }
            return nodes
        }

        /// The run as text and link nodes, or nil when it holds no autolink.
        /// cmark reads delimiters inside an address before any autolinking
        /// (`…/pkg/__init__.py` holds strong text), where GFM claims the whole
        /// address first. An address running into such a node stays text:
        /// linking its first part would open the wrong page.
        private mutating func autolinked(_ text: String, depth: Int, continuesIntoNext: Bool) -> [AgentMarkdownNode]? {
            let scalars = Array(text.unicodeScalars)
            let matches = AgentMarkdownAutolink.matches(in: scalars).filter { !(continuesIntoNext && $0.reachesEnd) }
            guard !matches.isEmpty, depth < AgentMarkdownDocument.maximumDepth else { return nil }
            func string(_ range: Range<Int>) -> String {
                var view = String.UnicodeScalarView()
                view.append(contentsOf: scalars[range])
                return String(view)
            }
            var nodes: [AgentMarkdownNode] = []
            var cursor = 0
            for match in matches {
                if cursor < match.range.lowerBound {
                    guard reserveNode() else { return nodes }
                    nodes.append(AgentMarkdownNode(kind: .text, text: limited(string(cursor..<match.range.lowerBound))))
                }
                guard reserveNode() else { return nodes }
                let label = string(match.range)
                if let destination = safeDestination(match.destination), reserveNode() {
                    nodes.append(AgentMarkdownNode(kind: .link, children: [AgentMarkdownNode(kind: .text, text: limited(label))], destination: destination))
                } else {
                    nodes.append(AgentMarkdownNode(kind: .text, text: limited(label)))
                }
                cursor = match.range.upperBound
            }
            if cursor < scalars.count, reserveNode() {
                nodes.append(AgentMarkdownNode(kind: .text, text: limited(string(cursor..<scalars.count))))
            }
            return nodes
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
            if keepsLinks, let destination, !destination.isEmpty { return limited(destination, destination: true) }
            guard let destination, let scheme = URL(string: destination)?.scheme?.lowercased(), ["http", "https", "mailto"].contains(scheme) else {
                return nil
            }
            return limited(destination, destination: true)
        }
    }
}

/// GFM's extended autolinks for web addresses: `http://` and `https://` URLs
/// and `www.` domains, with cmark-gfm's rules for where one starts and which
/// trailing characters it leaves to the sentence. Email autolinks stay text:
/// in a terminal app's prose `git@github.com` is an SSH address, not mail.
enum AgentMarkdownAutolink {
    struct Match: Equatable {
        /// Unicode scalar offsets into the scanned text.
        let range: Range<Int>
        let destination: String
        /// The address ran to the end of the text before trimming, so it may
        /// carry on into whatever node follows.
        let reachesEnd: Bool
    }

    static func matches(in scalars: [Unicode.Scalar]) -> [Match] {
        var matches: [Match] = []
        var domain: Domain?
        var index = 0
        while index < scalars.count {
            if let match = match(in: scalars, at: index, domain: &domain) {
                matches.append(match)
                index = match.range.upperBound
            } else {
                index += 1
            }
        }
        return matches
    }

    private static func match(in scalars: [Unicode.Scalar], at start: Int, domain cached: inout Domain?) -> Match? {
        let first = scalars[start]
        guard first == "h" || first == "H" || first == "w" else { return nil }
        let previous = start > 0 ? scalars[start - 1] : nil
        let domainStart: Int
        let www: Bool
        if let length = schemeLength(scalars, at: start) {
            // cmark-gfm reads the scheme back from the colon over ASCII
            // letters, so an address straight after CJK prose still links.
            if let previous, isASCIILetter(previous) { return nil }
            domainStart = start + length
            www = false
        } else if hasPrefix(scalars, at: start, wwwPrefix) {
            if let previous, !isSpace(previous), !"*_~(".unicodeScalars.contains(previous) { return nil }
            domainStart = start
            www = true
        } else {
            return nil
        }
        guard domainStart < scalars.count, isLetterOrDigit(scalars[domainStart]) else { return nil }
        if cached.map({ !$0.contains(domainStart) }) ?? true { cached = Domain(scalars, from: domainStart) }
        guard let domainEnd = cached?.validEnd(from: domainStart, allowsShort: !www) else { return nil }
        var pathEnd = domainEnd
        while pathEnd < scalars.count, !isSpace(scalars[pathEnd]), scalars[pathEnd] != "<" { pathEnd += 1 }
        let end = trimmedEnd(scalars, start: start, end: pathEnd)
        guard end > domainStart else { return nil }
        var label = String.UnicodeScalarView()
        label.append(contentsOf: scalars[start..<end])
        return Match(range: start..<end, destination: (www ? "http://" : "") + String(label), reachesEnd: pathEnd == scalars.count)
    }

    private static func schemeLength(_ scalars: [Unicode.Scalar], at start: Int) -> Int? {
        if hasPrefix(scalars, at: start, httpsPrefix, caseInsensitive: true) { return httpsPrefix.count }
        if hasPrefix(scalars, at: start, httpPrefix, caseInsensitive: true) { return httpPrefix.count }
        return nil
    }

    /// One scan of a run of domain characters, shared by every candidate that
    /// starts inside it. Rescanning from each start made `_www._www.…`
    /// quadratic.
    private struct Domain {
        let start: Int
        let end: Int
        let lastPeriod: Int?
        /// The last `_` after the last period, and the last one in the segment before it.
        let lastUnderscore: Int?
        let previousUnderscore: Int?

        init(_ scalars: [Unicode.Scalar], from start: Int) {
            var index = start
            var lastPeriod: Int?
            var lastUnderscore: Int?
            var previousUnderscore: Int?
            while index < scalars.count {
                let scalar = scalars[index]
                if scalar == "." {
                    // A period the domain ends on belongs to the sentence.
                    guard index + 1 < scalars.count, isDomainCharacter(scalars[index + 1]) else { break }
                    previousUnderscore = lastUnderscore
                    lastUnderscore = nil
                    lastPeriod = index
                } else if scalar == "_" {
                    lastUnderscore = index
                } else if !isDomainCharacter(scalar) {
                    break
                }
                index += 1
            }
            self.start = start
            end = index
            self.lastPeriod = lastPeriod
            self.lastUnderscore = lastUnderscore
            self.previousUnderscore = previousUnderscore
        }

        func contains(_ index: Int) -> Bool { index >= start && index < end }

        /// The domain read from `from` if valid: segments of letters, digits,
        /// `_` and `-` split by periods, no `_` in the last two, and a period
        /// unless short is allowed (`http://localhost:3000` links; a bare
        /// `www.` needs a real domain).
        func validEnd(from: Int, allowsShort: Bool) -> Int? {
            let hasPeriod = lastPeriod.map { $0 >= from } ?? false
            let underscoreInLast = lastUnderscore.map { $0 >= from } ?? false
            let underscoreInPrevious = hasPeriod && (previousUnderscore.map { $0 >= from } ?? false)
            guard end > from, !underscoreInLast, !underscoreInPrevious, allowsShort || hasPeriod else { return nil }
            return end
        }
    }

    /// Leaves trailing punctuation, an unmatched `)` and a trailing entity
    /// reference to the surrounding sentence.
    private static func trimmedEnd(_ scalars: [Unicode.Scalar], start: Int, end: Int) -> Int {
        var end = end
        // Counted once: a run of closing parentheses trims in linear time.
        var opening = 0
        var closing = 0
        for scalar in scalars[start..<end] {
            if scalar == "(" { opening += 1 } else if scalar == ")" { closing += 1 }
        }
        while end > start {
            let last = scalars[end - 1]
            if "?!.,:*_~'\"".unicodeScalars.contains(last) {
                end -= 1
            } else if last == ")" {
                guard closing > opening else { break }
                closing -= 1
                end -= 1
            } else if last == ";" {
                var entityStart = end - 2
                while entityStart > start, isASCIILetter(scalars[entityStart]) { entityStart -= 1 }
                end = entityStart >= start && entityStart < end - 2 && scalars[entityStart] == "&" ? entityStart : end - 1
            } else {
                break
            }
        }
        return end
    }

    private static let httpsPrefix = Array("https://".unicodeScalars)
    private static let httpPrefix = Array("http://".unicodeScalars)
    private static let wwwPrefix = Array("www.".unicodeScalars)

    private static func hasPrefix(_ scalars: [Unicode.Scalar], at start: Int, _ expected: [Unicode.Scalar], caseInsensitive: Bool = false) -> Bool {
        guard start + expected.count <= scalars.count else { return false }
        for (offset, scalar) in expected.enumerated() {
            let actual = scalars[start + offset]
            guard actual == scalar || caseInsensitive && asciiLowercased(actual) == scalar else { return false }
        }
        return true
    }

    private static func asciiLowercased(_ scalar: Unicode.Scalar) -> Unicode.Scalar {
        ("A"..."Z").contains(scalar) ? Unicode.Scalar(UInt8(scalar.value + 32)) : scalar
    }

    private static func isDomainCharacter(_ scalar: Unicode.Scalar) -> Bool {
        scalar == "-" || scalar == "_" || isLetterOrDigit(scalar)
    }

    private static func isLetterOrDigit(_ scalar: Unicode.Scalar) -> Bool {
        scalar.properties.isAlphabetic || scalar.properties.numericType != nil
    }

    private static func isASCIILetter(_ scalar: Unicode.Scalar) -> Bool {
        ("a"..."z").contains(scalar) || ("A"..."Z").contains(scalar)
    }

    private static func isSpace(_ scalar: Unicode.Scalar) -> Bool { scalar.properties.isWhitespace }
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
