import XCTest
@testable import TmuxControlCore

final class WindowModeStoreTests: XCTestCase {
    private struct KeyboardMode: Equatable {
        let normalFlags: Int
        let alternateFlags: Int

        func clearingAlternateScreenState() -> Self {
            .init(normalFlags: normalFlags, alternateFlags: 0)
        }
    }

    private let windowA = WindowId(1)
    private let windowB = WindowId(2)

    private func restoredMode(
        _ restore: WindowModeRestore<KeyboardMode>,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> KeyboardMode {
        guard case let .restore(mode) = restore.keyboardMode else {
            XCTFail("expected a keyboard-mode restore", file: file, line: line)
            fatalError("unreachable after XCTest failure")
        }
        return mode
    }

    func testRestoreWithoutSavedKeyboardModeResetsAndDefaultsBracketedPasteOff() {
        var store = WindowModeStore<KeyboardMode>()

        let restore = store.restore(
            for: windowA,
            paneInAltScreen: false,
            clearingAlternateScreenState: { $0.clearingAlternateScreenState() }
        )

        guard case .reset = restore.keyboardMode else {
            return XCTFail("an unsaved window must reset keyboard mode")
        }
        XCTAssertFalse(restore.bracketedPasteEnabled)
        XCTAssertNil(store.bracketedPasteEnabled(for: windowA))
    }

    func testSaveThenRestoreInAlternateScreenPreservesKeyboardAndBracketedPasteModes() {
        var store = WindowModeStore<KeyboardMode>()
        let saved = KeyboardMode(normalFlags: 1, alternateFlags: 2)
        store.save(
            keyboardMode: saved,
            bracketedPasteEnabled: true,
            for: windowA
        )

        let restore = store.restore(
            for: windowA,
            paneInAltScreen: true,
            clearingAlternateScreenState: { $0.clearingAlternateScreenState() }
        )

        XCTAssertEqual(restoredMode(restore), saved)
        XCTAssertTrue(restore.bracketedPasteEnabled)
        XCTAssertEqual(store.bracketedPasteEnabled(for: windowA), true)
    }

    func testNormalScreenRestoreClearsAndPersistsAlternateKeyboardState() {
        var store = WindowModeStore<KeyboardMode>()
        store.save(
            keyboardMode: .init(normalFlags: 1, alternateFlags: 2),
            bracketedPasteEnabled: true,
            for: windowA
        )

        let guarded = store.restore(
            for: windowA,
            paneInAltScreen: false,
            clearingAlternateScreenState: { $0.clearingAlternateScreenState() }
        )
        XCTAssertEqual(
            restoredMode(guarded),
            .init(normalFlags: 1, alternateFlags: 0)
        )
        XCTAssertTrue(guarded.bracketedPasteEnabled)

        let laterAltRestore = store.restore(
            for: windowA,
            paneInAltScreen: true,
            clearingAlternateScreenState: { $0.clearingAlternateScreenState() }
        )
        XCTAssertEqual(
            restoredMode(laterAltRestore),
            .init(normalFlags: 1, alternateFlags: 0)
        )
    }

    func testSavingEmptyKeyboardModeClearsStaleSnapshotButKeepsKnownPasteState() {
        var store = WindowModeStore<KeyboardMode>()
        store.save(
            keyboardMode: .init(normalFlags: 0, alternateFlags: 4),
            bracketedPasteEnabled: true,
            for: windowA
        )
        store.save(keyboardMode: nil, bracketedPasteEnabled: false, for: windowA)

        let restore = store.restore(
            for: windowA,
            paneInAltScreen: true,
            clearingAlternateScreenState: { $0.clearingAlternateScreenState() }
        )

        guard case .reset = restore.keyboardMode else {
            return XCTFail("an empty save must remove stale keyboard state")
        }
        XCTAssertFalse(restore.bracketedPasteEnabled)
        XCTAssertEqual(store.bracketedPasteEnabled(for: windowA), false)
    }

    func testWindowsKeepIndependentKeyboardAndBracketedPasteState() {
        var store = WindowModeStore<KeyboardMode>()
        store.save(
            keyboardMode: .init(normalFlags: 1, alternateFlags: 0),
            bracketedPasteEnabled: false,
            for: windowA
        )
        store.save(
            keyboardMode: .init(normalFlags: 0, alternateFlags: 2),
            bracketedPasteEnabled: true,
            for: windowB
        )

        let first = store.restore(
            for: windowA,
            paneInAltScreen: true,
            clearingAlternateScreenState: { $0.clearingAlternateScreenState() }
        )
        let second = store.restore(
            for: windowB,
            paneInAltScreen: true,
            clearingAlternateScreenState: { $0.clearingAlternateScreenState() }
        )

        XCTAssertEqual(restoredMode(first), .init(normalFlags: 1, alternateFlags: 0))
        XCTAssertFalse(first.bracketedPasteEnabled)
        XCTAssertEqual(restoredMode(second), .init(normalFlags: 0, alternateFlags: 2))
        XCTAssertTrue(second.bracketedPasteEnabled)
    }
}
