import Foundation

public enum ProgramStatusState: String, Sendable, Equatable, CaseIterable {
    case idle, working, blocked, done, error
}

public enum ProgramStatusBlockedKind: String, Sendable, Equatable, CaseIterable {
    case permission, question, auth
}

public struct ProgramStatusReport: Equatable, Sendable {
    public enum Action: Equatable, Sendable {
        case set(ProgramStatusState)
        case clear
    }

    public let action: Action
    public let idPath: [String]
    public let kind: ProgramStatusBlockedKind?
    public let progress: Int?
    public let app: String?
    public let title: String?
    public let message: String?

    public init(
        action: Action,
        idPath: [String] = [],
        kind: ProgramStatusBlockedKind? = nil,
        progress: Int? = nil,
        app: String? = nil,
        title: String? = nil,
        message: String? = nil
    ) {
        self.action = action
        self.idPath = idPath
        self.kind = kind
        self.progress = progress
        self.app = app
        self.title = title
        self.message = message
    }
}

public enum ProgramStatusSequence: Equatable, Sendable {
    case report(ProgramStatusReport)
    case query
}

public enum ProgramStatusParser {
    /// `body` is everything after "7501;" and before the terminator.
    /// Malformed pairs do not poison valid neighbours, but protocol limits
    /// reject the report so a truncated identity can never target the root.
    public static func parse<C: Collection>(body: C) -> ProgramStatusSequence? where C.Element == UInt8 {
        let pairs = body.split(separator: 0x3A, omittingEmptySubsequences: false)
        if let first = pairs.first, trim(first).elementsEqual([0x3F]) { return .query }
        var values: [String: [UInt8]] = [:]
        for pair in pairs {
            guard let equals = pair.firstIndex(of: 0x3D) else { continue }
            let key = trim(pair[..<equals])
            guard key.count <= 16 else { return nil }
            let value = trim(pair[pair.index(after: equals)...])
            // An explicit invalid target must never fall back to a root write
            // or root clear, even when its pair fails the generic value syntax.
            if key.elementsEqual("id".utf8), value.isEmpty || !value.allSatisfy(isValueByte) { return nil }
            guard !key.isEmpty, key.allSatisfy({ (0x61...0x7A).contains($0) }),
                  value.allSatisfy(isValueByte)
            else { continue }
            let name = String(decoding: key, as: UTF8.self)
            // Validate every occurrence before last-wins replacement or clear.
            switch name {
            case "id":
                guard identifierPath(value) != nil else { return nil }
            case "app":
                guard value.count <= 32 else { return nil }
            case "title":
                guard decodeText(Array(value), encodedLimit: 256, decodedLimit: 192) != nil else { return nil }
            case "msg":
                guard decodeText(Array(value), encodedLimit: 2732, decodedLimit: 2048) != nil else { return nil }
            default: break
            }
            switch name {
            case "state", "id", "kind", "progress", "app", "title", "msg":
                values[name] = Array(value)
            default: break
            }
        }
        guard let stateBytes = values["state"] else { return nil }
        let stateName = String(decoding: stateBytes, as: UTF8.self)
        let action: ProgramStatusReport.Action
        if stateName == "clear" {
            action = .clear
        } else if let state = ProgramStatusState(rawValue: stateName) {
            action = .set(state)
        } else {
            return nil
        }
        var path: [String] = []
        if let id = values["id"] {
            guard let parsed = identifierPath(id) else { return nil }
            path = parsed
        }
        // Validated metadata does not become part of a clear's target.
        if action == .clear { return .report(.init(action: action, idPath: path)) }
        var app: String?
        if let bytes = values["app"] {
            guard bytes.count <= 32 else { return nil }
            if !bytes.isEmpty, bytes.allSatisfy(isIdentifierByte) { app = String(decoding: bytes, as: UTF8.self) }
        }
        var title: String?
        var message: String?
        if let bytes = values["title"] {
            guard let decoded = decodeText(bytes, encodedLimit: 256, decodedLimit: 192) else { return nil }
            title = decoded.isEmpty ? nil : decoded
        }
        if let bytes = values["msg"] {
            guard let decoded = decodeText(bytes, encodedLimit: 2732, decodedLimit: 2048) else { return nil }
            message = decoded.isEmpty ? nil : decoded
        }
        let isBlocked = action == .set(.blocked)
        let kind = isBlocked ? values["kind"].flatMap {
            ProgramStatusBlockedKind(rawValue: String(decoding: $0, as: UTF8.self))
        } : nil
        var progress: Int?
        if isBlocked || action == .set(.working), let bytes = values["progress"],
           (1...3).contains(bytes.count), bytes.allSatisfy({ (0x30...0x39).contains($0) }) {
            let number = bytes.reduce(0) { $0 * 10 + Int($1 - 0x30) }
            if number <= 100 { progress = number }
        }
        return .report(.init(action: action, idPath: path, kind: kind, progress: progress,
                             app: app, title: title, message: message))
    }

    private static func trim<C: Collection>(_ bytes: C) -> C.SubSequence where C.Element == UInt8 {
        var start = bytes.startIndex
        var end = bytes.endIndex
        while start != end, bytes[start] == 0x20 || bytes[start] == 0x09 {
            bytes.formIndex(after: &start)
        }
        // Collection need not support backwards indexing.
        var lastContentEnd = start
        var index = start
        while index != end {
            let byte = bytes[index]
            bytes.formIndex(after: &index)
            if byte != 0x20 && byte != 0x09 { lastContentEnd = index }
        }
        end = lastContentEnd
        return bytes[start..<end]
    }

    private static func isIdentifierByte(_ byte: UInt8) -> Bool {
        (0x41...0x5A).contains(byte) || (0x61...0x7A).contains(byte)
            || (0x30...0x39).contains(byte) || [0x5F, 0x2E, 0x2B, 0x2D].contains(byte)
    }

    private static func isValueByte(_ byte: UInt8) -> Bool {
        isIdentifierByte(byte) || [0x2C, 0x2F, 0x3D].contains(byte)
    }

    private static func identifierPath<C: Collection>(_ bytes: C) -> [String]? where C.Element == UInt8 {
        guard bytes.count <= 128 else { return nil }
        let segments = bytes.split(separator: 0x2F, omittingEmptySubsequences: false)
        guard (1...8).contains(segments.count), segments.allSatisfy({
            (1...32).contains($0.count) && $0.allSatisfy(isIdentifierByte)
        }) else { return nil }
        return segments.map { String(decoding: $0, as: UTF8.self) }
    }

    private static func decodeText(_ bytes: [UInt8], encodedLimit: Int, decodedLimit: Int) -> String? {
        guard bytes.count <= encodedLimit else { return nil }
        let content = bytes.prefix { $0 != 0x3D }
        let padding = bytes.count - content.count
        guard content.allSatisfy({
            (0x41...0x5A).contains($0) || (0x61...0x7A).contains($0)
                || (0x30...0x39).contains($0) || $0 == 0x2B || $0 == 0x2F
        }), bytes.dropFirst(content.count).allSatisfy({ $0 == 0x3D }), padding <= 2,
        content.count % 4 != 1 else { return nil }
        let needed = (4 - content.count % 4) % 4
        guard padding == 0 || (bytes.count % 4 == 0 && padding == needed) else { return nil }
        var padded = Array(content)
        padded.append(contentsOf: repeatElement(0x3D, count: needed))
        guard let data = Data(base64Encoded: Data(padded)), data.count <= decodedLimit,
              let text = String(data: data, encoding: .utf8),
              !text.unicodeScalars.contains(where: {
                  $0.value <= 0x1F || (0x7F...0x9F).contains($0.value)
                      || $0.value == 0x2028 || $0.value == 0x2029
              }) else { return nil }
        return text
    }
}

public enum ProgramStatusText {
    /// Remove invisible direction/formatting instructions before presentation;
    /// the report itself retains validated text for platform adapters.
    public static func displaySanitized(_ text: String) -> String {
        var result = String.UnicodeScalarView()
        var pendingSpace = false
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x202A...0x202E, 0x2066...0x2069, 0x200E, 0x200F, 0x061C,
                 0x200B...0x200D, 0x2060...0x2064, 0xFEFF, 0x00AD,
                 0x034F, 0x115F, 0x1160, 0x17B4, 0x17B5, 0x180B...0x180F,
                 0x206A...0x206F, 0x3164, 0xFFA0, 0xFFF0...0xFFF8,
                 0x1BCA0...0x1BCA3, 0x1D173...0x1D17A, 0xE0000...0xE0FFF:
                continue
            default: break
            }
            if scalar.properties.isWhitespace {
                pendingSpace = !result.isEmpty
            } else {
                if pendingSpace { result.append(" "); pendingSpace = false }
                result.append(scalar)
            }
        }
        return String(result)
    }
}

public enum ProgramStatusReply {
    public static let query: [UInt8] = [0x1B, 0x5D, 0x37, 0x35, 0x30, 0x31, 0x3B, 0x3F, 0x1B, 0x5C]
}
