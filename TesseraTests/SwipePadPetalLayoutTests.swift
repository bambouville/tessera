// TesseraTests/SwipePadPetalLayoutTests.swift
// Petal layout (prompt/working/fallback builders, tints, overflow) and the
// SwipePadAgentContext projection AgentCenter publishes for hook mode.
import Observation
import TmuxControl
import XCTest
@testable import Tessera

final class SwipePadPetalLayoutTests: XCTestCase {

    @MainActor
    func test_plainMoshSidecarProbeBacksOffAndRecovers() async {
        var currentTime = Date(timeIntervalSince1970: 1_000)
        let gate = SwipePadSidecarProbeGate(now: { currentTime })
        var calls = 0

        func fail(at date: Date) async -> [String] {
            currentTime = date
            return await gate.probe(identity: "host:42") {
                calls += 1
                return .failure(type: "FixtureFailure")
            }
        }

        let startedAt = currentTime
        _ = await fail(at: startedAt)
        _ = await fail(at: startedAt.addingTimeInterval(4))
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(gate.consecutiveFailures, 1)

        _ = await fail(at: startedAt.addingTimeInterval(5))
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(gate.consecutiveFailures, 2)

        currentTime = startedAt.addingTimeInterval(100)
        let names = await gate.probe(identity: "host:42") {
            calls += 1
            return .success(["codex"])
        }
        XCTAssertEqual(names, ["codex"])
        XCTAssertEqual(gate.consecutiveFailures, 0)
        XCTAssertNil(gate.retryAfter)
    }

    @MainActor
    func test_plainMoshSidecarProbeJoinsAnInFlightAttempt() async {
        let gate = SwipePadSidecarProbeGate()
        var calls = 0
        let first = Task { @MainActor in
            await gate.probe(identity: "host:42") {
                calls += 1
                try? await Task.sleep(for: .milliseconds(75))
                return .success(["claude"])
            }
        }
        try? await Task.sleep(for: .milliseconds(10))
        let second = Task { @MainActor in
            await gate.probe(identity: "host:42") {
                calls += 1
                return .success(["should-not-run"])
            }
        }

        let results = await (first.value, second.value)
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(results.0, ["claude"])
        XCTAssertEqual(results.1, ["claude"])
    }

    // MARK: - Prompt petals

    func test_livePromptMapsOptionsInOrderWithRealLabels() {
        let viewport = """
        Do you want to proceed?
        ❯ 1. Yes
          2. Yes, and always allow access to claude/ from this project
          3. No

        Esc to cancel · Tab to amend · ctrl+e to explain
        """
        let parsed = AgentPromptParser.parse(
            visibleText: viewport,
            profile: .builtInClaudeCode
        )
        guard let prompt = parsed.prompt else {
            return XCTFail("expected a parsed prompt")
        }

        let petals = SwipePadPetalLayout.petals(for: prompt)

        XCTAssertEqual(petals.map(\.direction), [.right, .left, .up])
        XCTAssertEqual(petals.map(\.label), [
            "Yes",
            "Yes, and always allow access to claude/ from this project",
            "No",
        ])
        XCTAssertEqual(
            petals.map(\.action),
            [.macro("1↵"), .macro("2↵"), .macro("3↵")]
        )
        XCTAssertEqual(petals.map(\.tint), [.affirmative, .caution, .negative])
    }

    func test_codexShortcutPromptKeepsShortcutMacros() {
        let viewport = """
        Would you like to run the following command?

        $ touch created-by-probe

        › 1. Yes, proceed (y)
          2. Yes, and don't ask again for commands that start with `touch created-by-probe` (p)
          3. No, and tell Codex what to do differently (esc)

        Press enter to confirm or esc to cancel
        """
        let parsed = AgentPromptParser.parse(
            visibleText: viewport,
            profile: .builtInCodexCLI
        )
        guard let prompt = parsed.prompt else {
            return XCTFail("expected a parsed prompt")
        }

        let petals = SwipePadPetalLayout.petals(for: prompt)

        XCTAssertEqual(
            petals.map(\.action),
            [.macro("y"), .macro("p"), .macro("esc")]
        )
        XCTAssertEqual(petals.map(\.tint), [.affirmative, .caution, .negative])
        XCTAssertEqual(petals.map(\.caption), ["y", "p", "esc"])
    }

    func test_singleOptionPromptShowsOnePetal() {
        let prompt = AgentPrompt(
            signature: "s",
            summary: "continue?",
            options: [
                AgentPromptOption(id: 1, label: "Yes", responseMacro: "1↵", isDefault: true)
            ]
        )

        let petals = SwipePadPetalLayout.petals(for: prompt)

        XCTAssertEqual(petals.map(\.direction), [.right])
        XCTAssertEqual(petals.first?.tint, .affirmative)
    }

    func test_exactlyFourOptionsMapWithoutMorePetal() {
        let prompt = AgentPrompt(
            signature: "s",
            summary: "pick",
            options: (1...4).map {
                AgentPromptOption(id: $0, label: "Option \($0)", responseMacro: "\($0)↵", isDefault: $0 == 1)
            }
        )

        let petals = SwipePadPetalLayout.petals(for: prompt)

        XCTAssertEqual(petals.map(\.direction), [.right, .left, .up, .down])
        XCTAssertFalse(petals.contains { $0.action == .showMore })
    }

    func test_overflowingPromptShowsFirstThreePlusMore() {
        let prompt = AgentPrompt(
            signature: "s",
            summary: "pick",
            options: (1...5).map {
                AgentPromptOption(id: $0, label: "Option \($0)", responseMacro: "\($0)↵", isDefault: $0 == 1)
            }
        )

        let layout = SwipePadPetalLayout.promptLayout(for: prompt)
        let petals = layout.petals

        XCTAssertEqual(petals.count, 4)
        XCTAssertEqual(
            petals.prefix(3).map(\.action),
            [.macro("1↵"), .macro("2↵"), .macro("3↵")]
        )
        let more = petals[3]
        XCTAssertEqual(more.direction, .down)
        XCTAssertEqual(more.action, .showMore)
        XCTAssertEqual(more.label, "more")
        XCTAssertEqual(more.caption, "2 more")
        XCTAssertNil(layout.separateMoreCount)
    }

    /// A live option matching the configured `.down` macro keeps the user's
    /// trained gesture. Overflow moves to the separate puck action instead
    /// of replacing or relocating any direction binding.
    func test_overflowKeepsDownTrainedMacroAndMovesMoreToPuck() {
        var profile = SwipePadProfile.builtInClaudeCode
        profile.bindings = [.down: SwipePadBinding(macro: "2↵", label: "always")]
        let prompt = AgentPrompt(
            signature: "s",
            summary: "pick",
            options: (1...5).map {
                AgentPromptOption(id: $0, label: "Option \($0)", responseMacro: "\($0)↵", isDefault: $0 == 1)
            }
        )

        let layout = SwipePadPetalLayout.promptLayout(for: prompt, profile: profile)
        let petals = layout.petals

        let down = petals.first { $0.direction == .down }
        XCTAssertEqual(
            down?.action,
            .macro("2↵"),
            "overflow must not replace the user's configured down macro"
        )
        XCTAssertEqual(down?.label, "Option 2")
        XCTAssertFalse(petals.contains { $0.action == .showMore })
        XCTAssertEqual(layout.separateMoreCount, 1)
        // The separate overflow action must not disturb the untrained fill
        // order: a blind right-swipe still means option 1.
        let right = petals.first { $0.direction == .right }
        XCTAssertEqual(right?.action, .macro("1↵"), "blind right-swipe must stay option 1")
    }

    func test_overflowDownTrainedOptionBeyondFirstThreeKeepsDownDirection() {
        // R2-F4 drop case: the trained match must be searched across the
        // FULL menu. An option in position 5 whose macro the user trained
        // onto `.down` may not silently vanish behind "more" or move away
        // from its trained gesture.
        var profile = SwipePadProfile.builtInClaudeCode
        profile.bindings = [.down: SwipePadBinding(macro: "5↵", label: "always")]
        let prompt = AgentPrompt(
            signature: "s",
            summary: "pick",
            options: (1...5).map {
                AgentPromptOption(id: $0, label: "Option \($0)", responseMacro: "\($0)↵", isDefault: $0 == 1)
            }
        )

        let layout = SwipePadPetalLayout.promptLayout(for: prompt, profile: profile)
        let petals = layout.petals

        let trained = petals.first { $0.action == .macro("5↵") }
        XCTAssertNotNil(trained, "a down-trained option in position ≥4 must stay visible")
        XCTAssertEqual(trained?.direction, .down, "the trained gesture stays truthful")
        XCTAssertFalse(petals.contains { $0.action == .showMore })
        XCTAssertEqual(layout.separateMoreCount, 1)
        XCTAssertEqual(
            petals.first { $0.direction == .right }?.action,
            .macro("1↵"),
            "untrained fill still starts at option 1 on right"
        )
    }

    func test_overflowTrainedOptionBeyondFirstThreeKeepsItsTrainedDirection() {
        var profile = SwipePadProfile.builtInClaudeCode
        profile.bindings = [.right: SwipePadBinding(macro: "4↵", label: "approve pattern")]
        let prompt = AgentPrompt(
            signature: "s",
            summary: "pick",
            options: (1...5).map {
                AgentPromptOption(id: $0, label: "Option \($0)", responseMacro: "\($0)↵", isDefault: $0 == 1)
            }
        )

        let petals = SwipePadPetalLayout.petals(for: prompt, profile: profile)

        XCTAssertEqual(
            petals.first { $0.direction == .right }?.action,
            .macro("4↵"),
            "a trained gesture keeps its macro even when the option sits past position 3"
        )
        XCTAssertEqual(petals.first { $0.direction == .left }?.action, .macro("1↵"))
        XCTAssertEqual(petals.first { $0.direction == .up }?.action, .macro("2↵"))
        XCTAssertEqual(petals.first { $0.direction == .down }?.action, .showMore)
    }

    func test_overflowFourDirectionTrainedProfilePreservesEveryBinding() {
        // R4-F2 configuration: all four trained direction→macro mappings
        // remain direct byte-sending petals. More is a separate puck action,
        // so no configured binding is dropped, relocated, or repurposed.
        var profile = SwipePadProfile.builtInClaudeCode
        profile.bindings = [
            .right: SwipePadBinding(macro: "1↵", label: "one"),
            .left: SwipePadBinding(macro: "2↵", label: "two"),
            .up: SwipePadBinding(macro: "3↵", label: "three"),
            .down: SwipePadBinding(macro: "5↵", label: "five"),
        ]
        let prompt = AgentPrompt(
            signature: "s",
            summary: "pick",
            options: (1...5).map {
                AgentPromptOption(id: $0, label: "Option \($0)", responseMacro: "\($0)↵", isDefault: $0 == 1)
            }
        )

        let layout = SwipePadPetalLayout.promptLayout(for: prompt, profile: profile)
        let petals = layout.petals

        XCTAssertEqual(petals.count, 4)
        XCTAssertEqual(
            petals.first { $0.direction == .right }?.action,
            .macro("1↵"),
            "trained claims keep their directions"
        )
        XCTAssertEqual(petals.first { $0.direction == .left }?.action, .macro("2↵"))
        XCTAssertEqual(petals.first { $0.direction == .up }?.action, .macro("3↵"))
        XCTAssertEqual(
            petals.first { $0.direction == .down }?.action,
            .macro("5↵"),
            "the configured down macro must remain reachable on down"
        )
        XCTAssertFalse(petals.contains { $0.action == .showMore })
        XCTAssertEqual(layout.separateMoreCount, 1)
    }

    // MARK: - Unparsed prompt petals

    func test_unparsedPromptOffersOnlyZeroByteShowMore() {
        let petals = SwipePadPetalLayout.unparsedPromptPetals()

        XCTAssertEqual(petals.count, 1)
        XCTAssertEqual(petals.first?.direction, .down)
        XCTAssertEqual(petals.first?.action, .showMore)
        XCTAssertEqual(petals.first?.tint, .neutral)
        XCTAssertFalse(
            petals.contains { if case .macro = $0.action { true } else { false } },
            "an unparseable prompt must never become actionable through static macros"
        )
    }

    // MARK: - Radial geometry

    /// Firing maps the drag vector into 45°-boundary sectors relative to
    /// the puck (SwipePadView.direction(for:)). Mirrored here so geometry
    /// tests can assert a rendered position agrees with the gesture that
    /// fires it.
    private func gestureSector(of offset: CGSize) -> SwipeDirection? {
        guard offset != .zero else { return nil }
        let angle = atan2(offset.height, offset.width)
        let quarter = CGFloat.pi / 4
        if angle >= -quarter && angle < quarter { return .right }
        if angle >= quarter && angle < 3 * quarter { return .down }
        if angle <= -quarter && angle > -3 * quarter { return .up }
        return .left
    }

    func test_radialPetalsRenderInsideTheirGestureSectors() {
        // The radial's visible target must be reachable by the drag that
        // fires it: every petal's rendered offset (there is no cluster
        // translation — the radial simply refuses to render where it does
        // not fit) maps back to its own direction under the exact firing
        // sector math.
        for direction in [SwipeDirection.right, .left, .up, .down] {
            let offset = SwipePadPetalLayout.petalOffset(for: direction, diameter: 52)
            XCTAssertEqual(
                gestureSector(of: offset),
                direction,
                "\(direction) petal renders outside the sector that fires it"
            )
        }
    }

    func test_radialRefusedAtUnsafeCornerAcceptedAtSafeDefault() {
        let diameter: CGFloat = 52
        let canvas = CGSize(width: 1180, height: 820)
        let unsafeCorner = CGPoint(x: canvas.width - 48, y: canvas.height - 48)
        let directions: [SwipeDirection] = [.right, .left, .up, .down]
        let insets = SwipePadPetalLayout.radialCenterInsets(
            directions: directions,
            diameter: diameter
        )
        let safeDefault = CGPoint(
            x: canvas.width - insets.trailing,
            y: canvas.height - insets.bottom
        )

        XCTAssertFalse(
            SwipePadPetalLayout.radialFits(
                directions: directions,
                puckCenter: unsafeCorner,
                canvasSize: canvas,
                diameter: diameter
            )
        )
        XCTAssertTrue(
            SwipePadPetalLayout.radialFits(
                directions: directions,
                puckCenter: safeDefault,
                canvasSize: canvas,
                diameter: diameter
            )
        )
    }

    func test_safeBottomRightDefaultFitsPhoneProMaxAndIPadInBothOrientations() {
        let directions: [SwipeDirection] = [.right, .left, .up, .down]
        let deviceCanvases: [(name: String, portrait: CGSize)] = [
            ("iPhone", CGSize(width: 402, height: 874)),
            ("iPhone Pro Max", CGSize(width: 440, height: 956)),
            ("iPad", CGSize(width: 1032, height: 1376)),
        ]

        for diameter: CGFloat in [44, 52, 64] {
            let insets = SwipePadPetalLayout.radialCenterInsets(
                directions: directions,
                diameter: diameter
            )
            for device in deviceCanvases {
                for (orientation, canvas) in [
                    ("portrait", device.portrait),
                    ("landscape", CGSize(
                        width: device.portrait.height,
                        height: device.portrait.width
                    )),
                ] {
                    let center = CGPoint(
                        x: canvas.width - insets.trailing,
                        y: canvas.height - insets.bottom
                    )
                    XCTAssertGreaterThan(center.x, canvas.width / 2)
                    XCTAssertGreaterThan(center.y, canvas.height / 2)
                    XCTAssertTrue(
                        SwipePadPetalLayout.radialFits(
                            directions: directions,
                            puckCenter: center,
                            canvasSize: canvas,
                            diameter: diameter
                        ),
                        "\(device.name) \(orientation), diameter \(diameter)"
                    )
                }
            }
        }
    }

    func test_chipStackStaysOnCanvasAndInwardAtEveryCorner() {
        let diameter: CGFloat = 52
        let canvas = CGSize(width: 1180, height: 820)
        let corners = [
            CGPoint(x: 48, y: 48),
            CGPoint(x: canvas.width - 48, y: 48),
            CGPoint(x: 48, y: canvas.height - 48),
            CGPoint(x: canvas.width - 48, y: canvas.height - 48),
        ]
        let size = SwipePadPetalLayout.chipStackSize(petalCount: 4)

        for corner in corners {
            let offset = SwipePadPetalLayout.chipStackCenterOffset(
                petalCount: 4,
                puckCenter: corner,
                canvasSize: canvas,
                diameter: diameter
            )
            let center = CGPoint(x: corner.x + offset.width, y: corner.y + offset.height)
            XCTAssertGreaterThanOrEqual(center.x - size.width / 2, 0, "\(corner) clips leading")
            XCTAssertLessThanOrEqual(center.x + size.width / 2, canvas.width, "\(corner) clips trailing")
            XCTAssertGreaterThanOrEqual(center.y - size.height / 2, 0, "\(corner) clips top")
            XCTAssertLessThanOrEqual(center.y + size.height / 2, canvas.height, "\(corner) clips bottom")
            // Inward: the stack extends toward the canvas center, never
            // further into the puck's own edge.
            if corner.x > canvas.width / 2 {
                XCTAssertLessThan(center.x, corner.x, "\(corner) stack must extend left")
            } else {
                XCTAssertGreaterThan(center.x, corner.x, "\(corner) stack must extend right")
            }
        }
    }

    // MARK: - Corner fan geometry

    private typealias Fan = SwipePadPetalLayout
    private let allDirections: [SwipeDirection] = [.right, .left, .up, .down]

    /// Overlay corner-home replica for the phone path: actual corners,
    /// bottom edge pulled up by the home-indicator clearance + radius
    /// (matching SwipePadOverlay.clampedPosition's phone behavior).
    private func phoneCornerHome(
        _ quadrant: Fan.FanQuadrant,
        canvas: CGSize,
        diameter: CGFloat
    ) -> CGPoint {
        let inset = Fan.fanCornerInset(puckDiameter: diameter)
        let x = (quadrant == .topLeft || quadrant == .bottomLeft)
            ? inset : canvas.width - inset
        let y = (quadrant == .topLeft || quadrant == .topRight)
            ? inset : canvas.height - (34 + diameter / 2)
        return CGPoint(x: x, y: y)
    }

    func test_fanAnglesKeepOnScreenCardinalsAtTrueAxesWith30DegreeSlots() {
        // The two cardinals that still point on-screen anchor the fan ends
        // at their exact axes; slots step 30° across the inward quadrant.
        let trueCardinals: [(Fan.FanQuadrant, SwipeDirection, CGFloat)] = [
            (.bottomRight, .up, 90), (.bottomRight, .left, 180),
            (.bottomLeft, .right, 0), (.bottomLeft, .up, 90),
            (.topRight, .left, 180), (.topRight, .down, 270),
            (.topLeft, .down, 270), (.topLeft, .right, 360),
        ]
        for (quadrant, direction, expected) in trueCardinals {
            XCTAssertEqual(
                Fan.fanAngles(for: quadrant)[direction], expected,
                "\(quadrant) \(direction)"
            )
        }
        for quadrant in Fan.FanQuadrant.allCases {
            let angles = Fan.fanAngles(for: quadrant)
            XCTAssertEqual(Set(angles.keys), Set(allDirections), "\(quadrant)")
            let sorted = angles.values.sorted()
            XCTAssertEqual(
                zip(sorted.dropFirst(), sorted).map(-), [30, 30, 30],
                "\(quadrant) slots must step 30°"
            )
        }
    }

    func test_partialFanPacksOccupiedSlotsWithoutDirectionalHoles() {
        let directions: [SwipeDirection] = [.right, .left, .up]
        let angles = Fan.fanAngles(for: directions, quadrant: .bottomRight)

        XCTAssertEqual(angles[.up], 105)
        XCTAssertEqual(angles[.right], 135)
        XCTAssertEqual(angles[.left], 165)
        XCTAssertNil(angles[.down])

        for direction in directions {
            let offset = Fan.fanPetalOffset(
                for: direction,
                directions: directions,
                quadrant: .bottomRight,
                puckDiameter: 52
            )
            XCTAssertEqual(
                Fan.fanDirection(
                    for: offset,
                    directions: directions,
                    quadrant: .bottomRight
                ),
                direction
            )
        }
    }

    func test_singleFanTargetUsesInwardBisector() {
        let directions: [SwipeDirection] = [.up]
        for quadrant in Fan.FanQuadrant.allCases {
            let dynamic = Fan.fanAngles(for: directions, quadrant: quadrant)
            let canonical = Fan.fanAngles(for: quadrant).values.sorted()
            XCTAssertEqual(dynamic[.up], (canonical.first! + canonical.last!) / 2)
        }
    }

    func test_fanQuadrantsAreMirrorImages() {
        // Aim knowledge must transfer between corners: horizontal mirrors
        // swap left/right, vertical mirrors swap up/down.
        func mirrorH(_ d: SwipeDirection) -> SwipeDirection {
            d == .left ? .right : d == .right ? .left : d
        }
        func mirrorV(_ d: SwipeDirection) -> SwipeDirection {
            d == .up ? .down : d == .down ? .up : d
        }
        func norm(_ a: CGFloat) -> CGFloat {
            ((a.truncatingRemainder(dividingBy: 360)) + 360)
                .truncatingRemainder(dividingBy: 360)
        }
        let br = Fan.fanAngles(for: .bottomRight)
        let bl = Fan.fanAngles(for: .bottomLeft)
        let tr = Fan.fanAngles(for: .topRight)
        let tl = Fan.fanAngles(for: .topLeft)
        for d in allDirections {
            XCTAssertEqual(norm(bl[mirrorH(d)]!), norm(180 - br[d]!), "BR↔BL \(d)")
            XCTAssertEqual(norm(tr[mirrorV(d)]!), norm(360 - br[d]!), "BR↔TR \(d)")
            XCTAssertEqual(norm(tl[mirrorH(d)]!), norm(180 - tr[d]!), "TR↔TL \(d)")
        }
    }

    func test_fanPetalsRenderInsideTheirOwnFiringSectors() {
        // Fan analogue of the cross sector test: the drag vector that
        // points at a rendered petal must quantize back to that petal's
        // direction under the exact firing math.
        for quadrant in Fan.FanQuadrant.allCases {
            for direction in allDirections {
                let offset = Fan.fanPetalOffset(
                    for: direction, quadrant: quadrant, puckDiameter: 52
                )
                XCTAssertEqual(
                    Fan.fanDirection(for: offset, quadrant: quadrant),
                    direction,
                    "\(quadrant) \(direction) petal renders outside its firing sector"
                )
            }
        }
    }

    func test_fanDirectionRefusesOutsideArcAndResolvesBoundariesDeterministically() {
        func translation(mathDegrees: CGFloat) -> CGSize {
            let radians = mathDegrees * CGFloat.pi / 180
            return CGSize(width: cos(radians) * 100, height: -sin(radians) * 100)
        }
        // Bottom-right fan spans 90°…180°; a drag toward the corner
        // (down-right, -45°) points at no slot and must not fire.
        XCTAssertNil(Fan.fanDirection(
            for: translation(mathDegrees: -45), quadrant: .bottomRight
        ))
        // Just past the arc's tolerance at either end.
        XCTAssertNil(Fan.fanDirection(
            for: translation(mathDegrees: 74), quadrant: .bottomRight
        ))
        XCTAssertNil(Fan.fanDirection(
            for: translation(mathDegrees: 196), quadrant: .bottomRight
        ))
        // Inside the end slots' tolerance.
        XCTAssertEqual(Fan.fanDirection(
            for: translation(mathDegrees: 80), quadrant: .bottomRight
        ), .up)
        XCTAssertEqual(Fan.fanDirection(
            for: translation(mathDegrees: 190), quadrant: .bottomRight
        ), .left)
        // The exact between-slot boundary (105° sits 15° from both up and
        // right) resolves deterministically to the lower slot.
        XCTAssertEqual(Fan.fanDirection(
            for: translation(mathDegrees: 105), quadrant: .bottomRight
        ), .up)
        // Top-left's 360° slot must accept a plain rightward drag.
        XCTAssertEqual(Fan.fanDirection(
            for: CGSize(width: 100, height: 0), quadrant: .topLeft
        ), .right)
    }

    func test_fanRadiusKeepsPetalGapsAcrossPuckSizes() {
        for puck: CGFloat in [44, 52, 64] {
            let petal = Fan.fanPetalDiameter(puckDiameter: puck)
            let radius = Fan.fanRadius(petalDiameter: petal)
            let chord = 2 * radius * sin(15 * CGFloat.pi / 180)
            let idleGap = chord - petal
            XCTAssertGreaterThanOrEqual(idleGap, 8, "puck \(puck)")
            XCTAssertLessThanOrEqual(idleGap, 12, "puck \(puck)")
            // A swollen active petal must still clear its idle neighbor.
            let swollenPair = petal / 2 + petal * Fan.petalMaxScale / 2
            XCTAssertGreaterThanOrEqual(chord - swollenPair, 2, "puck \(puck)")
        }
    }

    func test_presentationPrefersCrossThenFanThenChips() {
        let diameter: CGFloat = 52
        let phoneCanvas = CGSize(width: 393, height: 765)

        // Mid-canvas: the cross fits — original four-direction radial.
        XCTAssertEqual(
            SwipePadPetalLayout.presentation(
                directions: allDirections,
                puckCenter: CGPoint(x: phoneCanvas.width / 2, y: phoneCanvas.height / 2),
                canvasSize: phoneCanvas,
                diameter: diameter
            ),
            .cross
        )
        // iPad default home: unchanged cross.
        let ipadCanvas = CGSize(width: 1180, height: 820)
        let insets = SwipePadPetalLayout.radialCenterInsets(
            directions: allDirections, diameter: diameter
        )
        XCTAssertEqual(
            SwipePadPetalLayout.presentation(
                directions: allDirections,
                puckCenter: CGPoint(
                    x: ipadCanvas.width - insets.trailing,
                    y: ipadCanvas.height - insets.bottom
                ),
                canvasSize: ipadCanvas,
                diameter: diameter
            ),
            .cross
        )
        // Every phone corner home: the fan, oriented to its own quadrant.
        for quadrant in Fan.FanQuadrant.allCases {
            let home = phoneCornerHome(quadrant, canvas: phoneCanvas, diameter: diameter)
            XCTAssertEqual(
                SwipePadPetalLayout.presentation(
                    directions: allDirections,
                    puckCenter: home,
                    canvasSize: phoneCanvas,
                    diameter: diameter
                ),
                .fan(quadrant),
                "\(quadrant)"
            )
        }
        // Dragged fully flush into a corner (clamp minimum: the bare puck
        // radius): still the fan, never a chip-row cliff.
        XCTAssertEqual(
            SwipePadPetalLayout.presentation(
                directions: allDirections,
                puckCenter: CGPoint(x: 26, y: phoneCanvas.height - 60),
                canvasSize: phoneCanvas,
                diameter: diameter
            ),
            .fan(.bottomLeft)
        )
        // iPad flush corner: same behavior — fan, not chips.
        XCTAssertEqual(
            SwipePadPetalLayout.presentation(
                directions: allDirections,
                puckCenter: CGPoint(x: ipadCanvas.width - 32, y: ipadCanvas.height - 32),
                canvasSize: ipadCanvas,
                diameter: 64
            ),
            .fan(.bottomRight)
        )
        // Degenerate canvas that fits neither radial: chip rows remain the
        // last-resort fallback.
        XCTAssertEqual(
            SwipePadPetalLayout.presentation(
                directions: allDirections,
                puckCenter: CGPoint(x: 70, y: 70),
                canvasSize: CGSize(width: 140, height: 140),
                diameter: diameter
            ),
            .chips
        )
    }

    func test_fanCornerHomesKeepSwollenPetalsOnCanvas() {
        // Homes must never rest inside the swell-clip tolerance fanFits
        // grants to user-dragged positions.
        let diameter: CGFloat = 52
        let petal = Fan.fanPetalDiameter(puckDiameter: diameter)
        let swollenRadius = petal * Fan.petalMaxScale / 2
        for canvas in [CGSize(width: 393, height: 765), CGSize(width: 852, height: 341)] {
            for quadrant in Fan.FanQuadrant.allCases {
                let home = phoneCornerHome(quadrant, canvas: canvas, diameter: diameter)
                for direction in allDirections {
                    let offset = Fan.fanPetalOffset(
                        for: direction, quadrant: quadrant, puckDiameter: diameter
                    )
                    let center = CGPoint(
                        x: home.x + offset.width, y: home.y + offset.height
                    )
                    XCTAssertGreaterThanOrEqual(
                        center.x - swollenRadius, 0, "\(canvas) \(quadrant) \(direction)"
                    )
                    XCTAssertLessThanOrEqual(
                        center.x + swollenRadius, canvas.width, "\(canvas) \(quadrant) \(direction)"
                    )
                    XCTAssertGreaterThanOrEqual(
                        center.y - swollenRadius, 0, "\(canvas) \(quadrant) \(direction)"
                    )
                    XCTAssertLessThanOrEqual(
                        center.y + swollenRadius, canvas.height, "\(canvas) \(quadrant) \(direction)"
                    )
                }
            }
        }
    }

    func test_fanLabelsAndReadoutStayOnCanvasAtPhoneHomes() {
        let diameter: CGFloat = 52
        let canvas = CGSize(width: 393, height: 765)
        for quadrant in Fan.FanQuadrant.allCases {
            let home = phoneCornerHome(quadrant, canvas: canvas, diameter: diameter)
            for direction in allDirections {
                let offset = Fan.fanLabelOffset(
                    for: direction,
                    quadrant: quadrant,
                    puckDiameter: diameter,
                    puckCenter: home,
                    canvasSize: canvas
                )
                let center = CGPoint(x: home.x + offset.width, y: home.y + offset.height)
                XCTAssertGreaterThanOrEqual(center.x - Fan.fanLabelWidth / 2, 0, "\(quadrant) \(direction)")
                XCTAssertLessThanOrEqual(center.x + Fan.fanLabelWidth / 2, canvas.width, "\(quadrant) \(direction)")
                XCTAssertGreaterThanOrEqual(center.y - 18, 0, "\(quadrant) \(direction)")
                XCTAssertLessThanOrEqual(center.y + 18, canvas.height, "\(quadrant) \(direction)")
            }
            let readout = Fan.fanReadoutOffset(
                quadrant: quadrant,
                puckDiameter: diameter,
                puckCenter: home,
                canvasSize: canvas
            )
            let center = CGPoint(x: home.x + readout.width, y: home.y + readout.height)
            XCTAssertGreaterThanOrEqual(center.x - 100, 0, "\(quadrant) readout")
            XCTAssertLessThanOrEqual(center.x + 100, canvas.width, "\(quadrant) readout")
        }
    }

    // MARK: - Working / fallback petals

    func test_workingStateOffersInterruptAndModeSwitchPetals() {
        let petals = SwipePadPetalLayout.workingPetals()
        let byDirection = Dictionary(uniqueKeysWithValues: petals.map { ($0.direction, $0) })

        XCTAssertEqual(petals.count, 2)
        XCTAssertEqual(byDirection[.left]?.label, "interrupt")
        XCTAssertEqual(byDirection[.left]?.action, .macro("esc"))
        XCTAssertEqual(byDirection[.left]?.tint, .negative)
        XCTAssertEqual(byDirection[.up]?.label, "switch mode")
        XCTAssertEqual(byDirection[.up]?.action, .macro("shift-tab"))
        XCTAssertEqual(byDirection[.up]?.tint, .neutral)
    }

    func test_idleStateOffersSingleModeSwitchPetal() {
        let petals = SwipePadPetalLayout.idlePetals()

        XCTAssertEqual(petals.count, 1)
        XCTAssertEqual(petals.first?.direction, .up)
        XCTAssertEqual(petals.first?.label, "switch mode")
        XCTAssertEqual(petals.first?.action, .macro("shift-tab"))
        XCTAssertEqual(petals.first?.tint, .neutral)
        XCTAssertEqual(MacroEncoder.encode("shift-tab"), [0x1B, 0x5B, 0x5A])
    }

    func test_justFinishedStateOffersSingleModeSwitchPetal() {
        let petals = SwipePadPetalLayout.justFinishedPetals()

        XCTAssertEqual(petals, SwipePadPetalLayout.idlePetals())
        XCTAssertEqual(petals.count, 1)
        XCTAssertEqual(petals.first?.direction, .up)
        XCTAssertEqual(petals.first?.label, "switch mode")
        XCTAssertEqual(petals.first?.action, .macro("shift-tab"))
        XCTAssertEqual(petals.first?.tint, .neutral)
    }

    func test_finishedAcknowledgementHidesOnlyTheAcknowledgedCompletionTint() {
        XCTAssertTrue(
            SwipePadFinishedAcknowledgement.tintIsVisible(
                status: .justFinished,
                stateKey: "completion-a",
                acknowledgedKey: nil
            )
        )
        XCTAssertFalse(
            SwipePadFinishedAcknowledgement.tintIsVisible(
                status: .justFinished,
                stateKey: "completion-a",
                acknowledgedKey: "completion-a"
            )
        )
        XCTAssertTrue(
            SwipePadFinishedAcknowledgement.tintIsVisible(
                status: .justFinished,
                stateKey: "completion-b",
                acknowledgedKey: "completion-a"
            ),
            "a later completion must light the tint again"
        )
        XCTAssertFalse(
            SwipePadFinishedAcknowledgement.tintIsVisible(
                status: .working,
                stateKey: "working",
                acknowledgedKey: nil
            )
        )
    }

    func test_builtInProfilePetalsUseBindingLabels() {
        let petals = SwipePadPetalLayout.petals(for: .builtInClaudeCode)

        XCTAssertEqual(
            petals.map(\.label).sorted(),
            ["always", "approve", "deny"]
        )
        let byDirection = Dictionary(uniqueKeysWithValues: petals.map { ($0.direction, $0) })
        XCTAssertEqual(byDirection[.right]?.tint, .affirmative)
        XCTAssertEqual(byDirection[.left]?.tint, .negative)
        XCTAssertEqual(byDirection[.up]?.tint, .caution)
        // Claude's menu is 1=Yes / 2=always / 3=No — deny MUST send 3.
        XCTAssertEqual(byDirection[.right]?.action, .macro("1↵"))
        XCTAssertEqual(byDirection[.left]?.action, .macro("3↵"))
        XCTAssertEqual(byDirection[.up]?.action, .macro("2↵"))
    }

    /// Drift guard: pins each built-in binding's label semantics to the
    /// macro the *parser* extracts from the live menu, so a provider menu
    /// reorder breaks this test instead of silently turning the deny
    /// gesture into a consent grant (the pre-2026-08 Claude bug).
    func test_builtInBindingsTrackParsedMenuSemantics() {
        let cases: [(profile: SwipePadProfile, viewport: String)] = [
            (.builtInClaudeCode, """
            Do you want to proceed?
            ❯ 1. Yes
              2. Yes, and always allow access to claude/ from this project
              3. No

            Esc to cancel · Tab to amend · ctrl+e to explain
            """),
            (.builtInCodexCLI, """
            Would you like to run the following command?

            $ touch created-by-probe

            › 1. Yes, proceed (y)
              2. Yes, and don't ask again for commands that start with `touch created-by-probe` (p)
              3. No, and tell Codex what to do differently (esc)

            Press enter to confirm or esc to cancel
            """),
        ]

        for (profile, viewport) in cases {
            guard let prompt = AgentPromptParser.parse(
                visibleText: viewport,
                profile: profile
            ).prompt else {
                XCTFail("\(profile.name): fixture must parse"); continue
            }
            func option(forBinding direction: SwipeDirection) -> AgentPromptOption? {
                let macro = profile.binding(for: direction).macro
                return prompt.options.first { $0.responseMacro == macro }
            }

            let deny = option(forBinding: .left)
            XCTAssertEqual(
                deny.map { AgentPromptOption.isNegativeLabel($0.label) }, true,
                "\(profile.name): the deny gesture must send the refusal option, got '\(deny?.label ?? "nil")'"
            )
            let always = option(forBinding: .up)
            XCTAssertEqual(
                always.map { $0.label.lowercased().contains("always") || $0.label.lowercased().contains("don't ask") }, true,
                "\(profile.name): the always gesture must send the sticky-consent option, got '\(always?.label ?? "nil")'"
            )
            let approve = option(forBinding: .right)
            XCTAssertEqual(
                approve?.id, 1,
                "\(profile.name): the approve gesture must send the plain-yes option"
            )
        }
    }

    // MARK: - Spatial placement (muscle memory)

    func test_livePetalsKeepTrainedDirectionsForBoundMacros() {
        let viewport = """
        Would you like to run the following command?

        $ touch created-by-probe

        › 1. Yes, proceed (y)
          2. Yes, and don't ask again for commands that start with `touch created-by-probe` (p)
          3. No, and tell Codex what to do differently (esc)

        Press enter to confirm or esc to cancel
        """
        guard let prompt = AgentPromptParser.parse(
            visibleText: viewport,
            profile: .builtInCodexCLI
        ).prompt else { return XCTFail("expected a parsed prompt") }

        let petals = SwipePadPetalLayout.petals(
            for: prompt,
            profile: .builtInCodexCLI
        )
        let byDirection = Dictionary(uniqueKeysWithValues: petals.map { ($0.direction, $0) })

        // Legacy keymap: → y · ← esc · ↑ p. Order-based placement would put
        // sticky consent (p) on the deny gesture — regression guard.
        XCTAssertEqual(byDirection[.right]?.action, .macro("y"))
        XCTAssertEqual(byDirection[.left]?.action, .macro("esc"))
        XCTAssertEqual(byDirection[.up]?.action, .macro("p"))
        XCTAssertNotEqual(
            byDirection[.left]?.action, .macro("p"),
            "sticky consent must never land on the trained deny direction"
        )
    }

    func test_livePetalsOrderFillUnboundOptions() {
        // A profile binding none of the live macros falls back to pure
        // menu-order placement.
        let prompt = AgentPrompt(
            signature: "s",
            summary: "pick",
            options: (1...3).map {
                AgentPromptOption(id: $0, label: "Option \($0)", responseMacro: "\($0)↵", isDefault: $0 == 1)
            }
        )
        let profile = SwipePadProfile(
            id: UUID(),
            name: "custom",
            matchProcess: "",
            bindings: [.right: SwipePadBinding(macro: "zz")],
            isBuiltIn: false
        )

        let petals = SwipePadPetalLayout.petals(for: prompt, profile: profile)

        XCTAssertEqual(petals.map(\.direction), [.right, .left, .up])
        XCTAssertEqual(
            petals.map(\.action),
            [.macro("1↵"), .macro("2↵"), .macro("3↵")]
        )
    }

    // MARK: - Fire guard

    func test_fireGuardRadialOpenReBaselinesOnlyOntoLiveHookState() {
        // hook→hook: re-baseline onto the state the user now sees.
        XCTAssertEqual(
            SwipePadFireGuard.keyAtRadialOpen(currentKey: "B", pressedKey: "A"),
            "B"
        )
        // hook→nil (proof vanished pre-radial): keep the touch-down key so
        // release (nil) mismatches and refuses the stale-resolver petals.
        XCTAssertEqual(
            SwipePadFireGuard.keyAtRadialOpen(currentKey: nil, pressedKey: "A"),
            "A"
        )
        // legacy→hook: capture the live state.
        XCTAssertEqual(
            SwipePadFireGuard.keyAtRadialOpen(currentKey: "B", pressedKey: nil),
            "B"
        )
        // legacy→legacy: stays nil.
        XCTAssertNil(
            SwipePadFireGuard.keyAtRadialOpen(currentKey: nil, pressedKey: nil)
        )
    }

    func test_fireGuardRefusesStaleState() {
        XCTAssertTrue(SwipePadFireGuard.allowsFire(pressedKey: "A", releaseKey: "A"))
        XCTAssertTrue(SwipePadFireGuard.allowsFire(pressedKey: nil, releaseKey: nil))
        XCTAssertFalse(SwipePadFireGuard.allowsFire(pressedKey: "A", releaseKey: "B"))
        // The J2 hole: hook proof vanished before radial-open; pressed key
        // retained, release key nil → refuse.
        XCTAssertFalse(SwipePadFireGuard.allowsFire(pressedKey: "A", releaseKey: nil))
        XCTAssertFalse(SwipePadFireGuard.allowsFire(pressedKey: nil, releaseKey: "B"))
    }

    func test_fireGuardKeyIncludesAgentIdentity() {
        let sessionID = UUID()
        func snapshot(
            paneID: Int? = 7,
            statusChangedAt: TimeInterval = 0,
            detectedAt: TimeInterval = -60,
            providerSessionID: String? = "conv-a",
            agentPID: Int? = 4242
        ) -> SwipePadAgentSnapshot {
            SwipePadAgentSnapshot(
                agentID: AgentInstanceID(sessionID: sessionID, paneID: paneID),
                profileID: SwipePadProfile.builtInClaudeCodeID,
                profileName: "Claude Code",
                status: .working,
                prompt: nil,
                statusChangedAt: Date(timeIntervalSinceReferenceDate: statusChangedAt),
                detectedAt: Date(timeIntervalSinceReferenceDate: detectedAt),
                providerSessionID: providerSessionID,
                agentPID: agentPID
            )
        }

        XCTAssertEqual(snapshot().fireGuardKey, snapshot().fireGuardKey)
        XCTAssertNotEqual(
            snapshot(paneID: 7).fireGuardKey,
            snapshot(paneID: 9).fireGuardKey,
            "two agents in identical states must have distinct guard keys"
        )
        XCTAssertNotEqual(
            snapshot(agentPID: 4242).fireGuardKey,
            snapshot(agentPID: 5000).fireGuardKey,
            "a same-pane process replacement is a different incarnation"
        )
        XCTAssertNotEqual(
            snapshot(providerSessionID: "conv-a").fireGuardKey,
            snapshot(providerSessionID: "conv-b").fireGuardKey,
            "a replaced provider conversation is a different incarnation"
        )
        XCTAssertNotEqual(
            snapshot(detectedAt: -60).fireGuardKey,
            snapshot(detectedAt: -1).fireGuardKey,
            "a re-detected agent is a different incarnation"
        )
        XCTAssertNotEqual(
            snapshot(statusChangedAt: 0).fireGuardKey,
            snapshot(statusChangedAt: 9).fireGuardKey,
            "an A→B→A status flip must not compare equal (state epoch)"
        )
    }

    func test_customUnlabeledBindingShowsMacroTextNotDeny() {
        // Regression: labels/tints were direction-derived, so a custom macro
        // bound to left rendered as red "deny" regardless of what it sent.
        let profile = SwipePadProfile(
            id: UUID(),
            name: "shell",
            matchProcess: "",
            bindings: [
                .left: SwipePadBinding(macro: "ls↵"),
            ],
            isBuiltIn: false
        )

        let petals = SwipePadPetalLayout.petals(for: profile)

        XCTAssertEqual(petals.count, 1)
        XCTAssertEqual(petals.first?.label, "ls↵")
        XCTAssertEqual(petals.first?.tint, .neutral)
        XCTAssertEqual(petals.first?.action, .macro("ls↵"))
    }

    // MARK: - Shared classifiers

    func test_negativeLabelClassifierSharedWithAgentCenter() {
        XCTAssertTrue(AgentPromptOption.isNegativeLabel("No"))
        XCTAssertTrue(AgentPromptOption.isNegativeLabel("No, and tell Codex what to do differently"))
        XCTAssertTrue(AgentPromptOption.isNegativeLabel("No, quit"))
        XCTAssertTrue(AgentPromptOption.isNegativeLabel("Deny this request"))
        XCTAssertTrue(AgentPromptOption.isNegativeLabel("Cancel"))
        XCTAssertTrue(AgentPromptOption.isNegativeLabel("Reject all"))
        XCTAssertFalse(AgentPromptOption.isNegativeLabel("Yes"))
        XCTAssertFalse(AgentPromptOption.isNegativeLabel("Not now but proceed"))
        XCTAssertFalse(AgentPromptOption.isNegativeLabel("Note the changes and proceed"))

        let option = AgentPromptOption(id: 3, label: "No", responseMacro: "3↵", isDefault: false)
        XCTAssertTrue(option.isNegativeLabel)
    }

    func test_bindingLabelTintClassification() {
        XCTAssertEqual(SwipePadPetalLayout.tint(forLabel: "approve"), .affirmative)
        XCTAssertEqual(SwipePadPetalLayout.tint(forLabel: "y"), .affirmative)
        XCTAssertEqual(SwipePadPetalLayout.tint(forLabel: "deny"), .negative)
        XCTAssertEqual(SwipePadPetalLayout.tint(forLabel: "esc"), .negative)
        XCTAssertEqual(SwipePadPetalLayout.tint(forLabel: "interrupt"), .negative)
        XCTAssertEqual(SwipePadPetalLayout.tint(forLabel: "always"), .caution)
        XCTAssertEqual(SwipePadPetalLayout.tint(forLabel: "ls↵"), .neutral)
    }

    // MARK: - SwipePadBinding label codability

    func test_bindingDecodesLegacyJSONWithoutLabel() throws {
        let legacy = Data(#"{"macro":"1↵"}"#.utf8)

        let binding = try JSONDecoder().decode(SwipePadBinding.self, from: legacy)

        XCTAssertEqual(binding.macro, "1↵")
        XCTAssertNil(binding.label)
    }

    func test_bindingRoundTripsWithLabel() throws {
        let original = SwipePadBinding(macro: "2↵", label: "deny")

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(SwipePadBinding.self, from: data)

        XCTAssertEqual(decoded, original)
    }

    // MARK: - Regex cache

    func test_regexCacheReturnsSameInstanceAndCachesInvalid() {
        let first = AgentRegexCache.regex("^codex")
        let second = AgentRegexCache.regex("^codex")

        XCTAssertNotNil(first)
        XCTAssertTrue(first === second)
        XCTAssertNil(AgentRegexCache.regex("(unclosed"))
        XCTAssertNil(AgentRegexCache.regex("(unclosed"))
    }
}

// MARK: - Store merge label backfill

@MainActor
final class SwipePadProfileStoreLabelBackfillTests: XCTestCase {
    private let defaultsKey = "tessera.swipePad.profiles"

    func test_legacyStoredBindingsRegainFactoryLabels() throws {
        let previous = UserDefaults.standard.data(forKey: defaultsKey)
        defer {
            if let previous {
                UserDefaults.standard.set(previous, forKey: defaultsKey)
            } else {
                UserDefaults.standard.removeObject(forKey: defaultsKey)
            }
        }

        // Pre-label-era storage: factory macro on right (label key absent in
        // JSON), customized macro on left, up removed by the user.
        var stored = SwipePadProfile.builtInClaudeCode
        stored.bindings = [
            .right: SwipePadBinding(macro: "1↵"),
            .left: SwipePadBinding(macro: "ls↵"),
        ]
        UserDefaults.standard.set(
            try JSONEncoder().encode([stored]),
            forKey: defaultsKey
        )

        let store = SwipePadProfileStore()
        let claude = store.profiles.first {
            $0.id == SwipePadProfile.builtInClaudeCodeID
        }

        XCTAssertEqual(
            claude?.binding(for: .right).label, "approve",
            "unchanged factory macro must regain its semantic label"
        )
        XCTAssertNil(
            claude?.binding(for: .left).label,
            "customized macro must keep reading as its macro text"
        )
        XCTAssertEqual(claude?.binding(for: .left).macro, "ls↵")
        XCTAssertNil(claude?.bindings[.up], "user-removed binding stays removed")
    }

    func test_untouchedLegacyClaudeFactorySetIsUpgraded() throws {
        let previous = UserDefaults.standard.data(forKey: defaultsKey)
        defer {
            if let previous {
                UserDefaults.standard.set(previous, forKey: defaultsKey)
            } else {
                UserDefaults.standard.removeObject(forKey: defaultsKey)
            }
        }

        // The exact pre-2026-08 factory set (deny was 2↵ against a menu
        // Claude later reordered). Never customized ⇒ silently corrected.
        var stored = SwipePadProfile.builtInClaudeCode
        stored.bindings = [
            .right: SwipePadBinding(macro: "1↵"),
            .left: SwipePadBinding(macro: "2↵"),
            .up: SwipePadBinding(macro: "3↵"),
        ]
        UserDefaults.standard.set(
            try JSONEncoder().encode([stored]),
            forKey: defaultsKey
        )

        let store = SwipePadProfileStore()
        let claude = store.profiles.first {
            $0.id == SwipePadProfile.builtInClaudeCodeID
        }

        XCTAssertEqual(claude?.binding(for: .left).macro, "3↵", "deny must send No")
        XCTAssertEqual(claude?.binding(for: .left).label, "deny")
        XCTAssertEqual(claude?.binding(for: .up).macro, "2↵", "always must send sticky consent")
        XCTAssertEqual(claude?.binding(for: .up).label, "always")
    }

    func test_partiallyCustomizedLegacyClaudeSetStillUpgradesUntouchedDirections() throws {
        let previous = UserDefaults.standard.data(forKey: defaultsKey)
        defer {
            if let previous {
                UserDefaults.standard.set(previous, forKey: defaultsKey)
            } else {
                UserDefaults.standard.removeObject(forKey: defaultsKey)
            }
        }

        // Legacy factory macros on right/left/up, plus a user-added `.down`.
        // The whole-map check would see "customized" and keep left=2↵ —
        // which Claude's menu reorder turned into sticky consent on the
        // trained deny gesture. Migration must be per direction.
        var stored = SwipePadProfile.builtInClaudeCode
        stored.bindings = [
            .right: SwipePadBinding(macro: "1↵"),
            .left: SwipePadBinding(macro: "2↵"),
            .up: SwipePadBinding(macro: "3↵"),
            .down: SwipePadBinding(macro: "ls↵"),
        ]
        UserDefaults.standard.set(
            try JSONEncoder().encode([stored]),
            forKey: defaultsKey
        )

        let store = SwipePadProfileStore()
        let claude = store.profiles.first {
            $0.id == SwipePadProfile.builtInClaudeCodeID
        }

        XCTAssertEqual(claude?.binding(for: .left).macro, "3↵", "untouched legacy deny still upgrades")
        XCTAssertEqual(claude?.binding(for: .up).macro, "2↵", "untouched legacy always still upgrades")
        XCTAssertEqual(claude?.binding(for: .down).macro, "ls↵", "real customization survives")
        XCTAssertNil(claude?.binding(for: .down).label)
    }

    func test_genuinelyCustomizedLegacyDirectionIsKeptVerbatim() throws {
        let previous = UserDefaults.standard.data(forKey: defaultsKey)
        defer {
            if let previous {
                UserDefaults.standard.set(previous, forKey: defaultsKey)
            } else {
                UserDefaults.standard.removeObject(forKey: defaultsKey)
            }
        }

        // left was rebound to a non-factory macro — that direction is the
        // user's own and must not be "corrected"; up still carries the
        // legacy factory macro and upgrades.
        var stored = SwipePadProfile.builtInClaudeCode
        stored.bindings = [
            .right: SwipePadBinding(macro: "1↵"),
            .left: SwipePadBinding(macro: "echo hi↵"),
            .up: SwipePadBinding(macro: "3↵"),
        ]
        UserDefaults.standard.set(
            try JSONEncoder().encode([stored]),
            forKey: defaultsKey
        )

        let store = SwipePadProfileStore()
        let claude = store.profiles.first {
            $0.id == SwipePadProfile.builtInClaudeCodeID
        }

        XCTAssertEqual(claude?.binding(for: .left).macro, "echo hi↵")
        XCTAssertNil(claude?.binding(for: .left).label)
        XCTAssertEqual(claude?.binding(for: .up).macro, "2↵")
    }

    func test_duplicateCustomProfileIDsCollapseToFirst() throws {
        let previous = UserDefaults.standard.data(forKey: defaultsKey)
        defer {
            if let previous {
                UserDefaults.standard.set(previous, forKey: defaultsKey)
            } else {
                UserDefaults.standard.removeObject(forKey: defaultsKey)
            }
        }

        let duplicatedID = UUID()
        let first = SwipePadProfile(
            id: duplicatedID,
            name: "mine",
            matchProcess: "vim",
            bindings: [.right: SwipePadBinding(macro: ":w↵")],
            isBuiltIn: false
        )
        var second = first
        second.name = "ghost"
        UserDefaults.standard.set(
            try JSONEncoder().encode([first, second]),
            forKey: defaultsKey
        )

        let store = SwipePadProfileStore()
        let matches = store.profiles.filter { $0.id == duplicatedID }

        XCTAssertEqual(matches.count, 1, "duplicate stored IDs must not survive as ghosts")
        XCTAssertEqual(matches.first?.name, "mine", "first occurrence wins")
    }

    func test_editorStyleLabelLessSaveKeepsFactoryLabels() {
        let previous = UserDefaults.standard.data(forKey: defaultsKey)
        defer {
            if let previous {
                UserDefaults.standard.set(previous, forKey: defaultsKey)
            } else {
                UserDefaults.standard.removeObject(forKey: defaultsKey)
            }
        }
        UserDefaults.standard.removeObject(forKey: defaultsKey)

        let store = SwipePadProfileStore()
        // The profile editor rewrites bindings label-less on every save.
        var edited = SwipePadProfile.builtInClaudeCode
        edited.bindings = edited.bindings.mapValues {
            SwipePadBinding(macro: $0.macro)
        }
        store.upsert(edited)

        let claude = store.profiles.first {
            $0.id == SwipePadProfile.builtInClaudeCodeID
        }
        XCTAssertEqual(
            claude?.binding(for: .left).label, "deny",
            "labels must re-attach at save time, not only at next launch"
        )

        // And the persisted JSON must round-trip with labels intact.
        let reloaded = SwipePadProfileStore()
        XCTAssertEqual(
            reloaded.profiles.first { $0.id == SwipePadProfile.builtInClaudeCodeID }?
                .binding(for: .left).label,
            "deny"
        )
    }
}

// MARK: - Plain-mosh sidecar probe fixtures

/// Live fixtures captured 2026-08-01 from a REAL local mosh session
/// (brew mosh-server 1.4.0 → zsh → tessera shim → provider TUI) by running
/// the exact `SwipePadPlainSSHProcessProbe.makeCommand(rootPID: <mosh-server
/// pid>)` bytes against the running tree — the same command the mosh mount's
/// SwipePad provider now sends over the FileBridge SSH sidecar. Plain mosh
/// can carry neither lifecycle OSC nor shell-integration OSC (the mosh
/// server's emulator consumes unknown OSC before the client sees it), so
/// this probe is the transport's only working process-name source; before it
/// was wired up, both providers failed the live E2E stuck on the generic
/// puck.
final class SwipePadPlainMoshProbeFixtureTests: XCTestCase {
    private let liveCodexTree = """
    40725 40653 S+   ttys002  /opt/homebrew/bi /opt/homebrew/bin/codex --enable hooks
    40855 40725 S    ttys002  /Applications/Ch /Applications/ChatGPT.app/Contents/Resources/cua_node/bin/node_repl
    39815 39812 Ss   ttys002  -zsh             -zsh
    40653 39815 S+   ttys002  /bin/sh          /bin/sh /Users/alice/.config/tessera/bin/codex
    """

    private let liveClaudeTree = """
    41861 39815 S+   ttys002  /bin/sh          /bin/sh /Users/alice/.config/tessera/bin/claude --allow-dangerously-skip-permissions
    41867 41861 S+   ttys002  /Users/alice/.lo /Users/alice/.local/bin/claude --allow-dangerously-skip-permissions
    39815 39812 Ss   ttys002  -zsh             -zsh
    """

    func test_liveMoshCodexTreeResolvesCodexProfile() {
        let names = SwipePadPlainSSHProcessProbe.processNames(from: liveCodexTree)
        let resolved = SwipePadActiveProfileResolver.resolve(
            candidates: SwipePadProfile.allBuiltIns,
            fallback: .fallback,
            processNames: names
        )

        XCTAssertTrue(names.contains("codex"), "probe names were \(names)")
        XCTAssertEqual(resolved.id, SwipePadProfile.builtInCodexCLIID)
    }

    func test_liveMoshClaudeTreeResolvesClaudeProfile() {
        let names = SwipePadPlainSSHProcessProbe.processNames(from: liveClaudeTree)
        let resolved = SwipePadActiveProfileResolver.resolve(
            candidates: SwipePadProfile.allBuiltIns,
            fallback: .fallback,
            processNames: names
        )

        XCTAssertTrue(names.contains("claude"), "probe names were \(names)")
        XCTAssertEqual(resolved.id, SwipePadProfile.builtInClaudeCodeID)
    }

    func test_bareShellMoshTreeStaysOnFallback() {
        let idleTree = "39815 39812 Ss   ttys002  -zsh             -zsh"
        let resolved = SwipePadActiveProfileResolver.resolve(
            candidates: SwipePadProfile.allBuiltIns,
            fallback: .fallback,
            processNames: SwipePadPlainSSHProcessProbe.processNames(from: idleTree)
        )

        XCTAssertEqual(resolved.id, SwipePadProfile.fallbackID)
    }
}

// MARK: - Resolver gates

@MainActor
final class SwipePadResolverGateTests: XCTestCase {
    func test_invalidateClearsRetainedProfile() async {
        let resolver = SwipePadActiveProfileResolver()
        let store = SwipePadProfileStore()

        await withCheckedContinuation { continuation in
            resolver.resolveActiveProfile(
                tmux: TmuxController(),
                store: store,
                processNameProvider: { ["claude"] }
            ) { _ in continuation.resume() }
        }
        XCTAssertEqual(
            resolver.currentProfile?.id,
            SwipePadProfile.builtInClaudeCodeID
        )

        resolver.invalidate(reason: "test")

        XCTAssertNil(
            resolver.currentProfile,
            "hook-loss must forget the previous program's profile, not retain it as fireable"
        )
    }

    func test_suspendedRefreshNeverQueriesTheProvider() async {
        let resolver = SwipePadActiveProfileResolver()
        let store = SwipePadProfileStore()
        var providerCalls = 0

        resolver.setSuspended(true)
        resolver.refresh(
            tmux: TmuxController(),
            store: store,
            processNameProvider: {
                providerCalls += 1
                return ["claude"]
            }
        )
        // Any provider work would be scheduled on the main actor; drain it.
        await Task.yield()
        await Task.yield()

        XCTAssertEqual(providerCalls, 0, "closed gates must drop queued refreshes, not defer them")
        XCTAssertNil(resolver.currentProfile)
    }

    func test_resolveInFlightDuringInvalidateDoesNotRepublishStaleProfile() async {
        let resolver = SwipePadActiveProfileResolver()
        let store = SwipePadProfileStore()

        // The invalidation lands while the query is in flight (inside the
        // provider). The completion still fires — the gesture in progress
        // needs its answer — but nothing may be published: republishing
        // would re-install exactly the stale state invalidate() cleared.
        await withCheckedContinuation { continuation in
            resolver.resolveActiveProfile(
                tmux: TmuxController(),
                store: store,
                processNameProvider: {
                    resolver.invalidate(reason: "mid-flight")
                    return ["claude"]
                }
            ) { resolved in
                XCTAssertEqual(resolved.id, SwipePadProfile.builtInClaudeCodeID)
                continuation.resume()
            }
        }

        XCTAssertNil(resolver.currentProfile)
    }

    // MARK: - VoiceOver fallback origin token (R3-F2)

    private func claudePetalFixture(
        store: SwipePadProfileStore
    ) -> (profile: SwipePadProfile, model: SwipePadPetalModel)? {
        guard let profile = store.profiles.first(where: {
            $0.id == SwipePadProfile.builtInClaudeCodeID
        }),
              let model = SwipePadPetalLayout.petals(for: profile).first
        else { return nil }
        return (profile, model)
    }

    func test_fallbackActionRefusesWhenSurfaceSuspendedMidFlight() async {
        let resolver = SwipePadActiveProfileResolver()
        let store = SwipePadProfileStore()
        let tmux = TmuxController()
        guard let origin = SwipePadAccessibilityFallbackGate.captureOrigin(
            resolver: resolver,
            tmux: tmux
        ) else {
            return XCTFail("a live surface must yield an origin token")
        }
        guard let (_, model) = claudePetalFixture(store: store) else {
            return XCTFail("built-in claude profile must offer petals")
        }

        let reason: String? = await withCheckedContinuation { continuation in
            resolver.resolveActiveProfile(
                tmux: tmux,
                store: store,
                processNameProvider: {
                    // The gate closes while the provider query is in
                    // flight: the session hid, the app backgrounded, or
                    // hook proof arrived — the overlay folds all three
                    // into suspension.
                    resolver.setSuspended(true)
                    return ["claude"]
                }
            ) { resolved in
                continuation.resume(
                    returning: SwipePadAccessibilityFallbackGate.refusalReason(
                        origin: origin,
                        current: SwipePadAccessibilityFallbackGate.captureOrigin(
                            resolver: resolver,
                            tmux: tmux
                        ),
                        liveHookSnapshot: nil,
                        resolvedProfile: resolved,
                        model: model
                    )
                )
            }
        }

        XCTAssertEqual(
            reason,
            "surface-inactive",
            "an equal resolved binding must not fire into a surface that went inactive mid-flight"
        )
    }

    func test_fallbackActionRefusesWhenInvalidatedMidFlight() async {
        let resolver = SwipePadActiveProfileResolver()
        let store = SwipePadProfileStore()
        let tmux = TmuxController()
        guard let origin = SwipePadAccessibilityFallbackGate.captureOrigin(
            resolver: resolver,
            tmux: tmux
        ) else {
            return XCTFail("a live surface must yield an origin token")
        }
        guard let (_, model) = claudePetalFixture(store: store) else {
            return XCTFail("built-in claude profile must offer petals")
        }

        let reason: String? = await withCheckedContinuation { continuation in
            resolver.resolveActiveProfile(
                tmux: tmux,
                store: store,
                processNameProvider: {
                    resolver.invalidate(reason: "focus-transition")
                    return ["claude"]
                }
            ) { resolved in
                continuation.resume(
                    returning: SwipePadAccessibilityFallbackGate.refusalReason(
                        origin: origin,
                        current: SwipePadAccessibilityFallbackGate.captureOrigin(
                            resolver: resolver,
                            tmux: tmux
                        ),
                        liveHookSnapshot: nil,
                        resolvedProfile: resolved,
                        model: model
                    )
                )
            }
        }

        XCTAssertEqual(
            reason,
            "state-invalidated",
            "a completion from before an invalidation describes a surface that no longer exists"
        )
    }

    func test_fallbackActionRefusesWhenTmuxFocusMovesBeforeCompletion() {
        let store = SwipePadProfileStore()
        guard let (profile, model) = claudePetalFixture(store: store) else {
            return XCTFail("built-in claude profile must offer petals")
        }
        let origin = SwipePadAccessibilityOrigin(
            tmuxMode: .tmuxControl,
            paneID: PaneId(7),
            resolutionEpoch: 3
        )

        XCTAssertNil(
            SwipePadAccessibilityFallbackGate.refusalReason(
                origin: origin,
                current: origin,
                liveHookSnapshot: nil,
                resolvedProfile: profile,
                model: model
            ),
            "an unchanged origin with an equal binding fires"
        )
        XCTAssertEqual(
            SwipePadAccessibilityFallbackGate.refusalReason(
                origin: origin,
                current: SwipePadAccessibilityOrigin(
                    tmuxMode: .tmuxControl,
                    paneID: PaneId(9),
                    resolutionEpoch: 3
                ),
                liveHookSnapshot: nil,
                resolvedProfile: profile,
                model: model
            ),
            "focus-changed",
            "the resolver retries an in-flight query against the NEW pane; its answer must not fire there"
        )
        XCTAssertEqual(
            SwipePadAccessibilityFallbackGate.refusalReason(
                origin: origin,
                current: SwipePadAccessibilityOrigin(
                    tmuxMode: .passthrough,
                    paneID: nil,
                    resolutionEpoch: 3
                ),
                liveHookSnapshot: nil,
                resolvedProfile: profile,
                model: model
            ),
            "focus-changed",
            "a tmux attach/detach mid-flight is a focus change too"
        )
    }

    func test_fallbackActionRefusesWhenHookModeStartsOrBindingDisappears() {
        let store = SwipePadProfileStore()
        guard let (profile, model) = claudePetalFixture(store: store) else {
            return XCTFail("built-in claude profile must offer petals")
        }
        let origin = SwipePadAccessibilityOrigin(
            tmuxMode: .passthrough,
            paneID: nil,
            resolutionEpoch: 0
        )
        let hookSnapshot = SwipePadAgentSnapshot(
            agentID: AgentInstanceID(sessionID: UUID(), paneID: 7),
            profileID: profile.id,
            profileName: profile.name,
            status: .working,
            prompt: nil,
            statusChangedAt: .now,
            detectedAt: .now,
            providerSessionID: "conversation",
            agentPID: 4242
        )

        XCTAssertEqual(
            SwipePadAccessibilityFallbackGate.refusalReason(
                origin: origin,
                current: origin,
                liveHookSnapshot: hookSnapshot,
                resolvedProfile: profile,
                model: model
            ),
            "hook-mode-started",
            "a fallback action never fires once live hook state owns the pad"
        )
        let fallbackProfile = store.profiles.first(where: {
            $0.id == SwipePadProfile.fallbackID
        }) ?? SwipePadProfile.fallback
        XCTAssertEqual(
            SwipePadAccessibilityFallbackGate.refusalReason(
                origin: origin,
                current: origin,
                liveHookSnapshot: nil,
                resolvedProfile: fallbackProfile,
                model: model
            ),
            "foreground-changed",
            "the freshly resolved foreground must still offer the exact binding"
        )
    }
}

// MARK: - Projection

@MainActor
final class SwipePadAgentContextTests: XCTestCase {
    private func waitingAgent(
        sessionID: UUID,
        paneID: Int = 7,
        status: AgentStatus = .waitingForInput
    ) -> AgentInstance {
        let now = Date.now
        return AgentCenterHarnessFixtures.make(
            sessionID: sessionID,
            paneID: paneID,
            profileID: SwipePadProfile.builtInClaudeCodeID,
            name: "Claude Code",
            host: "devbox",
            transport: "ssh+tmux",
            tmuxSession: "work",
            windowID: 1,
            windowName: "api",
            status: status,
            tail: "Do you want to proceed?",
            prompt: status == .waitingForInput
                ? AgentPrompt(
                    signature: "proceed?",
                    summary: "Do you want to proceed?",
                    options: [
                        AgentPromptOption(id: 1, label: "Yes", responseMacro: "1↵", isDefault: true),
                        AgentPromptOption(id: 2, label: "No", responseMacro: "2↵", isDefault: false),
                    ]
                )
                : nil,
            detectedAt: now.addingTimeInterval(-60),
            statusChangedAt: now.addingTimeInterval(-5),
            lastOutputAt: now.addingTimeInterval(-5)
        )
    }

    func test_activeHookProofPublishesSnapshotForFocusedPane() {
        let sessionID = UUID()
        let agent = waitingAgent(sessionID: sessionID)
        let center = AgentCenter()
        center.installHarnessAgents([agent])
        center.installHarnessLifecycleIntegrationState(.active, for: agent.id)

        let context = center.swipePadContext(sessionID: sessionID)
        XCTAssertNil(context.snapshot, "no focus reported yet")

        center.setSwipePadFocus(sessionID: sessionID, paneID: 7)

        XCTAssertEqual(context.snapshot?.agentID, agent.id)
        XCTAssertEqual(context.snapshot?.status, .waitingForInput)
        XCTAssertEqual(context.snapshot?.prompt?.options.count, 2)
        XCTAssertEqual(context.snapshot?.profileName, "Claude Code")
    }

    func test_lifecycleEventRotatesProviderSessionInFireGuard() {
        let sessionID = UUID()
        let agent = waitingAgent(sessionID: sessionID, status: .working)
        let center = AgentCenter()
        center.installHarnessAgents([agent])
        center.installHarnessLifecycleIntegrationState(.active, for: agent.id)
        center.setSwipePadFocus(sessionID: sessionID, paneID: 7)
        let context = center.swipePadContext(sessionID: sessionID)

        let before = context.snapshot
        XCTAssertNotNil(before)

        // Same pane, same process, same visible status — only the provider
        // conversation changed (resume / new thread). Exercises the REAL
        // acceptance path (applyLifecycleEvent → finishApplying → card →
        // snapshot republish): the card must adopt the event's session so
        // the fire-guard incarnation rotates before any discovery rebuild.
        let event = AgentLifecycleEvent(
            version: AgentLifecycleEvent.supportedVersion,
            provider: "claude",
            event: "PreToolUse",
            state: .working,
            reason: "",
            timestampNanoseconds: UInt64(Date.now.timeIntervalSince1970 * 1_000_000_000),
            providerSessionID: "conversation-after-resume",
            turnID: "turn-2",
            notificationType: "",
            permissionMode: "",
            agentPID: 4242
        )
        XCTAssertTrue(center.harnessApplyLifecycleEvent(event, to: agent.id))

        let after = context.snapshot
        XCTAssertEqual(after?.providerSessionID, "conversation-after-resume")
        XCTAssertNotEqual(
            before?.fireGuardKey,
            after?.fireGuardKey,
            "a same-status conversation swap must never leave the guard key unchanged"
        )
    }

    func test_statusNeutralProviderSessionSurvivesObservationRebuild() {
        let sessionID = UUID()
        let agent = waitingAgent(sessionID: sessionID, status: .working)
        let center = AgentCenter()
        center.installHarnessAgents([agent])
        center.installHarnessLifecycleIntegrationState(.active, for: agent.id)
        center.setSwipePadFocus(sessionID: sessionID, paneID: 7)
        let context = center.swipePadContext(sessionID: sessionID)

        let baseNanoseconds = UInt64(Date.now.timeIntervalSince1970 * 1_000_000_000)
        let rootEvent = AgentLifecycleEvent(
            version: AgentLifecycleEvent.supportedVersion,
            provider: "claude",
            event: "PreToolUse",
            state: .working,
            reason: "",
            timestampNanoseconds: baseNanoseconds,
            providerSessionID: "conversation-a",
            turnID: "turn-1",
            notificationType: "",
            permissionMode: "",
            agentPID: 4242
        )
        XCTAssertTrue(center.harnessApplyLifecycleEvent(rootEvent, to: agent.id))
        XCTAssertEqual(context.snapshot?.providerSessionID, "conversation-a")

        // R3-F1 step 1: the FIRST accepted proof of the new conversation is
        // status-neutral. SubagentStop cannot answer whether the root turn
        // stopped, so it never becomes the root-status event — but it does
        // carry the new session, and the card adopts it directly.
        let neutralEvent = AgentLifecycleEvent(
            version: AgentLifecycleEvent.supportedVersion,
            provider: "claude",
            event: "SubagentStop",
            state: .working,
            reason: "",
            timestampNanoseconds: baseNanoseconds + 1_000_000_000,
            providerSessionID: "conversation-b",
            turnID: "turn-2",
            notificationType: "",
            permissionMode: "",
            agentPID: 4242
        )
        XCTAssertTrue(center.harnessApplyLifecycleEvent(neutralEvent, to: agent.id))
        let adopted = context.snapshot
        XCTAssertEqual(adopted?.providerSessionID, "conversation-b")

        // R3-F1 step 2: the next terminal observation rebuilds the card.
        // The candidate selector rightly prefers the older non-neutral
        // root event for STATUS (retained neutral vs streamed non-neutral);
        // it must not also revert the conversation to A — that would
        // re-validate a press begun on A against conversation B (the
        // A→B→A guard hole).
        let location = AgentLocation(
            sessionID: sessionID,
            hostName: "devbox",
            transportLabel: "ssh+tmux",
            tmuxSessionName: "work",
            windowID: 1,
            windowName: "api",
            paneID: 7
        )
        center.harnessReplaceAgents(
            sessionID: sessionID,
            probes: [
                AgentProbeTarget(
                    location: location,
                    processNames: ["claude"],
                    processIDs: [4242],
                    visibleText: nil,
                    lifecycleEvent: neutralEvent,
                    bracketedPasteEnabled: false
                )
            ]
        )

        let rebuilt = context.snapshot
        XCTAssertEqual(
            rebuilt?.providerSessionID,
            "conversation-b",
            "a rebuild must keep the newest accepted conversation, not the root-status event's older one"
        )
        XCTAssertEqual(
            rebuilt?.fireGuardKey,
            adopted?.fireGuardKey,
            "an unchanged world must not rotate the guard key back (A→B→A)"
        )
    }

    func test_installationStatusAloneNeverEnablesHookMode() {
        let sessionID = UUID()
        let agent = waitingAgent(sessionID: sessionID)
        let center = AgentCenter()
        center.installHarnessAgents([agent])
        let context = center.swipePadContext(sessionID: sessionID)
        center.setSwipePadFocus(sessionID: sessionID, paneID: 7)

        for state: AgentLifecycleIntegrationState in [
            .checking, .notChecked, .checkUnavailable,
            .notInstalled, .installedInactive, .outdated(version: 3),
        ] {
            center.installHarnessLifecycleIntegrationState(state, for: agent.id)
            XCTAssertNil(context.snapshot, "state \(state) must stay fallback")
        }

        center.installHarnessLifecycleIntegrationState(.active, for: agent.id)
        XCTAssertNotNil(context.snapshot)
    }

    func test_focusOnPaneWithoutAgentPublishesNil() {
        let sessionID = UUID()
        let agent = waitingAgent(sessionID: sessionID)
        let center = AgentCenter()
        center.installHarnessAgents([agent])
        center.installHarnessLifecycleIntegrationState(.active, for: agent.id)
        let context = center.swipePadContext(sessionID: sessionID)

        center.setSwipePadFocus(sessionID: sessionID, paneID: 7)
        XCTAssertNotNil(context.snapshot)

        center.setSwipePadFocus(sessionID: sessionID, paneID: 99)
        XCTAssertNil(context.snapshot, "vim pane / plain shell must fall back")
    }

    func test_disablingAgentCenterPublishesNil() {
        let sessionID = UUID()
        let agent = waitingAgent(sessionID: sessionID)
        let center = AgentCenter()
        center.installHarnessAgents([agent])
        center.installHarnessLifecycleIntegrationState(.active, for: agent.id)
        let context = center.swipePadContext(sessionID: sessionID)
        center.setSwipePadFocus(sessionID: sessionID, paneID: 7)
        XCTAssertNotNil(context.snapshot)

        center.setEnabled(false)

        XCTAssertNil(context.snapshot)
    }

    func test_identicalRepublishDoesNotInvalidateObservers() {
        let sessionID = UUID()
        let agent = waitingAgent(sessionID: sessionID)
        let center = AgentCenter()
        center.installHarnessAgents([agent])
        center.installHarnessLifecycleIntegrationState(.active, for: agent.id)
        let context = center.swipePadContext(sessionID: sessionID)
        center.setSwipePadFocus(sessionID: sessionID, paneID: 7)

        // Sendable box: withObservationTracking's onChange is @Sendable, so
        // a captured var would be a Swift 6 error.
        final class Flag: @unchecked Sendable { var value = false }
        let invalidated = Flag()
        withObservationTracking {
            _ = context.snapshot
        } onChange: {
            invalidated.value = true
        }

        // Same content again — the choke point republishes, the equality
        // gate must swallow it.
        center.installHarnessAgents([agent])
        XCTAssertFalse(invalidated.value, "identical snapshot must not invalidate")

        var changed = agent
        changed.status = .working
        changed.prompt = nil
        center.installHarnessAgents([changed])
        XCTAssertTrue(invalidated.value, "real transition must invalidate")
    }

    func test_promptChangeAlonePublishesNewSnapshot() {
        let sessionID = UUID()
        let agent = waitingAgent(sessionID: sessionID)
        let center = AgentCenter()
        center.installHarnessAgents([agent])
        center.installHarnessLifecycleIntegrationState(.active, for: agent.id)
        let context = center.swipePadContext(sessionID: sessionID)
        center.setSwipePadFocus(sessionID: sessionID, paneID: 7)
        XCTAssertEqual(context.snapshot?.prompt?.signature, "proceed?")

        var changed = agent
        changed.prompt = AgentPrompt(
            signature: "different menu",
            summary: "Another question?",
            options: [
                AgentPromptOption(id: 1, label: "Yes", responseMacro: "1↵", isDefault: true)
            ]
        )
        center.installHarnessAgents([changed])

        XCTAssertEqual(
            context.snapshot?.prompt?.signature, "different menu",
            "a prompt swap with unchanged status must republish"
        )
    }
}
