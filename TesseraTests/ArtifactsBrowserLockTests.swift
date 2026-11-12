import Testing
@testable import Tessera

struct ArtifactsBrowserLockTests {
    @Test func lockingDismissesQuickOpenAndSwitcherWithoutRestoringThemOnUnlock() {
        for sheet in ArtifactBrowserSheet.allCases {
            var state = ArtifactBrowserSheetState()
            state.present(sheet, isLocked: false)
            #expect(state.visibleSheet(isLocked: false) == sheet)

            // The binding redacts before SwiftUI delivers onChange.
            #expect(state.visibleSheet(isLocked: true) == nil)
            state.lockChanged(isLocked: true)
            #expect(state.presentedSheet == nil)
            state.lockChanged(isLocked: false)
            #expect(state.visibleSheet(isLocked: false) == nil)
        }
    }

    @Test func initialQuickOpenAndSwitcherRequestsAreDiscardedWhileLocked() {
        for sheet in ArtifactBrowserSheet.allCases {
            var state = ArtifactBrowserSheetState()
            state.present(sheet, isLocked: true)
            #expect(state.presentedSheet == nil)
            state.lockChanged(isLocked: false)
            #expect(state.visibleSheet(isLocked: false) == nil)
        }
    }

    @Test func aLatePresentationCallbackCannotReplaceASheetWhileLocked() {
        var state = ArtifactBrowserSheetState()
        state.present(.quickOpen, isLocked: false)
        state.present(.switcher, isLocked: true)
        #expect(state.presentedSheet == nil)
        #expect(state.visibleSheet(isLocked: false) == nil)
    }

    @Test func dismissalClearsTheRequestAndANewTapAfterUnlockCanPresent() {
        var state = ArtifactBrowserSheetState()
        state.present(.quickOpen, isLocked: false)
        state.present(nil, isLocked: false)
        #expect(state.visibleSheet(isLocked: false) == nil)
        state.lockChanged(isLocked: true)
        state.lockChanged(isLocked: false)
        state.present(.switcher, isLocked: false)
        #expect(state.visibleSheet(isLocked: false) == .switcher)
    }
}
