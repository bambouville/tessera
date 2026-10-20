import Foundation

public struct AgentIngestionPartition: Equatable, Codable, Sendable {
    public let original: String
    public let id: String
    public let before: String
    public let after: String
    public let offset: Int
    public let count: Int
    public let hasOlder: Bool
    public let hasNewer: Bool

    public init(original: String, id: String, before: String, after: String, offset: Int, count: Int,
                hasOlder: Bool, hasNewer: Bool) throws {
        guard [original, id, before, after].allSatisfy(AgentIngestionRange.identifier), before != after,
              offset >= 0, offset < 100, count > 0, count <= 100 - offset else { throw AgentIngestionError.malformedFrame }
        self.original = original; self.id = id; self.before = before; self.after = after
        self.offset = offset; self.count = count; self.hasOlder = hasOlder; self.hasNewer = hasNewer
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(original: values.decode(String.self, forKey: .original), id: values.decode(String.self, forKey: .id),
            before: values.decode(String.self, forKey: .before), after: values.decode(String.self, forKey: .after),
            offset: values.decode(Int.self, forKey: .offset), count: values.decode(Int.self, forKey: .count),
            hasOlder: values.decode(Bool.self, forKey: .hasOlder), hasNewer: values.decode(Bool.self, forKey: .hasNewer))
    }
}

public struct AgentIngestionWindowTransaction: Equatable, Codable, Sendable {
    public enum Lane: String, Codable, Sendable { case bootstrap, before, after, head, revisions }
    public let lane: Lane
    public let version: UInt64
    public let segmentID: String?
    public let before: String?
    public let after: String?
    public let hasOlder: Bool
    public let hasNewer: Bool
    public let partitions: [AgentIngestionPartition]

    public init(lane: Lane, version: UInt64, segmentID: String? = nil, before: String? = nil,
                after: String? = nil, hasOlder: Bool = false, hasNewer: Bool = false,
                partitions: [AgentIngestionPartition] = []) throws {
        guard version > 0, [segmentID, before, after].allSatisfy({ $0.map(AgentIngestionRange.identifier) ?? true }),
              partitions.count <= 20, lane == .revisions || partitions.isEmpty,
              lane == .revisions ? (segmentID == nil && before == nil && after == nil && !hasOlder && !hasNewer) :
                  (segmentID != nil && before != nil && after != nil) else { throw AgentIngestionError.malformedFrame }
        self.lane = lane; self.version = version; self.segmentID = segmentID; self.before = before; self.after = after
        self.hasOlder = hasOlder; self.hasNewer = hasNewer
        self.partitions = partitions
    }

    public func segment(source: String, records: [AgentProjectionRecord]) throws -> AgentIngestionSegment {
        guard let segmentID, let before, let after, lane != .revisions else { throw AgentIngestionError.malformedFrame }
        return try .init(id: segmentID, source: source, before: before, after: after,
            hasOlder: hasOlder, hasNewer: hasNewer, records: records)
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(lane: values.decode(Lane.self, forKey: .lane), version: values.decode(UInt64.self, forKey: .version),
            segmentID: values.decodeIfPresent(String.self, forKey: .segmentID), before: values.decodeIfPresent(String.self, forKey: .before),
            after: values.decodeIfPresent(String.self, forKey: .after), hasOlder: values.decodeIfPresent(Bool.self, forKey: .hasOlder) ?? false,
            hasNewer: values.decodeIfPresent(Bool.self, forKey: .hasNewer) ?? false,
            partitions: values.decodeIfPresent([AgentIngestionPartition].self, forKey: .partitions) ?? [])
    }
}

public struct AgentIngestionWindowSnapshot: Equatable, Codable, Sendable {
    public let version: UInt64
    public let epoch: String
    public let viewportSegmentIDs: [String]
    public let headSegmentID: String?
    public let before: String?
    public let after: String?
    public let hasOlder: Bool
    public let hasNewer: Bool
    public let atLiveHead: Bool
    public let liveCursor: String?
    public let transition: AgentIngestionWindowTransaction.Lane
    public let retainsOutgoing: Bool
    /// The window is at the live head and one more full older page fits
    /// without evicting its newest segment, so a short transcript can fill
    /// its viewport without leaving the live head. Optional: older encodings
    /// omit it.
    public let olderPageFits: Bool?
    /// The transcript reaches the live head only across rows the host no
    /// longer retains (`AgentIngestionWindow.bridge`). It still reads as
    /// `atLiveHead`; a following reader asks for the newer page that retains
    /// them. Optional: older encodings omit it.
    public let bridgesToHead: Bool?

    init(_ window: AgentIngestionWindow, epoch: String, liveCursor: String?, transition: AgentIngestionWindowTransaction.Lane = .bootstrap,
         retainsOutgoing: Bool = false, derivedRoom: Bool = true) {
        version = window.version; self.epoch = epoch; viewportSegmentIDs = window.viewport.map(\.id); headSegmentID = window.head?.id
        before = window.before; after = window.after; hasOlder = window.hasOlder; hasNewer = window.hasNewer
        atLiveHead = window.atLiveHead || window.bridgesToHead; self.liveCursor = liveCursor
        self.transition = transition
        self.retainsOutgoing = retainsOutgoing
        olderPageFits = window.atLiveHead && window.olderPageFits && derivedRoom
        bridgesToHead = window.bridgesToHead
    }
}

/// A canonical page with two exclusive recovery boundaries. Neither boundary
/// is a live checkpoint: navigating a viewport never acknowledges a send.
public struct AgentIngestionSegment: Equatable, Codable, Sendable {
    public let id: String
    public let source: String
    public let before: String
    public let after: String
    public let hasOlder: Bool
    public let hasNewer: Bool
    public private(set) var records: [AgentProjectionRecord]
    public private(set) var encodedBytes: Int

    public init(id: String, source: String, before: String, after: String,
                hasOlder: Bool, hasNewer: Bool, records: [AgentProjectionRecord]) throws {
        guard [id, before, after].allSatisfy(AgentIngestionRange.identifier),
              !source.isEmpty, source.utf8.count <= 512, records.count <= 100,
              Set(records.map(\.recordID)).count == records.count,
              zip(records, records.dropFirst()).allSatisfy({ $0.sequence < $1.sequence }) else {
            throw AgentIngestionError.malformedFrame
        }
        let bytes = try JSONEncoder().encode(records).count
        guard bytes <= 262_144 else { throw AgentIngestionError.capacityExceeded }
        self.id = id; self.source = source; self.before = before; self.after = after
        self.hasOlder = hasOlder; self.hasNewer = hasNewer; self.records = records; self.encodedBytes = bytes
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(id: values.decode(String.self, forKey: .id), source: values.decode(String.self, forKey: .source),
            before: values.decode(String.self, forKey: .before), after: values.decode(String.self, forKey: .after),
            hasOlder: values.decode(Bool.self, forKey: .hasOlder), hasNewer: values.decode(Bool.self, forKey: .hasNewer),
            records: values.decode([AgentProjectionRecord].self, forKey: .records))
    }

    static func validOffsetRevision(from old: AgentProjectionRecord, to new: AgentProjectionRecord, source: String) -> Bool {
        if old.sourceOffset == new.sourceOffset { return true }
        // A completed snapshot can be appended later without changing the
        // item's canonical position. Only this indexed provider permits a
        // strictly newer revision to advance its physical byte provenance.
        guard source.hasPrefix("codex-history:"), new.revision > old.revision,
              let before = old.sourceOffset, let after = new.sourceOffset else { return false }
        return after > before
    }

    func revisedRecords(_ replacements: [String: AgentProjectionRecord]) throws -> [AgentProjectionRecord] {
        var next = records
        for index in next.indices {
            guard let incoming = replacements[next[index].recordID] else { continue }
            let old = next[index]
            guard incoming.sequence == old.sequence, Self.validOffsetRevision(from: old, to: incoming, source: source), incoming.revision >= old.revision,
                  incoming.revision != old.revision || incoming == old else { throw AgentIngestionError.staleEpoch }
            next[index] = incoming
        }
        return next
    }

    mutating func revise(_ replacements: [String: AgentProjectionRecord]) throws {
        let next = try revisedRecords(replacements)
        let bytes = try JSONEncoder().encode(next).count
        guard bytes <= 262_144 else { throw AgentIngestionError.capacityExceeded }
        records = next; encodedBytes = bytes
    }
}

/// Value-semantic transaction staging: callers publish this state and its
/// derived model together, then ACK `retainedIDs`. A failed admission leaves
/// both boundaries and the old viewport unchanged.
public struct AgentIngestionWindow: Equatable, Sendable {
    public enum Direction: String, Sendable { case before, after }
    /// Fixed at bootstrap from the device budget and the host's advertised
    /// acknowledgement limit; a larger viewport would be rejected on ACK.
    public let capacity: AgentIngestionWindowCapacity
    public private(set) var viewport: [AgentIngestionSegment] = []
    public private(set) var head: AgentIngestionSegment?
    public private(set) var version: UInt64 = 0
    /// Rows between the viewport's newest record and a head page that no
    /// longer holds it: a revision split (the host keeps only the head's last
    /// part) or a roll moved them out of the retained window. They were
    /// already presented from the old head, so they stay presented, in order,
    /// until an `.after` page retains them. Never acknowledged or revised.
    public private(set) var bridge: [AgentProjectionRecord] = []
    /// The viewport record `bridge` continues; nil when nothing is bridged.
    private var bridgeFrom: String?
    public var records: [AgentProjectionRecord] { viewport.flatMap(\.records) }
    /// Edge records without flattening every retained page. Metadata-only
    /// segments carry no records, so the edge is the nearest non-empty page.
    var firstRecord: AgentProjectionRecord? { viewport.lazy.compactMap(\.records.first).first }
    var lastRecord: AgentProjectionRecord? { viewport.reversed().lazy.compactMap(\.records.last).first }
    public var before: String? { viewport.first?.before }
    public var after: String? { viewport.last?.after }
    public var hasOlder: Bool { viewport.first?.hasOlder ?? false }
    public var hasNewer: Bool {
        guard !atLiveHead, !bridgesToHead else { return head?.hasNewer ?? false }
        if let newest = head?.records.last?.sequence, let visible = lastRecord?.sequence, newest > visible { return true }
        return viewport.last?.hasNewer ?? false
    }
    /// The viewport's newest record is inside the live head page, so the
    /// viewport and the head read as one contiguous transcript through the
    /// newest record (the projection shows their union).
    public var atLiveHead: Bool {
        guard let head, let last = viewport.last, last.source == head.source else { return false }
        if last.id == head.id { return true }
        guard let visible = lastRecord else { return false }
        return head.records.contains { $0.recordID == visible.recordID && $0.sequence == visible.sequence }
    }
    /// The viewport continues into the head page through `bridge` alone.
    public var bridgesToHead: Bool { bridgeFrom != nil && !atLiveHead }
    /// What the transcript shows: the viewport, continued through the newest
    /// record by a detached head that still overlaps it (see `atLiveHead`)
    /// or by the bridge to it. A head beyond a gap stays out of view until
    /// history reaches it.
    public var presentedRecords: [AgentProjectionRecord] {
        guard let head, viewport.last?.id != head.id, let last = lastRecord?.sequence else { return records }
        if atLiveHead { return records + head.records.filter { $0.sequence > last } }
        guard bridgesToHead else { return records }
        let bridged = bridge.last?.sequence ?? last
        return records + bridge + head.records.filter { $0.sequence > bridged }
    }
    /// `trim` admits an older page by dropping the newest segment once the
    /// viewport is over capacity; this is the room left before that happens.
    public var olderPageFits: Bool {
        viewport.count < capacity.segments
            && viewport.reduce(0, { $0 + $1.records.count }) + AgentIngestionWindowCapacity.recordsPerSegment <= capacity.records
            && viewport.reduce(0, { $0 + $1.encodedBytes }) + 262_144 <= capacity.bytes
    }
    public var retainedIDs: [String] {
        var ids = viewport.map(\.id)
        if let head, !ids.contains(head.id) { ids.append(head.id) }
        return ids
    }
    public var encodedBytes: Int {
        viewport.reduce(0) { $0 + $1.encodedBytes } +
            ((head != nil && !viewport.contains(where: { $0.id == head?.id })) ? head!.encodedBytes : 0)
    }

    public init(capacity: AgentIngestionWindowCapacity = .legacy) { self.capacity = capacity }

    public mutating func bootstrap(_ segment: AgentIngestionSegment) throws {
        guard !segment.hasNewer else { throw AgentIngestionError.incompletePage }
        try advanceVersion()
        viewport = [segment]; head = segment; settleBridge()
    }

    public mutating func navigate(_ segment: AgentIngestionSegment, direction: Direction,
                                 from: String, expectedVersion: UInt64, pinnedRecordID: String?) throws {
        guard expectedVersion == version, !viewport.isEmpty,
              segment.source == viewport[0].source,
              from == (direction == .before ? before : after),
              !viewport.contains(where: { $0.id == segment.id }),
              segment.id != head?.id || segment == head else { throw AgentIngestionError.staleEpoch }
        var next = self
        let previousIDs = Set(next.records.map(\.recordID))
        guard segment.records.allSatisfy({ !previousIDs.contains($0.recordID) }) else { throw AgentIngestionError.malformedFrame }
        // The rolling live head may be detached from the contiguous viewport.
        // History may overlap it, but cannot reassign its identity/provenance
        // or reintroduce a stale body under an already observed revision.
        let live = Dictionary(uniqueKeysWithValues: (head?.records ?? []).map { ($0.recordID, $0) })
        for record in segment.records {
            if let prior = live[record.recordID] {
                guard prior.sequence == record.sequence,
                      AgentIngestionSegment.validOffsetRevision(from: prior, to: record, source: segment.source),
                      record.revision >= prior.revision,
                      record.revision != prior.revision || record == prior else { throw AgentIngestionError.staleEpoch }
            }
        }
        if let first = segment.records.first?.sequence, let last = segment.records.last?.sequence {
            if direction == .before, let boundary = next.firstRecord?.sequence, last >= boundary { throw AgentIngestionError.staleEpoch }
            if direction == .after, let boundary = next.lastRecord?.sequence, first <= boundary { throw AgentIngestionError.staleEpoch }
        }
        // Even a metadata-only page is an advancing segment, not EOF.
        guard (direction == .before ? segment.before : segment.after) != from else { throw AgentIngestionError.incompletePage }
        if direction == .before { next.viewport.insert(segment, at: 0) }
        else { next.viewport.append(segment) }
        try next.trim(opposite: direction, pinnedRecordID: pinnedRecordID)
        // A newer page that ends inside the bridge retains its first rows.
        if direction == .after, next.bridgeFrom != nil, let last = next.lastRecord,
           next.bridge.contains(where: { $0.recordID == last.recordID && $0.sequence == last.sequence }) {
            next.bridge.removeAll { $0.sequence <= last.sequence }; next.bridgeFrom = last.recordID
        }
        next.settleBridge()
        try next.advanceVersion()
        self = next
    }

    public mutating func returnToHead() throws {
        guard let head else { throw AgentIngestionError.incompletePage }
        try advanceVersion(); viewport = [head]; settleBridge()
    }

    /// Additional derived-model admission uses the same whole-segment rule.
    /// This is part of a staged transaction and does not advance its version.
    /// Room for the derived model is estimated before an older page is read
    /// (`olderPageFits`), so a page can still overrun it. Such a page never
    /// evicts the newest segment under a following reader (no pin) at the
    /// live head, which would leave them behind "Return to latest": it is
    /// refused as over capacity. Readers paging history report a pin.
    mutating func evictOffscreen(opposite direction: Direction, pinnedRecordID: String?, protectedSegmentID: String?) -> Bool {
        guard viewport.count > 1, direction == .after || !followsLiveHead(pinnedRecordID) else { return false }
        let index = direction == .before ? viewport.count - 1 : 0
        guard viewport[index].id != protectedSegmentID,
              pinnedRecordID.map({ id in !viewport[index].records.contains(where: { $0.recordID == id }) }) ?? true else { return false }
        viewport.remove(at: index); settleBridge(); return true
    }

    private func followsLiveHead(_ pinnedRecordID: String?) -> Bool {
        pinnedRecordID == nil && (atLiveHead || bridgesToHead)
    }

    /// A head kept detached beside retained history (a rolled page) that
    /// leaves no room for both falls back to the head page alone, as a
    /// follower's head update did before history was kept. A reader pinned
    /// in that history keeps it instead.
    mutating func collapseToLiveHead(pinnedRecordID: String?) -> Bool {
        guard let head, viewport.last?.id != head.id, atLiveHead || bridgesToHead,
              pinnedRecordID.map({ id in head.records.contains { $0.recordID == id } || !records.contains { $0.recordID == id } }) ?? true
        else { return false }
        viewport = [head]; settleBridge(); return true
    }

    /// Head replacement cannot bridge an omitted historical interval. A reader
    /// pinned in the outgoing head keeps that segment as a detached viewport.
    public mutating func replaceHead(_ segment: AgentIngestionSegment, expectedVersion: UInt64, pinnedRecordID: String?) throws {
        guard expectedVersion == version, let old = head, old.source == segment.source,
              !retainedIDs.contains(segment.id) else { throw AgentIngestionError.staleEpoch }
        if let tail = old.records.last {
            guard let newer = segment.records.last, newer.sequence >= tail.sequence,
                  newer.sequence != tail.sequence || newer.recordID == tail.recordID else { throw AgentIngestionError.staleEpoch }
        }
        let known = Dictionary((records + bridge + old.records).map { ($0.recordID, $0) }, uniquingKeysWith: { lhs, rhs in lhs.revision >= rhs.revision ? lhs : rhs })
        for record in segment.records {
            if let prior = known[record.recordID] {
                guard prior.sequence == record.sequence, AgentIngestionSegment.validOffsetRevision(from: prior, to: record, source: segment.source), record.revision >= prior.revision,
                      record.revision != prior.revision || record == prior else { throw AgentIngestionError.staleEpoch }
            }
        }
        var next = self
        let follows = next.atLiveHead || next.bridgesToHead
        // Everything presented after the viewport, oldest first.
        let presentedTail = bridge + old.records.filter { $0.sequence > (bridge.last ?? lastRecord)?.sequence ?? 0 }
        // A bridge only survives by joining this head (below).
        next.bridge = []; next.bridgeFrom = nil
        next.head = segment
        if follows {
            let removedPin = pinnedRecordID.map { id in
                viewport.last?.records.contains(where: { $0.recordID == id }) == true &&
                    !segment.records.contains(where: { $0.recordID == id })
            } ?? false
            if viewport.last?.id == old.id && old.records.first?.recordID == segment.records.first?.recordID && !removedPin {
                next.viewport[next.viewport.count - 1] = segment
                try next.trim(opposite: .after, pinnedRecordID: pinnedRecordID)
            } else if next.atLiveHead {
                // A full head page rolls: each append drops its oldest record.
                // While it still holds the viewport's newest record there is
                // no gap, so keep the retained history and detach the head.
                // Collapsing to the head page here dropped a following
                // reader's history on every append.
            } else if let first = segment.records.first, let last = lastRecord,
                      presentedTail.contains(where: { $0.recordID == first.recordID && $0.sequence == first.sequence }),
                      case let rows = presentedTail.filter({ $0.sequence > last.sequence && $0.sequence < first.sequence }),
                      rows.count <= AgentIngestionWindowCapacity.recordsPerSegment {
                // The head rolled past the viewport's newest record, but the
                // rows between them are the ones already shown from the old
                // head. Bridge them rather than drop the reader's history;
                // a newer page retains them.
                next.bridge = rows; next.bridgeFrom = last.recordID
            } else if pinnedRecordID.map({ id in segment.records.contains(where: { $0.recordID == id }) }) ?? true {
                // A rolling newest page can leave a gap after older segments.
                // Following the live tail may replace the entire viewport;
                // otherwise retain the reader's old contiguous window.
                next.viewport = [segment]
            }
        }
        next.settleBridge()
        try next.advanceVersion(); self = next
    }

    public mutating func revise(_ patches: [AgentProjectionRecord], expectedVersion: UInt64,
                               partitions: [AgentIngestionPartition] = [], pinnedRecordID: String? = nil) throws {
        guard expectedVersion == version, patches.count <= 100,
              partitions.count <= 20, Set(patches.map(\.recordID)).count == patches.count else { throw AgentIngestionError.staleEpoch }
        let known = Set(records.map(\.recordID) + (head?.records.map(\.recordID) ?? []))
        guard patches.allSatisfy({ known.contains($0.recordID) }) else { throw AgentIngestionError.staleEpoch }
        let replacements = Dictionary(uniqueKeysWithValues: patches.map { ($0.recordID, $0) })
        var next = self
        let originals = Dictionary((viewport + (head.map { [$0] } ?? [])).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let groups = Dictionary(grouping: partitions, by: \.original)
        guard Set(partitions.map(\.id)).count == partitions.count,
              partitions.allSatisfy({ originals[$0.id] == nil && originals[$0.original] != nil }) else { throw AgentIngestionError.malformedFrame }
        var revised: [String: [AgentIngestionSegment]] = [:]
        for (id, original) in originals {
            guard let parts = groups[id] else {
                var segment = original; try segment.revise(replacements); revised[id] = [segment]; continue
            }
            guard parts.count >= 2, original.records.contains(where: { replacements[$0.recordID] != nil }) else {
                throw AgentIngestionError.malformedFrame
            }
            let records = try original.revisedRecords(replacements)
            var offset = 0
            var slices: [AgentIngestionSegment] = []
            for part in parts {
                guard part.offset == offset, part.count <= records.count - offset,
                      part.hasOlder == (original.hasOlder || offset > 0),
                      part.hasNewer == (original.hasNewer || offset + part.count < records.count),
                      offset != 0 || part.before == original.before,
                      offset + part.count != records.count || part.after == original.after else { throw AgentIngestionError.malformedFrame }
                let slice = Array(records[offset..<(offset + part.count)])
                slices.append(try .init(id: part.id, source: original.source, before: part.before, after: part.after,
                    hasOlder: part.hasOlder, hasNewer: part.hasNewer, records: slice))
                offset += part.count
            }
            guard offset == records.count else { throw AgentIngestionError.malformedFrame }
            revised[id] = slices
        }
        next.viewport = viewport.flatMap { revised[$0.id]! }
        if let head { next.head = revised[head.id]!.last }
        // The host retains only a split head's last part. Rows before it that
        // this window already presented past the viewport stay presented.
        if let head, viewport.last?.id != head.id, atLiveHead || bridgesToHead, !next.atLiveHead,
           let last = lastRecord, next.lastRecord?.recordID == last.recordID,
           let first = next.head?.records.first?.sequence {
            let tail = bridge + revised[head.id]!.flatMap(\.records)
            next.bridge = tail.filter { $0.sequence > last.sequence && $0.sequence < first }
            next.bridgeFrom = last.recordID
        }
        // Splits preserve record identity and order. Admit a contiguous
        // bounded interval around the reader's pin, evicting only edge parts.
        while next.viewport.count > capacity.segments || next.viewport.reduce(0, { $0 + $1.records.count }) > capacity.records ||
                next.viewport.reduce(0, { $0 + $1.encodedBytes }) > capacity.bytes {
            guard next.evictRevisionEdge(pinnedRecordID: pinnedRecordID) else { throw AgentIngestionError.capacityExceeded }
        }
        next.settleBridge()
        try next.advanceVersion(); self = next
    }

    mutating func evictRevisionEdge(pinnedRecordID: String?) -> Bool {
        guard viewport.count > 1 else { return false }
        let pin = pinnedRecordID.flatMap { id in viewport.firstIndex { $0.records.contains { $0.recordID == id } } }
        let removeLast = pin.map { $0 < viewport.count - 1 - $0 } ?? false
        if removeLast { viewport.removeLast() } else { viewport.removeFirst() }
        return true
    }

    private mutating func trim(opposite direction: Direction, pinnedRecordID: String?) throws {
        while viewport.count > capacity.segments || viewport.reduce(0, { $0 + $1.records.count }) > capacity.records ||
                viewport.reduce(0, { $0 + $1.encodedBytes }) > capacity.bytes {
            let index = direction == .before ? viewport.count - 1 : 0
            guard viewport.count > 1, pinnedRecordID.map({ id in !viewport[index].records.contains(where: { $0.recordID == id }) }) ?? true else {
                throw AgentIngestionError.capacityExceeded
            }
            viewport.remove(at: index)
        }
    }

    /// A bridge joins the viewport's newest record to the head page, and no
    /// more: it lapses once the viewport reaches the head or no longer ends
    /// where the bridge began.
    private mutating func settleBridge() {
        guard let from = bridgeFrom else { return }
        let joins = lastRecord?.recordID == from && !atLiveHead
            && (bridge.last?.sequence).map { last in head?.records.first.map { $0.sequence > last } ?? false } ?? (head?.records.isEmpty == false)
        if !joins { bridge = []; bridgeFrom = nil }
    }

    private mutating func advanceVersion() throws {
        guard version < UInt64.max else { throw AgentIngestionError.capacityExceeded }
        version += 1
    }
}
