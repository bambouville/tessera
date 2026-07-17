import XCTest
@testable import Tessera

final class FileBridgeTests: XCTestCase {
    func test_fileBridgeKey_stripsTransport() {
        let ssh = Host(
            address: "example.com",
            port: 22,
            user: "alice",
            transport: .ssh
        )
        let mosh = Host(
            id: ssh.id,
            address: "example.com",
            port: 22,
            user: "alice",
            transport: .mosh
        )

        XCTAssertEqual(FileBridgeKey(host: ssh), FileBridgeKey(host: mosh))
    }

    func test_fileBridgeKey_differsByPortAndUser() {
        let base = Host(address: "example.com", port: 22, user: "alice")
        let differentPort = Host(id: base.id, address: "example.com", port: 2222, user: "alice")
        let differentUser = Host(id: base.id, address: "example.com", port: 22, user: "bob")

        XCTAssertNotEqual(FileBridgeKey(host: base), FileBridgeKey(host: differentPort))
        XCTAssertNotEqual(FileBridgeKey(host: base), FileBridgeKey(host: differentUser))
    }

    func test_fileBridgeKey_doesNotShareAcrossManagedHostsAtSameEndpoint() {
        let first = Host(address: "10.0.0.5", port: 22, user: "alice")
        let second = Host(address: "10.0.0.5", port: 22, user: "alice")

        XCTAssertNotEqual(FileBridgeKey(host: first), FileBridgeKey(host: second))
    }

    func test_fileBridgeKey_changesWithRouteForSameManagedHost() {
        let hostID = UUID()
        var throughA = Host(
            id: hostID,
            address: "10.0.0.5",
            user: "alice"
        )
        throughA.jumpChain = [Host(address: "a.example", user: "jump")]
        var throughB = throughA
        throughB.jumpChain = [Host(address: "b.example", user: "jump")]

        XCTAssertNotEqual(FileBridgeKey(host: throughA), FileBridgeKey(host: throughB))
    }

    func test_entryMapping_detectsKindsAndMasksPermissions() {
        let modified = Date(timeIntervalSince1970: 1_700_000_000)

        let directory = FileBridge.mapEntry(
            filename: "Projects",
            absoluteDirectoryPath: "/home/alice",
            rawMode: 0o040755,
            size: 4_096,
            mtime: modified
        )
        let symlink = FileBridge.mapEntry(
            filename: "current",
            absoluteDirectoryPath: "/home/alice",
            rawMode: 0o120777,
            size: 11,
            mtime: modified
        )
        let file = FileBridge.mapEntry(
            filename: "notes.txt",
            absoluteDirectoryPath: "/home/alice",
            rawMode: 0o100644,
            size: 42,
            mtime: modified
        )

        XCTAssertEqual(directory.kind, .directory)
        XCTAssertNil(directory.size)
        XCTAssertEqual(directory.permissions, 0o755)
        XCTAssertEqual(directory.modified, modified)

        XCTAssertEqual(symlink.kind, .symlink)
        XCTAssertEqual(symlink.size, 11)
        XCTAssertEqual(symlink.permissions, 0o777)

        XCTAssertEqual(file.kind, .file)
        XCTAssertEqual(file.size, 42)
        XCTAssertEqual(file.permissions, 0o644)
    }

    func test_entryMapping_handlesHiddenNamesAndRootJoining() {
        let hidden = FileBridge.mapEntry(
            filename: ".env",
            absoluteDirectoryPath: "/home/alice/app",
            rawMode: 0o100600,
            size: 12,
            mtime: nil
        )
        let rootEntry = FileBridge.mapEntry(
            filename: "tmp",
            absoluteDirectoryPath: "/",
            rawMode: 0o040755,
            size: nil,
            mtime: nil
        )

        XCTAssertTrue(hidden.isHidden)
        XCTAssertEqual(hidden.path, "/home/alice/app/.env")
        XCTAssertEqual(rootEntry.path, "/tmp")
    }

    func test_sortedEntries_ordersDirectoriesFirstThenCaseInsensitiveName() {
        let entries = [
            entry("zeta.txt", kind: .file),
            entry("Beta", kind: .directory),
            entry("alpha.txt", kind: .file),
            entry("aardvark", kind: .directory),
            entry("Link", kind: .symlink),
        ]

        XCTAssertEqual(
            FileBridge.sortedEntries(entries).map(\.name),
            ["aardvark", "Beta", "alpha.txt", "Link", "zeta.txt"]
        )
    }

    @MainActor
    func test_registry_returnsSameInstanceForSameHost() {
        let registry = FileBridgeRegistry()
        let host = Host(address: "example.com", port: 22, user: "alice")

        let first = registry.bridge(for: host, requireBiometric: false, isSecureEnclave: false)
        let second = registry.bridge(for: host, requireBiometric: true, isSecureEnclave: true)

        XCTAssertTrue(first === second)
        XCTAssertEqual(registry.bridges.count, 1)
    }

    @MainActor
    func test_registry_sharesBridgeAcrossTransportsForSameManagedHost() {
        let registry = FileBridgeRegistry()
        let ssh = Host(
            address: "example.com",
            port: 22,
            user: "alice",
            transport: .ssh
        )
        let mosh = Host(
            id: ssh.id,
            address: "example.com",
            port: 22,
            user: "alice",
            transport: .mosh
        )

        let first = registry.bridge(for: ssh, requireBiometric: false, isSecureEnclave: false)
        let second = registry.bridge(for: mosh, requireBiometric: false, isSecureEnclave: false)

        XCTAssertTrue(first === second)
        XCTAssertEqual(registry.bridges.count, 1)
    }

    private func entry(
        _ name: String,
        kind: RemoteFileEntry.Kind
    ) -> RemoteFileEntry {
        RemoteFileEntry(
            name: name,
            path: "/home/alice/\(name)",
            kind: kind,
            size: kind == .directory ? nil : 1,
            modified: nil,
            permissions: nil
        )
    }
}
