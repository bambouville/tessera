import Foundation

public struct ArtifactsCacheEntry: Codable, Equatable, Sendable {
    public var key: String
    public var size: Int64
    public var viewedAt: Int64
    public var pinned: Bool

    public init(key: String, size: Int64, viewedAt: Int64, pinned: Bool = false) {
        self.key = key
        self.size = size
        self.viewedAt = viewedAt
        self.pinned = pinned
    }
}

public enum ArtifactsCacheState: String, Codable, Equatable, Sendable {
    case live, cached, stale, offline, none
}

/// {"state":"cached","fetchedAt":10,"canRefresh":false}.
/// `cached` always carries fetchedAt; `stale` carries it when bytes exist.
public struct ArtifactsCachePresentation: Codable, Equatable, Sendable {
    public var state: ArtifactsCacheState
    public var fetchedAt: Int64?
    public var canRefresh: Bool
}

public enum ArtifactsCachePolicy {
    /// Lowercase SHA-256 of UTF-8 `hostID|kind|normalized path`.
    /// Pages include scheme and port in the path and omit the fragment.
    /// Changes use immutable persistence blobs, not the fetched-file cache.
    public static func cacheKey(_ tab: ArtifactTab) -> String {
        let path: String
        switch tab.target.normalized {
        case let .file(p), let .change(p, _, _): path = p
        case let .page(scheme, port, p): path = "\(scheme)://localhost:\(port)\(ArtifactsPaths.withoutFragment(p))"
        }
        return ArtifactsDigest.hex("\(tab.hostID)|\(tab.kind.rawValue)|\(path)")
    }

    /// Oldest viewed entries first, with lexical keys breaking ties. Callers
    /// protect the selected tab's key; entry.pinned protects pinned tabs.
    /// A budget below the protected footprint simply evicts every candidate.
    public static func evictions(
        _ entries: [ArtifactsCacheEntry], budgetBytes: Int64, protectedKeys: Set<String>
    ) -> [String] {
        // A shared file key is accounted for once, conservatively retaining
        // the largest size, latest access and any pin among its references.
        var unique: [String: ArtifactsCacheEntry] = [:]
        for entry in entries {
            if var previous = unique[entry.key] {
                previous.size = max(previous.size, entry.size)
                previous.viewedAt = max(previous.viewedAt, entry.viewedAt)
                previous.pinned = previous.pinned || entry.pinned
                unique[entry.key] = previous
            } else { unique[entry.key] = entry }
        }
        var total: UInt64 = 0
        for entry in unique.values {
            let sum = total.addingReportingOverflow(UInt64(max(0, entry.size)))
            total = sum.overflow ? UInt64.max : sum.partialValue
        }
        let budget = UInt64(max(0, budgetBytes))
        let candidates = unique.values.filter { !$0.pinned && !protectedKeys.contains($0.key) }.sorted {
            $0.viewedAt == $1.viewedAt ? $0.key < $1.key : $0.viewedAt < $1.viewedAt
        }
        var result: [String] = []
        for entry in candidates where total > budget {
            result.append(entry.key)
            total -= min(total, UInt64(max(0, entry.size)))
        }
        return result
    }

    /// No implicit reconnect or time-based expiry. Staleness comes from a
    /// remote stat or agent edit, not elapsed wall time. nowMillis is supplied
    /// by the caller for deterministic future policy extensions.
    public static func presentation(
        _ tab: ArtifactTab, liveConnection: Bool, nowMillis: Int64
    ) -> ArtifactsCachePresentation {
        switch tab.target {
        case .page:
            return .init(state: liveConnection ? .live : .offline, canRefresh: liveConnection)
        case .change:
            return .init(state: .cached, fetchedAt: tab.openedAt, canRefresh: false)
        case .file: break
        }
        guard let cache = tab.cache else {
            return .init(state: liveConnection ? .none : .offline, canRefresh: liveConnection)
        }
        let stale = cache.isStale || (tab.agentEditedAt.map { $0 > cache.fetchedAt } ?? false)
        return .init(state: stale ? .stale : (liveConnection ? .live : .cached),
                     fetchedAt: cache.fetchedAt, canRefresh: liveConnection)
    }
}

/// Dependency-free SHA-256. TrustCore's SHA uses swift-crypto; this target's
/// only module dependency is DomainCore. All arithmetic is fixed-width.
enum ArtifactsDigest {
    #if DEBUG
    private final class Work: NSObject {
        var calls = 0
        var bytes = 0
    }
    private static let workKey = "TesseraArtifactsCore.digestWork"

    /// Thread-local so mechanism tests cannot count another executor's work.
    static func measure<T>(_ operation: () throws -> T) rethrows -> (value: T, calls: Int, bytes: Int) {
        let dictionary = Thread.current.threadDictionary
        let previous = dictionary[workKey]
        let work = Work()
        dictionary[workKey] = work
        defer { dictionary[workKey] = previous }
        let value = try operation()
        return (value, work.calls, work.bytes)
    }
    #endif

    static func hex(_ value: String) -> String {
        #if DEBUG
        if let work = Thread.current.threadDictionary[workKey] as? Work {
            work.calls += 1
            work.bytes += value.utf8.count
        }
        #endif
        var bytes = Array(value.utf8)
        let bitCount = UInt64(bytes.count) &* 8
        bytes.append(0x80)
        while bytes.count % 64 != 56 { bytes.append(0) }
        for shift in stride(from: 56, through: 0, by: -8) {
            bytes.append(UInt8(truncatingIfNeeded: bitCount >> UInt64(shift)))
        }
        var hash: [UInt32] = [
            0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
            0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
        ]
        for offset in stride(from: 0, to: bytes.count, by: 64) {
            var words = [UInt32](repeating: 0, count: 64)
            for i in 0..<16 {
                let p = offset + i * 4
                words[i] = UInt32(bytes[p]) << 24 | UInt32(bytes[p + 1]) << 16
                    | UInt32(bytes[p + 2]) << 8 | UInt32(bytes[p + 3])
            }
            for i in 16..<64 {
                let a = words[i - 15], b = words[i - 2]
                let s0 = rotate(a, 7) ^ rotate(a, 18) ^ (a >> 3)
                let s1 = rotate(b, 17) ^ rotate(b, 19) ^ (b >> 10)
                words[i] = words[i - 16] &+ s0 &+ words[i - 7] &+ s1
            }
            var a = hash[0], b = hash[1], c = hash[2], d = hash[3]
            var e = hash[4], f = hash[5], g = hash[6], h = hash[7]
            for i in 0..<64 {
                let s1 = rotate(e, 6) ^ rotate(e, 11) ^ rotate(e, 25)
                let choose = (e & f) ^ (~e & g)
                let t1 = h &+ s1 &+ choose &+ constants[i] &+ words[i]
                let s0 = rotate(a, 2) ^ rotate(a, 13) ^ rotate(a, 22)
                let majority = (a & b) ^ (a & c) ^ (b & c)
                let t2 = s0 &+ majority
                h = g; g = f; f = e; e = d &+ t1
                d = c; c = b; b = a; a = t1 &+ t2
            }
            for (i, value) in [a, b, c, d, e, f, g, h].enumerated() { hash[i] = hash[i] &+ value }
        }
        let digits = Array("0123456789abcdef".utf8)
        var output: [UInt8] = []
        for word in hash {
            for shift in stride(from: 24, through: 0, by: -8) {
                let byte = UInt8(truncatingIfNeeded: word >> UInt32(shift))
                output.append(digits[Int(byte >> 4)])
                output.append(digits[Int(byte & 15)])
            }
        }
        return String(decoding: output, as: UTF8.self)
    }

    private static func rotate(_ value: UInt32, _ bits: UInt32) -> UInt32 {
        (value >> bits) | (value << (32 - bits))
    }

    private static let constants: [UInt32] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
    ]
}
