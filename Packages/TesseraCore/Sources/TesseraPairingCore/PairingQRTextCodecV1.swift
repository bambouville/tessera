import Foundation

/// Canonical QR text adapter for Pairing-v1 offers. It intentionally parses
/// the small closed grammar itself rather than accepting URL normalization,
/// alternate query layouts, percent escapes, or optional URL components.
public enum PairingQRTextCodecV1 {
    public static let prefix = "tessera://pair/v1?offer="
    public static let maximumEncodedCharacters = prefix.count
        + ((PairingOfferV1.maximumEncodedBytes + 2) / 3) * 4

    public static func encode(_ offer: PairingOfferV1) throws -> String {
        try encode(offerBytes: offer.encoded())
    }

    /// Validates that callers cannot render non-canonical offer bytes into a
    /// QR image. This is useful for adapters holding the origin's raw bytes.
    public static func encode(offerBytes: Data) throws -> String {
        let offer = try PairingOfferV1.decode(offerBytes)
        let canonical = try offer.encoded()
        let text = prefix + base64URLEncoded(canonical)
        guard text.count <= maximumEncodedCharacters else {
            throw PairingQRTextErrorV1.tooLarge
        }
        return text
    }

    public static func decode(_ text: String) throws -> PairingOfferV1 {
        try PairingOfferV1.decode(decodeOfferBytes(text))
    }

    public static func decodeOfferBytes(_ text: String) throws -> Data {
        guard text.count <= maximumEncodedCharacters else { throw PairingQRTextErrorV1.tooLarge }
        guard text.hasPrefix(prefix) else { throw PairingQRTextErrorV1.invalidFormat }
        let encoded = String(text.dropFirst(prefix.count))
        guard !encoded.isEmpty,
              encoded.utf8.allSatisfy({
                  ($0 >= 65 && $0 <= 90)
                      || ($0 >= 97 && $0 <= 122)
                      || ($0 >= 48 && $0 <= 57)
                      || $0 == 45 || $0 == 95
              }) else {
            throw PairingQRTextErrorV1.invalidFormat
        }
        var standard = encoded.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = standard.utf8.count % 4
        guard remainder != 1 else { throw PairingQRTextErrorV1.invalidBase64URL }
        if remainder != 0 {
            standard.append(String(repeating: "=", count: 4 - remainder))
        }
        guard let bytes = Data(base64Encoded: standard),
              bytes.count <= PairingOfferV1.maximumEncodedBytes else {
            throw PairingQRTextErrorV1.invalidBase64URL
        }
        let offer = try PairingOfferV1.decode(bytes)
        guard try encode(offer) == text else { throw PairingQRTextErrorV1.nonCanonical }
        return try offer.encoded()
    }

    private static func base64URLEncoded(_ bytes: Data) -> String {
        bytes.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

public enum PairingQRTextErrorV1: Error, Equatable, Sendable {
    case invalidFormat
    case invalidBase64URL
    case tooLarge
    case nonCanonical
}
