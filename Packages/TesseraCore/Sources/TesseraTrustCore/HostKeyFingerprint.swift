import Crypto
import Foundation

extension SSHHostPublicKey {
    /// Base64 padding of a rendered `SHA256:` fingerprint.
    ///
    /// OpenSSH itself, Android's Known Hosts screen and
    /// `DevicePublicKeyValidator.fingerprint(forSSHBlob:)` all render the
    /// digest *unpadded* — that is the canonical cross-platform form and the
    /// default here.
    ///
    /// `.padded` exists for exactly one caller: iOS `KnownHostsStore` has
    /// persisted padded fingerprints in `known_hosts.json` since the store
    /// shipped, and it compares the stored string against a freshly computed
    /// one to decide "trusted" vs "changed". Silently switching that call site
    /// to the unpadded form would make every already-pinned host report a key
    /// MISMATCH on the next connection. The format divergence therefore lives
    /// here, in one place, with one implementation behind it.
    public enum FingerprintPadding: String, Codable, Equatable, Sendable {
        case unpadded
        case padded
    }

    /// OpenSSH-style `SHA256:` fingerprint of an SSH wire-format public key
    /// blob, matching OpenSSH's default `FingerprintHash sha256` display.
    public static func sha256Fingerprint(
        of blob: Data,
        padding: FingerprintPadding = .unpadded
    ) -> String {
        let digest = Data(SHA256.hash(data: blob)).base64EncodedString()
        switch padding {
        case .unpadded:
            return "SHA256:" + digest.replacingOccurrences(of: "=", with: "")
        case .padded:
            return "SHA256:" + digest
        }
    }

    /// The `"algorithm base64blob"` rendering used by OpenSSH `known_hosts`
    /// and `authorized_keys` lines.
    public var openSSHKeyString: String {
        "\(algorithm) \(blob.base64EncodedString())"
    }

    /// Largest public-key blob this core will decode. An RSA-8192 host key is
    /// roughly 1 KiB; the cap only exists so a hostile file cannot make the
    /// parser allocate without bound.
    public static let maximumBlobBytes = 16 * 1024

    /// Structural parse of an OpenSSH `"algorithm base64blob"` key string.
    ///
    /// Validation is deliberately *structural only*, mirroring the approach in
    /// `DevicePublicKeyValidator`: the algorithm token must be present, the
    /// base64 must decode and re-encode byte-identically (no sloppy or padded
    /// variants sneaking through), and the algorithm name declared inside the
    /// blob must equal the token in front of it. A key that lies about its own
    /// algorithm never becomes a pin.
    ///
    /// Deep, per-algorithm key parsing (curve points, RSA moduli, unsupported
    /// key types) is a platform enrichment: iOS runs `NIOSSHPublicKey` over the
    /// same string before showing an import plan. Core stays Foundation+Crypto.
    public static func parse(
        openSSHKeyString keyString: String,
        fingerprintPadding: FingerprintPadding = .unpadded
    ) throws -> SSHHostPublicKey {
        let fields = keyString.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard fields.count >= 2, !fields[0].isEmpty else {
            throw TrustPolicyError.invalidKey
        }
        let algorithm = fields[0]
        let encoded = fields[1]
        guard let blob = Data(base64Encoded: encoded),
              !blob.isEmpty,
              blob.count <= maximumBlobBytes,
              blob.base64EncodedString() == encoded
        else { throw TrustPolicyError.invalidKey }
        guard blobAlgorithmName(blob) == algorithm else {
            throw TrustPolicyError.keyAlgorithmMismatch
        }
        return try SSHHostPublicKey(
            algorithm: algorithm,
            blob: blob,
            fingerprint: sha256Fingerprint(of: blob, padding: fingerprintPadding)
        )
    }

    /// Reads the first SSH `string` field of a wire-format blob: by
    /// convention that field is the key's own algorithm name.
    static func blobAlgorithmName(_ blob: Data) -> String? {
        var cursor = SSHBlobCursor(data: blob)
        guard let name = cursor.readString(maximumLength: 128) else { return nil }
        return String(data: name, encoding: .utf8)
    }
}

/// Minimal reader for SSH's length-prefixed wire encoding. Deliberately a
/// local copy: `TesseraEnrollmentCore` has the same helper but depends on this
/// target, so sharing it the other way round would be a dependency cycle.
struct SSHBlobCursor {
    let data: Data
    var offset = 0

    var isAtEnd: Bool { offset == data.count }

    mutating func readString(maximumLength: Int) -> Data? {
        guard data.count >= 4, offset <= data.count - 4 else { return nil }
        let start = data.startIndex + offset
        let length = data[start..<(start + 4)].reduce(0) { ($0 << 8) | Int($1) }
        offset += 4
        guard length >= 0, length <= maximumLength, offset <= data.count - length else {
            return nil
        }
        let valueStart = data.startIndex + offset
        defer { offset += length }
        return data.subdata(in: valueStart..<(valueStart + length))
    }
}
