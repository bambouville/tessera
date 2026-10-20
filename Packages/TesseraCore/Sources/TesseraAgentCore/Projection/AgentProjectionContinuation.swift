import Foundation

/// Shared continuation rules for native clients. The remote projector proves
/// byte-prefix continuity; Core alone decides whether cached history survives.
enum AgentProjectionContinuation {
    static func preservesHistory(previousIdentity: String, page: AgentProjectionPage) -> Bool {
        page.summary?.objectValue?["continuedFrom"]?.stringValue == previousIdentity
    }

    static func rebase(_ cursor: String?, using latestCursor: String?) -> String? {
        guard var previous = decode(cursor), let latest = decode(latestCursor),
              let identity = latest["identity"] as? String,
              let hash = latest["prefixHash"] as? String, hash.count == 64 else { return nil }
        previous["identity"] = identity
        previous["prefixHash"] = hash
        guard let data = try? JSONSerialization.data(withJSONObject: previous, options: [.sortedKeys]) else { return nil }
        return data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    private static func decode(_ cursor: String?) -> [String: Any]? {
        guard let cursor, cursor.utf8.count <= 2_048 else { return nil }
        var value = cursor.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        value += String(repeating: "=", count: (4 - value.count % 4) % 4)
        guard let data = Data(base64Encoded: value) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}
