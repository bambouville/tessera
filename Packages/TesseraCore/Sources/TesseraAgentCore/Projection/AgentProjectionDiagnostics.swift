import Foundation

/// A diagnostic envelope is untrusted remote data. Admit only fixed labels and
/// numeric permission facts, never paths, stdout tails or transcript contents.
public enum AgentProjectionDiagnostics {
    public static func errorFields(stdout: Data) -> [String: String] {
        guard stdout.count <= AgentProjectionRequest.maximumBytes else { return [:] }
        for line in stdout.split(separator: 0x0A).reversed().prefix(8) {
            guard line.count <= 8_192,
                  let frame = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  frame["v"] as? Int == 1, frame["kind"] as? String == "error",
                  let code = frame["error"] as? String, AgentProjectionError(rawValue: code) != nil
            else { continue }
            var result = ["error": code]
            let fields = frame["diagnostics"] as? [String: String] ?? [:]
            let labels: [String: Set<String>] = [
                "provider": ["codex", "claude", "kimi", "opencode", "pi"],
                "pathKind": ["windowsDrive", "unc", "posix", "relative"],
                "stage": ["sourceRoot", "sourceStat", "sourcePolicy", "sourceOpen", "request", "snapshot", "normalize", "encode"],
                "reason": ["outsideAllowedRoot", "statDenied", "notRegularFile", "ownerMismatch", "groupOrWorldWritable", "openDenied", "sourceTooLarge", "frameTooLarge", "pageTooLarge", "recordExceedsPage", "adapterException"],
                "exception": ["TypeError", "ValueError", "OverflowError", "RecursionError", "UnicodeDecodeError", "UnicodeEncodeError", "OSError", "Other"],
            ]
            for (key, allowed) in labels {
                if let value = fields[key], allowed.contains(value) { result[key] = value }
            }
            for key in ["effectiveUID", "ownerUID", "ownerGID", "mode", "errno", "sourceBytes", "frameBytes", "limitBytes", "recordSequence"] {
                if let value = fields[key], !value.isEmpty, value.utf8.count <= 10,
                   value.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }) { result[key] = value }
            }
            return result
        }
        return [:]
    }
}
