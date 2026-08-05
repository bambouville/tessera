// Tessera/SwipePad/SwipePadPetalLayout.swift
// Pure petal layout: maps live agent prompts, the hook-mode working state,
// and legacy profile bindings onto the four radial directions.
import CoreGraphics
import Foundation

/// Everything a petal needs to render and fire, resolved before the radial
/// opens so the view layer stays dumb. `label` is real text (option label,
/// binding label, or the macro itself) — never a direction-derived name.
struct SwipePadPetalModel: Equatable, Identifiable {
    enum Tint: Equatable {
        case affirmative   // green — accept / default-yes
        case negative      // red — deny / cancel / interrupt
        case caution       // amber — always-allow / don't-ask-again
        case neutral       // monochrome
    }

    enum Action: Equatable {
        /// A MacroEncoder spec to send to the terminal.
        case macro(String)
        /// Open the full prompt UI (Agent Center) — used when a prompt has
        /// more options than the radial can hold.
        case showMore
    }

    let direction: SwipeDirection
    let label: String
    let caption: String
    let action: Action
    let tint: Tint

    var id: SwipeDirection { direction }
}

/// A live prompt can need one non-directional action in addition to its four
/// trained cardinal gestures. `separateMoreCount` asks the puck to expose an
/// explicit tap/accessibility action for the hidden options; it is never a
/// fifth gesture direction and never replaces a configured binding.
struct SwipePadPromptLayout: Equatable {
    let petals: [SwipePadPetalModel]
    let separateMoreCount: Int?
}

/// Pure decision core of the gesture fire guard, extracted from the view's
/// gesture handlers so the safety mechanism is unit-testable.
enum SwipePadFireGuard {
    /// Key to hold when the radial opens (petals become visible). A non-nil
    /// current key re-baselines — the user is seeing the petals of the NEW
    /// state and aims at them. A nil current key (hook proof vanished
    /// between touch-down and radial-open) must NOT overwrite the pressed
    /// key: petals then fall back to the resolver's stale profile, and
    /// baselining nil==nil would fire that stale macro into the new focus.
    static func keyAtRadialOpen(
        currentKey: String?,
        pressedKey: String?
    ) -> String? {
        currentKey ?? pressedKey
    }

    /// A macro fires only when the state the user aimed at is still the
    /// state on screen.
    static func allowsFire(pressedKey: String?, releaseKey: String?) -> Bool {
        pressedKey == releaseKey
    }
}

enum SwipePadPetalLayout {
    struct RadialCenterInsets: Equatable {
        let top: CGFloat
        let leading: CGFloat
        let bottom: CGFloat
        let trailing: CGFloat
    }

    /// Option order → petal position. Order-based on purpose: semantic
    /// re-placement could silently change which bytes a memorized gesture
    /// sends the day a provider reorders its menu. Honest labels + stable
    /// positions instead.
    static let directionOrder: [SwipeDirection] = [.right, .left, .up, .down]

    /// Petals for a confirmed on-screen prompt. A live option whose macro
    /// the profile already binds keeps its trained direction — the radial
    /// only opens after the finger has traveled toward a petal, so a
    /// legacy-trained no-look swipe must keep meaning what it always meant
    /// (Codex's menu order would otherwise put sticky consent on the deny
    /// gesture). Unmatched options fill the remaining directions in menu
    /// order. A menu longer than four shows the first three plus a "more"
    /// petal unless down is itself a trained live option; in that case all
    /// four directions keep their macros and the puck exposes More.
    static func promptLayout(
        for prompt: AgentPrompt,
        profile: SwipePadProfile? = nil
    ) -> SwipePadPromptLayout {
        let options = prompt.options
        let overflowing = options.count > directionOrder.count

        var macroDirection: [String: SwipeDirection] = [:]
        if let profile {
            for direction in SwipeDirection.allCases {
                let binding = profile.binding(for: direction)
                if binding.isBound, macroDirection[binding.macro] == nil {
                    macroDirection[binding.macro] = direction
                }
            }
        }

        // Overflow normally uses down for the zero-byte More petal. If the
        // live menu contains the macro the user explicitly trained to down,
        // that binding wins: all four direction→macro contracts stay intact
        // and More moves to the puck as a separate tap/accessibility action.
        // Matching spans the FULL menu, so a trained option at position 5+
        // cannot disappear merely because it was outside the first four.
        let moreUsesPuck = overflowing && options.contains {
            macroDirection[$0.responseMacro] == .down
        }
        var available = overflowing && !moreUsesPuck
            ? directionOrder.filter { $0 != .down }
            : directionOrder

        var placed: [SwipePadPetalModel] = []
        var untrained: [AgentPromptOption] = []
        for option in options {
            guard let trained = macroDirection[option.responseMacro] else {
                untrained.append(option)
                continue
            }
            if let index = available.firstIndex(of: trained) {
                available.remove(at: index)
                placed.append(petal(option: option, direction: trained))
            } else {
                // Trained direction already claimed (two options sharing a
                // responseMacro) — no trained slot to honor.
                untrained.append(option)
            }
        }
        for option in untrained {
            guard !available.isEmpty else { break }
            placed.append(petal(option: option, direction: available.removeFirst()))
        }

        let hiddenCount = options.count - placed.count
        var separateMoreCount: Int?
        if overflowing {
            if moreUsesPuck {
                separateMoreCount = hiddenCount
            } else {
                placed.append(
                    SwipePadPetalModel(
                        direction: .down,
                        label: "more",
                        caption: "\(hiddenCount) more",
                        action: .showMore,
                        tint: .neutral
                    )
                )
            }
        }
        let sorted = placed.sorted {
            (directionOrder.firstIndex(of: $0.direction) ?? .max)
                < (directionOrder.firstIndex(of: $1.direction) ?? .max)
        }
        return SwipePadPromptLayout(
            petals: sorted,
            separateMoreCount: separateMoreCount
        )
    }

    static func petals(
        for prompt: AgentPrompt,
        profile: SwipePadProfile? = nil
    ) -> [SwipePadPetalModel] {
        promptLayout(for: prompt, profile: profile).petals
    }

    private static func petal(
        option: AgentPromptOption,
        direction: SwipeDirection
    ) -> SwipePadPetalModel {
        SwipePadPetalModel(
            direction: direction,
            label: option.label,
            caption: option.responseMacro,
            action: .macro(option.responseMacro),
            tint: tint(for: option)
        )
    }

    /// Petals for a confirmed blocking prompt whose options could not be
    /// parsed. The parser safety invariant — an unparseable prompt is never
    /// actionable — extends to the pad: no static keymap, no guessed bytes.
    /// The one offer is zero-byte: open the full prompt UI so the amber
    /// ring never solicits a gesture into an empty radial. Down matches the
    /// overflow "more" position, and a trained blind swipe on any other
    /// direction lands on no petal at all instead of a guessed answer.
    static func unparsedPromptPetals() -> [SwipePadPetalModel] {
        [
            SwipePadPetalModel(
                direction: .down,
                label: "options",
                caption: "open",
                action: .showMore,
                tint: .neutral
            )
        ]
    }

    /// The actions that stay meaningful while a hook-proven agent is
    /// working: interrupt (Esc) and mode switching (Shift-Tab) for both
    /// Claude Code and Codex.
    static func workingPetals() -> [SwipePadPetalModel] {
        [
            SwipePadPetalModel(
                direction: .left,
                label: "interrupt",
                caption: "esc",
                action: .macro("esc"),
                tint: .negative
            ),
            modeSwitchPetal()
        ]
    }

    /// A hook-proven composer has one provider-shared mode control:
    /// Shift-Tab cycles mode in both Claude Code and Codex. Hook state keeps
    /// it scoped to known agent surfaces rather than legacy profile matches.
    static func idlePetals() -> [SwipePadPetalModel] {
        [modeSwitchPetal()]
    }

    /// A just-finished agent remains at its composer and exposes the same
    /// provider-shared mode switch as the idle state.
    static func justFinishedPetals() -> [SwipePadPetalModel] {
        [modeSwitchPetal()]
    }

    private static func modeSwitchPetal() -> SwipePadPetalModel {
        SwipePadPetalModel(
            direction: .up,
            label: "switch mode",
            caption: "shift-tab",
            action: .macro("shift-tab"),
            tint: .neutral
        )
    }

    /// Legacy fallback: profile bindings, in the profile's own directions.
    /// The label falls back to the macro text itself, so a custom macro
    /// reads as what it sends instead of inheriting a direction name.
    static func petals(for profile: SwipePadProfile) -> [SwipePadPetalModel] {
        SwipeDirection.allCases.compactMap { direction in
            let binding = profile.binding(for: direction)
            guard binding.isBound else { return nil }
            return SwipePadPetalModel(
                direction: direction,
                label: binding.label ?? binding.macro,
                caption: binding.macro,
                action: .macro(binding.macro),
                tint: binding.label.map(tint(forLabel:)) ?? .neutral
            )
        }
    }

    /// Prompt options share Agent Center's negative classifier so a "deny"
    /// answer tints identically wherever it appears; sticky-consent wording
    /// warrants caution before the default-affirmative check so "don't ask
    /// again" can never read as a plain yes.
    static func tint(for option: AgentPromptOption) -> SwipePadPetalModel.Tint {
        if option.isNegativeLabel { return .negative }
        if isCautionLabel(option.label) { return .caution }
        if option.id == 1 || option.isDefault { return .affirmative }
        return .neutral
    }

    /// Binding labels have no option position, so affirmative is recognized
    /// from wording alone. Classifies only explicit human labels — raw
    /// macro text must never be classified (an `echo yes↵` macro is not an
    /// approval), which is why `petals(for profile:)` passes `.neutral`
    /// for unlabeled bindings.
    static func tint(forLabel label: String) -> SwipePadPetalModel.Tint {
        let lowered = label.lowercased()
        if AgentPromptOption.isNegativeLabel(label)
            || lowered.contains("interrupt")
            || lowered == "esc" {
            return .negative
        }
        if isCautionLabel(label) { return .caution }
        if lowered.contains("approve")
            || lowered.contains("yes")
            || lowered.contains("accept")
            || lowered == "y" {
            return .affirmative
        }
        return .neutral
    }

    private static func isCautionLabel(_ label: String) -> Bool {
        let lowered = label.lowercased()
        return lowered.contains("always")
            || lowered.contains("don't ask")
            || lowered.contains("do not ask")
    }

    // MARK: - Radial geometry

    /// Gap between the puck edge and each petal edge.
    static let petalGap: CGFloat = 28
    /// Width of the label/caption ribbon centered under every petal.
    static let petalCaptionWidth: CGFloat = 148
    /// Vertical room the ribbon needs below a petal's circle.
    static let petalCaptionAllowance: CGFloat = 48
    /// Active petals swell to 1.25× the puck diameter; clamp margins use
    /// the swollen radius so an aimed-at petal cannot swell offscreen.
    static let petalMaxScale: CGFloat = 1.25

    /// Ideal petal-center offset from the puck center. With petal size ==
    /// puck diameter: offset = puck radius + gap + petal radius.
    static func petalOffset(for direction: SwipeDirection, diameter: CGFloat) -> CGSize {
        let r = diameter + petalGap
        switch direction {
        case .up: return CGSize(width: 0, height: -r)
        case .right: return CGSize(width: r, height: 0)
        case .down: return CGSize(width: 0, height: r)
        case .left: return CGSize(width: -r, height: 0)
        }
    }

    /// True when the ideal radial — every petal at its cardinal offset,
    /// swollen, with its caption ribbon — fits the canvas around this puck
    /// position. The radial may ONLY render when this holds: firing derives
    /// the direction from the raw drag vector relative to the puck, so a
    /// petal drawn anywhere outside its own angular sector would make the
    /// user aim (and drag) toward the wrong sector. Translating or clamping
    /// the cluster is therefore never an option; when the radial does not
    /// fit, the pad renders `chipStack` instead, which states each drag
    /// direction explicitly with an arrow rather than implying it by
    /// position.
    static func radialFits(
        directions: [SwipeDirection],
        puckCenter: CGPoint,
        canvasSize: CGSize,
        diameter: CGFloat
    ) -> Bool {
        guard !directions.isEmpty,
              canvasSize.width > 0, canvasSize.height > 0 else { return true }

        let swollenRadius = diameter * petalMaxScale / 2
        let horizontalMargin = max(swollenRadius, petalCaptionWidth / 2) + 4
        let topMargin = swollenRadius + 4
        let bottomMargin = swollenRadius + petalCaptionAllowance

        for direction in directions {
            let offset = petalOffset(for: direction, diameter: diameter)
            let center = CGPoint(
                x: puckCenter.x + offset.width,
                y: puckCenter.y + offset.height
            )
            if center.x - horizontalMargin < 0 { return false }
            if center.x + horizontalMargin > canvasSize.width { return false }
            if center.y - topMargin < 0 { return false }
            if center.y + bottomMargin > canvasSize.height { return false }
        }
        return true
    }

    /// Minimum distance from each canvas edge to the puck center that keeps
    /// every requested radial petal, its active swell, and its caption fully
    /// visible. Corner defaults use these values so opening the pad does not
    /// immediately fall back to direction rows merely because of its home
    /// position.
    static func radialCenterInsets(
        directions: [SwipeDirection],
        diameter: CGFloat
    ) -> RadialCenterInsets {
        let puckRadius = diameter / 2
        let swollenRadius = diameter * petalMaxScale / 2
        let horizontalMargin = max(swollenRadius, petalCaptionWidth / 2) + 4
        let topMargin = swollenRadius + 4
        let bottomMargin = swollenRadius + petalCaptionAllowance

        var top = puckRadius
        var leading = puckRadius
        var bottom = puckRadius
        var trailing = puckRadius

        for direction in directions {
            let offset = petalOffset(for: direction, diameter: diameter)
            leading = max(leading, horizontalMargin - offset.width)
            trailing = max(trailing, horizontalMargin + offset.width)
            top = max(top, topMargin - offset.height)
            bottom = max(bottom, bottomMargin + offset.height)
        }

        return RadialCenterInsets(
            top: top,
            leading: leading,
            bottom: bottom,
            trailing: trailing
        )
    }

    // MARK: - Corner fan geometry

    /// Canvas quadrant the puck occupies; the fan opens toward the opposite
    /// (inward) quadrant. Chosen by canvas halves so the orientation is
    /// discrete and stable — petal slots never rotate continuously with
    /// puck position.
    enum FanQuadrant: String, CaseIterable, Equatable {
        case topLeft, topRight, bottomLeft, bottomRight
    }

    /// How an open radial presents at the current puck position, in strict
    /// preference order: the full cross wherever it fits (all four cardinals
    /// truthful), else the 90° corner fan, else the chip rows for geometry
    /// neither can serve (degenerate canvases).
    enum RadialPresentation: Equatable {
        case cross
        case fan(FanQuadrant)
        case chips
    }

    static func presentation(
        directions: [SwipeDirection],
        puckCenter: CGPoint,
        canvasSize: CGSize,
        diameter: CGFloat
    ) -> RadialPresentation {
        if radialFits(
            directions: directions,
            puckCenter: puckCenter,
            canvasSize: canvasSize,
            diameter: diameter
        ) {
            return .cross
        }
        let quadrant = fanQuadrant(puckCenter: puckCenter, canvasSize: canvasSize)
        if fanFits(
            directions: directions,
            quadrant: quadrant,
            puckCenter: puckCenter,
            canvasSize: canvasSize,
            puckDiameter: diameter
        ) {
            return .fan(quadrant)
        }
        return .chips
    }

    static func fanQuadrant(puckCenter: CGPoint, canvasSize: CGSize) -> FanQuadrant {
        let right = puckCenter.x > canvasSize.width / 2
        let bottom = puckCenter.y > canvasSize.height / 2
        switch (right, bottom) {
        case (false, false): return .topLeft
        case (true, false): return .topRight
        case (false, true): return .bottomLeft
        case (true, true): return .bottomRight
        }
    }

    /// Fan petals shrink below the puck so the 90° arc stays compact on a
    /// phone canvas (52 → 44).
    static func fanPetalDiameter(puckDiameter: CGFloat) -> CGFloat {
        (puckDiameter * 0.85).rounded()
    }

    /// Petal slots sit 30° apart, so four span exactly the inward quadrant.
    static let fanSlotSpacing: CGFloat = 30

    /// Radius that keeps ~10 pt between adjacent petal edges at 30° spacing:
    /// chord(30°) = 2·R·sin(15°) = petal + 10. For the phone's Ø44 petals
    /// this lands on R 104 (vs the cross's 80 offset).
    static func fanRadius(petalDiameter: CGFloat) -> CGFloat {
        ((petalDiameter + 10) / (2 * sin(15 * CGFloat.pi / 180))).rounded()
    }

    /// Direction → math angle (degrees, y-up) per quadrant. The two
    /// cardinals that still point on-screen keep their exact axes at the
    /// fan ends; the two off-screen cardinals fill the middle slots in
    /// clockwise compass order (up → right → down → left). Quadrants are
    /// mirror images of each other, so aim knowledge transfers.
    static func fanAngles(for quadrant: FanQuadrant) -> [SwipeDirection: CGFloat] {
        switch quadrant {
        case .bottomRight: return [.up: 90, .right: 120, .down: 150, .left: 180]
        case .bottomLeft: return [.right: 0, .down: 30, .left: 60, .up: 90]
        case .topRight: return [.left: 180, .up: 210, .right: 240, .down: 270]
        case .topLeft: return [.down: 270, .left: 300, .up: 330, .right: 360]
        }
    }

    /// Occupied fan slots stay contiguous. Filtering the fixed four-slot map
    /// used to leave a conspicuous empty slot whenever a menu exposed fewer
    /// than four directions; pack the surviving directions at the same 30°
    /// cadence and center the group on the inward quadrant's bisector.
    static func fanAngles(
        for directions: [SwipeDirection],
        quadrant: FanQuadrant
    ) -> [SwipeDirection: CGFloat] {
        let canonical = fanAngles(for: quadrant)
        let ordered = Set(directions).sorted {
            (canonical[$0] ?? 0) < (canonical[$1] ?? 0)
        }
        guard !ordered.isEmpty else { return [:] }

        let canonicalAngles = canonical.values.sorted()
        guard let minimum = canonicalAngles.first,
              let maximum = canonicalAngles.last else { return [:] }
        let bisector = (minimum + maximum) / 2
        let first = bisector - fanSlotSpacing * CGFloat(ordered.count - 1) / 2
        return Dictionary(uniqueKeysWithValues: ordered.enumerated().map { index, direction in
            (direction, first + CGFloat(index) * fanSlotSpacing)
        })
    }

    private static func polarOffset(angleDegrees: CGFloat, radius: CGFloat) -> CGSize {
        let radians = angleDegrees * CGFloat.pi / 180
        return CGSize(width: radius * cos(radians), height: -radius * sin(radians))
    }

    static func fanPetalOffset(
        for direction: SwipeDirection,
        directions: [SwipeDirection] = directionOrder,
        quadrant: FanQuadrant,
        puckDiameter: CGFloat
    ) -> CGSize {
        let petal = fanPetalDiameter(puckDiameter: puckDiameter)
        guard let angle = fanAngles(for: directions, quadrant: quadrant)[direction] else {
            return .zero
        }
        return polarOffset(angleDegrees: angle, radius: fanRadius(petalDiameter: petal))
    }

    /// True when every requested petal's idle disc fits on canvas at its
    /// slot. Deliberately tolerant of the active swell clipping a few
    /// points at flush-dragged positions: unlike a translated petal, a
    /// clipped swell cannot misdirect aim — the disc stays centered in its
    /// own angular sector — and demanding swell room would snap the pad to
    /// chip rows at exactly the flush corners the fan exists for.
    static func fanFits(
        directions: [SwipeDirection],
        quadrant: FanQuadrant,
        puckCenter: CGPoint,
        canvasSize: CGSize,
        puckDiameter: CGFloat
    ) -> Bool {
        guard !directions.isEmpty,
              canvasSize.width > 0, canvasSize.height > 0 else { return true }
        let margin = fanPetalDiameter(puckDiameter: puckDiameter) / 2
        for direction in directions {
            let offset = fanPetalOffset(
                for: direction,
                directions: directions,
                quadrant: quadrant,
                puckDiameter: puckDiameter
            )
            let center = CGPoint(
                x: puckCenter.x + offset.width,
                y: puckCenter.y + offset.height
            )
            if center.x - margin < 0 { return false }
            if center.x + margin > canvasSize.width { return false }
            if center.y - margin < 0 { return false }
            if center.y + margin > canvasSize.height { return false }
        }
        return true
    }

    /// Corner-home inset (puck center to the two nearest edges) that keeps
    /// the fan's edge-axis petals fully visible *including* their swell —
    /// homes never rest in the tolerance zone `fanFits` allows for
    /// user-dragged positions.
    static func fanCornerInset(puckDiameter: CGFloat) -> CGFloat {
        (fanPetalDiameter(puckDiameter: puckDiameter) * petalMaxScale / 2 + 4)
            .rounded(.up)
    }

    /// Firing sector for fan mode: the nearest slot within ±15°. Outside
    /// the fan's arc (plus that tolerance) there is no petal and no fire —
    /// the exact analogue of the cross's quadrant math. Iteration is
    /// angle-sorted so an exact between-slots tie resolves
    /// deterministically to the lower slot.
    static func fanDirection(
        for translation: CGSize,
        directions: [SwipeDirection] = directionOrder,
        quadrant: FanQuadrant
    ) -> SwipeDirection? {
        guard translation != .zero else { return nil }
        let degrees = atan2(-translation.height, translation.width) * 180 / CGFloat.pi
        var best: (direction: SwipeDirection, distance: CGFloat)?
        for (direction, slot) in fanAngles(
            for: directions,
            quadrant: quadrant
        ).sorted(by: { $0.value < $1.value }) {
            let raw = abs(degrees - slot).truncatingRemainder(dividingBy: 360)
            let distance = min(raw, 360 - raw)
            if best == nil || distance < best!.distance {
                best = (direction, distance)
            }
        }
        guard let best, best.distance <= fanSlotSpacing / 2 else { return nil }
        return best.direction
    }

    // MARK: - Fan labels / readout

    /// Fan petals carry a compact two-line ribbon (the cross's 148 pt
    /// ribbon cannot fit between 30° slots); the aimed petal's full text
    /// appears in the readout pill instead.
    static let fanLabelWidth: CGFloat = 68
    static let fanReadoutMaxWidth: CGFloat = 220

    /// Mini-label center offset from the puck: radially outward of its
    /// petal, then clamped fully on-canvas (labels are informational — a
    /// shifted label cannot misdirect aim the way a shifted petal would).
    static func fanLabelOffset(
        for direction: SwipeDirection,
        directions: [SwipeDirection] = directionOrder,
        quadrant: FanQuadrant,
        puckDiameter: CGFloat,
        puckCenter: CGPoint,
        canvasSize: CGSize
    ) -> CGSize {
        let petal = fanPetalDiameter(puckDiameter: puckDiameter)
        guard let angle = fanAngles(for: directions, quadrant: quadrant)[direction] else {
            return .zero
        }
        // Center radius chosen so the ribbon's inner edge clears the petal
        // even at full label width — a centered-at-fixed-radius ribbon would
        // reach back over the petal's outer half.
        let radius = fanRadius(petalDiameter: petal) + petal / 2 + fanLabelWidth / 2 + 6
        let offset = polarOffset(angleDegrees: angle, radius: radius)
        let center = clampedOnCanvas(
            CGPoint(x: puckCenter.x + offset.width, y: puckCenter.y + offset.height),
            halfWidth: fanLabelWidth / 2 + 4,
            halfHeight: 18,
            canvasSize: canvasSize
        )
        return CGSize(width: center.x - puckCenter.x, height: center.y - puckCenter.y)
    }

    /// Readout pill center offset from the puck: on the fan's bisector,
    /// past the mini-labels, clamped on-canvas.
    static func fanReadoutOffset(
        quadrant: FanQuadrant,
        puckDiameter: CGFloat,
        puckCenter: CGPoint,
        canvasSize: CGSize
    ) -> CGSize {
        let petal = fanPetalDiameter(puckDiameter: puckDiameter)
        let angles = fanAngles(for: quadrant).values
        let bisector = (angles.min()! + angles.max()!) / 2
        let radius = fanRadius(petalDiameter: petal) + 106
        let offset = polarOffset(angleDegrees: bisector, radius: radius)
        let center = clampedOnCanvas(
            CGPoint(x: puckCenter.x + offset.width, y: puckCenter.y + offset.height),
            halfWidth: fanReadoutMaxWidth / 2 + 8,
            halfHeight: 30,
            canvasSize: canvasSize
        )
        return CGSize(width: center.x - puckCenter.x, height: center.y - puckCenter.y)
    }

    private static func clampedOnCanvas(
        _ point: CGPoint,
        halfWidth: CGFloat,
        halfHeight: CGFloat,
        canvasSize: CGSize
    ) -> CGPoint {
        var clamped = point
        if halfWidth <= canvasSize.width - halfWidth {
            clamped.x = min(max(clamped.x, halfWidth), canvasSize.width - halfWidth)
        }
        if halfHeight <= canvasSize.height - halfHeight {
            clamped.y = min(max(clamped.y, halfHeight), canvasSize.height - halfHeight)
        }
        return clamped
    }

    // MARK: - Chip-stack geometry (edge fallback)

    /// Chip rows replace the radial near canvas edges after the user moves
    /// the puck there. Each row names its drag direction with an arrow glyph,
    /// so the visuals stay honest at positions where an in-sector petal
    /// cannot physically fit.
    static let chipWidth: CGFloat = 236
    static let chipRowHeight: CGFloat = 44
    static let chipRowSpacing: CGFloat = 6
    /// Gap between the puck edge and the near edge of the chip stack.
    static let chipGap: CGFloat = 24
    static let chipCanvasMargin: CGFloat = 8

    static func chipStackSize(petalCount: Int) -> CGSize {
        guard petalCount > 0 else { return .zero }
        let rows = CGFloat(petalCount)
        return CGSize(
            width: chipWidth,
            height: rows * chipRowHeight + (rows - 1) * chipRowSpacing
        )
    }

    /// Offset from the puck center to the chip stack's center: beside the
    /// puck on its inward side, vertically centered on it, then clamped so
    /// the whole stack stays on-canvas.
    static func chipStackCenterOffset(
        petalCount: Int,
        puckCenter: CGPoint,
        canvasSize: CGSize,
        diameter: CGFloat
    ) -> CGSize {
        let size = chipStackSize(petalCount: petalCount)
        guard size != .zero else { return .zero }

        let side: CGFloat = puckCenter.x > canvasSize.width / 2 ? -1 : 1
        var centerX = puckCenter.x + side * (diameter / 2 + chipGap + size.width / 2)
        var centerY = puckCenter.y

        let minX = chipCanvasMargin + size.width / 2
        let maxX = canvasSize.width - chipCanvasMargin - size.width / 2
        let minY = chipCanvasMargin + size.height / 2
        let maxY = canvasSize.height - chipCanvasMargin - size.height / 2
        if minX <= maxX { centerX = min(max(centerX, minX), maxX) }
        if minY <= maxY { centerY = min(max(centerY, minY), maxY) }

        return CGSize(
            width: centerX - puckCenter.x,
            height: centerY - puckCenter.y
        )
    }
}
