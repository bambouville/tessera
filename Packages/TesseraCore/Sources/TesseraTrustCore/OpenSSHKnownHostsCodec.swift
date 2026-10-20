import Foundation

public struct OpenSSHKnownHostEntry: Equatable, Sendable {
    public let hosts: [String]
    public let algorithm: String
    public let blob: Data
    public let comment: String?

    public init(hosts: [String], algorithm: String, blob: Data, comment: String? = nil) {
        self.hosts = hosts
        self.algorithm = algorithm
        self.blob = blob
        self.comment = comment
    }
}

public enum OpenSSHKnownHostsCodec {
    public static let maximumLineBytes = 64 * 1024
    public static let maximumEntryCount = 10_000

    public static func decode(_ data: Data) throws -> [OpenSSHKnownHostEntry] {
        guard let text = String(data: data, encoding: .utf8) else {
            throw TrustPolicyError.invalidKnownHostsLine(1)
        }
        var result: [OpenSSHKnownHostEntry] = []
        for (offset, rawLine) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let lineNumber = offset + 1
            guard rawLine.utf8.count <= maximumLineBytes else {
                throw TrustPolicyError.lineTooLong(lineNumber)
            }
            let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
            var fields = trimmed.split(
                omittingEmptySubsequences: true,
                whereSeparator: { $0 == " " || $0 == "\t" }
            ).map(String.init)
            if fields.first?.hasPrefix("@") == true {
                let marker = fields.removeFirst()
                guard marker == "@cert-authority" || marker == "@revoked" else {
                    throw TrustPolicyError.unsupportedMarker(marker)
                }
                // Tessera's pin repository does not silently reinterpret CA or
                // revocation entries as ordinary exact host pins.
                continue
            }
            guard fields.count >= 3,
                  !fields[0].isEmpty,
                  !fields[1].isEmpty,
                  let blob = Data(base64Encoded: fields[2]),
                  blob.base64EncodedString() == fields[2]
            else { throw TrustPolicyError.invalidKnownHostsLine(lineNumber) }
            let hosts = fields[0].split(separator: ",").map(String.init)
            guard !hosts.isEmpty, hosts.allSatisfy({ !$0.isEmpty }) else {
                throw TrustPolicyError.invalidKnownHostsLine(lineNumber)
            }
            result.append(OpenSSHKnownHostEntry(
                hosts: hosts,
                algorithm: fields[1],
                blob: blob,
                comment: fields.count > 3 ? fields.dropFirst(3).joined(separator: " ") : nil
            ))
            guard result.count <= maximumEntryCount else {
                throw TrustPolicyError.invalidKnownHostsLine(lineNumber)
            }
        }
        return result
    }

    public static func encode(_ entries: [OpenSSHKnownHostEntry]) throws -> Data {
        guard entries.count <= maximumEntryCount else {
            throw TrustPolicyError.invalidKnownHostsLine(maximumEntryCount + 1)
        }
        let lines = try entries.map { entry -> String in
            guard !entry.hosts.isEmpty,
                  entry.hosts.allSatisfy({ !$0.isEmpty && !$0.contains(" ") && !$0.contains("\t") }),
                  !entry.algorithm.isEmpty,
                  entry.algorithm.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
                  !entry.blob.isEmpty
            else { throw TrustPolicyError.invalidKnownHostsLine(0) }
            var line = "\(entry.hosts.joined(separator: ",")) \(entry.algorithm) \(entry.blob.base64EncodedString())"
            if let comment = entry.comment, !comment.isEmpty {
                line += " \(comment.replacingOccurrences(of: "\n", with: " "))"
            }
            return line
        }
        return Data((lines.joined(separator: "\n") + (lines.isEmpty ? "" : "\n")).utf8)
    }

    // MARK: - Import plan

    /// Which key space an import plan is computed in.
    ///
    /// A plan's candidate keys, its add/replace/unchanged lookup against
    /// `existingFingerprints`, its ambiguity detection and its duplicate
    /// warnings must all live in ONE key space, and this picks which. Mixing
    /// two is what makes a review sheet lie: a pin the file spells differently
    /// from the store misses the lookup, is planned as `add` with no
    /// `expectedPriorFingerprint`, and is then refused by the store's
    /// compare-and-swap at apply time — the sheet promised an add that never
    /// happens. Worse, two spellings of one host read as two endpoints, so
    /// neither the `ambiguousEndpoint` rejection nor the duplicate warning
    /// fires and whichever line applies last silently wins.
    public enum EndpointNormalization: String, Codable, Equatable, Sendable, CaseIterable {
        /// Host tokens become endpoint keys exactly as the file spells them.
        ///
        /// This is what iOS needs and stays byte-identical to the codec's
        /// original behavior: `KnownHostsStore` keys its records by the address
        /// **as the user typed it** at connection time, so an importer that
        /// normalized would land on a second, shadow key for the same host.
        case verbatim
        /// Host tokens are routed through `KnownHostEndpoint.normalized(host:port:)`
        /// — trim, one trailing dot, one matched bracket pair, lowercase —
        /// before they become candidate, lookup and dedup keys.
        ///
        /// This is what Android needs: its Room store is itself keyed in the
        /// normalized space, so a plan built verbatim would be keyed in a
        /// different space from the store it writes to. A token that
        /// normalization rejects becomes an `unnormalizableHost` rejection for
        /// that token alone; the rest of the line is unaffected.
        case normalized
    }

    /// Parses `known_hosts` text into a reviewable plan without touching any
    /// pin store.
    ///
    /// Guard order is load-bearing and matches the shipped iOS behavior
    /// exactly, because it decides which message the user sees for a line that
    /// is wrong in more than one way:
    ///   1. blank and `#` comment lines are skipped silently;
    ///   2. fewer than three fields → `missingFields` (before we look at the
    ///      host, so `@cert-authority host` alone is "incomplete", not
    ///      "unsupported");
    ///   3. an `@`-marker first field → `unsupportedMarker`;
    ///   4. the key is validated ONCE per line, before the host list is
    ///      expanded — a line with a bad key produces one rejection, not one
    ///      per comma-separated host;
    ///   5. each host token is then mapped to an endpoint, with per-token
    ///      rejections so `good.example,*.bad` still contributes `good.example`.
    ///
    /// Host tokens map **verbatim** by default (no lowercasing, no
    /// trailing-dot strip). The resulting `endpointKey` has to collide with the
    /// key the calling store writes — on iOS that is the address as the user
    /// typed it — or an import would create a second, shadow pin for the same
    /// host. A store that is itself keyed in the normalized space (Android's
    /// Room table) passes `.normalized` instead, so the plan and the store
    /// agree; see `EndpointNormalization`.
    ///
    /// - Parameters:
    ///   - text: raw `known_hosts` file contents.
    ///   - existingFingerprints: endpoint storage key → currently pinned
    ///     fingerprint, used to classify add/replace/unchanged. Its keys must
    ///     be in the key space named by `endpointNormalization`.
    ///   - endpointNormalization: the key space for candidates, the lookup and
    ///     the dedup/ambiguity grouping. `.verbatim` (the default) is exactly
    ///     the behavior this codec has always had, and is what iOS passes.
    ///   - validateKey: platform key validation; defaults to the structural
    ///     core check.
    public static func importPlan(
        text: String,
        existingFingerprints: [String: String],
        endpointNormalization: EndpointNormalization = .verbatim,
        validateKey: KnownHostsImportKeyValidator = structuralKeyValidation
    ) -> KnownHostsImportPlan {
        var parsed: [ParsedCandidate] = []
        var rejections: [KnownHostsImportRejection] = []

        for (offset, rawLine) in text.components(separatedBy: .newlines).enumerated() {
            let lineNumber = offset + 1
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }

            let fields = line.split(whereSeparator: { $0.isWhitespace })
            guard fields.count >= 3 else {
                rejections.append(.init(
                    lineNumber: lineNumber,
                    source: line,
                    reason: .missingFields
                ))
                continue
            }
            guard !fields[0].hasPrefix("@") else {
                rejections.append(.init(
                    lineNumber: lineNumber,
                    source: line,
                    reason: .unsupportedMarker(String(fields[0]))
                ))
                continue
            }

            let hostField = String(fields[0])
            let keyString = "\(fields[1]) \(fields[2])"
            guard case let .accepted(canonicalKey, fingerprint) = validateKey(keyString) else {
                rejections.append(.init(
                    lineNumber: lineNumber,
                    source: line,
                    reason: .invalidPublicKey
                ))
                continue
            }

            for hostToken in hostField.split(separator: ",", omittingEmptySubsequences: false) {
                let token = String(hostToken)
                var endpoint: KnownHostEndpoint
                do {
                    endpoint = try parseEndpoint(fromKnownHostsHostToken: token)
                } catch let reason as KnownHostsImportRejectionReason {
                    rejections.append(.init(
                        lineNumber: lineNumber,
                        source: token,
                        reason: reason
                    ))
                    continue
                } catch {
                    rejections.append(.init(
                        lineNumber: lineNumber,
                        source: token,
                        reason: .invalidHostField
                    ))
                    continue
                }

                // Canonicalize BEFORE the endpoint becomes a key: everything
                // downstream — the add/replace/unchanged lookup, the ambiguity
                // grouping, the duplicate warning — reads `endpoint.storageKey`,
                // so normalizing here is what puts all of them in one space.
                if endpointNormalization == .normalized {
                    guard let canonical = try? KnownHostEndpoint.normalized(
                        host: endpoint.host,
                        port: Int(endpoint.port)
                    ) else {
                        rejections.append(.init(
                            lineNumber: lineNumber,
                            source: token,
                            reason: .unnormalizableHost
                        ))
                        continue
                    }
                    endpoint = canonical
                }

                parsed.append(ParsedCandidate(
                    lineNumber: lineNumber,
                    endpoint: endpoint,
                    keyString: canonicalKey,
                    fingerprint: fingerprint
                ))
            }
        }

        var deduplicated: [ParsedCandidate] = []
        // Sorted so a plan is reproducible: `Dictionary(grouping:)` iterates in
        // hash order, and a review sheet whose rejection list reshuffles
        // between two runs over the same file is not reviewable.
        var ambiguousRejections: [KnownHostsImportRejection] = []
        var warnings: [KnownHostsImportWarning] = []
        for (endpointKey, group) in Dictionary(grouping: parsed, by: \.endpointKey) {
            let fingerprints = Set(group.map(\.fingerprint))
            guard fingerprints.count == 1 else {
                for candidate in group {
                    ambiguousRejections.append(.init(
                        lineNumber: candidate.lineNumber,
                        source: endpointKey,
                        reason: .ambiguousEndpoint
                    ))
                }
                continue
            }
            if group.count > 1 {
                for duplicate in group.dropFirst() {
                    warnings.append(.duplicatePinIgnored(
                        lineNumber: duplicate.lineNumber,
                        endpointKey: endpointKey
                    ))
                }
            }
            if let first = group.first {
                deduplicated.append(first)
            }
        }
        ambiguousRejections.sort { lhs, rhs in
            lhs.lineNumber == rhs.lineNumber
                ? lhs.source < rhs.source
                : lhs.lineNumber < rhs.lineNumber
        }
        warnings.sort { lhs, rhs in
            let left = lhs.sortKey
            let right = rhs.sortKey
            return left.0 == right.0 ? left.1 < right.1 : left.0 < right.0
        }
        rejections.append(contentsOf: ambiguousRejections)

        deduplicated.sort { lhs, rhs in
            lhs.lineNumber == rhs.lineNumber
                ? lhs.endpointKey < rhs.endpointKey
                : lhs.lineNumber < rhs.lineNumber
        }

        let candidates = deduplicated.map { candidate -> KnownHostsImportCandidate in
            let current = existingFingerprints[candidate.endpointKey]
            let action: KnownHostsImportAction
            if let current {
                action = current == candidate.fingerprint ? .unchanged : .replace
            } else {
                action = .add
            }
            return KnownHostsImportCandidate(
                lineNumber: candidate.lineNumber,
                endpoint: candidate.endpoint,
                keyString: candidate.keyString,
                fingerprint: candidate.fingerprint,
                action: action,
                expectedPriorFingerprint: current
            )
        }
        return KnownHostsImportPlan(
            candidates: candidates,
            rejections: rejections,
            warnings: warnings
        )
    }

    /// Core's Foundation-only key check: algorithm token, canonical base64,
    /// and the algorithm name declared inside the blob agreeing with the token.
    public static let structuralKeyValidation: KnownHostsImportKeyValidator = { keyString in
        guard let key = try? SSHHostPublicKey.parse(openSSHKeyString: keyString) else {
            return .rejected
        }
        return .accepted(
            canonicalKeyString: key.openSSHKeyString,
            fingerprint: key.fingerprint
        )
    }

    // MARK: - Export

    /// Renders one `known_hosts` line for a stored pin.
    public static func exportLine(endpointKey: String, keyString: String) -> String {
        "\(knownHostsHostField(fromEndpointKey: endpointKey)) \(keyString)"
    }

    /// Renders a whole `known_hosts` file, lines sorted so the output is
    /// stable across runs (the store is a dictionary) and diffable.
    ///
    /// Host fingerprints are public material; this export never reads or
    /// includes authentication key material.
    public static func exportText(records: [KnownHostsExportRecord]) -> String {
        let lines = records
            .map { exportLine(endpointKey: $0.endpointKey, keyString: $0.keyString) }
            .sorted()
        return lines.joined(separator: "\n").appending(lines.isEmpty ? "" : "\n")
    }

    /// The `ssh(1)`-shaped host field for a storage key.
    ///
    /// OpenSSH writes a bare host at the default port and `[host]:port`
    /// otherwise — writing `[host]:22` instead would round-trip through our own
    /// importer but would not match what `ssh` writes, so a user's real
    /// `known_hosts` and ours would disagree on the same host.
    ///
    /// A key with no colon, or with a non-numeric trailing segment, is passed
    /// through verbatim rather than mangled: it is not a `host:port` key.
    public static func knownHostsHostField(fromEndpointKey endpointKey: String) -> String {
        guard let separator = endpointKey.lastIndex(of: ":") else { return endpointKey }
        let host = String(endpointKey[..<separator])
        let port = String(endpointKey[endpointKey.index(after: separator)...])
        guard Int(port) != nil else { return endpointKey }
        return port == "22" ? host : "[\(host)]:\(port)"
    }

    // MARK: - Host tokens

    /// Maps one `known_hosts` host token onto a Tessera endpoint.
    ///
    /// Throws a `KnownHostsImportRejectionReason` so callers can attribute the
    /// failure to the offending token rather than the whole line.
    public static func parseEndpoint(
        fromKnownHostsHostToken token: String
    ) throws -> KnownHostEndpoint {
        guard !token.isEmpty else {
            throw KnownHostsImportRejectionReason.emptyHostField
        }
        guard !token.hasPrefix("|") else {
            throw KnownHostsImportRejectionReason.hashedHost
        }
        guard !token.contains("*"), !token.contains("?"), !token.hasPrefix("!") else {
            throw KnownHostsImportRejectionReason.wildcardOrNegatedHost
        }
        if token.hasPrefix("[") {
            guard let close = token.firstIndex(of: "]"),
                  token.index(after: close) < token.endIndex,
                  token[token.index(after: close)] == ":" else {
                throw KnownHostsImportRejectionReason.invalidBracketedHostPort
            }
            let host = String(token[token.index(after: token.startIndex)..<close])
            let portStart = token.index(close, offsetBy: 2)
            let port = String(token[portStart...])
            guard !host.isEmpty,
                  let portNumber = Int(port),
                  (1...65535).contains(portNumber) else {
                throw KnownHostsImportRejectionReason.invalidHostOrPort
            }
            return KnownHostEndpoint(host: host, port: UInt16(portNumber))
        }
        return KnownHostEndpoint(host: token, port: 22)
    }

    private struct ParsedCandidate {
        let lineNumber: Int
        let endpoint: KnownHostEndpoint
        let keyString: String
        let fingerprint: String

        var endpointKey: String { endpoint.storageKey }
    }
}

extension KnownHostsImportRejectionReason: Error {}

private extension KnownHostsImportWarning {
    var sortKey: (Int, String) {
        switch self {
        case let .duplicatePinIgnored(lineNumber, endpointKey):
            return (lineNumber, endpointKey)
        }
    }
}
