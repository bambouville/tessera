import CoreTransferable
import Foundation
import UniformTypeIdentifiers
import XCTest
@testable import Tessera

final class TerminalDropTargetTests: XCTestCase {
    func testLineCountPreservesEmptyLinesAndTrailingNewline() {
        let cases: [(String, Int)] = [
            ("", 0), ("echo hello", 1), ("a\nb", 2), ("a\n", 2),
            ("\n", 2), ("a\n\n", 3), ("\na", 2), ("\n\n", 3)
        ]
        for (text, expected) in cases {
            XCTAssertEqual(TerminalDropPayload.lineCount(in: text), expected, text.debugDescription)
        }
    }

    func testCRLFIsOneBreakAndBareCRStillCounts() {
        let cases: [(String, Int)] = [
            ("a\r\nb", 2), ("a\r\n", 2), ("\r\n", 2),
            ("a\rb", 2), ("a\r", 2), ("a\r\nb\rc\n", 4), ("\r\r\n", 3)
        ]
        for (text, expected) in cases {
            XCTAssertEqual(TerminalDropPayload.lineCount(in: text), expected, text.debugDescription)
        }
    }

    func testUnicodeTextDoesNotInventTerminalLineBreaks() {
        XCTAssertEqual(TerminalDropPayload.lineCount(in: "café 👩🏽‍💻\r\n日本語"), 2)
        XCTAssertEqual(TerminalDropPayload.lineCount(in: "a\u{2028}b\u{2029}c"), 1)
    }

    func testTextItemsBecomeOneVerbatimPasteInDragOrder() {
        XCTAssertEqual(TerminalDropPayload.decision(texts: ["a\r\nb\n", "c"], files: []), .text("a\r\nb\n\nc"))
        XCTAssertEqual(TerminalDropPayload.decision(texts: [], files: []), .none)
        XCTAssertEqual(TerminalDropPayload.decision(texts: [""], files: []), .none)
        XCTAssertEqual(TerminalDropPayload.decision(texts: [" "], files: []), .text(" "))
    }

    func testFilesWinMixedDropsAndKeepFileOrder() {
        let files = [URL(fileURLWithPath: "/tmp/b.sql"), URL(fileURLWithPath: "/tmp/a.sql")]
        XCTAssertEqual(TerminalDropPayload.decision(texts: ["never paste this"], files: files), .files(files))
        XCTAssertEqual(TerminalDropPayload.decision(texts: [], files: files), .files(files))
    }

    func testNonFileURLsNeverBecomeUploadPaths() {
        let web = URL(string: "https://example.invalid/file.txt")!
        XCTAssertEqual(TerminalDropPayload.decision(texts: [], files: [web]), .none)
        XCTAssertEqual(TerminalDropPayload.decision(texts: ["literal"], files: [web]), .text("literal"))
    }

    func testOfferedTypesDistinguishFilesTextAndFilePromises() {
        XCTAssertTrue(TerminalDropPayload.isFile(typeIdentifiers: [UTType.fileURL.identifier, UTType.plainText.identifier]))
        XCTAssertTrue(TerminalDropPayload.isFile(typeIdentifiers: [UTType.pdf.identifier]))
        XCTAssertTrue(TerminalDropPayload.isFile(typeIdentifiers: [UTType.png.identifier]))
        XCTAssertFalse(TerminalDropPayload.isFile(typeIdentifiers: [UTType.utf8PlainText.identifier]))
        XCTAssertFalse(TerminalDropPayload.isFile(typeIdentifiers: [UTType.url.identifier]))
        XCTAssertFalse(TerminalDropPayload.isFile(typeIdentifiers: []))
    }

    @MainActor
    func testTextCallsThePastePathExactlyOnce() {
        var texts: [String] = []
        let accepted = TerminalDropPayload.deliver(
            TerminalDropPayload.decision(texts: ["one\r\ntwo\n", "three"], files: []),
            isEnabled: true,
            onText: { texts.append($0) }, onFiles: { _ in XCTFail("text invoked upload") }
        )
        XCTAssertTrue(accepted)
        XCTAssertEqual(texts, ["one\r\ntwo\n\nthree"])
    }

    @MainActor
    func testMixedDropUploadsOnlyFilesAndNeverPastes() {
        let urls = [URL(fileURLWithPath: "/tmp/fixture.sql")]
        var uploads: [[URL]] = []
        XCTAssertTrue(TerminalDropPayload.deliver(
            TerminalDropPayload.decision(texts: ["do not execute"], files: urls),
            isEnabled: true,
            onText: { _ in XCTFail("mixed drop pasted text") }, onFiles: { uploads.append($0) }
        ))
        XCTAssertEqual(uploads, [urls])
    }

    @MainActor
    func testDisabledDropHasNoDeliveryAndNoTextFallback() {
        let file = URL(fileURLWithPath: "/tmp/fixture.sql")
        for decision: TerminalDropDecision in [.text("hello"), .files([file]), .none] {
            XCTAssertFalse(TerminalDropPayload.deliver(
                decision, isEnabled: false,
                onText: { _ in XCTFail("rejected drop pasted") }, onFiles: { _ in XCTFail("rejected drop uploaded") }
            ))
        }
    }

    func testEveryAdmissionGateRefusesDisconnectedLaunchAuthorityAndInactiveSessions() {
        for connected in [false, true] {
            for overlay in [false, true] {
                for gated in [false, true] {
                    for active in [false, true] {
                        XCTAssertEqual(TerminalDropPayload.isEnabled(
                            connected: connected, showsLaunchOverlay: overlay, authorityGated: gated, isActive: active
                        ), connected && !overlay && !gated && active)
                    }
                }
            }
        }
    }

    func testHighlightCopyNamesTheShippedFileActionAndTheTextLineCount() {
        XCTAssertEqual(TerminalDropPreview.text(lines: nil).message, String(localized: "drop to paste"))
        let lines = TerminalDropPayload.lineCount(in: "one\r\ntwo\n")
        XCTAssertEqual(TerminalDropPreview.text(lines: lines).message,
                       String(localized: "drop to paste · \(lines) lines"))
        XCTAssertEqual(TerminalDropPreview.files.message, String(localized: "Upload & paste path"))
    }

    func testUnclaimedStagingDeletesOnlyItsOwnCopy() throws {
        let sourceDirectory = try makeSourceDirectory()
        defer { try? FileManager.default.removeItem(at: sourceDirectory) }
        let source = sourceDirectory.appendingPathComponent("a file.sql")
        try Data("select 1;".utf8).write(to: source)
        var staging: TerminalDropStaging? = try TerminalDropStaging.copy(of: source)
        let copy = try XCTUnwrap(staging?.url)
        XCTAssertNotEqual(copy, source)
        XCTAssertEqual(copy.lastPathComponent, source.lastPathComponent)
        XCTAssertEqual(try Data(contentsOf: copy), try Data(contentsOf: source))
        staging = nil
        XCTAssertFalse(FileManager.default.fileExists(atPath: copy.deletingLastPathComponent().path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }

    func testTakenStagingSurvivesUntilCallerCleansItUp() throws {
        let sourceDirectory = try makeSourceDirectory()
        defer { try? FileManager.default.removeItem(at: sourceDirectory) }
        let source = sourceDirectory.appendingPathComponent("fixture.sql")
        try Data("select 2;".utf8).write(to: source)
        var staging: TerminalDropStaging? = try TerminalDropStaging.copy(of: source)
        let copy = try XCTUnwrap(staging?.take())
        defer { try? FileManager.default.removeItem(at: copy.deletingLastPathComponent()) }
        staging = nil
        XCTAssertTrue(FileManager.default.fileExists(atPath: copy.path))
        XCTAssertEqual(try Data(contentsOf: copy), try Data(contentsOf: source))
    }

    @MainActor
    func testRejectedDeliveryReleasesCopiesAndAcceptedDeliveryTransfersOwnership() throws {
        let sourceDirectory = try makeSourceDirectory()
        defer { try? FileManager.default.removeItem(at: sourceDirectory) }
        let source = sourceDirectory.appendingPathComponent("fixture.sql")
        try Data("select 3;".utf8).write(to: source)
        var unclaimed: TerminalDropStaging? = try TerminalDropStaging.copy(of: source)
        let unclaimedURL = try XCTUnwrap(unclaimed?.url)
        XCTAssertFalse(TerminalDropPayload.deliver(
            .files([unclaimedURL]), isEnabled: false,
            onText: { _ in XCTFail("unexpected paste") },
            onFiles: { _ in _ = unclaimed?.take(); XCTFail("unexpected handoff") }
        ))
        unclaimed = nil
        XCTAssertFalse(FileManager.default.fileExists(atPath: unclaimedURL.path))

        var claimed: TerminalDropStaging? = try TerminalDropStaging.copy(of: source)
        let claimedURL = try XCTUnwrap(claimed?.url)
        defer { try? FileManager.default.removeItem(at: claimedURL.deletingLastPathComponent()) }
        XCTAssertTrue(TerminalDropPayload.deliver(
            .files([claimedURL]), isEnabled: true,
            onText: { _ in XCTFail("unexpected paste") }, onFiles: { _ in _ = claimed?.take() }
        ))
        claimed = nil
        XCTAssertTrue(FileManager.default.fileExists(atPath: claimedURL.path))
    }

    func testDirectoriesAndRemoteURLsAreRefusedWithoutDeletingTheSource() throws {
        let sourceDirectory = try makeSourceDirectory()
        defer { try? FileManager.default.removeItem(at: sourceDirectory) }
        XCTAssertThrowsError(try TerminalDropStaging.copy(of: sourceDirectory))
        XCTAssertThrowsError(try TerminalDropStaging.copy(of: URL(string: "https://example.invalid/file.sql")!))
        XCTAssertTrue(FileManager.default.fileExists(atPath: sourceDirectory.path))
    }

    private final class Pending<Item>: @unchecked Sendable {
        let progress = Progress(totalUnitCount: 1)
        let started: XCTestExpectation
        private let lock = NSLock()
        private var completion: (@Sendable (Result<Item, Error>) -> Void)?

        init(started: XCTestExpectation) { self.started = started }

        func start(_ completion: @escaping @Sendable (Result<Item, Error>) -> Void) -> Progress {
            lock.lock()
            self.completion = completion
            lock.unlock()
            started.fulfill()
            return progress
        }

        func complete(_ result: Result<Item, Error>) {
            lock.lock()
            let callback = completion
            lock.unlock()
            callback?(result)
        }
    }

    @MainActor
    func testInvalidationCancelsProgressDeletesEarlierCopiesAndNeverDelivers() async throws {
        let sourceDirectory = try makeSourceDirectory()
        defer { try? FileManager.default.removeItem(at: sourceDirectory) }
        let source = sourceDirectory.appendingPathComponent("fixture.sql")
        try Data("select 4;".utf8).write(to: source)
        let copy = try stagedFixture(of: source)
        let owner = NSObject()
        let target = identity(owner)
        let lifetime = TerminalDropLifetime()
        lifetime.update(isEnabled: true, target: target)
        let batch = try XCTUnwrap(lifetime.begin(files: true))
        let _: TerminalDropFile = try await batch.load { completion in
            completion(.success(TerminalDropFile(staging: copy)))
            return Progress(totalUnitCount: 1)
        }
        let pending = Pending<TerminalDropFile>(started: expectation(description: "second provider pending"))
        let importing = Task { @MainActor in
            do {
                let _: TerminalDropFile = try await batch.load(start: pending.start)
                XCTFail("cancelled import returned an item")
            } catch is CancellationError {
            } catch { XCTFail("unexpected error: \(error)") }
            if lifetime.accepts(batch, target: target) { XCTFail("invalidated batch delivered") }
        }
        await fulfillment(of: [pending.started], timeout: 1)
        lifetime.invalidate()
        XCTAssertTrue(pending.progress.isCancelled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: copy.url.deletingLastPathComponent().path),
                       "cleanup must not wait for the second provider or for copy deinit")
        let late = try stagedFixture(of: source)
        pending.complete(.success(TerminalDropFile(staging: late)))
        pending.complete(.success(TerminalDropFile(staging: late)))
        XCTAssertFalse(FileManager.default.fileExists(atPath: late.url.deletingLastPathComponent().path))
        XCTAssertNil(batch.takeFiles())
        await importing.value
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }

    func testCancelBeforeProgressReturnsStillCancelsItAndResumesOnce() async {
        let batch = TerminalDropImportBatch()
        let progress = Progress(totalUnitCount: 1)
        do {
            let _: String = try await batch.load { completion in
                batch.cancel()
                completion(.success("too late"))
                return progress
            }
            XCTFail("cancelled import succeeded")
        } catch is CancellationError {
        } catch { XCTFail("unexpected error: \(error)") }
        XCTAssertTrue(progress.isCancelled)
    }

    func testSynchronousCompletionBeforeProgressAndDuplicateCompletionResumeOnce() async throws {
        let batch = TerminalDropImportBatch()
        defer { batch.cancel() }
        let value: String = try await batch.load { completion in
            completion(.success("first"))
            completion(.success("second"))
            return Progress(totalUnitCount: 1)
        }
        XCTAssertEqual(value, "first")
    }

    @MainActor
    func testIdentityIncludesSessionCarrierWindowPaneAndInputBox() throws {
        let first = NSObject(), second = NSObject()
        let original = identity(first)
        var changes: [TerminalDropIdentity] = []
        var changed = original; changed.sessionID = UUID(); changes.append(changed)
        changed = original; changed.carrier = ObjectIdentifier(second); changes.append(changed)
        changed = original; changed.windowID = 2; changes.append(changed)
        changed = original; changed.paneID = 9; changes.append(changed)
        changed = original; changed.inputBox = ObjectIdentifier(second); changes.append(changed)
        for target in changes {
            let lifetime = TerminalDropLifetime()
            lifetime.update(isEnabled: true, target: original)
            let batch = try XCTUnwrap(lifetime.begin(files: false))
            XCTAssertEqual(lifetime.delivery(batch, acceptedTarget: original, currentTarget: original), .ready)
            XCTAssertEqual(lifetime.delivery(batch, acceptedTarget: original, currentTarget: target), .paneChanged,
                           "delivery must check live identity before SwiftUI onChange runs")
            XCTAssertTrue(lifetime.update(isEnabled: true, target: target))
            XCTAssertFalse(lifetime.accepts(batch, target: original))
            lifetime.update(isEnabled: true, target: original)
            XCTAssertEqual(lifetime.delivery(batch, acceptedTarget: original, currentTarget: original), .invalidated,
                           "returning to the original pane must not revive an import")
        }
    }

    @MainActor
    func testDisableAndSessionEndRefuseSilentlyAndCannotRevivePendingText() throws {
        let owner = NSObject()
        let target = identity(owner)
        let lifetime = TerminalDropLifetime()
        XCTAssertFalse(lifetime.update(isEnabled: false, target: target))
        XCTAssertNil(lifetime.begin(files: false))
        lifetime.update(isEnabled: true, target: target)
        let batch = try XCTUnwrap(lifetime.begin(files: false))
        XCTAssertFalse(lifetime.update(isEnabled: false, target: target))
        XCTAssertFalse(lifetime.accepts(batch, target: target))
        lifetime.update(isEnabled: true, target: target)
        XCTAssertFalse(lifetime.accepts(batch, target: target))
        lifetime.invalidate()
    }

    @MainActor
    func testFileImportsKeepShippedAdmissionAcrossPaneChangesAndStillCancelOnDisable() throws {
        let owner = NSObject()
        let target = identity(owner)
        var nextPane = target
        nextPane.paneID = 8
        let lifetime = TerminalDropLifetime()
        lifetime.update(isEnabled: true, target: target)
        let batch = try XCTUnwrap(lifetime.begin(files: true))
        XCTAssertFalse(lifetime.update(isEnabled: true, target: nextPane))
        XCTAssertEqual(lifetime.delivery(batch, acceptedTarget: target, currentTarget: nextPane), .ready)
        lifetime.update(isEnabled: false, target: nextPane)
        XCTAssertEqual(lifetime.delivery(batch, acceptedTarget: target, currentTarget: nextPane), .invalidated)
        XCTAssertNil(batch.takeFiles())
    }

    private func identity(_ owner: NSObject) -> TerminalDropIdentity {
        TerminalDropIdentity(sessionID: UUID(), carrier: ObjectIdentifier(owner),
                             windowID: 1, paneID: 7, inputBox: ObjectIdentifier(owner))
    }

    /// Cancellation tests own already-staged files; coordinated provider reads
    /// are covered separately above and need the platform's file coordinator.
    private func stagedFixture(of source: URL) throws -> TerminalDropStaging {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tessera-staging", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(source.lastPathComponent)
        try FileManager.default.copyItem(at: source, to: url)
        return TerminalDropStaging(stagedURL: url)
    }

    private func makeSourceDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("duo-drop-tests-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
