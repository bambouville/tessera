import Foundation
import TesseraInputCore

/// Argument decoding and result copy-out shared by the stateless shared-core
/// helpers (input, trust, session policy, mosh, OS detection, forwarding,
/// pairing QR, continuation identity).
///
/// Every one of those functions follows the same two contracts:
///
///  * **The string/bytes contract.** A NULL or zero-capacity output buffer
///    queries the exact byte count, so a caller with no fixed ceiling can size
///    the buffer precisely; a buffer that is present but too small returns -1
///    rather than truncating. The same call must be answered identically in
///    both phases, which is why every producer here is a pure function of its
///    inputs.
///  * **The JSON contract.** Structured requests and responses are `Codable`
///    values encoded with `.sortedKeys` + `.withoutEscapingSlashes`, so the
///    bytes a platform sees are canonical and byte-stable across runs. The
///    request/response structs in these files ARE the ABI: the Kotlin wrapper
///    mirrors them field for field.
///
///    Two properties of that encoding are load-bearing for the Kotlin side and
///    are pinned by a test. Keys are sorted. And an absent optional is
///    **omitted**, not written as null — Swift's synthesized encoder uses
///    `encodeIfPresent` — which is why every Kotlin reader asks `isNull`, a
///    question that treats a missing key and an explicit null alike. Requests
///    coming the other way may spell an absent value either way: the decoder
///    accepts both.
///
/// Input decoding is deliberately *strict* UTF-8: an invalid sequence is
/// rejected instead of being repaired into replacement characters, because
/// every consumer here is a validator, a parser, or a byte producer where a
/// silently substituted U+FFFD would change the answer.
enum SharedABI {
    /// Ceiling on any single UTF-8/JSON argument. Matches the published
    /// `TESSERA_CORE_ABI_MAX_PAYLOAD_BYTES` so a platform has one number to
    /// reason about.
    static let maximumInputBytes = 1_048_576

    /// Ceiling on one render payload (`RenderEffect.feed` bytes), published as
    /// `TESSERA_TMUX_ABI_MAX_RENDER_BYTES`.
    ///
    /// Deliberately larger than `maximumInputBytes`: an argument is something a
    /// platform composes, while a render payload is a `capture-pane` reply
    /// whose size the tmux host decides. A full-depth inline history capture of
    /// a wide pane weighs several hundred KB, so a 1 MiB ceiling would silently
    /// drop exactly the deepest rung of the SSH+tmux scrollback ladder. The
    /// argument ceiling and `TESSERA_CORE_ABI_MAX_PAYLOAD_BYTES` are unchanged.
    static let maximumRenderBytes = 8_388_608

    /// Canonical encoder for every response in this batch.
    static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    // MARK: - Argument decoding

    /// A required UTF-8 argument. Rejects a missing pointer, a non-positive
    /// count, an over-long argument, and invalid UTF-8.
    static func requiredString(
        _ bytes: UnsafePointer<UInt8>?,
        _ count: Int,
        maximum: Int = maximumInputBytes
    ) -> String? {
        guard let bytes, count > 0, count <= maximum else { return nil }
        return String(bytes: UnsafeBufferPointer(start: bytes, count: count), encoding: .utf8)
    }

    /// An argument the caller may legitimately omit. The double optional
    /// distinguishes "omitted" (`.some(nil)`) from "supplied but invalid"
    /// (`.none`) so a caller cannot smuggle malformed bytes past a `?? nil`.
    static func optionalString(
        _ bytes: UnsafePointer<UInt8>?,
        _ count: Int,
        maximum: Int = maximumInputBytes
    ) -> String?? {
        if bytes == nil || count <= 0 { return .some(nil) }
        guard let value = requiredString(bytes, count, maximum: maximum) else { return .none }
        return .some(value)
    }

    /// Raw bytes with no text interpretation (key blobs, typed key events).
    static func requiredData(
        _ bytes: UnsafePointer<UInt8>?,
        _ count: Int,
        maximum: Int = maximumInputBytes
    ) -> Data? {
        guard let bytes, count > 0, count <= maximum else { return nil }
        return Data(bytes: bytes, count: count)
    }

    /// Decodes a bounded canonical JSON request.
    static func decode<T: Decodable>(
        _ type: T.Type,
        _ bytes: UnsafePointer<UInt8>?,
        _ count: Int,
        maximum: Int = maximumInputBytes
    ) -> T? {
        guard let data = requiredData(bytes, count, maximum: maximum) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    // MARK: - Result copy-out

    /// The string contract. See the type comment.
    static func copyOut(
        _ value: String,
        _ outputBytes: UnsafeMutablePointer<UInt8>?,
        _ outputCapacity: Int
    ) -> Int32 {
        copyOut(Array(value.utf8), outputBytes, outputCapacity)
    }

    /// The bytes contract, identical in shape to the string one so a producer
    /// of terminal bytes and a producer of text behave the same at the seam.
    static func copyOut(
        _ result: [UInt8],
        _ outputBytes: UnsafeMutablePointer<UInt8>?,
        _ outputCapacity: Int
    ) -> Int32 {
        guard result.count <= Int(Int32.max) else { return -1 }
        guard let outputBytes, outputCapacity > 0 else { return Int32(result.count) }
        guard result.count <= outputCapacity else { return -1 }
        result.withUnsafeBytes { raw in
            guard let baseAddress = raw.baseAddress else { return }
            outputBytes.update(
                from: baseAddress.assumingMemoryBound(to: UInt8.self),
                count: result.count
            )
        }
        return Int32(result.count)
    }

    /// Encodes a response and copies it out under the string contract.
    static func copyOutJSON<T: Encodable>(
        _ value: T,
        _ outputBytes: UnsafeMutablePointer<UInt8>?,
        _ outputCapacity: Int
    ) -> Int32 {
        guard let data = try? encoder.encode(value) else { return -1 }
        return copyOut([UInt8](data), outputBytes, outputCapacity)
    }
}

// MARK: - Modifier bit vector

/// The modifier bit vector every input entry point takes.
///
/// It is a bit vector rather than JSON because these calls sit in the typing
/// path, and because the four flags are the whole argument. The values are
/// fixed ABI constants — see `TESSERA_INPUT_MODIFIER_*` in the header — and
/// deliberately NOT xterm's `1 + shift + 2*alt + 4*ctrl` parameter, which is a
/// wire encoding rather than a state description and has no bit for Command.
enum TerminalModifierBits {
    static let control: Int32 = 1 << 0
    static let alternate: Int32 = 1 << 1
    static let shift: Int32 = 1 << 2
    static let command: Int32 = 1 << 3
    static let all: Int32 = control | alternate | shift | command
}

extension TerminalModifiers {
    /// Nil when the caller set a bit this ABI does not define, so a future
    /// flag cannot be silently ignored by an older core.
    init?(abiBits bits: Int32) {
        guard bits >= 0, bits & ~TerminalModifierBits.all == 0 else { return nil }
        self.init(
            ctrl: bits & TerminalModifierBits.control != 0,
            alt: bits & TerminalModifierBits.alternate != 0,
            shift: bits & TerminalModifierBits.shift != 0,
            cmd: bits & TerminalModifierBits.command != 0
        )
    }

    var abiBits: Int32 {
        var bits: Int32 = 0
        if ctrl { bits |= TerminalModifierBits.control }
        if alt { bits |= TerminalModifierBits.alternate }
        if shift { bits |= TerminalModifierBits.shift }
        if cmd { bits |= TerminalModifierBits.command }
        return bits
    }
}
