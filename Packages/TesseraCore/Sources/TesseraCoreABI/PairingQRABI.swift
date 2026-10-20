import Foundation
import TesseraCrossDeviceCore
import TesseraPairingCore

/// The pairing QR text codec, plus the cross-device command canonicalizer.
///
/// Both exist for the same reason: the pairing boundary accepts exactly one
/// byte sequence for a given meaning, and a platform that hand-builds those
/// bytes will eventually disagree with Swift's encoder about key order or
/// escaping. Rather than have Kotlin reproduce Swift's JSON, it submits what
/// it has and takes back the canonical form.

/// The decoded offer.
///
/// ```json
/// {"expiresAt":1756000000,"offerBytes":"eyJ2…","offerID":"…","ok":true,
///  "originRole":"origin","purpose":"bootstrap",
///  "supportedPairingVersions":[1],"supportedTransactionVersions":[1],
///  "version":1}
/// ```
/// or `{"error":"nonCanonical","ok":false}`.
///
/// `offerBytes` is the base64 of the *canonical* offer encoding, which is what
/// a caller must forward to the pairing runtime — not the scanned text and not
/// its own re-encoding.
///
/// `error` is `invalidFormat` (wrong prefix, or a character outside the strict
/// base64url alphabet), `invalidBase64URL` (the alphabet was right but the
/// bytes are not), `tooLarge`, or `nonCanonical` (the payload decoded but does
/// not re-encode to the exact text that was scanned — a re-spelled offer is
/// rejected rather than normalized).
public struct PairingQRDecodeABIResponse: Codable, Equatable, Sendable {
    public enum Failure: String, Codable, Sendable {
        case invalidFormat, invalidBase64URL, tooLarge, nonCanonical
    }

    public var ok: Bool
    public var offerBytes: Data?
    public var offerID: UUID?
    public var version: Int?
    public var purpose: PairingPurpose?
    public var originRole: PairingRoleV1?
    /// Unix time in whole seconds. Integer time is intentional: it has one
    /// canonical, language-neutral JSON representation.
    public var expiresAt: Int64?
    public var supportedPairingVersions: [Int]?
    public var supportedTransactionVersions: [Int]?
    public var error: Failure?
}

private func pairingQRFailure(_ error: Error) -> PairingQRDecodeABIResponse.Failure? {
    guard let error = error as? PairingQRTextErrorV1 else { return nil }
    switch error {
    case .invalidFormat: return .invalidFormat
    case .invalidBase64URL: return .invalidBase64URL
    case .tooLarge: return .tooLarge
    case .nonCanonical: return .nonCanonical
    }
}

/// Decodes scanner text into a canonical pairing offer.
///
/// The grammar is a small closed one, parsed directly rather than through URL
/// normalization: no percent escapes, no alternate query layouts, no optional
/// URL components. Returns the byte count under the string contract, or -1 for
/// invalid arguments. A rejected scan is a successful call with `ok: false`.
@_cdecl("tessera_pairing_qr_decode_offer")
public func tesseraPairingQRDecodeOffer(
    textBytes: UnsafePointer<UInt8>?,
    textCount: Int,
    outputBytes: UnsafeMutablePointer<UInt8>?,
    outputCapacity: Int
) -> Int32 {
    guard let text = SharedABI.requiredString(
        textBytes,
        textCount,
        maximum: PairingQRTextCodecV1.maximumEncodedCharacters * 4
    ) else { return -1 }

    let response: PairingQRDecodeABIResponse
    do {
        let offerBytes = try PairingQRTextCodecV1.decodeOfferBytes(text)
        let offer = try PairingOfferV1.decode(offerBytes)
        response = PairingQRDecodeABIResponse(
            ok: true,
            offerBytes: offerBytes,
            offerID: offer.offerID,
            version: offer.version,
            purpose: offer.purpose,
            originRole: offer.originRole,
            expiresAt: offer.expiresAt,
            supportedPairingVersions: offer.supportedPairingVersions,
            supportedTransactionVersions: offer.supportedTransactionVersions,
            error: nil
        )
    } catch {
        guard let failure = pairingQRFailure(error) else { return -1 }
        response = PairingQRDecodeABIResponse(
            ok: false,
            offerBytes: nil,
            offerID: nil,
            version: nil,
            purpose: nil,
            originRole: nil,
            expiresAt: nil,
            supportedPairingVersions: nil,
            supportedTransactionVersions: nil,
            error: failure
        )
    }
    return SharedABI.copyOutJSON(response, outputBytes, outputCapacity)
}

/// `{"error":"tooLarge","ok":false}` / `{"ok":true,"text":"tessera://pair/v1?offer=…"}`
public struct PairingQREncodeABIResponse: Codable, Equatable, Sendable {
    public var ok: Bool
    public var text: String?
    public var error: PairingQRDecodeABIResponse.Failure?
}

/// Renders offer bytes as QR text.
///
/// The bytes are re-decoded and re-encoded canonically first, so an adapter
/// holding a hand-built offer cannot put a non-canonical payload into a QR
/// image that the scanning side would then reject as `nonCanonical`. Returns
/// the byte count under the string contract, or -1 for invalid arguments.
@_cdecl("tessera_pairing_qr_encode_offer")
public func tesseraPairingQREncodeOffer(
    offerBytes: UnsafePointer<UInt8>?,
    offerCount: Int,
    outputBytes: UnsafeMutablePointer<UInt8>?,
    outputCapacity: Int
) -> Int32 {
    guard let offer = SharedABI.requiredData(
        offerBytes,
        offerCount,
        maximum: PairingOfferV1.maximumEncodedBytes
    ) else { return -1 }

    let response: PairingQREncodeABIResponse
    do {
        response = PairingQREncodeABIResponse(
            ok: true,
            text: try PairingQRTextCodecV1.encode(offerBytes: offer),
            error: nil
        )
    } catch {
        // A malformed offer that never becomes text is reported the same way a
        // malformed scan is: as an outcome, not as an argument error.
        response = PairingQREncodeABIResponse(
            ok: false,
            text: nil,
            error: pairingQRFailure(error) ?? .invalidFormat
        )
    }
    return SharedABI.copyOutJSON(response, outputBytes, outputCapacity)
}

// MARK: - Cross-device command canonicalization

/// Re-encodes a cross-device ABI command into the exact bytes the pairing ABI
/// will accept.
///
/// `tessera_cross_device_runtime_send` decodes with a strict byte-equality
/// gate: the payload must re-encode to itself, so an adapter cannot smuggle
/// ignored fields or alternate JSON spellings past the boundary. That gate is
/// correct, but it means a Kotlin builder has to reproduce Swift's encoder
/// (sorted keys, unescaped slashes, its own field-presence rules) exactly.
/// This call removes that duplication: submit what you built, send back what
/// this returns.
///
/// Returns the canonical bytes' count under the shared bytes contract, or -1
/// when the command is invalid — malformed JSON, an unsupported version, or a
/// field the command's kind does not allow.
@_cdecl("tessera_cross_device_canonicalize_command")
public func tesseraCrossDeviceCanonicalizeCommand(
    commandBytes: UnsafePointer<UInt8>?,
    commandCount: Int,
    outputBytes: UnsafeMutablePointer<UInt8>?,
    outputCapacity: Int
) -> Int32 {
    guard let command = SharedABI.requiredData(
        commandBytes,
        commandCount,
        maximum: CrossDeviceABICommandV1.maximumPayloadBytes
    ), let decoded = try? JSONDecoder().decode(CrossDeviceABICommandV1.self, from: command),
       let canonical = try? decoded.encoded()
    else { return -1 }
    return SharedABI.copyOut([UInt8](canonical), outputBytes, outputCapacity)
}
