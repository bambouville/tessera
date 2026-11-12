import XCTest
@testable import Tessera

@MainActor
final class OnboardingControllerTests: XCTestCase {
    func test_spotlightExpansionStaysInsideEveryOverlayEdge() {
        let bounds = CGRect(x: 0, y: 0, width: 320, height: 480)
        for target in [
            CGRect(x: 0, y: 100, width: 80, height: 44),
            CGRect(x: 240, y: 100, width: 80, height: 44),
            CGRect(x: 100, y: 0, width: 80, height: 44),
            CGRect(x: 100, y: 436, width: 80, height: 44),
        ] {
            let hole = OnboardingOverlay.spotlightHole(for: target, in: bounds)
            XCTAssertGreaterThanOrEqual(hole.minX, 2)
            XCTAssertGreaterThanOrEqual(hole.minY, 2)
            XCTAssertLessThanOrEqual(hole.maxX, 318)
            XCTAssertLessThanOrEqual(hole.maxY, 478)
        }
    }


    private func makeController(currentVersion: String = WhatsNewPolicy.version) -> (OnboardingController, AppearancePreferences) {
        let defaults = UserDefaults.standard
        let previous = [
            "tessera.pref.hasSeenWelcome",
            "tessera.pref.lastSeenWhatsNewVersion",
            "tessera.pref.agentCenterEnabled"
        ].map { (key: $0, value: defaults.object(forKey: $0)) }
        addTeardownBlock {
            for entry in previous {
                if let value = entry.value {
                    defaults.set(value, forKey: entry.key)
                } else {
                    defaults.removeObject(forKey: entry.key)
                }
            }
        }
        defaults.set(false, forKey: "tessera.pref.hasSeenWelcome")
        defaults.set("", forKey: "tessera.pref.lastSeenWhatsNewVersion")
        let appearance = AppearancePreferences()
        let controller = OnboardingController(appearance: appearance, currentVersion: currentVersion)
        return (controller, appearance)
    }

    // MARK: - beginIfFirstLaunch truth table

    func test_begin_unseenNoHosts_showsWelcome() {
        let (controller, _) = makeController()
        controller.beginIfFirstLaunch(hasHosts: false, hasSeen: false)
        XCTAssertEqual(controller.phase, .welcome)
    }

    func test_begin_unseenWithHosts_staysInactive() {
        let (controller, _) = makeController()
        controller.beginIfFirstLaunch(hasHosts: true, hasSeen: false)
        XCTAssertEqual(controller.phase, .inactive)
    }

    func test_begin_seenNoHosts_staysInactive() {
        let (controller, _) = makeController()
        controller.beginIfFirstLaunch(hasHosts: false, hasSeen: true)
        XCTAssertEqual(controller.phase, .inactive)
    }

    func test_begin_seenWithHosts_staysInactive() {
        let (controller, _) = makeController()
        controller.beginIfFirstLaunch(hasHosts: true, hasSeen: true)
        XCTAssertEqual(controller.phase, .inactive)
    }

    func test_begin_isIdempotent_doesNotResetActiveTour() {
        let (controller, _) = makeController()
        controller.startTour()
        controller.next()
        XCTAssertEqual(controller.phase, .touring(1))
        // A re-entrant onAppear must not yank an in-progress tour back to welcome.
        controller.beginIfFirstLaunch(hasHosts: false, hasSeen: false)
        XCTAssertEqual(controller.phase, .touring(1))
    }

    // MARK: - next / back clamping

    func test_startTour_beginsAtFirstStep() {
        let (controller, _) = makeController()
        controller.startTour()
        XCTAssertEqual(controller.phase, .touring(0))
    }

    func test_next_advancesThroughSteps() {
        let (controller, _) = makeController()
        controller.startTour()
        controller.next()
        XCTAssertEqual(controller.phase, .touring(1))
        controller.next()
        XCTAssertEqual(controller.phase, .touring(2))
    }

    func test_next_pastLastStep_finishes() {
        let (controller, appearance) = makeController()
        appearance.hasSeenWelcome = false
        controller.startTour()
        for _ in 0..<(controller.steps.count - 1) {
            controller.next()
        }
        XCTAssertEqual(controller.phase, .touring(controller.steps.count - 1))
        // Advancing past the final step ends the tour and records the flag.
        controller.next()
        XCTAssertEqual(controller.phase, .inactive)
        XCTAssertTrue(appearance.hasSeenWelcome)
        XCTAssertEqual(appearance.lastSeenWhatsNewVersion, WhatsNewPolicy.version)
    }

    func test_back_clampsAtFirstStep() {
        let (controller, _) = makeController()
        controller.startTour()
        controller.back()
        XCTAssertEqual(controller.phase, .touring(0))
    }

    func test_back_steppingDown() {
        let (controller, _) = makeController()
        controller.startTour()
        controller.next()
        controller.next()
        controller.back()
        XCTAssertEqual(controller.phase, .touring(1))
    }

    func test_nextAndBack_onlyApplyWhileTouring() {
        let (controller, _) = makeController()
        // No-ops outside .touring.
        controller.next()
        XCTAssertEqual(controller.phase, .inactive)
        controller.back()
        XCTAssertEqual(controller.phase, .inactive)
    }

    // MARK: - finish / skip flip the flag

    func test_finish_setsHasSeenWelcome() {
        let (controller, appearance) = makeController()
        appearance.hasSeenWelcome = false
        controller.startTour()
        controller.finish()
        XCTAssertEqual(controller.phase, .inactive)
        XCTAssertTrue(appearance.hasSeenWelcome)
        XCTAssertEqual(appearance.lastSeenWhatsNewVersion, WhatsNewPolicy.version)
    }

    func test_skip_setsHasSeenWelcome() {
        let (controller, appearance) = makeController()
        appearance.hasSeenWelcome = false
        controller.startTour()
        controller.skip()
        XCTAssertEqual(controller.phase, .inactive)
        XCTAssertTrue(appearance.hasSeenWelcome)
        XCTAssertEqual(appearance.lastSeenWhatsNewVersion, WhatsNewPolicy.version)
    }

    func test_skipFromWelcome_setsFlagAndDismisses() {
        let (controller, appearance) = makeController()
        appearance.hasSeenWelcome = false
        controller.beginIfFirstLaunch(hasHosts: false, hasSeen: false)
        XCTAssertEqual(controller.phase, .welcome)
        controller.skip()
        XCTAssertEqual(controller.phase, .inactive)
        XCTAssertTrue(appearance.hasSeenWelcome)
        XCTAssertEqual(appearance.lastSeenWhatsNewVersion, WhatsNewPolicy.version)
    }

    // MARK: - Step list shape

    func test_firstRun_hasElevenStepsInOrder() {
        let steps = OnboardingStep.firstRun(.glyph)
        XCTAssertEqual(steps.count, 11)
        XCTAssertEqual(steps[0].kind, .spotlight(.addHost, .below))
        XCTAssertEqual(steps[1].kind, .spotlight(.settingsNav, .right))
        XCTAssertEqual(steps[2].kind, .illustration(.mockTerminal))
        XCTAssertEqual(steps[3].kind, .illustration(.agentCenter))
        XCTAssertEqual(steps[4].kind, .illustration(.swipePad))
        XCTAssertEqual(steps[5].kind, .illustration(.filesPanel))
        XCTAssertEqual(steps[6].kind, .spotlight(.artifactsNav, .right))
        XCTAssertEqual(steps[7].kind, .illustration(.openInArtifacts))
        XCTAssertEqual(steps[8].kind, .illustration(.shareInOut))
        XCTAssertEqual(steps[9].kind, .illustration(.agentImagePaste))
        XCTAssertEqual(steps[10].kind, .illustration(.shortcuts))
        XCTAssertTrue(steps[1].body.contains("Keys and known hosts live in Settings"))
        XCTAssertTrue(steps[5].body.contains("open files in Artifacts"))
        XCTAssertFalse(steps[5].body.contains("Quick Look"))
        XCTAssertTrue(steps[6].body.contains("Every tab from every session, grouped by host"))
        XCTAssertTrue(steps[7].body.contains("localhost link"))
        XCTAssertTrue(steps[4].body.contains("swipe toward an option"))
        XCTAssertTrue(steps[4].body.contains("release"))
    }

    func test_compactFirstRun_adaptsDeviceSpecificStepsWithoutChangingSequence() {
        let steps = OnboardingStep.firstRun(.glyph).map { $0.presentation(compact: true) }

        XCTAssertEqual(steps.count, 11)
        XCTAssertEqual(steps[0].kind, .spotlight(.addHost, .below))
        XCTAssertEqual(steps[1].kind, .spotlight(.settingsNav, .above))
        XCTAssertEqual(steps[2].kind, .illustration(.mockTerminal))
        XCTAssertEqual(steps[3].kind, .spotlight(.agentsNav, .above))
        XCTAssertEqual(steps[4].kind, .illustration(.swipePad))
        XCTAssertEqual(steps[5].kind, .illustration(.filesPanel))
        XCTAssertEqual(steps[6].kind, .spotlight(.artifactsNav, .above))
        XCTAssertEqual(steps[7].kind, .illustration(.openInArtifacts))
        XCTAssertEqual(steps[8].kind, .illustration(.shareInOut))
        XCTAssertEqual(steps[9].kind, .illustration(.agentImagePaste))
        XCTAssertEqual(steps[10].kind, .illustration(.phoneControls))
        XCTAssertEqual(steps[5].title, "files from your phone")
        XCTAssertEqual(steps[10].title, "terminal controls")
        XCTAssertFalse(steps[0].body.contains("⌘"))
        XCTAssertFalse(steps[10].body.contains("Magic Keyboard"))
        XCTAssertTrue(steps[2].body.contains("focused pane fits the phone viewport"))
    }

    func test_controllerStepsMatchFirstRun() {
        let (controller, appearance) = makeController()
        let expected = OnboardingStep.firstRun(appearance.modifierNotation, agentCenterEnabled: appearance.agentCenterEnabled)
        XCTAssertEqual(controller.steps.count, expected.count)
        XCTAssertEqual(controller.steps.map(\.kind), expected.map(\.kind))
    }

    func test_compactAgentCenterUsesIllustrationWhenDisabled() {
        let steps = OnboardingStep.firstRun(.glyph, agentCenterEnabled: false)
        XCTAssertEqual(steps[3].presentation(compact: true).kind, .illustration(.agentCenter))
        XCTAssertEqual(steps[3].presentation(compact: false).kind, .illustration(.agentCenter))
    }

    func test_offscreenSpotlightFallsBackAndPartialTargetIsClipped() {
        let bounds = CGRect(x: 0, y: 0, width: 320, height: 480)
        XCTAssertNil(OnboardingOverlay.visibleSpotlightRect(CGRect(x: 340, y: 40, width: 80, height: 44), in: bounds))
        XCTAssertNil(OnboardingOverlay.visibleSpotlightRect(.zero, in: bounds))
        XCTAssertNil(OnboardingOverlay.visibleSpotlightRect(.null, in: bounds))
        XCTAssertNil(OnboardingOverlay.visibleSpotlightRect(.infinite, in: bounds))
        XCTAssertEqual(
            OnboardingOverlay.visibleSpotlightRect(CGRect(x: 280, y: 450, width: 80, height: 44), in: bounds),
            CGRect(x: 280, y: 450, width: 40, height: 30)
        )
    }

    // MARK: - What's new policy and release tour

    func test_whatsNewPolicyMatrix() {
        for version in ["0.4.0", "0.4.1", "0.4.2", ""] {
            for lastSeen in ["", "0.4.0", "0.4.1", "0.4.2", "0.4.10", "1.0.0"] {
                for seenWelcome in [false, true] {
                    for hostCount in [-1, 0, 1, 4] {
                        let expected = version == "0.4.1"
                            && ["", "0.4.0"].contains(lastSeen)
                            && (seenWelcome || hostCount > 0)
                        XCTAssertEqual(
                            WhatsNewPolicy.shouldShowWhatsNew(
                                currentVersion: version, lastSeen: lastSeen,
                                hasSeenWelcome: seenWelcome, hostCount: hostCount
                            ), expected,
                            "version=\(version), lastSeen=\(lastSeen), welcome=\(seenWelcome), hosts=\(hostCount)"
                        )
                    }
                }
            }
        }
    }

    func test_whatsNewStepFilterUsesWalkthroughOrderAndPhoneOnlyAgentsStep() {
        let all = OnboardingStep.firstRun(.glyph)
        XCTAssertEqual(WhatsNewPolicy.walkthroughStepNumbers(isPhone: true), [2, 4, 6, 7, 8, 11])
        XCTAssertEqual(WhatsNewPolicy.walkthroughStepNumbers(isPhone: false), [2, 6, 7, 8, 11])
        for isPhone in [false, true] {
            let expected = WhatsNewPolicy.walkthroughStepNumbers(isPhone: isPhone).map { all[$0 - 1] }
            let actual = WhatsNewPolicy.walkthroughSteps(all, isPhone: isPhone)
            XCTAssertEqual(actual.map(\.kind), expected.map(\.kind))
            XCTAssertEqual(actual.map(\.title), expected.map(\.title))
        }
        XCTAssertTrue(WhatsNewPolicy.walkthroughSteps([], isPhone: true).isEmpty)
        XCTAssertEqual(WhatsNewPolicy.walkthroughSteps(Array(all.prefix(2)), isPhone: false).count, 1)
    }

    func test_whatsNewWaitsBehindLockAndSetupWithoutRecordingSeen() {
        let (controller, appearance) = makeController()
        appearance.hasSeenWelcome = true
        for gates in [(true, false), (false, true), (true, true)] {
            controller.beginWhatsNewIfNeeded(hostCount: 1, isLocked: gates.0, isSetupPresented: gates.1)
            XCTAssertEqual(controller.phase, .inactive)
            XCTAssertEqual(appearance.lastSeenWhatsNewVersion, "")
        }
        controller.beginWhatsNewIfNeeded(hostCount: 1, isLocked: false, isSetupPresented: false)
        XCTAssertEqual(controller.phase, .whatsNew)
        XCTAssertEqual(appearance.lastSeenWhatsNewVersion, "")
    }

    func test_whatsNewUsesSavedHostsEvenWhenWelcomeWasNeverSeen() {
        let (controller, appearance) = makeController()
        controller.beginWhatsNewIfNeeded(hostCount: 1, isLocked: false, isSetupPresented: false)
        XCTAssertEqual(controller.phase, .whatsNew)
        controller.dismissWhatsNew()
        XCTAssertFalse(appearance.hasSeenWelcome)
        XCTAssertEqual(appearance.lastSeenWhatsNewVersion, WhatsNewPolicy.version)
        controller.beginWhatsNewIfNeeded(hostCount: 1, isLocked: false, isSetupPresented: false)
        XCTAssertEqual(controller.phase, .inactive)
    }

    func test_whatsNewDoesNotAutoPresentForAnotherBundleVersion() {
        let (controller, appearance) = makeController(currentVersion: "0.4.0")
        appearance.hasSeenWelcome = true
        controller.beginWhatsNewIfNeeded(hostCount: 1, isLocked: false, isSetupPresented: false)
        XCTAssertEqual(controller.phase, .inactive)
        XCTAssertEqual(appearance.lastSeenWhatsNewVersion, "")
    }

    func test_freshInstallGetsWelcomeAndCompletionAcknowledgesReleaseCard() {
        let (controller, appearance) = makeController()
        controller.beginWhatsNewIfNeeded(hostCount: 0, isLocked: false, isSetupPresented: false)
        XCTAssertEqual(controller.phase, .inactive)
        controller.beginIfFirstLaunch(hasHosts: false, hasSeen: false)
        XCTAssertEqual(controller.phase, .welcome)
        controller.skip()
        XCTAssertEqual(appearance.lastSeenWhatsNewVersion, WhatsNewPolicy.version)
        controller.beginWhatsNewIfNeeded(hostCount: 0, isLocked: false, isSetupPresented: false)
        XCTAssertEqual(controller.phase, .inactive)
    }

    func test_whatsNewCannotInterruptWelcomeOrActiveWalkthrough() {
        let (controller, _) = makeController()
        controller.beginIfFirstLaunch(hasHosts: false, hasSeen: false)
        controller.beginWhatsNewIfNeeded(hostCount: 1, isLocked: false, isSetupPresented: false)
        XCTAssertEqual(controller.phase, .welcome)
        controller.startTour()
        controller.next()
        controller.beginWhatsNewIfNeeded(hostCount: 1, isLocked: false, isSetupPresented: false)
        XCTAssertEqual(controller.phase, .touring(1))
    }

    func test_showMeAcknowledgesBeforeTourAndReplayRestoresAllElevenSteps() {
        let (controller, appearance) = makeController()
        controller.showWhatsNew()
        controller.startWhatsNewTour(isPhone: true)
        XCTAssertEqual(appearance.lastSeenWhatsNewVersion, WhatsNewPolicy.version)
        XCTAssertEqual(controller.phase, .touring(0))
        XCTAssertEqual(controller.steps.count, 6)
        XCTAssertEqual(controller.steps.last?.presentation(compact: true).kind, .illustration(.phoneControls))
        for _ in 0..<6 { controller.next() }
        XCTAssertEqual(controller.phase, .inactive)
        controller.startTour()
        XCTAssertEqual(controller.steps.count, 11)
        XCTAssertEqual(controller.steps.first?.kind, .spotlight(.addHost, .below))
    }

    func test_padShowMeOmitsAgentsAndAboutCanReopenAcknowledgedCard() {
        let (controller, appearance) = makeController()
        controller.startWhatsNewTour(isPhone: false)
        XCTAssertEqual(controller.steps.count, 5)
        XCTAssertFalse(controller.steps.contains { $0.kind == .illustration(.agentCenter) })
        controller.skip()
        controller.showWhatsNew()
        XCTAssertEqual(controller.phase, .whatsNew)
        XCTAssertEqual(appearance.lastSeenWhatsNewVersion, WhatsNewPolicy.version)
        controller.dismissWhatsNew()
        XCTAssertEqual(controller.phase, .inactive)
    }

    func test_setupCompletionMarksWelcomeAndReleaseCardSeen() {
        let (controller, appearance) = makeController()
        controller.completeWelcome()
        XCTAssertTrue(appearance.hasSeenWelcome)
        XCTAssertEqual(appearance.lastSeenWhatsNewVersion, WhatsNewPolicy.version)
        XCTAssertEqual(AppearancePreferences().lastSeenWhatsNewVersion, WhatsNewPolicy.version)
    }

    func test_acknowledgingOldCardDoesNotDowngradeNewerSeenVersion() {
        let (controller, appearance) = makeController()
        appearance.lastSeenWhatsNewVersion = "0.4.10"
        controller.showWhatsNew()
        controller.dismissWhatsNew()
        XCTAssertEqual(appearance.lastSeenWhatsNewVersion, "0.4.10")
    }

    func test_whatsNewPreferenceNeverSyncs() {
        XCTAssertEqual(BootstrapSyncClassification.appearancePreferences["lastSeenWhatsNewVersion"], .neverSyncs)
    }
}
