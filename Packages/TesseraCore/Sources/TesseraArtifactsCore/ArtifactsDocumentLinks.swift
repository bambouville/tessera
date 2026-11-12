import Foundation
import TesseraDomainCore

/// Where a link in a document shown in Artifacts goes. The document lives on
/// its host, so its paths and its localhost pages are that host's: they open
/// as Artifacts tabs, never on the device.
/// {"type":"file","path":"/work/docs/b.md"},
/// {"type":"page","scheme":"http","port":3000,"pathAndQuery":"/x?y#z"},
/// {"type":"external"}, {"type":"refused"} or {"type":"ignored"}.
public enum ArtifactsDocumentLink: Codable, Equatable, Sendable {
    /// An absolute path on the document's host.
    case file(path: String)
    /// A port on the document's host's own loopback. pathAndQuery keeps the
    /// fragment, as a terminal link's does.
    case page(scheme: String, port: UInt16, pathAndQuery: String)
    /// Elsewhere on the internet, or a mail address: the device opens it.
    case external
    /// Opens nowhere: the device's own loopback, another machine's file, a
    /// path that cannot be resolved, or a scheme that runs code or an app.
    case refused
    /// Nothing to open: the document itself, or an anchor in it.
    case ignored

    private struct Wire: Codable {
        var type: String
        var path: String?
        var scheme: String?
        var port: UInt16?
        var pathAndQuery: String?
    }

    public init(from decoder: Decoder) throws {
        let w = try Wire(from: decoder)
        switch w.type {
        case "file":
            guard let path = w.path, path.hasPrefix("/") else { throw ArtifactsCoding.invalid(decoder, "invalid document file link") }
            self = .file(path: path)
        case "page":
            guard let scheme = w.scheme, let port = w.port, let path = w.pathAndQuery,
                  ["http", "https"].contains(scheme), port > 0 else {
                throw ArtifactsCoding.invalid(decoder, "invalid document page link")
            }
            self = .page(scheme: scheme, port: port, pathAndQuery: path)
        case "external": self = .external
        case "refused": self = .refused
        case "ignored": self = .ignored
        default: throw ArtifactsCoding.invalid(decoder, "unknown document link type")
        }
    }

    public func encode(to encoder: Encoder) throws {
        let w: Wire
        switch self {
        case let .file(path): w = Wire(type: "file", path: path)
        case let .page(scheme, port, path): w = Wire(type: "page", scheme: scheme, port: port, pathAndQuery: path)
        case .external: w = Wire(type: "external")
        case .refused: w = Wire(type: "refused")
        case .ignored: w = Wire(type: "ignored")
        }
        try w.encode(to: encoder)
    }

    public static func == (lhs: ArtifactsDocumentLink, rhs: ArtifactsDocumentLink) -> Bool {
        switch (lhs, rhs) {
        case let (.file(a), .file(b)): return a.utf8.elementsEqual(b.utf8)
        case let (.page(aScheme, aPort, aPath), .page(bScheme, bPort, bPath)):
            return aScheme == bScheme && aPort == bPort && aPath.utf8.elementsEqual(bPath.utf8)
        case (.external, .external), (.refused, .refused), (.ignored, .ignored): return true
        default: return false
        }
    }
}

public enum ArtifactsDocumentLinks {
    /// Resolves `link` as a browser resolves a link in a file it shows:
    /// relative to the document's directory, with "." and ".." applied to the
    /// path as written. A leading "~" is the host's home, when it is known.
    /// The query and fragment of a path are dropped; a document has neither.
    public static func resolve(_ link: String, documentPath: String, home: String? = nil) -> ArtifactsDocumentLink {
        let text = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.hasPrefix("#") else { return .ignored }
        guard !RemotePathGrammar.containsControlCharacter(text) else { return .refused }
        if let scheme = scheme(of: text) {
            switch scheme {
            case "http", "https":
                switch ArtifactsLinkClassifier.classify(text) {
                case let .remoteLoopback(scheme, port, path): return .page(scheme: scheme, port: port, pathAndQuery: path)
                case .external: return .external
                // A malformed web address could still name this device.
                case .refused, .unsupported: return .refused
                }
            case "mailto", "tel": return .external
            case "file": return fileURL(text, documentPath: documentPath, home: home)
            default: return .refused
            }
        }
        // A scheme-relative link takes the document's file scheme, naming
        // another machine's file.
        if text.hasPrefix("//") { return .refused }
        let path = pathBeforeQuery(text)
        if path.isEmpty { return .ignored }
        let base: String
        let rest: Substring
        if path == "~" || path.hasPrefix("~/") {
            guard let home, home.hasPrefix("/") else { return .refused }
            base = home
            rest = path.dropFirst()
        } else if path.hasPrefix("/") {
            base = "/"
            rest = path[...]
        } else {
            guard documentPath.hasPrefix("/"), let slash = documentPath.lastIndex(of: "/") else { return .refused }
            base = String(documentPath[...slash])
            rest = path[...]
        }
        guard let decoded = decodedSegments(rest) else { return .refused }
        return .file(path: resolved(base + "/" + decoded))
    }

    /// RFC 3986: a letter, then letters, digits, "+", "-" or ".", then ":",
    /// before any "/", "?" or "#".
    private static func scheme(of text: String) -> String? {
        var scheme = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            if scalar == ":" { return scheme.isEmpty ? nil : String(scheme).lowercased() }
            let isLetter = (scalar >= "a" && scalar <= "z") || (scalar >= "A" && scalar <= "Z")
            let isOther = (scalar >= "0" && scalar <= "9") || "+-.".unicodeScalars.contains(scalar)
            guard isLetter || (!scheme.isEmpty && isOther) else { return nil }
            scheme.append(scalar)
        }
        return nil
    }

    /// file:///path and file://localhost/path are the document's own host,
    /// as an absolute path is; any other authority is another machine.
    private static func fileURL(_ text: String, documentPath: String, home: String?) -> ArtifactsDocumentLink {
        // The scheme is "file", so its colon is the fifth scalar.
        var rest = Substring(text.unicodeScalars.dropFirst(5))
        if rest.hasPrefix("//") {
            rest = rest.dropFirst(2)
            let authority = rest.prefix { !"/?#".contains($0) }
            guard authority.isEmpty || authority.lowercased() == "localhost" else { return .refused }
            rest = rest.dropFirst(authority.count)
        }
        guard rest.hasPrefix("/") else { return .refused }
        return resolve(String(rest), documentPath: documentPath, home: home)
    }

    /// The path before any query or fragment, still percent-encoded.
    private static func pathBeforeQuery(_ text: String) -> String {
        let scalars = text.unicodeScalars
        let end = scalars.firstIndex { $0 == "?" || $0 == "#" } ?? scalars.endIndex
        return String(scalars[..<end])
    }

    /// Each segment percent-decoded on its own, as a browser reads a path: an
    /// escaped "/" is part of a name, which no file's can be, rather than a
    /// separator. An invalid escape is kept as written, as a browser keeps it.
    private static func decodedSegments(_ path: Substring) -> String? {
        var segments: [String] = []
        for segment in path.split(separator: "/", omittingEmptySubsequences: false) {
            let decoded = segment.removingPercentEncoding ?? String(segment)
            guard !decoded.contains("/"), !RemotePathGrammar.containsControlCharacter(decoded) else { return nil }
            segments.append(decoded)
        }
        return segments.joined(separator: "/")
    }

    /// "." and ".." as a browser applies them; ".." stops at the root. A
    /// link is a URL, so this happens before the host sees it, unlike an
    /// image's fetch path (`MarkdownLocalImage.remotePath`), and a file has
    /// one tab whichever document links to it.
    static func resolved(_ path: String) -> String {
        var parts: [Substring] = []
        for part in path.split(separator: "/") {
            if part == "." { continue }
            if part == ".." { _ = parts.popLast(); continue }
            parts.append(part)
        }
        return "/" + parts.joined(separator: "/")
    }
}
