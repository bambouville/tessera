import NIOCore
import NIOPosix
import os
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
        let fifo = FileBridge.mapEntry(
            filename: "events",
            absoluteDirectoryPath: "/home/alice",
            rawMode: 0o010600,
            size: 0,
            mtime: modified
        )
        let unknown = FileBridge.mapEntry(
            filename: "metadata-omitted",
            absoluteDirectoryPath: "/home/alice",
            rawMode: nil,
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
        XCTAssertEqual(fifo.kind, .other)
        XCTAssertEqual(fifo.permissions, 0o600)
        XCTAssertEqual(unknown.kind, .other)
        XCTAssertNil(unknown.permissions)
    }

    func test_byteCount_treatsASizeBeyondInt64AsUnknown() {
        XCTAssertEqual(FileBridge.byteCount(42), 42)
        XCTAssertEqual(FileBridge.byteCount(UInt64(Int64.max)), Int64.max)
        XCTAssertNil(FileBridge.byteCount(UInt64(Int64.max) + 1))
        XCTAssertNil(FileBridge.byteCount(.max))
        XCTAssertNil(FileBridge.byteCount(nil))
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

@MainActor
final class SFTPTransferPipelineTests: XCTestCase {
    private enum ScriptedFailure: Error { case rejected }

    private static let writeLength = SFTPTransferPipeline.writeRequestLength
    private static let readLength = Int(SFTPTransferPipeline.readRequestLength)

    func test_upload_startsWithFourRequestsThenOpensToTheCeilingOnAFastLink() async throws {
        let source = Self.pattern(byteCount: 3_000_000 + 1_234)
        let file = ScriptedSFTPFile()
        let window = SFTPPipelineWindow.uploads()
        let clock = ManualClock()
        let acknowledged = Recorder()
        let upload = Self.upload(source, to: file, window: window, clock: clock) {
            acknowledged.values.append($0)
        }

        try await waitUntil { file.pendingWrites.count == 4 }
        await idle()
        XCTAssertEqual(file.writeLog.map(\.count), Array(repeating: Self.writeLength, count: 4))
        XCTAssertEqual(acknowledged.values, [], "queued bytes are not progress")

        // 32 KB answered in a millisecond: a quarter second carries far more
        // than the 2 MB ceiling.
        clock.advance(milliseconds: 1)
        try await file.acknowledgeWrites(1)
        try await waitUntil { file.pendingWriteBytes > 64 * Self.writeLength - 8 * Self.writeLength }
        await idle()
        XCTAssertLessThanOrEqual(file.pendingWriteBytes, 64 * Self.writeLength)
        XCTAssertEqual(file.writeLog.last?.count, 8 * Self.writeLength)
        XCTAssertEqual(acknowledged.values, [Int64(Self.writeLength)])

        try await drive([file], until: [upload])

        XCTAssertEqual(file.contents, source)
        XCTAssertEqual(acknowledged.values.last, Int64(source.count))
        XCTAssertEqual(acknowledged.values, acknowledged.values.sorted())
        XCTAssertEqual(Set(acknowledged.values).count, acknowledged.values.count)
        XCTAssertEqual(window.outstandingBytes, 0)
    }

    func test_upload_onASlowLinkSendsOneRequestAtATimeThenRecovers() async throws {
        let source = Self.pattern(byteCount: 3_000_000)
        let file = ScriptedSFTPFile()
        let window = SFTPPipelineWindow.uploads()
        let clock = ManualClock()
        let upload = Self.upload(source, to: file, window: window, clock: clock)

        try await waitUntil { file.pendingWrites.count == 4 }
        // One request a second: a round trip plus a quarter second carries
        // less than two, so nothing more leaves until the queue is empty.
        for answered in 1...3 {
            clock.advance(milliseconds: 1_000)
            try await file.acknowledgeWrites(1)
            await idle()
            XCTAssertEqual(file.writeLog.count, 4, "after \(answered) slow replies")
        }
        clock.advance(milliseconds: 1_000)
        try await file.acknowledgeWrites(1)
        try await waitUntil { file.writeLog.count == 5 }
        await idle()
        XCTAssertEqual(file.writeLog.count, 5)
        XCTAssertEqual(file.pendingWrites.count, 1)

        // Answered a millisecond after it left: the link is fast again.
        clock.advance(milliseconds: 1)
        try await file.acknowledgeWrites(1)
        try await waitUntil { file.pendingWriteBytes > 1_000_000 }

        try await drive([file], until: [upload])
        XCTAssertEqual(file.contents, source)
        XCTAssertEqual(window.outstandingBytes, 0)
    }

    func test_uploads_onOneConnectionShareItsWindow() async throws {
        let first = Self.pattern(byteCount: 1_000_000)
        let second = Array(first.reversed())
        let files = [ScriptedSFTPFile(), ScriptedSFTPFile()]
        let window = SFTPPipelineWindow.uploads()
        let clock = ManualClock()
        let uploads = [
            Self.upload(first, to: files[0], window: window, clock: clock),
        ]
        try await waitUntil { files[0].pendingWrites.count == 4 }
        let late = Self.upload(second, to: files[1], window: window, clock: clock)

        // The window is full, so the second transfer gets the one request
        // every transfer may keep in flight, and no more.
        try await waitUntil { files[1].pendingWrites.count == 1 }
        await idle()
        XCTAssertEqual(files[0].writeLog.count, 4)
        XCTAssertEqual(files[1].writeLog.count, 1)
        XCTAssertEqual(window.outstandingBytes, 5 * Self.writeLength)

        try await drive(files, until: uploads + [late])
        XCTAssertEqual(files[0].contents, first)
        XCTAssertEqual(files[1].contents, second)
        XCTAssertEqual(window.outstandingBytes, 0)
    }

    func test_upload_rejectedWriteFailsTheTransferAndReturnsItsBytes() async throws {
        let file = ScriptedSFTPFile()
        let window = SFTPPipelineWindow.uploads()
        let upload = Self.upload(Self.pattern(byteCount: 1_000_000), to: file, window: window, clock: ManualClock())

        try await waitUntil { file.pendingWrites.count == 4 }
        try await file.failWrites(1, with: ScriptedFailure.rejected)
        do {
            try await upload.value
            XCTFail("a rejected write must fail the upload")
        } catch ScriptedFailure.rejected {}
        XCTAssertEqual(file.writeLog.count, 4)
        try await file.failWrites(file.pendingWrites.count, with: ScriptedFailure.rejected)
        XCTAssertEqual(window.outstandingBytes, 0)
    }

    func test_upload_cancellationStopsAtTheNextAcknowledgement() async throws {
        let file = ScriptedSFTPFile()
        let window = SFTPPipelineWindow.uploads()
        let upload = Self.upload(Self.pattern(byteCount: 1_000_000), to: file, window: window, clock: ManualClock())

        try await waitUntil { file.pendingWrites.count == 4 }
        upload.cancel()
        try await file.acknowledgeWrites(1)
        do {
            try await upload.value
            XCTFail("a cancelled upload must not complete")
        } catch is CancellationError {}
        XCTAssertEqual(file.writeLog.count, 4)
        try await file.acknowledgeWrites(file.pendingWrites.count)
        XCTAssertEqual(window.outstandingBytes, 0)
    }

    func test_download_readsAheadWithinTheKnownSizeThenProbesOnceForEOF() async throws {
        let source = Self.pattern(byteCount: 3 * 1024 * 1024 + 777)
        let file = ScriptedSFTPFile(contents: source)
        let window = SFTPPipelineWindow.downloads()
        let clock = ManualClock()
        let progress = Recorder()
        let received = Received()
        let download = Self.download(from: file, window: window, sizeHint: source.count, clock: clock, into: received) {
            progress.values.append($0)
        }

        try await waitUntil { file.pendingReads.count == 4 }
        await idle()
        XCTAssertEqual(file.pendingReads.count, 4)
        XCTAssertEqual(received.bytes.count, 0)

        clock.advance(milliseconds: 1)
        try await file.answerReads(1)
        try await waitUntil { file.pendingReadBytes > 32 * Self.readLength - 4 * Self.readLength }
        await idle()
        XCTAssertLessThanOrEqual(file.pendingReadBytes, 32 * Self.readLength)
        XCTAssertEqual(
            file.readLog.map(\.offset),
            (0..<file.readLog.count).map { UInt64($0 * Self.readLength) },
            "read-ahead requests consecutive blocks"
        )

        try await drive([file], until: [download])

        XCTAssertEqual(received.bytes, source)
        XCTAssertEqual(progress.values.last, Int64(source.count))
        XCTAssertEqual(progress.values, progress.values.sorted())
        XCTAssertEqual(
            file.readLog.filter { $0.offset >= UInt64(source.count) }.map(\.offset),
            [UInt64(source.count)],
            "read-ahead stops at the known size; one request confirms end of file"
        )
        XCTAssertEqual(window.outstandingBytes, 0)
    }

    func test_download_onASlowLinkReadsOneRequestAtATime() async throws {
        let source = Self.pattern(byteCount: 2_000_000)
        let file = ScriptedSFTPFile(contents: source)
        let clock = ManualClock()
        let received = Received()
        let download = Self.download(
            from: file, window: .downloads(), sizeHint: source.count, clock: clock, into: received
        )

        try await waitUntil { file.pendingReads.count == 4 }
        // One 64 KiB read every two seconds.
        for _ in 1...4 {
            clock.advance(milliseconds: 2_000)
            try await file.answerReads(1)
        }
        try await waitUntil { file.readLog.count == 5 }
        await idle()
        XCTAssertEqual(file.readLog.count, 5)
        XCTAssertEqual(file.pendingReads.count, 1)

        try await drive([file], until: [download])
        XCTAssertEqual(received.bytes, source)
    }

    func test_download_resumesAtAShortReplyAndShrinksOnlyWhenTheServerCapsReads() async throws {
        let source = Self.pattern(byteCount: 1_000_000)
        let file = ScriptedSFTPFile(contents: source)
        file.readCap = 40_000
        let window = SFTPPipelineWindow.downloads()
        let received = Received()
        let download = Self.download(
            from: file, window: window, sizeHint: source.count, clock: ManualClock(), into: received
        )

        try await drive([file], until: [download])

        XCTAssertEqual(received.bytes, source)
        let resumed = try XCTUnwrap(file.readLog.first { $0.offset == 40_000 })
        XCTAssertEqual(resumed.length, SFTPTransferPipeline.readRequestLength, "one short reply changes nothing")
        let capped = try XCTUnwrap(file.readLog.firstIndex { $0.offset == 80_000 })
        XCTAssertTrue(file.readLog[capped...].allSatisfy { $0.length == 40_000 }, "a second one is the server's cap")
        XCTAssertEqual(window.outstandingBytes, 0, "dropped requests return their bytes when answered")
    }

    func test_download_aLoneShortReplyDoesNotShrinkReads() async throws {
        let source = Self.pattern(byteCount: 600_000)
        let file = ScriptedSFTPFile(contents: source)
        file.shortReplies[UInt64(Self.readLength)] = 10
        let received = Received()
        let download = Self.download(
            from: file, window: .downloads(), sizeHint: source.count, clock: ManualClock(), into: received
        )

        try await drive([file], until: [download])

        XCTAssertEqual(received.bytes, source)
        let resumed = try XCTUnwrap(file.readLog.firstIndex { $0.offset == UInt64(Self.readLength + 10) })
        XCTAssertTrue(file.readLog[resumed...].allSatisfy { $0.length == SFTPTransferPipeline.readRequestLength })
    }

    func test_download_neverShrinksReadsBelowTheMinimum() async throws {
        let source = Self.pattern(byteCount: 60_000)
        let file = ScriptedSFTPFile(contents: source)
        file.readCap = 1_000
        let received = Received()
        let download = Self.download(
            from: file, window: .downloads(), sizeHint: source.count, clock: ManualClock(), into: received
        )

        try await drive([file], until: [download])

        XCTAssertEqual(received.bytes, source)
        let capped = try XCTUnwrap(file.readLog.firstIndex { $0.offset == 2_000 })
        XCTAssertTrue(
            file.readLog[capped...].allSatisfy { $0.length == SFTPTransferPipeline.minimumReadRequestLength },
            "a 1,000-byte cap shrinks reads to the minimum, not to 1,000 bytes"
        )
    }

    func test_download_readsAheadAgainOnceAFileOutgrowsItsSizeHint() async throws {
        let source = Self.pattern(byteCount: 3_000_000)
        let file = ScriptedSFTPFile(contents: source)
        let clock = ManualClock()
        let received = Received()
        let download = Self.download(from: file, window: .downloads(), sizeHint: 100_000, clock: clock, into: received)

        try await waitUntil { file.pendingReads.count == 2 }
        await idle()
        XCTAssertEqual(file.pendingReads.count, 2, "read-ahead stops at the size seen at open")
        clock.advance(milliseconds: 1)
        try await file.answerReads(2)
        try await waitUntil { file.pendingReads.count > 4 }

        try await drive([file], until: [download])
        XCTAssertEqual(received.bytes, source)
    }

    func test_download_detectsGrowthBehindAServerCap() async throws {
        let source = Self.pattern(byteCount: 3_000_000)
        let file = ScriptedSFTPFile(contents: source)
        file.readCap = 32_768
        let received = Received()
        let download = Self.download(
            from: file, window: .downloads(), sizeHint: 100_000, clock: ManualClock(), into: received
        )

        try await drive([file], until: [download])

        XCTAssertEqual(received.bytes, source)
        XCTAssertTrue(
            file.readLog.contains { $0.offset > 200_000 && $0.pendingAtIssue >= 2 },
            "capped full replies past the old size resume read-ahead"
        )
    }

    func test_download_ofAnEmptyFileSendsOneRequest() async throws {
        let file = ScriptedSFTPFile(contents: [])
        let window = SFTPPipelineWindow.downloads()
        let progress = Recorder()
        let download = Task { @MainActor in
            try await SFTPTransferPipeline.download(
                from: file,
                window: window,
                sizeHint: 0,
                write: { _ in XCTFail("an empty file has no bytes") },
                progress: { progress.values.append($0) },
                clock: ManualClock().read
            )
        }

        try await drive([file], until: [download])
        XCTAssertEqual(file.readLog.count, 1)
        XCTAssertEqual(progress.values, [0])
        XCTAssertEqual(window.outstandingBytes, 0)
    }

    private static func upload(
        _ source: [UInt8],
        to file: ScriptedSFTPFile,
        window: SFTPPipelineWindow,
        clock: ManualClock,
        acknowledged: @escaping @MainActor (Int64) -> Void = { _ in }
    ) -> Task<Void, Error> {
        Task { @MainActor in
            try await SFTPTransferPipeline.upload(
                to: file,
                window: window,
                nextChunk: reader(source),
                acknowledged: acknowledged,
                clock: clock.read
            )
        }
    }

    private static func download(
        from file: ScriptedSFTPFile,
        window: SFTPPipelineWindow,
        sizeHint: Int,
        clock: ManualClock,
        into received: Received,
        progress: @escaping @MainActor (Int64) -> Void = { _ in }
    ) -> Task<Void, Error> {
        Task { @MainActor in
            try await SFTPTransferPipeline.download(
                from: file,
                window: window,
                sizeHint: Int64(sizeHint),
                write: { received.bytes.append(contentsOf: $0.readableBytesView) },
                progress: progress,
                clock: clock.read
            )
        }
    }

    /// Replies complete on an event-loop thread and resume the pipeline on
    /// the main actor later, so poll for the state a step should reach.
    private func waitUntil(
        _ condition: () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !condition() {
            guard ContinuousClock.now < deadline else {
                XCTFail("condition not reached", file: file, line: line)
                throw CancellationError()
            }
            try await Task.sleep(for: .milliseconds(1))
        }
    }

    /// Gives a pipeline that should be blocked time to (wrongly) move on.
    private func idle() async {
        try? await Task.sleep(for: .milliseconds(100))
    }

    /// Answers every request as it arrives until the transfers finish.
    private func drive(
        _ files: [ScriptedSFTPFile],
        until transfers: [Task<Void, Error>],
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let finished = Finished()
        Task { @MainActor in
            for transfer in transfers {
                _ = try? await transfer.value
            }
            finished.value = true
        }
        let deadline = ContinuousClock.now + .seconds(30)
        while !finished.value {
            guard ContinuousClock.now < deadline else {
                XCTFail("transfers did not finish", file: file, line: line)
                throw CancellationError()
            }
            if files.allSatisfy({ $0.pendingReads.isEmpty && $0.pendingWrites.isEmpty }) {
                try await Task.sleep(for: .milliseconds(1))
            } else {
                for scripted in files {
                    try await scripted.answerReads(scripted.pendingReads.count)
                    try await scripted.acknowledgeWrites(scripted.pendingWrites.count)
                }
            }
        }
        // Complete requests a finished pipeline dropped.
        for scripted in files {
            try await scripted.answerReads(scripted.pendingReads.count)
        }
        for transfer in transfers {
            try await transfer.value
        }
    }

    /// Hands out `source` in chunks of the size the pipeline asks for.
    private static func reader(_ source: [UInt8]) -> (Int) throws -> Data? {
        var cursor = 0
        return { maximumByteCount in
            guard cursor < source.count else { return nil }
            let end = min(cursor + maximumByteCount, source.count)
            defer { cursor = end }
            return Data(source[cursor..<end])
        }
    }

    /// Position-dependent bytes, so data at a wrong offset cannot match.
    private static func pattern(byteCount: Int) -> [UInt8] {
        (0..<byteCount).map { UInt8(truncatingIfNeeded: ($0 &* 2_654_435_761) >> 13) }
    }
}

final class SFTPPipelineWindowTests: XCTestCase {
    private static let millisecond: UInt64 = 1_000_000

    private func window(initialBytes: Int = 128_000) -> SFTPPipelineWindow {
        SFTPPipelineWindow(floorBytes: 32_000, ceilingBytes: 2_048_000, initialBytes: initialBytes)
    }

    /// A request answered on its own: `outstanding` bytes, itself included,
    /// crossed between the two times.
    private func sample(
        _ window: SFTPPipelineWindow,
        outstanding: Int,
        sentAt: UInt64,
        answeredAt: UInt64
    ) {
        let ticket = window.send(bytes: outstanding, at: sentAt)
        window.answer(ticket, at: answeredAt, succeeded: true)
    }

    func test_aFastLinkOpensToTheCeilingWithinTwoRoundTrips() {
        // 16 MB/s with a 13 ms round trip: a lone 32 KB request takes 15 ms.
        let window = window()
        sample(window, outstanding: 32_000, sentAt: 0, answeredAt: 15 * Self.millisecond)
        XCTAssertGreaterThan(window.limitBytes, 4 * 128_000, "grows by (round trip + budget) / round trip")
        let outstanding = window.limitBytes
        let latency = 13 * Self.millisecond + UInt64(Double(outstanding) / 16_000_000 * 1e9)
        sample(window, outstanding: outstanding, sentAt: 20 * Self.millisecond, answeredAt: 20 * Self.millisecond + latency)
        XCTAssertEqual(window.limitBytes, 2_048_000)
    }

    func test_aSaturatedLinkQueuesAboutTheBudgetBeyondTheRoundTrip() {
        // 1.25 MB/s (10 Mbit/s) with a 50 ms round trip.
        let rate = 1_250_000.0
        let window = window()
        let firstLatency = 50 * Self.millisecond + UInt64(32_000 / rate * 1e9)
        sample(window, outstanding: 32_000, sentAt: 0, answeredAt: firstLatency)
        var clock: UInt64 = firstLatency
        for _ in 0..<40 {
            // Saturated: everything outstanding drains at the link rate.
            let outstanding = max(window.limitBytes, Int(rate * 0.05))
            let latency = UInt64(Double(outstanding) / rate * 1e9)
            sample(window, outstanding: outstanding, sentAt: clock, answeredAt: clock + latency)
            clock += latency
        }
        let expected = rate * (Double(firstLatency) / 1e9 + 0.25)
        XCTAssertEqual(Double(window.limitBytes), expected, accuracy: expected * 0.01)
        XCTAssertLessThan(window.limitBytes, 500_000, "far below the 2 MB ceiling")
    }

    func test_aLinkSlowerThanARequestPerQuarterSecondSendsOneAtATime() {
        // 32 KB/s: a lone request takes a second, and a saturated queue
        // drains at the same rate.
        let window = window()
        sample(window, outstanding: 32_000, sentAt: 0, answeredAt: 1_000 * Self.millisecond)
        var clock = 1_000 * Self.millisecond
        for _ in 0..<10 {
            let outstanding = window.limitBytes
            let latency = UInt64(Double(outstanding) / 32_000 * 1e9)
            sample(window, outstanding: outstanding, sentAt: clock, answeredAt: clock + latency)
            clock += latency
        }
        XCTAssertLessThan(window.limitBytes, 2 * 32_000)
        XCTAssertEqual(window.requestsPerBatch(requestLength: 32_000, maximum: 8), 1)
    }

    func test_aLongRoundTripStillCoversItself() {
        // 150 ms round trip at 4 MB/s: 1.6 MB covers it plus the budget.
        let window = window()
        sample(window, outstanding: 600_000, sentAt: 0, answeredAt: 150 * Self.millisecond)
        XCTAssertEqual(Double(window.limitBytes), 1_600_000, accuracy: 1)
    }

    func test_aStallShorterThanTheRateWindowKeepsTheWindowButALongerSlowdownShrinksIt() {
        let window = window()
        sample(window, outstanding: 500_000, sentAt: 0, answeredAt: 100 * Self.millisecond)
        let fast = window.limitBytes
        sample(window, outstanding: 500_000, sentAt: 100 * Self.millisecond, answeredAt: 2_100 * Self.millisecond)
        XCTAssertEqual(window.limitBytes, fast, "the fast sample is still within two seconds")
        sample(window, outstanding: 500_000, sentAt: 2_200 * Self.millisecond, answeredAt: 4_200 * Self.millisecond)
        XCTAssertLessThan(window.limitBytes, fast)
    }

    func test_aSlowerPathRaisesTheRoundTripOnlyThroughALoneRequestTenSecondsOn() {
        let window = window()
        sample(window, outstanding: 32_000, sentAt: 0, answeredAt: 30 * Self.millisecond)
        // Then the path gets a second slower, and replies keep arriving.
        var clock = 30 * Self.millisecond
        func run(outstanding: Int, until end: UInt64) {
            while clock < end {
                sample(window, outstanding: outstanding, sentAt: clock, answeredAt: clock + 1_030 * Self.millisecond)
                clock += 1_030 * Self.millisecond
            }
        }
        // Replies behind a queue can't tell that from their own queue, and
        // a lone request doesn't replace a round trip measured under ten
        // seconds ago: the window sits at the floor.
        run(outstanding: 64_000, until: 5_000 * Self.millisecond)
        XCTAssertEqual(window.limitBytes, 32_000)
        run(outstanding: 32_000, until: 9_000 * Self.millisecond)
        XCTAssertEqual(window.limitBytes, 32_000)
        run(outstanding: 64_000, until: 12_000 * Self.millisecond)
        XCTAssertEqual(window.limitBytes, 32_000, "queued replies never raise it")

        // Once it is ten seconds old, a lone request's round trip replaces it.
        run(outstanding: 32_000, until: clock + 1)
        XCTAssertGreaterThan(window.limitBytes, 32_000)
    }

    func test_failedRequestsReturnTheirBytesWithoutASample() {
        let window = window()
        let first = window.send(bytes: 64_000, at: 0)
        let second = window.send(bytes: 64_000, at: 0)
        XCTAssertEqual(window.outstandingBytes, 128_000)
        XCTAssertEqual(second.outstandingAtSend, 128_000)
        window.answer(first, at: 5_000 * Self.millisecond, succeeded: false)
        XCTAssertEqual(window.outstandingBytes, 64_000)
        XCTAssertEqual(window.limitBytes, 128_000, "no sample from a failure")
        window.answer(second, at: 5_000 * Self.millisecond, succeeded: true)
        XCTAssertEqual(window.outstandingBytes, 0)
    }

    func test_anIdleConnectionRelearnsItsWindow() {
        let window = window()
        sample(window, outstanding: 32_000, sentAt: 0, answeredAt: 1 * Self.millisecond)
        XCTAssertEqual(window.limitBytes, 2_048_000)
        let ticket = window.send(bytes: 32_000, at: 11_000 * Self.millisecond)
        XCTAssertEqual(window.limitBytes, 128_000)
        window.answer(ticket, at: 11_500 * Self.millisecond, succeeded: true)
        XCTAssertEqual(window.outstandingBytes, 0)
    }

    func test_aReplyTimedBeforeItsRequestCountsAsInstant() {
        let window = window()
        sample(window, outstanding: 32_000, sentAt: 10, answeredAt: 10)
        sample(window, outstanding: 32_000, sentAt: 10, answeredAt: 5)
        XCTAssertEqual(window.limitBytes, 2_048_000)
    }

    func test_batchesAreAQuarterOfTheWindowInWholeRequests() {
        XCTAssertEqual(window(initialBytes: 128_000).requestsPerBatch(requestLength: 32_000, maximum: 8), 1)
        XCTAssertEqual(window(initialBytes: 1_000).requestsPerBatch(requestLength: 32_000, maximum: 8), 1)
        XCTAssertEqual(window(initialBytes: 512_000).requestsPerBatch(requestLength: 32_000, maximum: 8), 4)
        XCTAssertEqual(window(initialBytes: 2_048_000).requestsPerBatch(requestLength: 32_000, maximum: 8), 8)
    }
}

@MainActor
private final class Recorder {
    var values: [Int64] = []
}

@MainActor
private final class Received {
    var bytes: [UInt8] = []
}

@MainActor
private final class Finished {
    var value = false
}

/// An uptime the test moves by hand. Replies read it on an event-loop
/// thread, so the fake settles each reply before the test moves on.
private final class ManualClock: Sendable {
    private let now = OSAllocatedUnfairLock<UInt64>(initialState: 1_000_000_000)

    var read: @Sendable () -> UInt64 {
        { [now] in now.withLock { $0 } }
    }

    func advance(milliseconds: UInt64) {
        now.withLock { $0 += milliseconds * 1_000_000 }
    }
}

/// An in-memory SFTP file whose replies arrive only when the test says so.
private final class ScriptedSFTPFile: PipelinedSFTPFile {
    struct Write {
        let offset: UInt64
        let bytes: [UInt8]
        let promise: EventLoopPromise<Void>
    }

    struct Read {
        let offset: UInt64
        let length: UInt32
        let promise: EventLoopPromise<ByteBuffer>
    }

    let loop = MultiThreadedEventLoopGroup.singleton.next()
    var contents: [UInt8]
    var readCap = Int.max
    /// Reads at these offsets return only this many bytes.
    var shortReplies: [UInt64: Int] = [:]
    private(set) var pendingWrites: [Write] = []
    private(set) var pendingReads: [Read] = []
    private(set) var writeLog: [(offset: UInt64, count: Int)] = []
    /// With how many reads were already pending when each was sent.
    private(set) var readLog: [(offset: UInt64, length: UInt32, pendingAtIssue: Int)] = []

    var pendingWriteBytes: Int { pendingWrites.reduce(0) { $0 + $1.bytes.count } }
    var pendingReadBytes: Int { pendingReads.reduce(0) { $0 + Int($1.length) } }

    init(contents: [UInt8] = []) {
        self.contents = contents
    }

    func writeFuture(_ data: ByteBuffer, at offset: UInt64) -> EventLoopFuture<Void> {
        let promise = loop.makePromise(of: Void.self)
        pendingWrites.append(Write(offset: offset, bytes: Array(data.readableBytesView), promise: promise))
        writeLog.append((offset, data.readableBytes))
        return promise.futureResult
    }

    func readFuture(from offset: UInt64, length: UInt32) -> EventLoopFuture<ByteBuffer> {
        let promise = loop.makePromise(of: ByteBuffer.self)
        readLog.append((offset, length, pendingReads.count))
        pendingReads.append(Read(offset: offset, length: length, promise: promise))
        return promise.futureResult
    }

    @MainActor
    func acknowledgeWrites(_ count: Int) async throws {
        for write in pendingWrites.prefix(count) {
            let end = Int(write.offset) + write.bytes.count
            if contents.count < end {
                contents.append(contentsOf: repeatElement(0, count: end - contents.count))
            }
            contents.replaceSubrange(Int(write.offset)..<end, with: write.bytes)
            write.promise.succeed(())
        }
        pendingWrites.removeFirst(min(count, pendingWrites.count))
        try await settle()
    }

    @MainActor
    func failWrites(_ count: Int, with error: Error) async throws {
        for write in pendingWrites.prefix(count) {
            write.promise.fail(error)
        }
        pendingWrites.removeFirst(min(count, pendingWrites.count))
        try await settle()
    }

    @MainActor
    func answerReads(_ count: Int) async throws {
        for read in pendingReads.prefix(count) {
            let start = min(Int(read.offset), contents.count)
            let length = min(Int(read.length), shortReplies[read.offset] ?? readCap)
            let end = min(start + length, contents.count)
            read.promise.succeed(ByteBuffer(bytes: contents[start..<end]))
        }
        pendingReads.removeFirst(min(count, pendingReads.count))
        try await settle()
    }

    /// Replies completed off the loop run their callbacks — which time
    /// them — on it; queue behind those.
    private func settle() async throws {
        try await loop.submit {}.get()
    }
}
