import Foundation
import CryptoKit
import XCTest

final class AgentHostBundlePackagingTests: XCTestCase {
    private struct Manifest: Decodable {
        struct Artifact: Decodable {
            let target: String
            let bytes: Int
            let sha256: String
        }
        let artifacts: [Artifact]
    }

    func testBundledHelpersAreCompressedAndMatchManifest() throws {
        let resources = try XCTUnwrap(Bundle.main.resourceURL)
        let directory = resources.appendingPathComponent("agent-host")
        let manifestURL = directory.appendingPathComponent("manifest.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: manifestURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("THIRD-PARTY-NOTICES.txt").path))
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: manifestURL))
        XCTAssertFalse(manifest.artifacts.isEmpty)
        for entry in manifest.artifacts {
            let url = directory.appendingPathComponent("tessera-agent-host-" + entry.target + ".lzfse")
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), url.path)
            let data = try Data(contentsOf: url)
            let artifact = try (data as NSData).decompressed(using: .lzfse) as Data
            XCTAssertEqual(artifact.count, entry.bytes, entry.target)
            XCTAssertEqual(SHA256.hash(data: artifact).map { String(format: "%02x", $0) }.joined(), entry.sha256, entry.target)
        }

        let rawNames = Set(manifest.artifacts.map { "tessera-agent-host-" + $0.target })
        let files = try XCTUnwrap(FileManager.default.enumerator(
            at: Bundle.main.bundleURL, includingPropertiesForKeys: [.isRegularFileKey],
            errorHandler: { url, error in
                XCTFail("Could not enumerate \(url.path): \(error)")
                return true
            }
        ))
        for case let url as URL in files {
            XCTAssertFalse(rawNames.contains(url.lastPathComponent), url.path)
        }

        let executableMagic: Set<Data> = [
            Data([0xfe, 0xed, 0xfa, 0xcf]), Data([0xcf, 0xfa, 0xed, 0xfe]),
            Data([0xca, 0xfe, 0xba, 0xbe]), Data([0x7f, 0x45, 0x4c, 0x46])
        ]
        let helperFiles = try XCTUnwrap(FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: [.isRegularFileKey],
            errorHandler: { url, error in
                XCTFail("Could not enumerate \(url.path): \(error)")
                return true
            }
        ))
        for case let url as URL in helperFiles {
            guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
            let prefix = Data(try Data(contentsOf: url).prefix(4))
            XCTAssertFalse(executableMagic.contains(prefix), "Executable payload at \(url.path)")
            let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
            XCTAssertEqual(try XCTUnwrap(permissions).intValue & 0o111, 0, url.path)
        }
    }
}
