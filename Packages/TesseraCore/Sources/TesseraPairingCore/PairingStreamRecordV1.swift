import Foundation

/// The only records local byte-stream adapters exchange while establishing a
/// Pairing-v1 channel. The offer itself is delivered out-of-band (normally by
/// QR); transaction payloads travel inside `authenticatedPairingFrame` only.
public enum PairingStreamRecordKindV1: UInt8, CaseIterable, Sendable {
    case recipientCommitment = 1
    case originHello = 2
    case recipientHello = 3
    case authenticatedPairingFrame = 4
}

public struct PairingStreamRecordV1: Equatable, Sendable {
    public static let currentVersion: UInt8 = 1
    public static let magic = Data([0x54, 0x50, 0x52, 0x31]) // TPR1
    public static let headerByteCount = 4 + 1 + 1 + 4
    public static let maximumPayloadBytes = PairingFrameV1.maximumEncodedBytes

    public let version: UInt8
    public let kind: PairingStreamRecordKindV1
    public let payload: Data

    public init(kind: PairingStreamRecordKindV1, payload: Data) throws {
        version = Self.currentVersion
        self.kind = kind
        self.payload = payload
        try validate()
    }

    public func encoded() throws -> Data {
        try validate()
        var data = Self.magic
        data.append(version)
        data.append(kind.rawValue)
        data.pairingAppendUInt32(UInt32(payload.count))
        data.append(payload)
        return data
    }

    public static func decodeExactly(_ data: Data) throws -> PairingStreamRecordV1 {
        let decoder = PairingStreamRecordDecoderV1()
        let records = try decoder.append(data)
        try decoder.finish()
        guard records.count == 1 else { throw PairingStreamRecordErrorV1.trailingRecords }
        return records[0]
    }

    fileprivate init(
        version: UInt8,
        kind: PairingStreamRecordKindV1,
        payload: Data
    ) throws {
        self.version = version
        self.kind = kind
        self.payload = payload
        try validate()
    }

    private func validate() throws {
        guard version == Self.currentVersion else {
            throw PairingStreamRecordErrorV1.unsupportedVersion(version)
        }
        guard !payload.isEmpty else { throw PairingStreamRecordErrorV1.zeroLength }
        let maximum = Self.maximumPayloadBytes(for: kind)
        guard payload.count <= maximum else {
            throw PairingStreamRecordErrorV1.payloadTooLarge(
                actual: payload.count,
                maximum: maximum
            )
        }
    }

    public static func maximumPayloadBytes(for kind: PairingStreamRecordKindV1) -> Int {
        switch kind {
        case .recipientCommitment:
            return PairingCommitmentV1.maximumEncodedBytes
        case .originHello, .recipientHello:
            return PairingHelloV1.maximumEncodedBytes
        case .authenticatedPairingFrame:
            return maximumPayloadBytes
        }
    }
}

public enum PairingStreamRecordErrorV1: Error, Equatable, Sendable {
    case invalidMagic
    case unsupportedVersion(UInt8)
    case unknownKind(UInt8)
    case zeroLength
    case payloadTooLarge(actual: Int, maximum: Int)
    case bufferedBytesTooLarge(actual: Int, maximum: Int)
    case truncatedAtFinish
    case trailingRecords
    case decoderFailed
}

/// Incremental, allocation-bounded decoder for local TCP/socket adapters.
/// It deliberately accepts arbitrary fragmentation and coalescing, but an
/// error makes this decoder terminal so callers cannot continue a bad stream.
public final class PairingStreamRecordDecoderV1: @unchecked Sendable {
    /// A byte-stream read may contain several coalesced records, but it must
    /// not make the decoder an unbounded allocation sink before a header can
    /// be inspected. This remains well above the largest individual record.
    public static let maximumBufferedBytes = 1_048_576

    private var buffered = Data()
    private var failed = false
    private let lock = NSLock()

    public init() {}

    public func append(_ bytes: Data) throws -> [PairingStreamRecordV1] {
        lock.lock()
        defer { lock.unlock() }
        guard !failed else { throw PairingStreamRecordErrorV1.decoderFailed }
        let (combinedCount, overflow) = buffered.count.addingReportingOverflow(bytes.count)
        guard !overflow, combinedCount <= Self.maximumBufferedBytes else {
            failed = true
            throw PairingStreamRecordErrorV1.bufferedBytesTooLarge(
                actual: overflow ? Int.max : combinedCount,
                maximum: Self.maximumBufferedBytes
            )
        }
        buffered.append(bytes)
        do {
            var output: [PairingStreamRecordV1] = []
            while buffered.count >= PairingStreamRecordV1.headerByteCount {
                guard buffered.prefix(PairingStreamRecordV1.magic.count)
                    == PairingStreamRecordV1.magic else {
                    throw PairingStreamRecordErrorV1.invalidMagic
                }
                let version = buffered[PairingStreamRecordV1.magic.count]
                guard version == PairingStreamRecordV1.currentVersion else {
                    throw PairingStreamRecordErrorV1.unsupportedVersion(version)
                }
                let kindOffset = PairingStreamRecordV1.magic.count + 1
                let rawKind = buffered[kindOffset]
                guard let kind = PairingStreamRecordKindV1(rawValue: rawKind) else {
                    throw PairingStreamRecordErrorV1.unknownKind(rawKind)
                }
                let lengthStart = kindOffset + 1
                let lengthEnd = lengthStart + 4
                let length = Int(buffered.subdata(in: lengthStart..<lengthEnd).pairingUInt32BigEndian)
                guard length != 0 else { throw PairingStreamRecordErrorV1.zeroLength }
                let maximum = PairingStreamRecordV1.maximumPayloadBytes(for: kind)
                guard length <= maximum else {
                    throw PairingStreamRecordErrorV1.payloadTooLarge(
                        actual: length,
                        maximum: maximum
                    )
                }
                let total = PairingStreamRecordV1.headerByteCount + length
                guard buffered.count >= total else { break }
                let payload = buffered.subdata(in: PairingStreamRecordV1.headerByteCount..<total)
                let record = try PairingStreamRecordV1(
                    version: version,
                    kind: kind,
                    payload: payload
                )
                // Require the unique byte representation used by `encoded()`.
                guard try record.encoded() == buffered.prefix(total) else {
                    throw PairingStreamRecordErrorV1.invalidMagic
                }
                output.append(record)
                // `Data.removeFirst` may retain a non-zero start index. Make
                // the next header parse a fresh zero-indexed value instead.
                buffered = Data(buffered.dropFirst(total))
            }
            return output
        } catch {
            failed = true
            throw error
        }
    }

    public func finish() throws {
        lock.lock()
        defer { lock.unlock() }
        guard !failed else { throw PairingStreamRecordErrorV1.decoderFailed }
        guard buffered.isEmpty else {
            failed = true
            throw PairingStreamRecordErrorV1.truncatedAtFinish
        }
    }
}
