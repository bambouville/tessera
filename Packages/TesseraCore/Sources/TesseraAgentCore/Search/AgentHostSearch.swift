import Foundation

/// One response to an Agent Host `search`: the records its folded prefilter
/// accepted, the threads it could not read itself, and where the search goes
/// on. The prefilter may over-match; `matches` applies the same exact match as
/// a paged search, so results never depend on which side scanned.
public struct AgentHostSearchReply: Sendable {
    public struct Candidate: Sendable {
        public let thread: String
        public let record: AgentProjectionRecord
    }
    public struct Skipped: Equatable, Sendable {
        public let thread: String
        public let code: String
    }
    /// Codes after which the app pages that thread itself: a source only its
    /// provider's server reads, or a handle from before the host restarted.
    public static let pagedFallbackCodes: Set<String> = ["searchUnsupported", "sourceHandleExpired"]
    /// Android's bound too: a host keeps each reply near 192 KiB.
    public static let maximumBytes = 1_048_576
    public static let maximumFrames = 8_194

    public let candidates: [Candidate]
    public let skipped: [Skipped]
    public let cursor: String?
    /// Matching records the host left out as too large to send.
    public let oversizedRecords: UInt64

    /// `frames` are one response's decoded frames in arrival order.
    public init(frames: [[String: AgentJSONValue]], epoch: String, requestID: String) throws {
        guard AgentIngestionRange.identifier(epoch), AgentIngestionRange.identifier(requestID),
              (2...Self.maximumFrames).contains(frames.count), frames.first?["kind"]?.stringValue == "search.begin",
              frames.last?["kind"]?.stringValue == "search.end" else { throw AgentIngestionError.malformedFrame }
        var candidates: [Candidate] = []
        var skipped: [Skipped] = []
        for (index, frame) in frames.enumerated() {
            guard frame["serviceEpoch"]?.stringValue == epoch else { throw AgentIngestionError.staleEpoch }
            guard frame["id"]?.stringValue == requestID, let kind = frame["kind"]?.stringValue else { throw AgentIngestionError.malformedFrame }
            switch kind {
            case "search.begin", "search.end":
                guard index == 0 || index == frames.count - 1 else { throw AgentIngestionError.malformedFrame }
            case "search.record":
                guard let thread = frame["thread"]?.stringValue, AgentIngestionRange.identifier(thread),
                      let recordID = frame["recordID"]?.stringValue,
                      let order = AgentIngestionPageDecoder.unsigned(frame["order"]),
                      let revision = AgentIngestionPageDecoder.unsigned(frame["revision"]), revision > 0,
                      let body = frame["record"],
                      frame["sourceOffset"] == nil || AgentIngestionPageDecoder.unsigned(frame["sourceOffset"]) != nil,
                      frame["receiptSourceOffset"] == nil || AgentIngestionPageDecoder.receiptOffset(frame["receiptSourceOffset"]) != nil,
                      let record = AgentProjectionRecord(sequence: order, recordID: recordID, record: body,
                          sourceOffset: AgentIngestionPageDecoder.unsigned(frame["sourceOffset"]), revision: revision,
                          receiptSourceIdentity: frame["receiptSourceIdentity"]?.stringValue,
                          receiptSourceOffset: AgentIngestionPageDecoder.receiptOffset(frame["receiptSourceOffset"]),
                          seekToken: frame["seekToken"]?.stringValue)
                else { throw AgentIngestionError.malformedFrame }
                candidates.append(.init(thread: thread, record: record))
            case "search.skipped":
                guard let thread = frame["thread"]?.stringValue, AgentIngestionRange.identifier(thread),
                      let code = frame["code"]?.stringValue, !code.isEmpty, code.utf8.count <= 128 else { throw AgentIngestionError.malformedFrame }
                skipped.append(.init(thread: thread, code: code))
            default:
                throw AgentIngestionError.malformedFrame
            }
        }
        let end = frames[frames.count - 1]
        let cursor = end["cursor"]?.stringValue
        guard AgentIngestionPageDecoder.unsigned(end["records"]) == UInt64(candidates.count),
              end["oversizedRecords"] == nil || AgentIngestionPageDecoder.unsigned(end["oversizedRecords"]) != nil,
              end["cursor"] == nil || cursor.map(AgentIngestionRange.identifier) == true else { throw AgentIngestionError.malformedFrame }
        self.candidates = candidates; self.skipped = skipped; self.cursor = cursor
        self.oversizedRecords = AgentIngestionPageDecoder.unsigned(end["oversizedRecords"]) ?? 0
    }

    /// The framed bytes of one response, as JNI passes them.
    public static func decode(_ bytes: Data, epoch: String, requestID: String) throws -> Self {
        guard bytes.count <= maximumBytes else { throw AgentIngestionError.capacityExceeded }
        var framer = AgentIngestionFramer()
        var frames: [[String: AgentJSONValue]] = []
        try framer.append(bytes) { frame in
            guard let object = try JSONDecoder().decode(AgentJSONValue.self, from: frame).objectValue else {
                throw AgentIngestionError.malformedFrame
            }
            frames.append(object)
        }
        try framer.finish()
        return try Self(frames: frames, epoch: epoch, requestID: requestID)
    }

    /// Exact matches among the candidates, in host order, for the threads the
    /// caller holds; a candidate of any other handle is dropped.
    public func matches(threads: [String: AgentThreadID], query: String, perThread: Int = 25) -> [AgentSearchResult] {
        var order: [String] = []
        var grouped: [String: [AgentProjectionRecord]] = [:]
        for candidate in candidates where threads[candidate.thread] != nil {
            if grouped[candidate.thread] == nil { order.append(candidate.thread) }
            grouped[candidate.thread, default: []].append(candidate.record)
        }
        return order.flatMap { thread in
            AgentNativePageSearch.matches(records: grouped[thread] ?? [], threadID: threads[thread]!, query: query).prefix(perThread)
        }
    }

    /// The query as every search sends and matches it: trimmed, and at most
    /// the 512 UTF-8 bytes a host accepts, cut between characters.
    public static func needle(_ query: String) -> String {
        var needle = Substring(query.trimmingCharacters(in: .whitespacesAndNewlines))
        while needle.utf8.count > 512 { needle.removeLast() }
        return needle.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Handles split into searches whose thread lists stay well inside one
    /// request frame, in order.
    public static func batches(_ handles: [String], maximumBytes: Int = 49_152, maximumCount: Int = 1_000) -> [[String]] {
        var batches: [[String]] = []
        var batch: [String] = [], bytes = 0
        for handle in handles {
            // A quoted identifier and its comma.
            let cost = handle.utf8.count + 3
            if !batch.isEmpty, batch.count == maximumCount || bytes + cost > maximumBytes {
                batches.append(batch); batch = []; bytes = 0
            }
            batch.append(handle); bytes += cost
        }
        if !batch.isEmpty { batches.append(batch) }
        return batches
    }
}

/// One host's search over the thread handles the app holds there: batches,
/// cursors, and the threads already holding their share, so the host reads
/// on only where results can still change.
public enum AgentHostSearchRun {
    public struct Outcome: Sendable {
        public var results: [AgentSearchResult] = []
        /// Handles to page instead: a batch the host refused outright, and
        /// threads it skipped with a paged-fallback code.
        public var paged: [String] = []
        /// False when time or the connection ran out first, or a thread could
        /// not be read to its end; what was found stands.
        public var complete = true
    }

    /// Stops at 100 results counting `admitted`, 25 per thread. `request`
    /// sends one search request within the given deadline and returns its
    /// reply; `accept` admits a match still current for the caller, on the
    /// caller's actor; `progress` sees the results so far after each reply
    /// that added some. Only the caller's own cancellation is rethrown.
    public static func run(
        handles: [String],
        threads: [String: AgentThreadID],
        query: String,
        admitted: Int,
        timeLeft: () -> Duration,
        request: ([String: AgentJSONValue], Duration) async throws -> AgentHostSearchReply,
        accept: (AgentSearchResult) async -> Bool,
        progress: ([AgentSearchResult]) async -> Void = { _ in }
    ) async throws -> Outcome {
        var outcome = Outcome()
        var perThread: [AgentThreadID: Int] = [:]
        var pagedHandles: Set<String> = []
        for batch in AgentHostSearchReply.batches(handles) where admitted + outcome.results.count < 100 {
            var batchThreads: [String: AgentThreadID] = [:]
            for handle in batch { batchThreads[handle] = threads[handle] }
            var satisfied: Set<String> = []
            var cursor: String?
            repeat {
                try Task.checkCancellation()
                let left = timeLeft()
                guard left > .zero else { outcome.complete = false; return outcome }
                var fields: [String: AgentJSONValue] = ["kind": .string("search")]
                if let cursor {
                    fields["cursor"] = .string(cursor)
                    fields["satisfied"] = .array(satisfied.sorted().map { .string($0) })
                } else {
                    fields["query"] = .string(query)
                    fields["threads"] = .array(batch.map { .string($0) })
                }
                let reply: AgentHostSearchReply
                do { reply = try await request(fields, min(left, .seconds(15))) }
                catch is CancellationError where Task.isCancelled { throw CancellationError() }
                catch AgentIngestionError.remote(let code) where cursor == nil && !connectionFailures.contains(code) {
                    // Refused outright (busy, a query it will not take): page.
                    outcome.paged += batch
                    break
                } catch {
                    // Out of time, or the connection closed under the request
                    // (which fails it with a cancellation of its own).
                    outcome.complete = false
                    return outcome
                }
                let before = outcome.results.count
                for match in reply.matches(threads: batchThreads, query: query) {
                    guard admitted + outcome.results.count < 100, perThread[match.threadID, default: 0] < 25 else { continue }
                    // A thread whose route changed meanwhile shows nothing it found.
                    guard await accept(match) else { outcome.complete = false; continue }
                    outcome.results.append(match); perThread[match.threadID, default: 0] += 1
                }
                if outcome.results.count > before { await progress(outcome.results) }
                // Matches the host could not send leave the host incomplete.
                if reply.oversizedRecords > 0 { outcome.complete = false }
                for (handle, threadID) in batchThreads where perThread[threadID, default: 0] >= 25 { satisfied.insert(handle) }
                for skipped in reply.skipped {
                    guard let threadID = batchThreads[skipped.thread] else { continue }
                    if pagedFallbackCodes.contains(skipped.code), perThread[threadID, default: 0] == 0 {
                        if pagedHandles.insert(skipped.thread).inserted { outcome.paged.append(skipped.thread) }
                    }
                    // Not read to its end (its source changed mid-search, or
                    // paging would repeat what it gave): what it gave stands,
                    // and the host reads as incomplete.
                    else { outcome.complete = false }
                }
                cursor = reply.cursor
            } while cursor != nil && admitted + outcome.results.count < 100
        }
        return outcome
    }

    static var pagedFallbackCodes: Set<String> { AgentHostSearchReply.pagedFallbackCodes }
    /// The app's own connection failures, which reach `request` as remote
    /// codes too; only a host's error frame refuses a search.
    static let connectionFailures: Set<String> = ["deadlineExceeded", "disconnected", "helperDiagnostic"]
}
