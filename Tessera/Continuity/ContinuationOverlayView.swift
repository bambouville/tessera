import Foundation
import Security
import Observation
import SwiftUI
import UIKit
import SwiftTerm
import TmuxControl

enum ContinuationOverlayPhase: Equatable, Sendable {
    case resolving
    case connecting
    case attached
    case failed(String)
}

struct ContinuationOverlayPresentation: Identifiable, Equatable, Sendable {
    let id: UUID
    let descriptor: SessionActivityDescriptor
    var phase: ContinuationOverlayPhase

    init(
        id: UUID = UUID(),
        descriptor: SessionActivityDescriptor,
        phase: ContinuationOverlayPhase = .resolving
    ) {
        self.id = id
        self.descriptor = descriptor
        self.phase = phase
    }
}

struct ContinuationOverlayView: View {
    let presentation: ContinuationOverlayPresentation
    let onDismiss: () -> Void

    @Environment(\.designTokens) private var T

    var body: some View {
        Group {
            if presentation.phase == .attached {
                attachedToast
            } else {
                blockingOverlay
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var blockingOverlay: some View {
        ZStack {
            Color.black.opacity(0.58)
                .ignoresSafeArea()

            VStack(spacing: 16) {
                statusIcon

                Text(verbatim: title)
                    .font(Typography.tesseraMono(size: 16, weight: .semibold))
                    .foregroundStyle(T.fg)

                Text(verbatim: "\(presentation.descriptor.name) · \(presentation.descriptor.user)@\(presentation.descriptor.address):\(presentation.descriptor.port)")
                    .font(Typography.tesseraMono(size: 11))
                    .foregroundStyle(T.fgMuted)
                    .multilineTextAlignment(.center)

                details

                if canDismiss {
                    Btn(
                        "close",
                        style: .default,
                        full: true,
                        action: onDismiss
                    )
                }
            }
            .padding(22)
            .frame(maxWidth: 420)
            .background(T.panelBg)
            .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .stroke(T.borderStrong, lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.45), radius: 24, y: 12)
            .padding(24)
        }
    }

    private var attachedToast: some View {
        VStack {
            Spacer()
            HStack(spacing: 9) {
                Image(systemName: "rectangle.on.rectangle")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(T.fgMuted)

                Text(verbatim: title)
                    .font(Typography.tesseraMono(size: 11.5, weight: .medium))
                    .foregroundStyle(T.fg)

                Circle()
                    .fill(T.green)
                    .frame(width: 6, height: 6)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial)
            .clipShape(Capsule())
            .overlay {
                Capsule()
                    .stroke(T.borderStrong, lineWidth: 0.5)
            }
            .shadow(color: .black.opacity(0.28), radius: 12, y: 6)
            .padding(.horizontal, 20)
            .padding(.bottom, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch presentation.phase {
        case .resolving, .connecting:
            ProgressView()
                .tint(T.accent)
                .controlSize(.large)
        case .attached:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 34, weight: .medium))
                .foregroundStyle(T.green)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 34, weight: .medium))
                .foregroundStyle(T.amber)
        }
    }

    /// Every phase/action pair is spelled out as a whole sentence rather than
    /// assembled from a stem plus a gerund. Composed sentences cannot be
    /// translated: the fragments inflect with tense, gender, and word order,
    /// and languages that put the verb last have nowhere to insert the stem.
    private var title: String {
        let isContinue = presentation.descriptor.continuationAction == .continueSession
        switch presentation.phase {
        case .resolving:
            return isContinue
                ? String(
                    localized: "preparing to continue from your other device",
                    comment: "Continuity overlay title while the route is being resolved"
                )
                : String(
                    localized: "preparing to reconnect from your other device",
                    comment: "Continuity overlay title while the route is being resolved"
                )
        case .connecting:
            return isContinue
                ? String(
                    localized: "continuing from your other device",
                    comment: "Continuity overlay title while connecting"
                )
                : String(
                    localized: "reconnecting from your other device",
                    comment: "Continuity overlay title while connecting"
                )
        case .attached:
            return isContinue
                ? String(
                    localized: "attached · other device stays attached",
                    comment: "Continuity overlay title once the tmux session is shared with the other device"
                )
                : String(
                    localized: "reconnected on this device",
                    comment: "Continuity overlay title once the session has moved to this device"
                )
        case .failed:
            return isContinue
                ? String(
                    localized: "could not continue",
                    comment: "Continuity overlay title when continuing the session failed"
                )
                : String(
                    localized: "could not reconnect",
                    comment: "Continuity overlay title when reconnecting failed"
                )
        }
    }

    @ViewBuilder
    private var details: some View {
        switch presentation.phase {
        case .failed(let message):
            Text(message)
                .tesseraSansScaled(size: 12)
                .foregroundStyle(T.fgMuted)
                .multilineTextAlignment(.center)
        default:
            VStack(alignment: .leading, spacing: 6) {
                if let tmux = presentation.descriptor.tmuxSessionName {
                    detailRow("tmux attach", verbatimValue: tmux)
                    detailRow("geometry", "fits this device")
                } else {
                    detailRow("remote shell", "new session")
                }
                detailRow("transport", verbatimValue: presentation.descriptor.transport.rawValue)
                detailRow("credentials", "stay on each device")
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(T.inputBg)
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(T.border, lineWidth: 1)
            }
        }
    }

    private func detailRow(_ key: LocalizedStringKey, _ value: LocalizedStringKey) -> some View {
        detailRow(key, valueText: Text(value))
    }

    /// The tmux session name and the transport are literal remote values.
    private func detailRow(_ key: LocalizedStringKey, verbatimValue: String) -> some View {
        detailRow(key, valueText: Text(verbatim: verbatimValue))
    }

    private func detailRow(_ key: LocalizedStringKey, valueText: Text) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(key)
                .foregroundStyle(T.fgDim)
            Spacer(minLength: 8)
            valueText
                .foregroundStyle(T.fgMuted)
                .multilineTextAlignment(.trailing)
        }
        .font(Typography.tesseraMono(size: 10.5))
    }

    private var canDismiss: Bool {
        switch presentation.phase {
        case .failed: true
        case .resolving, .connecting, .attached: false
        }
    }
}

// MARK: - Grid authority (continuity takeover)

/// Stable per-install identity stamped into the tmux `@tessera_authority`
/// option when this device takes the shared grid. The display name is what
/// the *other* device's takeover card shows ("continued on iPhone"), so it
/// stays a generic device-class label, never the user-assigned device name.
enum GridAuthorityDeviceIdentity {
    private static let idKey = "TesseraGridAuthorityDeviceID"

    private static let service = "com.bambouville.Tessera.grid-authority"
    // Lazy static initialization is process-wide and serialized. A failed read
    // keeps one fallback identity for this process, without trusting backup data.
    private static let processID: String = {
        defer { UserDefaults.standard.removeObject(forKey: idKey) }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: idKey,
            kSecAttrSynchronizable as String: false,
        ]
        var read = query
        read[kSecReturnData as String] = true
        read[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(read as CFDictionary, &item)
        if status == errSecSuccess, let data = item as? Data,
           let value = String(data: data, encoding: .utf8), UUID(uuidString: value) != nil {
            return value
        }
        let fresh = UUID().uuidString
        if status == errSecItemNotFound {
            var insert = query
            insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            insert[kSecValueData as String] = Data(fresh.utf8)
            let writeStatus = SecItemAdd(insert as CFDictionary, nil)
            if writeStatus == errSecSuccess { return fresh }
            NSLog("grid authority identity Keychain write failed status=%d; using process UUID", writeStatus)
        } else {
            NSLog("grid authority identity Keychain read failed status=%d; using process UUID", status)
        }
        return fresh
    }()

    static func current() -> TmuxController.GridAuthorityIdentity {
        .init(id: processID, displayName: selfDisplayName)
    }

    static var selfDisplayName: String {
        UIDevice.current.userInterfaceIdiom == .phone ? "iPhone" : "iPad"
    }

    /// The device classes this platform stamps. A peer name outside the set
    /// comes from another platform's install and is not a name this UI can
    /// render as a device.
    static let knownDeviceNames: Set<String> = ["iPhone", "iPad"]

    /// Single entry point for deciding how to name whoever holds the grid. The
    /// policy lives in `TmuxPeerLabel` so Android resolves an unrecognised peer
    /// to the same words rather than printing a foreign stamp verbatim.
    ///
    /// Call sites that have a dedicated localised template per case switch on
    /// this; the rest use `peerLabel`. "another" must not be glued on in Swift
    /// where a translation exists for the whole sentence.
    static func peerKind(_ peerDisplayName: String?) -> TmuxPeerLabel.Kind {
        TmuxPeerLabel.resolve(
            peerDisplayName: peerDisplayName,
            selfDisplayName: selfDisplayName,
            knownDeviceNames: knownDeviceNames
        )
    }

    static func peerLabel(_ peerDisplayName: String?) -> String {
        TmuxPeerLabel.display(
            peerDisplayName: peerDisplayName,
            selfDisplayName: selfDisplayName,
            knownDeviceNames: knownDeviceNames
        )
    }

    static func continuationPeerLabel(_ peerDisplayName: String?) -> String? {
        guard let peerDisplayName, knownDeviceNames.contains(peerDisplayName) else { return nil }
        return peerLabel(peerDisplayName)
    }
}

/// What a veiled session spends while nobody can use it (P9).
enum ContinuedElsewherePresentationPolicy {
    /// How long the veil takes to fade in or out over the terminal.
    static let veilFadeDuration: TimeInterval = 0.35

    /// The terminal under the veil stops drawing once the veil covers it:
    /// compositing a terminal that keeps redrawing under a full-screen
    /// material is the most expensive frame the app produces. Not before:
    /// stopping hides the terminal at once, which would leave the veil
    /// fading in over an empty background. Output is still consumed;
    /// lifting the veil redraws the current buffer at once.
    static func terminalDraws(inherited: Bool, veiled: Bool, veilHasFadedIn: Bool) -> Bool {
        inherited && !(veiled && veilHasFadedIn)
    }

    /// The veil is on screen: it is up, and neither the launch overlay nor
    /// a connection that is not `.connected` outranks it. Both the veil and
    /// the drawing gate key off this, so the terminal never stops drawing
    /// with no veil covering it.
    static func veilIsDrawn(veilUp: Bool, launchOverlayShown: Bool, connected: Bool) -> Bool {
        veilUp && !launchOverlayShown && connected
    }

    /// The veil's breathing glyph runs only on a displayed, unlocked veil in
    /// a foreground app: a hidden tab keeps its veil mounted at opacity 0,
    /// and a repeat-forever animation there, or in the background, redraws
    /// for nobody.
    static func breathes(displayed: Bool, appIsActive: Bool) -> Bool {
        displayed && appIsActive
    }
}

/// Which raise of the veil has finished fading in. Every change of the
/// veil, up or down, starts a new raise, and only the fade of the raise
/// that is current counts. A veil lifted and raised again before the old
/// fade's task ran therefore waits for its own fade, instead of
/// inheriting one that covered a veil since lifted.
struct ContinuedElsewhereVeilFade: Equatable {
    private(set) var raise: UInt64 = 0
    private var fadedInRaise: UInt64?

    /// The veil went up or came down.
    mutating func veilChanged() {
        raise &+= 1
    }

    /// The fade begun at `finished` completed; a superseded raise is ignored.
    mutating func fadeFinished(raise finished: UInt64) {
        guard finished == raise else { return }
        fadedInRaise = finished
    }

    var hasFadedIn: Bool { fadedInRaise == raise }
}

/// Applies `ContinuedElsewherePresentationPolicy.terminalDraws` to every
/// terminal below it: drawing stops one fade after the veil goes up, and
/// resumes the moment it starts to lift. `veiled` must be the veil's own
/// visibility (`veilIsDrawn`), not merely whether a peer holds the grid.
struct ContinuedElsewhereDrawingGate: ViewModifier {
    let veiled: Bool
    @Environment(\.terminalDrawingEnabled) private var inherited
    @State private var fade = ContinuedElsewhereVeilFade()

    func body(content: Content) -> some View {
        content
            .environment(\.terminalDrawingEnabled, ContinuedElsewherePresentationPolicy.terminalDraws(
                inherited: inherited,
                veiled: veiled,
                veilHasFadedIn: fade.hasFadedIn
            ))
            // In the update that moved the veil, not in a task that may run
            // after it was raised again.
            .onChange(of: veiled) { fade.veilChanged() }
            .task(id: fade.raise) {
                let raise = fade.raise
                guard veiled,
                      (try? await Task.sleep(for: .seconds(ContinuedElsewherePresentationPolicy.veilFadeDuration))) != nil,
                      !Task.isCancelled
                else { return }
                fade.fadeFinished(raise: raise)
            }
    }
}

/// Which veil key presses take control back (D8). Only a deliberate
/// gesture counts: Return or a printable key. Modifier-only presses, ⌘
/// chords (system and app shortcuts, including the session switcher),
/// Escape, arrows, function keys and other system keys pass through, so
/// navigating away from a yielded session never seizes the grid.
enum ContinuedElsewhereKeyPolicy {
    /// D8: a veil may hold keyboard focus, and any gesture on it may take
    /// control back, only while its session is the one on screen and the app
    /// is unlocked. ContentView keeps hidden sessions mounted (opacity 0, no
    /// hit testing) and the app lock covers a still-mounted ContentView, so
    /// neither visibility nor hit testing alone keeps a key, a VoiceOver
    /// action or a stale focus from reclaiming a session the user cannot see.
    static func admitsGesture(sessionIsActive: Bool, appIsLocked: Bool) -> Bool {
        sessionIsActive && !appIsLocked
    }

    /// Every terminal chord the app binds carries ⌘
    /// (`KeyBinding.validate` rejects a binding without it), so the ⌘ rule
    /// below keeps ⌘F, ⌘⇧E, ⌘R, the tmux window chords and ⌘C/⌘V on a veil
    /// that took first responder from the terminal from reclaiming control.
    static func takesBack(
        key: KeyEquivalent,
        characters: String,
        modifiers: EventModifiers
    ) -> Bool {
        if modifiers.contains(.command) { return false }
        if key == .escape { return false }
        if key == .return { return true }
        guard !characters.isEmpty else { return false }
        return characters.unicodeScalars.allSatisfy { scalar in
            // Control characters (⌃-chords, Tab, Delete) and the private-use
            // range UIKit reports arrows and function keys in are not text.
            !CharacterSet.controlCharacters.contains(scalar)
                && !(0xF700...0xF8FF).contains(scalar.value)
                && scalar.value != 0x7F
        }
    }
}

/// Finds the current first responder without walking every window.
@MainActor
enum FirstResponderProbe {
    private static weak var found: UIResponder?

    static func current() -> UIResponder? {
        found = nil
        UIApplication.shared.sendAction(
            #selector(UIResponder.tessera_reportFirstResponder),
            to: nil,
            from: nil,
            for: nil
        )
        return found
    }

    /// A text field, palette search or composer is taking typing. The
    /// terminal itself (the veil's own target) does not count.
    static var otherTextInputIsActive: Bool {
        guard let responder = current() else { return false }
        if responder is TerminalView { return false }
        return responder is UITextInput || responder is UIKeyInput
    }

    fileprivate static func report(_ responder: UIResponder) { found = responder }
}

extension UIResponder {
    @objc fileprivate func tessera_reportFirstResponder() {
        FirstResponderProbe.report(self)
    }
}

/// Full-terminal veil shown while another device holds the shared tmux grid.
/// Mounted as a ZStack sibling above the terminal surface (like
/// `SessionLaunchOverlay`), so it blurs only the terminal — top bar and
/// sidebar stay live. A tap anywhere, the pill, Return or a printable key
/// takes control back (D8, `ContinuedElsewhereKeyPolicy`); taking focus here
/// also moves first responder off the terminal, which is what suppresses
/// keystrokes from reaching the shared PTY while yielded.
struct ContinuedElsewhereOverlay: View {
    let T: DesignTokens
    /// Stamp display name of the device holding the grid.
    let peerDisplayName: String
    /// True from the take-back gesture until confirmed geometry/repaint (or
    /// until the claim timeout folds the spinner back).
    let isReclaiming: Bool
    /// The tap was admitted while the control channel was down: the claim
    /// starts when it reconnects, and the user may cancel it meanwhile.
    var awaitingConnection: Bool = false
    /// The veil may take keyboard focus only while its session is displayed
    /// and unlocked (ContentView stays mounted under the lock, and hidden
    /// tabs keep their veils mounted at opacity 0).
    var capturesKeys: Bool = true
    /// P9: whether the glyph may breathe (`ContinuedElsewherePresentationPolicy.breathes`).
    var animatesMotion: Bool = true
    let onTakeBack: () -> Void
    /// Cancels a pending take-back that waits for the connection.
    var onCancel: (() -> Void)?
    /// Session switching stays reachable while yielded. ⌘⇧J / ⌘⇧K only change
    /// which session is on screen — they never reach the peer's terminal — and
    /// the ⌘K palette already works here, so withdrawing the neighbour-walk
    /// would be an inconsistency, not a safeguard. Taking focus for the veil
    /// pulls first responder off the terminal, which takes
    /// `TesseraTerminalContainer`'s key commands out of the responder chain;
    /// these hidden buttons re-register the two chords for exactly as long as
    /// the veil is up. Optional so harnesses and previews can omit it.
    var onSwitcherShortcut: ((TesseraSwitcherShortcut) -> Void)?

    @FocusState private var captureKeys: Bool
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(AppearancePreferences.self) private var appearance
    @Environment(ShortcutStore.self) private var shortcutStore: ShortcutStore?

    /// "iPhone" stays "iPhone"; a peer of our own device class reads
    /// "another iPad" so two iPads never claim the session continued on
    /// the device you are holding. An unresolved or unrecognised peer keeps
    /// the headline neutral until a recognised stamp arrives.
    private var peerLabel: String? {
        GridAuthorityDeviceIdentity.continuationPeerLabel(peerDisplayName)
    }

    private var glyphName: String {
        guard GridAuthorityDeviceIdentity.knownDeviceNames.contains(peerDisplayName)
        else { return "display" }
        switch peerDisplayName {
        case "iPhone": return "iphone"
        case "iPad": return "ipad.landscape"
        default: return "display"
        }
    }

    private var cardShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
    }

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.ultraThinMaterial)
                .overlay(Color.black.opacity(0.30))
            card
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture {
            guard !isReclaiming else { return }
            onTakeBack()
        }
        .focusable(capturesKeys)
        .focusEffectDisabled()
        .focused($captureKeys)
        .onKeyPress(phases: .down) { press in
            guard ContinuedElsewhereKeyPolicy.takesBack(
                key: press.key,
                characters: press.characters,
                modifiers: press.modifiers
            ) else { return .ignored }
            guard !isReclaiming else { return .handled }
            onTakeBack()
            return .handled
        }
        .onAppear { updateKeyCapture() }
        .onChange(of: capturesKeys) { _, _ in updateKeyCapture() }
        .background(switcherShortcuts)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityDescription)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: Text("cancel")) {
            if awaitingConnection { onCancel?() }
        }
    }

    private var accessibilityDescription: Text {
        if isReclaiming {
            return Text(awaitingConnection
                ? "takes control when reconnected"
                : "Taking back control of this session.")
        }
        if let peerLabel {
            return Text("Session continued on \(peerLabel). Double-tap to take back control.")
        }
        return Text("Session continued elsewhere. Double-tap to take back control.")
    }

    /// Focus only a displayed, unlocked veil, and never over another text
    /// input the user is typing into (a rename field, the palette search).
    private func updateKeyCapture() {
        captureKeys = capturesKeys && !FirstResponderProbe.otherTextInputIsActive
    }

    /// The two neighbour-walk chords, taken from the user's keymap rather than
    /// written out as literals — a literal here would answer to the shipped
    /// chord after a rebind and release nothing after an unbind. Same shape as
    /// the global ⌘K button in `ContentView`.
    @ViewBuilder
    private var switcherShortcuts: some View {
        if let onSwitcherShortcut {
            ZStack {
                Button(ShortcutAction.nextSession.title) {
                    onSwitcherShortcut(.cycleNext)
                }
                .storedKeyboardShortcut(.nextSession, in: shortcutStore)
                Button(ShortcutAction.previousSession.title) {
                    onSwitcherShortcut(.cyclePrevious)
                }
                .storedKeyboardShortcut(.previousSession, in: shortcutStore)
            }
            .opacity(0)
            .frame(width: 0, height: 0)
        }
    }

    private var card: some View {
        VStack(spacing: 0) {
            if isReclaiming {
                ProgressView()
                    .tint(T.fgMuted)
                    .padding(.bottom, 14)
            } else {
                Image(systemName: glyphName)
                    .font(.system(size: 38, weight: .light))
                    .foregroundStyle(T.fgMuted)
                    .modifier(ContinuedElsewhereBreathing(active: animatesMotion))
                    .padding(.bottom, 14)
            }

            Group {
                if isReclaiming {
                    Text(awaitingConnection ? "takes control when reconnected" : "taking back control…")
                } else if let peerLabel {
                    Text("continued on \(peerLabel)")
                } else {
                    Text("continued elsewhere")
                }
            }
            .font(Typography.tesseraMono(size: 15, weight: .medium))
            .foregroundStyle(T.fg)

            if isReclaiming, awaitingConnection, let onCancel {
                Button(action: onCancel) {
                    Text("cancel")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(T.fgMuted)
                        .padding(.horizontal, 16)
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.top, 8)
            }

            if !isReclaiming {
                Text("This session is being controlled from another device.")
                    .tesseraSansScaled(size: 12.5)
                    .foregroundStyle(T.fgMuted)
                    .multilineTextAlignment(.center)
                    .padding(.top, 7)

                Button(action: onTakeBack) {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.uturn.backward")
                            .font(.system(size: 12, weight: .medium))
                        Text("take back control")
                            .font(.system(size: 12.5, weight: .medium))
                    }
                    .foregroundStyle(T.fg)
                    .padding(.horizontal, 16)
                    .frame(height: 34)
                    .floatingGlass(
                        appearance.chromeMaterial,
                        tint: T.sidebarBg,
                        solidFill: T.inputBg,
                        in: Capsule()
                    )
                    .overlay {
                        Capsule().stroke(T.borderStrong, lineWidth: 0.5)
                    }
                }
                .buttonStyle(.plain)
                .padding(.top, 18)

                Text(
                    CompactLayout.isPhone(horizontalSizeClass)
                        ? "tap anywhere"
                        : "tap anywhere · or press any key"
                )
                .font(Typography.tesseraMono(size: 10.5))
                .foregroundStyle(T.fgFaint)
                .padding(.top, 11)
            }
        }
        .padding(.top, 26)
        .padding(.bottom, 22)
        .padding(.horizontal, 34)
        .frame(maxWidth: 340)
        .floatingGlass(
            appearance.chromeMaterial,
            tint: T.sidebarBg,
            solidFill: T.panelBg,
            in: cardShape
        )
        .overlay {
            cardShape.stroke(T.borderStrong, lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.45), radius: 24, y: 12)
        .padding(24)
    }
}

private struct ContinuedElsewhereBreathing: ViewModifier {
    /// P9: false stops the repeat-forever animation (a non-animated change
    /// of the value replaces it) until the veil is displayed again.
    let active: Bool
    @State private var dim = false

    /// Reduced motion keeps the static dim it always had.
    private var target: Bool { ContinuousMotion.isSuppressed || active }

    func body(content: Content) -> some View {
        content
            .opacity(dim ? 0.55 : 1)
            .animation(
                ContinuousMotion.isSuppressed || !active
                    ? nil
                    : .easeInOut(duration: 1.3).repeatForever(autoreverses: true),
                value: dim
            )
            .onAppear { dim = target }
            .onChange(of: target) { _, now in dim = now }
    }
}

/// Small capsule shown while a show resolves (`.resuming`): the terminal
/// stays visible and only input waits for the authority read, so resuming
/// a session never flashes the veil. It appears only if the read takes
/// longer than a beat, and while the show waits for its connection it
/// offers a cancel (the same as hiding the session).
struct GridAuthorityResumingIndicator: View {
    let T: DesignTokens
    let awaitingConnection: Bool
    let onCancel: () -> Void

    @State private var visible = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.mini)
                    .tint(T.fgMuted)
                Text(awaitingConnection ? "takes control when reconnected" : "resuming…")
                    .font(Typography.tesseraMono(size: 11.5, weight: .medium))
                    .foregroundStyle(T.fg)
                if awaitingConnection {
                    Button(action: onCancel) {
                        Image(systemName: "xmark")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(T.fgMuted)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("cancel"))
                }
            }
            .padding(.leading, 14)
            .padding(.trailing, awaitingConnection ? 0 : 14)
            .frame(minHeight: 32)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay { Capsule().stroke(T.borderStrong, lineWidth: 0.5) }
            .padding(.top, 12)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .opacity(visible ? 1 : 0)
        .allowsHitTesting(visible && awaitingConnection)
        .accessibilityHidden(!visible)
        .task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.15)) { visible = true }
        }
    }
}
