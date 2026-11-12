// TesseraTests/ShortcutCheatSheetTests.swift
// Pin the passive hold behavior and effective-keymap projection without real
// keyboard timing, shared preferences, or a connected terminal.
import XCTest
import GameController
@testable import Tessera

final class ShortcutCheatSheetTests: XCTestCase {
    private var defaultsSuites: [String] = []

    override func tearDown() {
        for suite in defaultsSuites { UserDefaults.standard.removePersistentDomain(forName: suite) }
        defaultsSuites.removeAll()
        super.tearDown()
    }

    @MainActor
    func testHoldPastDelayShowsOnceAndReleaseHidesOnce() {
        let rig = DetectorRig()
        rig.detector.keyChanged(.leftCommand, pressed: true)
        rig.clock.advance(by: 0.79)
        XCTAssertEqual(rig.events, [])
        rig.clock.advance(by: 0.02)
        rig.clock.advance(by: 2)
        rig.detector.keyChanged(.leftCommand, pressed: true)
        XCTAssertEqual(rig.events, ["show"])
        rig.detector.keyChanged(.leftCommand, pressed: false)
        rig.detector.keyChanged(.leftCommand, pressed: false)
        rig.detector.reset()
        XCTAssertEqual(rig.events, ["show", "hide"])
    }

    @MainActor
    func testEarlyReleaseNeverShowsEvenIfCancelledWorkRuns() {
        let rig = DetectorRig()
        rig.detector.keyChanged(.leftCommand, pressed: true)
        rig.clock.advance(by: 0.3)
        rig.detector.keyChanged(.leftCommand, pressed: false)
        rig.clock.advance(by: 1, includingCancelled: true)
        XCTAssertEqual(rig.events, [])
    }

    @MainActor
    func testLetterAndShiftSpoilUntilEveryCommandIsReleased() {
        for key in [CommandHoldDetector.Key.other(4), .other(225)] {
            let rig = DetectorRig()
            rig.detector.keyChanged(.leftCommand, pressed: true)
            rig.clock.advance(by: 0.3)
            rig.detector.keyChanged(key, pressed: true)
            rig.detector.keyChanged(key, pressed: false)
            rig.detector.keyChanged(.rightCommand, pressed: true)
            rig.clock.advance(by: 1, includingCancelled: true)
            rig.detector.keyChanged(.leftCommand, pressed: false)
            rig.clock.advance(by: 1)
            XCTAssertEqual(rig.events, [])
            rig.detector.keyChanged(.rightCommand, pressed: false)
            rig.detector.keyChanged(.leftCommand, pressed: true)
            rig.clock.advance(by: 0.81)
            XCTAssertEqual(rig.events, ["show"])
        }
    }

    @MainActor
    func testOtherKeyWhileShownHidesWithoutRearming() {
        let rig = DetectorRig()
        rig.detector.keyChanged(.leftCommand, pressed: true)
        rig.clock.advance(by: 1)
        rig.detector.keyChanged(.other(4), pressed: true)
        rig.detector.keyChanged(.other(4), pressed: true)
        rig.detector.keyChanged(.other(4), pressed: false)
        rig.clock.advance(by: 1)
        rig.detector.keyChanged(.leftCommand, pressed: false)
        XCTAssertEqual(rig.events, ["show", "hide"])
    }

    @MainActor
    func testRightCommandAloneWorks() {
        let rig = DetectorRig()
        rig.detector.keyChanged(.rightCommand, pressed: true)
        rig.clock.advance(by: 0.81)
        XCTAssertEqual(rig.events, ["show"])
        rig.detector.keyChanged(.rightCommand, pressed: false)
        XCTAssertEqual(rig.events, ["show", "hide"])
    }

    @MainActor
    func testOverlappingCommandsDoNotRearmAndNeedBothUp() {
        let rig = DetectorRig()
        rig.detector.keyChanged(.leftCommand, pressed: true)
        rig.clock.advance(by: 0.4)
        rig.detector.keyChanged(.rightCommand, pressed: true)
        rig.clock.advance(by: 0.41)
        XCTAssertEqual(rig.events, ["show"], "the second command must not restart the delay")
        rig.detector.keyChanged(.leftCommand, pressed: false)
        XCTAssertEqual(rig.events, ["show"])
        rig.detector.keyChanged(.rightCommand, pressed: false)
        XCTAssertEqual(rig.events, ["show", "hide"])
    }

    @MainActor
    func testModifierAlreadyHeldSpoilsTheHold() {
        let rig = DetectorRig()
        rig.detector.keyChanged(.other(225), pressed: true)
        rig.detector.keyChanged(.leftCommand, pressed: true)
        rig.detector.keyChanged(.other(225), pressed: false)
        rig.clock.advance(by: 1)
        XCTAssertEqual(rig.events, [])
        rig.detector.keyChanged(.leftCommand, pressed: false)
        rig.detector.keyChanged(.leftCommand, pressed: true)
        rig.clock.advance(by: 1)
        XCTAssertEqual(rig.events, ["show"])
    }

    @MainActor
    func testLostKeyUpIsForgottenOnlyWhenTheKeyboardSaysItIsUp() {
        let rig = DetectorRig()
        // ⇧'s key-up never arrives.
        rig.detector.keyChanged(.other(225), pressed: true)
        rig.detector.keyChanged(.leftCommand, pressed: true)
        rig.clock.advance(by: 1)
        rig.detector.keyChanged(.leftCommand, pressed: false)
        XCTAssertEqual(rig.events, [])

        // Still physically down: the remembered key keeps spoiling.
        rig.detector.forgetKeys { _ in true }
        rig.detector.keyChanged(.leftCommand, pressed: true)
        rig.clock.advance(by: 1)
        rig.detector.keyChanged(.leftCommand, pressed: false)
        XCTAssertEqual(rig.events, [])

        // Reported up: the stale entry goes and the next hold reveals.
        rig.detector.forgetKeys { _ in false }
        rig.detector.keyChanged(.leftCommand, pressed: true)
        rig.clock.advance(by: 1)
        XCTAssertEqual(rig.events, ["show"])
    }

    @MainActor
    func testResetHidesAndForgetsAllHeldKeys() {
        let rig = DetectorRig()
        rig.detector.keyChanged(.leftCommand, pressed: true)
        rig.clock.advance(by: 1)
        rig.detector.reset()
        rig.detector.reset()
        XCTAssertEqual(rig.events, ["show", "hide"])
        rig.detector.keyChanged(.other(225), pressed: true)
        rig.detector.reset()
        rig.detector.keyChanged(.leftCommand, pressed: true)
        rig.clock.advance(by: 1)
        XCTAssertEqual(rig.events, ["show", "hide", "show"])
    }

    @MainActor
    func testResetInvalidatesPendingTimerAcrossANewHold() {
        let rig = DetectorRig()
        rig.detector.keyChanged(.leftCommand, pressed: true)
        rig.clock.advance(by: 0.5)
        rig.detector.reset()
        rig.detector.keyChanged(.rightCommand, pressed: true)
        rig.clock.advance(by: 0.31, includingCancelled: true)
        XCTAssertEqual(rig.events, [])
        rig.clock.advance(by: 0.5)
        XCTAssertEqual(rig.events, ["show"])
    }

    @MainActor
    func testPermissionIsEvaluatedAtFireTimeAndDoesNotRearm() {
        let rig = DetectorRig()
        rig.detector.keyChanged(.leftCommand, pressed: true)
        rig.allowed = false
        rig.clock.advance(by: 1)
        XCTAssertEqual(rig.events, [])
        rig.allowed = true
        rig.detector.keyChanged(.leftCommand, pressed: true)
        rig.clock.advance(by: 1)
        XCTAssertEqual(rig.events, [])
        rig.detector.keyChanged(.leftCommand, pressed: false)
        rig.allowed = false
        rig.detector.keyChanged(.leftCommand, pressed: true)
        rig.allowed = true
        rig.clock.advance(by: 1)
        XCTAssertEqual(rig.events, ["show"])
    }

    @MainActor
    func testDefaultsListEveryBoundActionInRegistryGroupOrder() throws {
        let store = try makeStore()
        let defaults = ShortcutCheatSheet.sections(store: nil, notation: .glyph)
        XCTAssertEqual(ShortcutCheatSheet.sections(store: store, notation: .glyph), defaults)
        let groups = ShortcutGroup.allCases.filter { $0 != .custom }
        XCTAssertEqual(defaults.map(\.id), groups.map(\.id))
        for (section, group) in zip(defaults, groups) {
            XCTAssertEqual(section.title, group.title)
            XCTAssertEqual(section.rows.map(\.id), ShortcutAction.allCases.filter {
                $0.group == group && $0.defaultBinding != nil
            }.map(\.id))
        }
        let ids = defaults.flatMap(\.rows).map(\.id)
        XCTAssertEqual(ids.count, ShortcutAction.allCases.filter { $0.defaultBinding != nil }.count)
        XCTAssertFalse(ids.contains(ShortcutAction.tmuxMoveWindowLeft.id))
        XCTAssertFalse(ids.contains(ShortcutAction.tmuxMoveWindowRight.id))
        XCTAssertEqual(defaults.first { $0.id == "tmux" }?.note,
                       String(localized: "— live only while a tmux session is attached"))
        XCTAssertEqual(defaults.first { $0.id == "panes" }?.note,
                       String(localized: "— live once a window holds more than one pane"))
    }

    @MainActor
    func testArtifactsAppearsBesideAgentCenterAndFollowsRemappingAndUnbinding() throws {
        let store = try makeStore()
        let global = try XCTUnwrap(ShortcutCheatSheet.sections(store: store, notation: .glyph)
            .first { $0.id == ShortcutGroup.global.id })
        let agentsIndex = try XCTUnwrap(global.rows.firstIndex { $0.id == ShortcutAction.toggleAgentCenter.id })
        XCTAssertEqual(global.rows[agentsIndex + 1].id, ShortcutAction.toggleArtifacts.id)
        XCTAssertEqual(global.rows[agentsIndex + 1].chord, "⇧⌘B")
        store.setBinding(.cmdShift("o"), for: .toggleArtifacts)
        let remapped = ShortcutCheatSheet.sections(store: store, notation: .words).flatMap(\.rows)
        XCTAssertEqual(remapped.first { $0.id == ShortcutAction.toggleArtifacts.id }?.chord, "shift-cmd-o")
        store.setBinding(nil, for: .toggleArtifacts)
        let unbound = ShortcutCheatSheet.sections(store: store, notation: .glyph).flatMap(\.rows)
        XCTAssertFalse(unbound.contains { $0.id == ShortcutAction.toggleArtifacts.id })
    }

    @MainActor
    func testRemapAndUnbindAreReflectedWithoutRestoringDefaults() throws {
        let store = try makeStore()
        store.setBinding(.cmdShift("p"), for: .openSettings)
        var rows = ShortcutCheatSheet.sections(store: store, notation: .glyph).flatMap(\.rows)
        XCTAssertEqual(rows.first { $0.id == ShortcutAction.openSettings.id }?.chord, "⇧⌘P")
        store.setBinding(nil, for: .openSettings)
        rows = ShortcutCheatSheet.sections(store: store, notation: .glyph).flatMap(\.rows)
        XCTAssertFalse(rows.contains { $0.id == ShortcutAction.openSettings.id })
        // Persistence must preserve the deliberate unbind as well.
        let reloaded = try XCTUnwrap(defaultsSuites.last.flatMap { UserDefaults(suiteName: $0) })
        let reloadedRows = ShortcutCheatSheet.sections(
            store: ShortcutStore(defaults: reloaded), notation: .glyph
        ).flatMap(\.rows)
        XCTAssertFalse(reloadedRows.contains { $0.id == ShortcutAction.openSettings.id })
    }

    @MainActor
    func testDigitBlockUsesCompactRangeInBothNotationsAndFollowsRemapping() throws {
        for (notation, expected) in [(ModifierNotation.glyph, "⌘1–9"), (.words, "cmd-1–9")] {
            let row = ShortcutCheatSheet.sections(store: nil, notation: notation)
                .flatMap(\.rows).first { $0.id == ShortcutAction.tmuxSelectWindow.id }
            XCTAssertEqual(row?.chord, expected)
        }
        let store = try makeStore()
        store.setBinding(KeyBinding([.command, .shift], .character("1")), for: .tmuxSelectWindow)
        XCTAssertEqual(ShortcutCheatSheet.sections(store: store, notation: .glyph)
            .flatMap(\.rows).first { $0.id == ShortcutAction.tmuxSelectWindow.id }?.chord, "⇧⌘1–9")
    }

    @MainActor
    func testBoundCustomsAppearLastInStoreOrderWithStableIDsAndUntitledFallback() throws {
        let store = try makeStore()
        let first = CustomShortcut(name: "deploy", binding: .cmd("y"), tokens: [.text("deploy")])
        let chipOnly = CustomShortcut(name: "chip only", tokens: [.text("x")])
        let nameless = CustomShortcut(name: "", binding: .cmd("u"), tokens: [])
        for shortcut in [first, chipOnly, nameless] { store.upsert(shortcut) }
        let sections = ShortcutCheatSheet.sections(store: store, notation: .glyph)
        let custom = try XCTUnwrap(sections.last)
        XCTAssertEqual(custom.id, ShortcutGroup.custom.id)
        XCTAssertEqual(custom.title, ShortcutGroup.custom.title)
        XCTAssertEqual(custom.rows.map(\.id), [first.chipRawID, nameless.chipRawID])
        XCTAssertEqual(custom.rows.map(\.title), ["deploy", String(localized: "untitled")])
        XCTAssertEqual(custom.rows.map(\.chord), ["⌘Y", "⌘U"])
        let words = try XCTUnwrap(ShortcutCheatSheet.sections(store: store, notation: .words).last)
        XCTAssertEqual(words.rows.map(\.id), custom.rows.map(\.id))
        XCTAssertEqual(words.rows.map(\.chord), ["cmd-y", "cmd-u"])
    }

    @MainActor
    func testFunctionKeysKeepTheirWholeLabelInTheSheetAndRecorder() throws {
        let store = try makeStore()
        for number in 1...12 {
            let binding = KeyBinding([.command], .function(number))
            store.upsert(CustomShortcut(name: "f\(number)", binding: binding, tokens: []))
            XCTAssertEqual(binding.renderedParts(.glyph), ["⌘", "F\(number)"])
            XCTAssertEqual(binding.renderedParts(.words), ["cmd", "f\(number)"])
        }
        XCTAssertEqual(ShortcutCheatSheet.sections(store: store, notation: .glyph).last?.rows.map(\.chord),
                       (1...12).map { "⌘F\($0)" })
        XCTAssertEqual(ShortcutCheatSheet.sections(store: store, notation: .words).last?.rows.map(\.chord),
                       (1...12).map { "cmd-f\($0)" })
    }

    @MainActor
    func testEmptyBuiltInAndCustomSectionsAreOmitted() throws {
        let store = try makeStore()
        for action in ShortcutAction.actions(in: .global) { store.setBinding(nil, for: action) }
        store.upsert(CustomShortcut(name: "chip only", tokens: []))
        let sections = ShortcutCheatSheet.sections(store: store, notation: .glyph)
        XCTAssertFalse(sections.contains { $0.id == ShortcutGroup.global.id || $0.id == ShortcutGroup.custom.id })
        for action in ShortcutAction.allCases { store.setBinding(nil, for: action) }
        XCTAssertEqual(ShortcutCheatSheet.sections(store: store, notation: .glyph), [])
    }

    @MainActor
    func testWholeSectionsKeepReadingOrderAcrossColumnCounts() {
        let sections = ShortcutCheatSheet.sections(store: nil, notation: .glyph)
        for count in 1...3 {
            let columns = ShortcutCheatSheetColumns.balanced(sections, count: count)
            XCTAssertEqual(columns.count, count)
            XCTAssertTrue(columns.allSatisfy { !$0.isEmpty })
            XCTAssertEqual(columns.flatMap { $0 }, sections)
        }
        XCTAssertEqual(ShortcutCheatSheetColumns.balanced([], count: 3), [])
    }

    @MainActor
    func testHubMulticastsInSubscriptionOrderAndCancellationIsImmediate() {
        let hub = HardwareKeyboardEvents(observesHardware: false)
        var received: [String] = []
        let first = hub.subscribe { key, pressed in received.append("first:\(key.rawValue):\(pressed)") }
        let second = hub.subscribe { key, pressed in received.append("second:\(key.rawValue):\(pressed)") }
        defer { first.cancel(); second.cancel() }
        hub.deliver(keyCode: .leftGUI, pressed: true)
        XCTAssertEqual(received, ["first:\(GCKeyCode.leftGUI.rawValue):true", "second:\(GCKeyCode.leftGUI.rawValue):true"])
        first.cancel()
        first.cancel()
        received.removeAll()
        hub.deliver(keyCode: .leftGUI, pressed: false)
        XCTAssertEqual(received, ["second:\(GCKeyCode.leftGUI.rawValue):false"])
    }

    @MainActor
    func testHubDoesNotRetainSubscriptions() {
        let hub = HardwareKeyboardEvents(observesHardware: false)
        var count = 0
        var token: HardwareKeyboardSubscription? = hub.subscribe { _, _ in count += 1 }
        weak let released = token
        hub.deliver(keyCode: .rightGUI, pressed: true)
        XCTAssertEqual(count, 1)
        token = nil
        XCTAssertNil(released)
        hub.deliver(keyCode: .rightGUI, pressed: false)
        XCTAssertEqual(count, 1)
    }

    @MainActor
    func testEarlierSubscriberCanCancelALaterSubscriberDuringDelivery() {
        let hub = HardwareKeyboardEvents(observesHardware: false)
        var received: [String] = []
        var later: HardwareKeyboardSubscription?
        let first = hub.subscribe { _, _ in received.append("first"); later?.cancel() }
        later = hub.subscribe { _, _ in received.append("later") }
        defer { first.cancel(); later?.cancel() }
        hub.deliver(keyCode: .leftGUI, pressed: true)
        XCTAssertEqual(received, ["first"])
    }

    @MainActor
    private func makeStore() throws -> ShortcutStore {
        let suite = "tessera.shortcut-cheat-sheet-tests.\(UUID().uuidString)"
        defaultsSuites.append(suite)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        return ShortcutStore(defaults: defaults)
    }
}

@MainActor
private final class DetectorRig {
    let clock = ManualHoldClock()
    var allowed = true
    var events: [String] = []
    lazy var detector = CommandHoldDetector(
        schedule: { [unowned self] delay, work in clock.schedule(after: delay, work) },
        isAllowed: { [weak self] in self?.allowed == true },
        onShow: { [weak self] in self?.events.append("show") },
        onHide: { [weak self] in self?.events.append("hide") }
    )
}

@MainActor
private final class ManualHoldClock {
    private final class Job {
        let deadline: TimeInterval
        let work: @MainActor () -> Void
        var cancelled = false
        init(deadline: TimeInterval, work: @escaping @MainActor () -> Void) {
            self.deadline = deadline
            self.work = work
        }
    }
    private var now: TimeInterval = 0
    private var jobs: [Job] = []

    func schedule(after delay: TimeInterval, _ work: @escaping @MainActor () -> Void) -> (() -> Void) {
        let job = Job(deadline: now + delay, work: work)
        jobs.append(job)
        return { job.cancelled = true }
    }

    func advance(by interval: TimeInterval, includingCancelled: Bool = false) {
        now += interval
        let ready = jobs.filter { $0.deadline <= now }
        jobs.removeAll { $0.deadline <= now }
        for job in ready where includingCancelled || !job.cancelled { job.work() }
    }
}
