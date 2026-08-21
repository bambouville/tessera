// Tessera/Files/FilesPanelView.swift
//
// The Remote Files panel — a 340pt trailing inspector that floats as a
// rounded card OVERLAY over the terminal surface (the terminal keeps
// full width and never resizes; the card's material follows the chrome
// setting, so the terminal blurs through on glass/frosted). Chrome
// follows FindBar's conventions: theme-derived DesignTokens passed in by
// the session view, monospace typography, hairline borders, monochrome
// glyphs, accentSoft toggled fills.
// Design reference: docs/mockups/remote-files/index.html.

import SwiftUI
import UIKit

/// Drop-on-terminal (mockup §4): the terminal surface accepts file
/// drops — upload to the host's temp dir, then type the quoted path
/// into the session (desktop drag-into-terminal convention; the
/// Claude Code attach flow, but general). Owns the hover affordance
/// so each session view pays a single modifier against its
/// type-checker budget.
struct TerminalFileDropTarget: ViewModifier {
    let T: DesignTokens
    /// Set by the drop pipeline when staging/upload fails — the panel
    /// may be CLOSED during a terminal drop, so failures surface here
    /// as a transient toast (performUpload's "a failure MUST surface
    /// or it's silent" rule) instead of the panel-only error banner.
    @Binding var failureMessage: String?
    let handle: ([NSItemProvider]) -> Bool

    @State private var targeted = false

    func body(content: Content) -> some View {
        content
            .onDrop(of: [.item], isTargeted: $targeted) { providers in
                failureMessage = nil
                return handle(providers)
            }
            .overlay(alignment: .top) {
                if targeted {
                    dropPill(
                        icon: "arrow.up.doc", iconColor: T.accent,
                        text: "Upload & paste path", stroke: T.accent
                    )
                } else if let failureMessage {
                    dropPill(
                        icon: "exclamationmark.triangle", iconColor: T.red,
                        resolvedText: failureMessage, stroke: T.red
                    )
                }
            }
            .onChange(of: failureMessage) { _, message in
                guard let message else { return }
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 6_000_000_000)
                    if failureMessage == message { failureMessage = nil }
                }
            }
    }

    private func dropPill(
        icon: String, iconColor: Color, text: LocalizedStringKey, stroke: Color
    ) -> some View {
        dropPill(icon: icon, iconColor: iconColor, message: Text(text), stroke: stroke)
    }

    /// The failure variant shows a message the drop handler already produced.
    private func dropPill(
        icon: String, iconColor: Color, resolvedText: String, stroke: Color
    ) -> some View {
        dropPill(icon: icon, iconColor: iconColor, message: Text(verbatim: resolvedText), stroke: stroke)
    }

    private func dropPill(
        icon: String, iconColor: Color, message: Text, stroke: Color
    ) -> some View {
        HStack(spacing: 7) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .light))
                .foregroundStyle(iconColor)
            message
                .font(Typography.tesseraMono(size: 11.5))
                .foregroundStyle(T.fg)
                .lineLimit(2)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(T.bg.opacity(0.92), in: Capsule())
        .overlay(Capsule().stroke(stroke, lineWidth: 1))
        .frame(maxWidth: 420)
        .padding(.top, 54)
        .allowsHitTesting(false)
        .transition(.opacity)
    }
}

/// The floating-card surface for the Files panel: material (liquid glass
/// / frosted / solid) following the chrome setting, rounded clip, hairline
/// border, drag-over highlight, shadow, and edge inset. Extracted to a
/// ViewModifier so `panelStack` stays inside the type-checker's budget
/// (same reasoning as `TerminalFileDropTarget`).
private struct FloatingCardSurface: ViewModifier {
    let material: ChromeMaterial
    let T: DesignTokens
    let showDropHighlight: Bool
    /// True while a row context menu is presented. UIKit re-hosts the
    /// window's content in a portal layer for the context-menu zoom/dim,
    /// and backdrop layers (Material / Liquid Glass) don't render inside
    /// portals — the card would read as fully transparent, leaving bare
    /// rows floating over the terminal. While the menu is up we fade an
    /// opaque fill in BEHIND the glass so the card stays a card; the
    /// system's dimming shade makes the swap invisible.
    let opaqueBackstop: Bool
    /// The session's background picture, when one backs the canvas. The
    /// stand-in then renders a blurred aligned crop of it instead of plain
    /// black — glass over a bright picture reads bright, so a black
    /// stand-in would flash on every arm/release.
    let terminalBackground: ResolvedTerminalBackground?

    /// With a picture backdrop the card doesn't use a backdrop-sampling
    /// material AT ALL — the blurred image composite IS the surface.
    ///
    /// Why (2026-07-10 recordings, three iterations): UIKit suppresses
    /// backdrop layers inside the context-menu portal at unobservable
    /// frames, so (1) a timed stand-in races it — bare-terminal holes at
    /// touch-down and release; (2) an always-on stand-in UNDER the glass
    /// still steps, because the glass adds its own tint over it — idle
    /// (glass over stand-in, Y≈37) vs suppressed (stand-in raw, Y≈45)
    /// can never match. Only self-contained content renders identically
    /// inside and outside the portal — zero flash by construction. Costs
    /// the live-terminal see-through and glass refraction at idle; over
    /// a picture the blur is dominated by the picture anyway. Solid
    /// material is already portal-proof (opaque), and solid-color themes
    /// keep the timed measured-black backstop (invisible there).
    private var usesSelfContainedSurface: Bool {
        terminalBackground != nil && material.resolved != .solid
    }

    private var cardShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
    }
    private var solidFill: Color {
        T.isLight ? Color(rgbInt: 0xF2F2F7) : Color(rgbInt: 0x1C1C1E)
    }
    private var shadowColor: Color {
        Color.black.opacity(T.isLight ? 0.18 : 0.40)
    }

    func body(content: Content) -> some View {
        surfaced(content)
            .clipShape(cardShape)
            .overlay { cardShape.stroke(T.border, lineWidth: 0.5) }
            .overlay { dropHighlight }
            .shadow(color: shadowColor, radius: 18, x: 0, y: 8)
            // Inset from the terminal edges so it reads as a floating card.
            .padding(.vertical, 10)
            .padding(.trailing, 10)
    }

    // Staged into a helper so the type-checker stays within budget —
    // `floatingGlass`'s @ViewBuilder switch plus a long chain on the opaque
    // ModifierContent otherwise times out.
    @ViewBuilder
    private func surfaced(_ content: Content) -> some View {
        if usesSelfContainedSurface {
            // Picture backdrop: the composite is the surface (see
            // `usesSelfContainedSurface`) — no material, nothing for the
            // menu portal to suppress, no backstop timing at all.
            content.background { backstopFill }
        } else {
            // Solid-color themes: real material, mirroring the sidebar/top
            // bar (`floatingGlass` handles OS gating + Reduce Transparency),
            // with the timed measured-black backstop for menu interactions.
            content
                .floatingGlass(material, tint: T.sidebarBg, solidFill: solidFill, in: cardShape)
                .background {
                    backstopFill
                        .opacity(opaqueBackstop ? 1 : 0)
                        // All arm/release DELAYS live in FilesPanelView's
                        // task logic (cancellable, source-aware); here only
                        // the blend: fast in (the glass is already gone when
                        // this arms — every frame counts), slow out (the
                        // release moment can't be synced to the system
                        // restoring the glass, so a soft crossfade hides
                        // the residual step).
                        .animation(
                            opaqueBackstop
                                ? .easeIn(duration: 0.08)
                                : .easeOut(duration: 0.5),
                            value: opaqueBackstop
                        )
                }
        }
    }

    @ViewBuilder
    private var dropHighlight: some View {
        if showDropHighlight {
            cardShape
                .fill(T.accent.opacity(0.06))
                .overlay { cardShape.stroke(T.accent, lineWidth: 1.5) }
                .allowsHitTesting(false)
        }
    }

    /// What the backstop shows while the glass is suppressed. Not the
    /// `solidFill` panel color: rendered glass over a dark terminal reads
    /// nearly BLACK (measured Y≈18 vs solidFill's Y≈40 in the 2026-07-09
    /// recordings — even the sidebar tint composited on black measured
    /// Y≈49), and any brighter stand-in makes arming and release read as
    /// a tone jump on the card. Plain black is the closest static match,
    /// so the swap is invisible on dark terminals; light themes keep the
    /// solid fill (glass over light content reads bright).
    ///
    /// With a background picture the glass shows the (blurred) picture, so
    /// the stand-in becomes a blurred aligned crop of the same backdrop +
    /// the glass tint wash — self-contained content (no backdrop sampling),
    /// so unlike the real material it still renders inside the menu portal.
    @ViewBuilder
    private var backstopFill: some View {
        if let terminalBackground {
            GeometryReader { geo in
                let frame = geo.frame(in: .global)
                let screen = UIScreen.main.bounds
                TerminalBackdrop(
                    background: terminalBackground,
                    baseColor: T.bg,
                    bleed: EdgeInsets(
                        top: max(0, frame.minY),
                        leading: max(0, frame.minX),
                        bottom: max(0, screen.height - frame.maxY),
                        trailing: max(0, screen.width - frame.maxX)
                    )
                )
                // Approximate the frosted look: heavy blur of the aligned
                // crop, the same tint wash floatingGlass applies, and the
                // material's own darkening.
                .blur(radius: 24)
                .overlay(T.sidebarBg)
                .overlay(SwiftUI.Color.black.opacity(T.isLight ? 0 : 0.25))
            }
            .clipShape(cardShape)
        } else if T.isLight {
            cardShape.fill(solidFill)
        } else {
            cardShape.fill(.black)
        }
    }
}

struct FilesPanelView: View {
    @Bindable var controller: FilesPanelController
    let T: DesignTokens
    /// Whether the owning session is the foreground tab. Gates the
    /// auto-reconnect below — background panels must not resurrect
    /// dropped bridges in a loop the user can't see.
    var sessionIsActive: Bool = true
    /// The session's background picture (nil = solid theme color). Only
    /// feeds the context-menu backstop stand-in so it matches the glass
    /// over the picture; defaults nil for the harness and previews.
    var terminalBackground: ResolvedTerminalBackground? = nil
    #if DEBUG
    /// Harness hook for capturing compact quick-open without simulator input.
    var initiallyShowingQuickOpen = false
    #endif

    /// Drives the floating-card surface material (liquid glass / frosted
    /// / solid), matching the sidebar and top bar. Injected app-wide via
    /// `.environment(appearance)`; the `#Preview` below provides one too.
    @Environment(AppearancePreferences.self) private var appearance

    static let width: CGFloat = 340

    private var isPhone: Bool {
        UIDevice.current.userInterfaceIdiom == .phone
    }

    /// Backoff for auto-reconnect: an open panel reconnects a dropped/
    /// idle bridge by itself (opening the panel IS the intent to browse),
    /// but a server that accepts connects and then drops channels would
    /// otherwise put us in a tight reconnect loop.
    @State private var lastAutoReconnect: Date?

    @State private var newFolderName = ""
    @State private var showingNewFolder = false
    @State private var dropTargeted = false
    @State private var renameTarget: RemoteFileEntry?
    @State private var renameText = ""
    @State private var deleteTarget: RemoteFileEntry?
    @State private var showingInstallConfirm = false

    // MARK: Files-panel improvements (§ numbers → docs/mockups/files-panel-improvements)

    /// §1 toolbar search — field focus drives textEntryActive.
    @FocusState private var searchFieldFocused: Bool

    /// §2 editable path bar.
    @State private var isEditingPath = false
    @State private var pathText = ""
    @FocusState private var pathFieldFocused: Bool
    @State private var pathCompletion = PathCompletionModel()

    /// §4 quick open by path.
    @State private var showingQuickOpen = false
    @State private var quickOpenText = ""
    @FocusState private var quickOpenFocused: Bool
    @State private var quickOpenCompletion = PathCompletionModel()

    // MARK: Context-menu backstop
    //
    // UIKit suppresses the card's glass for the WHOLE context-menu
    // interaction: measured (2026-07-09 recordings) it can start within
    // ~1 frame of TOUCH-DOWN on a held touch and persists ~1s after
    // dismissal. `backstopOn` swaps in a glass-look stand-in fill for
    // that window, driven by two signals:
    //  • panel touch-down (zero-distance drag gesture) — arms instantly;
    //    SwiftUI's Button `isPressed` fires hundreds of ms late inside a
    //    ScrollView and cannot be used. The stand-in is visually ≈ the
    //    glass over dark content, so arming on every touch (taps and
    //    scrolls included) is imperceptible;
    //  • the menu's lifted preview lifecycle (the only part of a SwiftUI
    //    context menu hosted as a real view; menu ITEMS are bridged to
    //    UIKit `UIMenu` and never get `onAppear`) — holds the backstop
    //    while the menu is up, and releases with a linger that outlives
    //    the system's ~1s post-dismiss glass suppression.

    /// > 0 while a row context menu is presented (preview lifecycle).
    @State private var presentedMenuItemCount = 0

    /// Whether a touch is currently down anywhere on the panel.
    @State private var panelTouchActive = false

    /// Whether the opaque stand-in is showing (see MARK comment).
    @State private var backstopOn = false

    @State private var backstopReleaseTask: Task<Void, Never>?
    @State private var backstopFailsafeTask: Task<Void, Never>?

    // Split into panelStack → chrome → alerts so each expression stays
    // inside the type-checker's complexity budget (the session views hit
    // the same wall — see moshTerminalSurface's extraction note).
    var body: some View {
        let _ = FilesUIDiagnostics.shared.panelBodyPass()
        return panelChrome
            .onAppear {
                controller.transfers?.acknowledgeBackgroundAttention()
                #if DEBUG
                if initiallyShowingQuickOpen {
                    showingQuickOpen = true
                }
                #endif
            }
            .onChange(of: controller.transfers?.backgroundAttention) { _, attention in
                if attention != BackgroundTransferAttention.none {
                    controller.transfers?.acknowledgeBackgroundAttention()
                }
            }
            .onChange(of: showingNewFolder) { _, _ in syncTextEntryFlag() }
            .onChange(of: showingInstallConfirm) { _, _ in syncTextEntryFlag() }
            .onChange(of: renameTarget) { _, _ in syncTextEntryFlag() }
            .onChange(of: deleteTarget) { _, _ in syncTextEntryFlag() }
            .onChange(of: searchFieldFocused) { _, _ in syncTextEntryFlag() }
            .onChange(of: pathFieldFocused) { _, _ in syncTextEntryFlag() }
            .onChange(of: showingQuickOpen) { _, _ in syncTextEntryFlag() }
            .quickLookPreview(item: $controller.presentedPreview)
            .sheet(item: $controller.presentedShare) { request in
                ActivityShareSheet(items: request.items)
                    .ignoresSafeArea()
                    .presentationDetents([.medium, .large])
            }
            .fileImporter(
                isPresented: $controller.showingUploadPicker,
                allowedContentTypes: [.item],
                allowsMultipleSelection: true
            ) { result in
                if case .success(let urls) = result {
                    controller.uploadLocalFiles(urls)
                }
            }
            // Whole panel is a drop zone: files dragged in land in the
            // current directory. The drag-over highlight is drawn inside
            // `panelStack`, framed to the rounded card (see below).
            .onDrop(of: [.item], isTargeted: $dropTargeted) { providers in
                controller.handleDroppedItems(providers)
            }
    }

    private var panelStack: some View {
        VStack(spacing: 0) {
            header
            pathBar
                .padding(.horizontal, 10)
                .padding(.bottom, 6)
            if isEditingPath, !pathCompletion.candidates.isEmpty {
                pathSuggestions(pathCompletion) { acceptPathSuggestion($0) }
                    .padding(.horizontal, 10)
                    .padding(.bottom, 6)
            }
            if controller.followState == .unavailable, controller.onInstallShellIntegration != nil {
                followUnavailableCTA
                    .padding(.horizontal, 10)
                    .padding(.bottom, 6)
            }
            toolbar
            if isPhone, showingQuickOpen {
                compactQuickOpen
                    .padding(.horizontal, 10)
                    .padding(.bottom, 6)
            }
            if controller.searchActive {
                searchRow
                    .padding(.horizontal, 10)
                    .padding(.bottom, 6)
            }
            Rectangle().fill(T.border).frame(height: 0.5)
            content
            if let transfers = controller.transfers, !transfers.items.isEmpty {
                transferStrip(transfers)
            }
        }
        // The 340pt inspector is deliberate on iPad, where it floats over a
        // much wider terminal. On iPhone the panel already lives in a sheet;
        // let it use that compact surface instead of nesting an iPad-width
        // card inside the phone's limited width.
        .frame(width: isPhone ? nil : Self.width)
        .frame(maxWidth: isPhone ? .infinity : nil)
        .frame(maxHeight: .infinity)
        // Touch-down sensor for the backstop (see MARK above). Zero
        // minimum distance so it reports at first contact; simultaneous
        // so row taps, scrolling, drags, and the context-menu interaction
        // all behave exactly as before.
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in panelTouchChanged(true) }
                .onEnded { _ in panelTouchChanged(false) }
        )
        .modifier(FloatingCardSurface(
            material: appearance.chromeMaterial,
            T: T,
            showDropHighlight: dropTargeted,
            opaqueBackstop: backstopOn,
            terminalBackground: terminalBackground
        ))
    }

    private var panelChrome: some View {
        panelStack
            .alert("Install shell integration?", isPresented: $showingInstallConfirm) {
            Button("Install") { controller.onInstallShellIntegration?() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(RemoteShellIntegrationInstaller.snippetPreview)
        }
        .alert("New Folder", isPresented: $showingNewFolder) {
            TextField("name", text: $newFolderName)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            Button("Create") {
                controller.createFolder(named: newFolderName)
                newFolderName = ""
            }
            Button("Cancel", role: .cancel) { newFolderName = "" }
        }
        .alert("Rename", isPresented: renameAlertBinding) {
            TextField("name", text: $renameText)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            Button("Rename") {
                if let target = renameTarget {
                    controller.rename(target, to: renameText)
                }
                renameTarget = nil
            }
            Button("Cancel", role: .cancel) { renameTarget = nil }
        }
        .alert("Delete \"\(deleteTarget?.name ?? "")\"?", isPresented: deleteAlertBinding) {
            Button("Delete", role: .destructive) {
                if let target = deleteTarget { controller.delete(target) }
                deleteTarget = nil
            }
            Button("Cancel", role: .cancel) { deleteTarget = nil }
        } message: {
            Text(deleteTarget?.kind == .directory
                 ? "Only empty folders can be deleted."
                 : "This permanently deletes the file on the host.")
        }
    }

    /// Keeps the controller's `textEntryActive` in sync with the four
    /// alert states so the session view suppresses the terminal's
    /// first-responder reclaim while an alert (and its TextField) is up.
    private func syncTextEntryFlag() {
        controller.textEntryActive = showingNewFolder
            || showingInstallConfirm
            || renameTarget != nil
            || deleteTarget != nil
            || searchFieldFocused
            || pathFieldFocused
            || showingQuickOpen
    }

    private var renameAlertBinding: Binding<Bool> {
        Binding(get: { renameTarget != nil }, set: { if !$0 { renameTarget = nil } })
    }

    private var deleteAlertBinding: Binding<Bool> {
        Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } })
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "folder")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(T.fgMuted)
            Text("files")
                .font(Typography.tesseraMono(size: 13, weight: .medium))
                .foregroundStyle(T.fg)
            Spacer(minLength: 4)
            // Gap 0: the close button's hit frame supplies the old 8 pt
            // chip gap and 12 pt trailing edge, so nothing moves.
            HStack(spacing: 0) {
                bridgeChip
                Button {
                    controller.close()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(T.fgDim)
                        .frame(width: 24, height: 22)      // unchanged visual
                        // 44 pt-wide hit frame: iPadOS 26 expands sub-44 pt
                        // targets itself and mis-assigns taps. Height stops
                        // at the header's bottom edge so the frame cannot
                        // overlap the path bar's tap area below.
                        .padding(.leading, 8)
                        .padding(.trailing, 12)
                        .frame(height: 38)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("close files panel")
            }
        }
        .padding(.leading, 12)
        .padding(.top, 4)
    }

    @ViewBuilder
    private var bridgeChip: some View {
        if let bridge = controller.bridge {
            HStack(spacing: 5) {
                StatusDot(color: bridgeDotColor(bridge.state), size: 5)
                Text(bridge.key.description)
                    .font(Typography.tesseraMono(size: 10))
                    .foregroundStyle(T.fgMuted)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(verbatim: "· sftp")
                    .font(Typography.tesseraMono(size: 10))
                    .foregroundStyle(T.fgDim)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .overlay(
                Capsule().stroke(T.border, lineWidth: 0.5)
            )
        }
    }

    private func bridgeDotColor(_ state: FileBridgeState) -> Color {
        switch state {
        case .connected: return T.green
        case .connecting: return T.amber
        case .dropped, .failed: return T.red
        case .idle: return T.fgFaint
        }
    }

    // MARK: - Path bar

    private var pathBar: some View {
        HStack(spacing: 6) {
            followButton
            if isEditingPath {
                pathField
            } else {
                crumbsView
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 30)
        .background(T.inputBg)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(isEditingPath ? T.accent : T.border,
                        lineWidth: isEditingPath ? 1 : 0.5)
        )
        // §2: tapping the bar's empty area flips to the text field.
        // Crumb buttons and the follow toggle win their own taps.
        .contentShape(Rectangle())
        .onTapGesture {
            if !isEditingPath, controller.currentDirectory != nil { beginPathEdit() }
        }
    }

    // MARK: - Path bar editing (§2)

    /// Mono path field replacing the crumbs while editing. Pre-filled
    /// with the current absolute path and (iOS 18+) fully selected so
    /// one keystroke replaces it. ⏎ commits, esc closes the dropdown
    /// first and then reverts to crumbs; tab/↑↓ drive the completion
    /// dropdown rendered under the bar.
    private var pathField: some View {
        Group {
            if #available(iOS 18.0, *) {
                SelectAllOnAppearTextField(text: $pathText)
            } else {
                TextField("path", text: $pathText)
            }
        }
        .font(Typography.tesseraMono(size: 10.5))
        .foregroundStyle(T.fg)
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .focused($pathFieldFocused)
        .submitLabel(.go)
        .onKeyPress(.escape) {
            if !pathCompletion.candidates.isEmpty {
                pathCompletion.clear()
            } else {
                endPathEdit()
            }
            return .handled
        }
        .onKeyPress(.tab) {
            acceptHighlighted(of: pathCompletion, into: $pathText)
            return .handled
        }
        .onKeyPress(.upArrow) {
            pathCompletion.move(-1)
            return .handled
        }
        .onKeyPress(.downArrow) {
            pathCompletion.move(1)
            return .handled
        }
        .onKeyPress(keys: [.return], phases: .down) { _ in
            commitPathEdit()
            return .handled
        }
        // Software-keyboard "go": hardware Return is short-circuited by
        // the .handled above (FindBar precedent), so this only fires
        // for the soft keyboard — without it, touch-only commits were
        // impossible and the resign-on-submit blur cancelled the edit.
        .onSubmit { commitPathEdit() }
        .onChange(of: pathText) { _, text in
            pathCompletion.update(typed: text, controller: controller)
        }
        .onChange(of: pathFieldFocused) { _, focused in
            // Blur (tap into the terminal / another field) = cancel,
            // matching the esc path — never leave a stale field up.
            if !focused, isEditingPath { endPathEdit() }
        }
    }

    private func beginPathEdit() {
        pathText = controller.currentDirectory ?? controller.bridge?.homeDirectory ?? "/"
        pathCompletion.clear()
        isEditingPath = true
        pathFieldFocused = true
    }

    private func endPathEdit() {
        isEditingPath = false
        pathFieldFocused = false
        pathCompletion.clear()
    }

    private func commitPathEdit() {
        if pathCompletion.shouldAcceptOnReturn(for: pathText) {
            acceptHighlighted(of: pathCompletion, into: $pathText)
        }
        let text = pathText
        pathCompletion.clear()
        Task {
            if await controller.commitPathInput(text) { endPathEdit() }
        }
    }

    private func acceptPathSuggestion(_ entry: RemoteFileEntry) {
        if let accepted = pathCompletion.accept(entry: entry, typed: pathText) {
            pathText = accepted
        }
    }

    /// Tab-accept: swap the mid-typed segment for the highlighted
    /// entry; the field's onChange re-runs completion for the next
    /// segment (directories gain a trailing "/").
    private func acceptHighlighted(
        of model: PathCompletionModel, into text: Binding<String>
    ) {
        // Results lag typing by the debounce; accepting against text the
        // dropdown wasn't computed for would rewrite the user's newer
        // input to a stale entry.
        guard model.isCurrent(for: text.wrappedValue),
              let entry = model.highlightedEntry,
              let accepted = model.accept(entry: entry, typed: text.wrappedValue) else { return }
        text.wrappedValue = accepted
    }

    @ViewBuilder
    private var followButton: some View {
        let state = controller.followState
        Button {
            controller.toggleFollow()
        } label: {
            Image(systemName: state == .unavailable ? "exclamationmark.triangle" : "link")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(followColor(state))
                .frame(width: 22, height: 20)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(followBackground(state))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(state == .unavailable)
        .accessibilityLabel(followAccessibilityLabel(state))
    }

    private func followColor(_ state: FilesPanelController.FollowState) -> Color {
        switch state {
        case .following: return T.accent
        case .manual: return T.fgDim
        case .unavailable: return T.amber
        }
    }

    private func followBackground(_ state: FilesPanelController.FollowState) -> Color {
        switch state {
        case .following: return T.accentSoft
        case .manual: return T.inputBgSoft
        case .unavailable: return T.amber.opacity(0.14)
        }
    }

    private func followAccessibilityLabel(_ state: FilesPanelController.FollowState) -> LocalizedStringResource {
        switch state {
        case .following: return "following terminal directory — tap to browse freely"
        case .manual: return "not following — tap to sync to terminal directory"
        case .unavailable: return "no directory signal from this session"
        }
    }

    /// Collapses long paths: first crumb + "…" menu + last two components.
    @ViewBuilder
    private var crumbsView: some View {
        let crumbs = controller.breadcrumbs
        HStack(spacing: 2) {
            if crumbs.count > 3 {
                crumbButton(crumbs[0])
                crumbSeparator
                Menu {
                    ForEach(crumbs.dropFirst().dropLast(2)) { crumb in
                        Button(crumb.name) { controller.navigate(to: crumb.path) }
                    }
                } label: {
                    Text(verbatim: "…")
                        .font(Typography.tesseraMono(size: 10.5))
                        .foregroundStyle(T.fgMuted)
                        .padding(.horizontal, 2)
                        .contentShape(Rectangle())
                }
                crumbSeparator
                ForEach(crumbs.suffix(2)) { crumb in
                    if crumb != crumbs.suffix(2).first { crumbSeparator }
                    crumbButton(crumb, emphasized: crumb == crumbs.last)
                }
            } else {
                ForEach(crumbs) { crumb in
                    if crumb != crumbs.first { crumbSeparator }
                    crumbButton(crumb, emphasized: crumb == crumbs.last)
                }
            }
        }
        .lineLimit(1)
    }

    private var crumbSeparator: some View {
        Text(verbatim: "/")
            .font(Typography.tesseraMono(size: 10.5))
            .foregroundStyle(T.fgFaint)
    }

    private func crumbButton(_ crumb: FilesPanelController.Crumb, emphasized: Bool = false) -> some View {
        Button {
            controller.navigate(to: crumb.path)
        } label: {
            Text(crumb.name)
                .font(Typography.tesseraMono(size: 10.5, weight: emphasized ? .medium : .regular))
                .foregroundStyle(emphasized ? T.fg : T.fgMuted)
                .lineLimit(1)
                .truncationMode(.middle)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var followUnavailableCTA: some View {
        Button {
            showingInstallConfirm = true
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "wand.and.rays")
                    .font(.system(size: 10))
                Text("Enable follow — install shell integration")
                    .font(Typography.tesseraSans(size: 11))
                Spacer(minLength: 0)
            }
            .foregroundStyle(T.amber)
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(T.amber.opacity(0.10))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        // Gap 0 + 9 pt edges: the 30 pt hit frames supply the old 2 pt
        // gaps and 6 pt bottom padding, keeping glyph centers put.
        HStack(spacing: 0) {
            toolButton("arrow.up.doc", label: "upload here",
                       disabled: controller.onUploadRequested == nil) {
                controller.onUploadRequested?()
            }
            toolButton("folder.badge.plus", label: "new folder",
                       disabled: controller.currentDirectory == nil) {
                showingNewFolder = true
            }
            toolButton(controller.showHidden ? "eye" : "eye.slash",
                       label: "toggle hidden files",
                       active: controller.showHidden) {
                controller.showHidden.toggle()
            }
            toolButton("arrow.up.arrow.down", label: "sort by modified",
                       active: controller.sortByModified) {
                controller.sortByModified.toggle()
            }
            toolButton("arrow.clockwise", label: "refresh",
                       disabled: controller.currentDirectory == nil) {
                controller.refresh()
            }
            Spacer()
            if controller.isLoadingRoot {
                ProgressView()
                    .controlSize(.mini)
                    .tint(T.fgDim)
            }
            toolButton("magnifyingglass", label: "filter this directory",
                       accented: controller.searchActive) {
                toggleSearch()
            }
            quickOpenButton
        }
        .padding(.horizontal, 9)
    }

    private func toggleSearch() {
        controller.searchActive.toggle()
        if controller.searchActive {
            searchFieldFocused = true
        }
    }

    /// §4 quick open: anchored popover with one mono path field —
    /// file → Quick Look, directory → the panel browses there.
    @ViewBuilder
    private var quickOpenButton: some View {
        if isPhone {
            quickOpenToggle
        } else {
            quickOpenToggle
                .popover(isPresented: $showingQuickOpen, arrowEdge: .top) {
                    quickOpenPopover
                        .presentationCompactAdaptation(.popover)
                }
        }
    }

    private var quickOpenToggle: some View {
        toolButton("doc.viewfinder", label: "open by path",
                   accented: showingQuickOpen,
                   disabled: controller.bridge == nil) {
            if isPhone {
                showingQuickOpen.toggle()
            } else {
                showingQuickOpen = true
            }
        }
    }

    private func toolButton(
        _ systemName: String,
        label: LocalizedStringKey,
        active: Bool = false,
        accented: Bool = false,
        disabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(disabled ? T.fgFaint
                                 : accented ? T.accent
                                 : active ? T.fg : T.fgMuted)
                .frame(width: 28, height: 24)      // unchanged visual
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(accented ? T.accentSoft
                              : active ? T.inputBgSoft : Color.clear)
                )
                // Full-pitch hit frame: the bar's 30 pt pitch cannot absorb
                // 44 pt without moving glyphs, so each frame fills the pitch
                // (gap 0) and the bar's height instead — iPadOS 26 expands
                // sub-44 pt targets itself and mis-assigns taps between
                // adjacent small controls. Top-aligned: the extra 6 pt
                // replaces the bar's old bottom padding, not the row above.
                .frame(width: 30, height: 30, alignment: .top)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .accessibilityLabel(label)
    }

    // MARK: - Search row (§1)

    /// A filter, not a host-wide find: narrows the loaded rows live.
    /// The search tool button stays accent-tinted while this row is up
    /// so a shortened list is never mistaken for directory content.
    private var searchRow: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10))
                .foregroundStyle(T.fgDim)
            TextField("filter this directory", text: $controller.searchText)
                .font(Typography.tesseraMono(size: 10.5))
                .foregroundStyle(T.fg)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($searchFieldFocused)
                .submitLabel(.done)
                .onKeyPress(.escape) {
                    controller.searchActive = false
                    return .handled
                }
            if !controller.searchText.isEmpty {
                Text(verbatim: matchCountLabel)
                    .font(Typography.tesseraMono(size: 9))
                    .foregroundStyle(T.fgDim)
            }
            Button {
                controller.searchActive = false
            } label: {
                Image(systemName: "xmark.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(T.fgDim)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("close filter")
        }
        .padding(.horizontal, 8)
        .frame(minHeight: 28)
        .background(T.inputBg)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(searchFieldFocused ? T.accent : T.border,
                        lineWidth: searchFieldFocused ? 1 : 0.5)
        )
        .onAppear { searchFieldFocused = true }
    }

    private var matchCountLabel: String {
        String(
            localized: "\(controller.searchRows.count) matches",
            comment: "Find-in-files result count. Pluralized on the match count."
        )
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if let error = controller.lastError {
            errorBanner(error)
        }
        if let info = controller.infoMessage {
            infoBanner(info)
        }
        if controller.bridge == nil {
            statusPlaceholder("No host attached", detail: nil)
        } else if let bridge = controller.bridge, bridge.state != .connected {
            connectionPlaceholder(bridge)
        } else if controller.rows.isEmpty && !controller.isLoadingRoot {
            statusPlaceholder("Empty directory", detail: controller.currentDirectory)
        } else {
            fileList
        }
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 6) {
            Text(verbatim: message)
                .font(Typography.tesseraSans(size: 11))
                .foregroundStyle(T.red)
                .lineLimit(2)
            Spacer(minLength: 0)
            Button {
                controller.lastError = nil
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(T.fgDim)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(T.red.opacity(0.08))
    }

    private func infoBanner(_ message: String) -> some View {
        HStack(spacing: 6) {
            Text(message)
                .font(Typography.tesseraSans(size: 11))
                .foregroundStyle(T.fgMuted)
                .lineLimit(2)
            Spacer(minLength: 0)
            Button {
                controller.infoMessage = nil
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(T.fgDim)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(T.inputBgSoft)
    }

    private func autoReconnectIfAppropriate(_ state: FileBridgeState) {
        guard sessionIsActive, state == .idle || state == .dropped else { return }
        let now = Date()
        if let last = lastAutoReconnect, now.timeIntervalSince(last) < 5 { return }
        lastAutoReconnect = now
        controller.open()
    }

    @ViewBuilder
    private func connectionPlaceholder(_ bridge: any FileBridging) -> some View {
        VStack(spacing: 10) {
            switch bridge.state {
            case .connecting:
                ProgressView().tint(T.fgDim)
                Text("Connecting to \(bridge.key.description)…")
                    .font(Typography.tesseraMono(size: 11))
                    .foregroundStyle(T.fgMuted)
            case .failed(let message):
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 16))
                    .foregroundStyle(T.amber)
                Text(message)
                    .font(Typography.tesseraMono(size: 11))
                    .foregroundStyle(T.fgMuted)
                    .multilineTextAlignment(.center)
                retryButton
            case .dropped:
                Image(systemName: "bolt.slash")
                    .font(.system(size: 16))
                    .foregroundStyle(T.fgDim)
                Text("Connection lost")
                    .font(Typography.tesseraMono(size: 11))
                    .foregroundStyle(T.fgMuted)
                retryButton
            case .idle:
                // Post-idle-teardown (or never-connected-yet with the
                // panel somehow open): offer an explicit way back —
                // a bare spinner here strands the user on a dead panel.
                Image(systemName: "moon.zzz")
                    .font(.system(size: 16))
                    .foregroundStyle(T.fgDim)
                Text("Disconnected")
                    .font(Typography.tesseraMono(size: 11))
                    .foregroundStyle(T.fgMuted)
                retryButton
            case .connected:
                ProgressView().tint(T.fgDim)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Auto-heal: reaching this placeholder with a dropped/idle bridge
        // means the user is looking at a dead panel they deliberately
        // opened — reconnect for them. Failed connects land in .failed
        // (manual retry only), and the id re-fires on every state or
        // foreground change.
        .task(id: "\(String(describing: bridge.state))-\(sessionIsActive)") {
            autoReconnectIfAppropriate(bridge.state)
        }
    }

    private var retryButton: some View {
        Btn("Reconnect", style: .default, compact: true) {
            controller.open()
        }
    }

    /// `detail` is a remote path, never prose.
    private func statusPlaceholder(_ title: LocalizedStringKey, detail: String?) -> some View {
        VStack(spacing: 6) {
            Text(title)
                .font(Typography.tesseraSans(size: 12))
                .foregroundStyle(T.fgDim)
            if let detail {
                Text(verbatim: detail)
                    .font(Typography.tesseraMono(size: 10))
                    .foregroundStyle(T.fgFaint)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var filterActive: Bool {
        controller.searchActive && !controller.searchText.isEmpty
    }

    private var rowsForDisplay: [FilesPanelController.Row] {
        let rows = FilesUIDiagnostics.shared.measureRows {
            filterActive ? controller.searchRows : controller.rows
        }
        FilesUIDiagnostics.shared.noteTree(rowCount: rows.count, filtering: filterActive)
        return rows
    }

    /// Which context-menu actions the session has wired up. Read once for
    /// the whole list and handed to each row as a comparable value, so a row
    /// never reaches into the controller for it.
    private var menuCapabilities: FileRowView.MenuCapabilities {
        FileRowView.MenuCapabilities(
            canPreview: controller.onPreviewFile != nil,
            canDownload: controller.onDownloadFile != nil,
            canShare: controller.onShareFile != nil,
            canSendPath: controller.onSendPathToTerminal != nil
        )
    }

    private var fileList: some View {
        let capabilities = menuCapabilities
        let root = controller.currentDirectory
        let dragAvailable = controller.bridge != nil
        let search = filterActive ? controller.searchText : ""
        return ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(rowsForDisplay) { row in
                    FileRowView(
                        row: row,
                        T: T,
                        filterActive: filterActive,
                        searchText: search,
                        rootDirectory: root,
                        isExpanded: controller.isExpanded(row.entry),
                        isLoading: controller.isLoading(row.entry),
                        // Drag-out: rows are file-promise sources — the
                        // download runs only when a drop target accepts (no
                        // pre-fetch on drag start).
                        canDrag: dragAvailable && row.entry.kind == .file,
                        capabilities: capabilities,
                        controller: controller,
                        renameTarget: $renameTarget,
                        renameText: $renameText,
                        deleteTarget: $deleteTarget,
                        onMenuPresence: { menuPresenceChanged(present: $0) }
                    )
                    // The whole fix: an unrelated panel pass must not
                    // re-enter a row body, because re-entering rebuilds the
                    // row's `.contextMenu` items and preview, which
                    // re-publishes the live `UIMenu` — UIKit answers that by
                    // crossfading the platter and cancelling touch tracking
                    // on the item under the finger.
                    .equatable()
                }
                if filterActive, controller.searchHiddenCount > 0 {
                    Text("\(controller.searchHiddenCount) rows hidden by filter")
                        .font(Typography.tesseraSans(size: 10))
                        .foregroundStyle(T.fgFaint)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
        }
    }

    /// Every backstop transition goes through here so the diagnostics log
    /// carries a complete timeline, and so a redundant write can never
    /// invalidate the card for a value it already holds.
    private func setBackstop(_ requested: Bool, reason: String) {
        let on = FilesDiagnosticsEnvironment.backstopDisabled ? false : requested
        guard backstopOn != on else {
            FilesUIDiagnostics.shared.timeline(
                "backstop-noop", detail: "want=\(on ? 1 : 0) why=\(reason)"
            )
            return
        }
        backstopOn = on
        FilesUIDiagnostics.shared.timeline(
            on ? "backstop-on" : "backstop-off", detail: "why=\(reason)"
        )
    }

    private func panelTouchChanged(_ active: Bool) {
        guard active != panelTouchActive else { return }
        panelTouchActive = active
        FilesUIDiagnostics.shared.timeline(active ? "touch-down" : "touch-up")
        if active {
            FilesUIDiagnostics.shared.scrollBegan(.filesTree)
        } else {
            FilesUIDiagnostics.shared.scrollEnded(.filesTree)
        }
        backstopFailsafeTask?.cancel()
        backstopFailsafeTask = nil
        if active {
            backstopReleaseTask?.cancel()
            backstopReleaseTask = nil
            setBackstop(true, reason: "touch-down")
            // A drag-out session or the context-menu interaction claiming
            // the touch can swallow the drag gesture's `onEnded`; don't
            // let a stale touch flag wedge the card opaque forever.
            backstopFailsafeTask = Task { @MainActor in
                defer { backstopFailsafeTask = nil }
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                guard !Task.isCancelled, presentedMenuItemCount == 0 else { return }
                FilesUIDiagnostics.shared.timeline("backstop-failsafe")
                panelTouchActive = false
                scheduleBackstopRelease(after: 0)
            }
        } else if presentedMenuItemCount == 0 {
            // Bridge the release→preview gap of a menu about to present;
            // if none comes, this quietly stands the card back down.
            scheduleBackstopRelease(after: 0.8)
        }
    }

    private func menuPresenceChanged(present: Bool) {
        presentedMenuItemCount = max(0, presentedMenuItemCount + (present ? 1 : -1))
        FilesUIDiagnostics.shared.menuPresenceDidChange(count: presentedMenuItemCount)
        FilesUIDiagnostics.shared.timeline(present ? "menu-present" : "menu-dismiss")
        if presentedMenuItemCount > 0 {
            backstopReleaseTask?.cancel()
            backstopReleaseTask = nil
            setBackstop(true, reason: "menu-present")
        } else {
            // The menu interaction claimed the long-press touch, so the drag
            // sensor's `onEnded` never fired and `panelTouchActive` is stale-
            // true — gating the release on it wedged the card opaque until
            // the 15s failsafe. Menu gone ⇒ that touch is definitionally
            // over: clear the flag and stand down. A genuinely live touch
            // re-arms via the sensor's next `onChanged` tick.
            panelTouchActive = false
            // The system keeps the glass suppressed ~1s after dismissal;
            // releasing sooner re-exposes the transparent hole.
            scheduleBackstopRelease(after: 0.9)
        }
    }

    private func scheduleBackstopRelease(after seconds: Double) {
        backstopReleaseTask?.cancel()
        FilesUIDiagnostics.shared.timeline(
            "backstop-release-scheduled", detail: "delayMs=\(Int(seconds * 1_000))"
        )
        backstopReleaseTask = Task { @MainActor in
            defer { backstopReleaseTask = nil }
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            guard !panelTouchActive, presentedMenuItemCount == 0 else {
                FilesUIDiagnostics.shared.timeline(
                    "backstop-release-skipped",
                    detail: "touch=\(panelTouchActive ? 1 : 0) menuUp=\(presentedMenuItemCount)"
                )
                return
            }
            setBackstop(false, reason: "release")
        }
    }

    // MARK: - Completion dropdown (§2, shared with quick open §4)

    private func pathSuggestions(
        _ model: PathCompletionModel,
        accept: @escaping (RemoteFileEntry) -> Void
    ) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(model.candidates.enumerated()), id: \.element.path) { index, entry in
                suggestionRow(entry,
                              prefix: model.context?.prefix ?? "",
                              highlighted: index == model.highlightIndex,
                              accept: accept)
            }
        }
        .background(T.isLight ? Color(rgbInt: 0xF2F2F7) : Color(rgbInt: 0x1C1C1E))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(T.borderStrong, lineWidth: 0.5)
        )
    }

    private func suggestionRow(
        _ entry: RemoteFileEntry,
        prefix: String,
        highlighted: Bool,
        accept: @escaping (RemoteFileEntry) -> Void
    ) -> some View {
        Button { accept(entry) } label: {
            HStack(spacing: 7) {
                Image(systemName: filesIconName(for: entry))
                    .font(.system(size: 10))
                    .foregroundStyle(highlighted ? T.accent : T.fgDim)
                    .frame(width: 14)
                suggestionText(entry, prefix: prefix, highlighted: highlighted)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 6)
                if highlighted {
                    // A keycap badge, not prose — the key is engraved "tab"
                    // on every keyboard layout Tessera runs against.
                    Text(verbatim: "tab")
                        .font(Typography.tesseraMono(size: 8.5))
                        .foregroundStyle(T.fgDim)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .overlay(
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .stroke(T.borderStrong, lineWidth: 0.5)
                        )
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(highlighted ? T.accentSoft : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Directories display with a trailing "/"; the typed prefix
    /// renders accent (anchored match only — it IS the prefix).
    private func suggestionText(
        _ entry: RemoteFileEntry, prefix: String, highlighted: Bool
    ) -> Text {
        let display = entry.kind == .directory ? entry.name + "/" : entry.name
        var attr = AttributedString(display)
        attr.foregroundColor = highlighted ? T.fg : T.fgMuted
        if !prefix.isEmpty,
           let range = display.range(of: prefix, options: [.caseInsensitive, .anchored]),
           let attrRange = Range(range, in: attr) {
            attr[attrRange].foregroundColor = T.accent
        }
        return Text(attr).font(Typography.tesseraMono(size: 10.5))
    }

    // MARK: - Quick open popover (§4)

    private var quickOpenPopover: some View {
        quickOpenContent
            .padding(12)
            .frame(width: 300)
            .presentationBackground(T.isLight ? Color(rgbInt: 0xF2F2F7) : Color(rgbInt: 0x1C1C1E))
            .onAppear { quickOpenFocused = true }
            .onDisappear { resetQuickOpen() }
    }

    private var compactQuickOpen: some View {
        quickOpenContent
            .padding(10)
            .background(T.inputBg)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(T.border, lineWidth: 0.5)
            )
            .onAppear { quickOpenFocused = true }
            .onDisappear { resetQuickOpen() }
    }

    private var quickOpenContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "doc.viewfinder")
                    .font(.system(size: 11))
                    .foregroundStyle(T.fgMuted)
                Text("open by path")
                    .font(Typography.tesseraMono(size: 11.5, weight: .medium))
                    .foregroundStyle(T.fg)
            }
            quickOpenField
            if !quickOpenCompletion.candidates.isEmpty {
                pathSuggestions(quickOpenCompletion) { acceptQuickOpenSuggestion($0) }
            }
            HStack(spacing: 10) {
                Text("⏎ file → Quick Look")
                Text("dir → browse there")
            }
            .font(Typography.tesseraSans(size: 10))
            .foregroundStyle(T.fgDim)
            if quickOpenText.isEmpty, !controller.recentQuickOpenPaths.isEmpty {
                quickOpenRecents
            }
        }
    }

    private func resetQuickOpen() {
        quickOpenText = ""
        quickOpenCompletion.clear()
    }

    private let quickOpenPlaceholder = "~/path/to/file"

    private var quickOpenField: some View {
        HStack(spacing: 6) {
            // A sample path, not prose — it must read the same in every
            // language, so it goes through `TextField`'s StringProtocol
            // overload rather than being extracted as a key.
            TextField(quickOpenPlaceholder, text: $quickOpenText)
                .font(Typography.tesseraMono(size: 10.5))
                .foregroundStyle(T.fg)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($quickOpenFocused)
                .submitLabel(.go)
                .onKeyPress(.escape) {
                    if !quickOpenCompletion.candidates.isEmpty {
                        quickOpenCompletion.clear()
                    } else {
                        showingQuickOpen = false
                    }
                    return .handled
                }
                .onKeyPress(.tab) {
                    acceptHighlighted(of: quickOpenCompletion, into: $quickOpenText)
                    return .handled
                }
                .onKeyPress(.upArrow) {
                    quickOpenCompletion.move(-1)
                    return .handled
                }
                .onKeyPress(.downArrow) {
                    quickOpenCompletion.move(1)
                    return .handled
                }
                .onKeyPress(keys: [.return], phases: .down) { _ in
                    commitQuickOpen()
                    return .handled
                }
                .onSubmit { commitQuickOpen() }
                .onChange(of: quickOpenText) { _, text in
                    quickOpenCompletion.update(typed: text, controller: controller)
                }
        }
        .padding(.horizontal, 8)
        .frame(minHeight: 28)
        .background(T.inputBg)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(quickOpenFocused ? T.accent : T.border,
                        lineWidth: quickOpenFocused ? 1 : 0.5)
        )
    }

    private var quickOpenRecents: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("RECENT")
                .font(Typography.tesseraMono(size: 8.5))
                .foregroundStyle(T.fgFaint)
                .padding(.top, 2)
            ForEach(controller.recentQuickOpenPaths, id: \.self) { path in
                Button {
                    quickOpenText = path
                    commitQuickOpen()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "clock")
                            .font(.system(size: 9))
                            .foregroundStyle(T.fgDim)
                        Text(homeAbbreviated(path))
                            .font(Typography.tesseraMono(size: 10))
                            .foregroundStyle(T.fgMuted)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .padding(.vertical, 3)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func commitQuickOpen() {
        if quickOpenCompletion.shouldAcceptOnReturn(for: quickOpenText) {
            acceptHighlighted(of: quickOpenCompletion, into: $quickOpenText)
        }
        let text = quickOpenText
        quickOpenCompletion.clear()
        Task {
            if await controller.quickOpen(text) {
                showingQuickOpen = false
            }
        }
    }

    private func acceptQuickOpenSuggestion(_ entry: RemoteFileEntry) {
        if let accepted = quickOpenCompletion.accept(entry: entry, typed: quickOpenText) {
            quickOpenText = accepted
        }
    }

    private func homeAbbreviated(_ path: String) -> String {
        guard let home = controller.bridge?.homeDirectory,
              path == home || path.hasPrefix(home + "/") else { return path }
        return "~" + path.dropFirst(home.count)
    }

    // MARK: - Transfer strip

    private func transferStrip(_ transfers: any TransferQueueing) -> some View {
        VStack(spacing: 6) {
            Rectangle().fill(T.border).frame(height: 0.5)
            ForEach(transfers.items.suffix(3)) { item in
                transferRow(item, transfers: transfers)
            }
        }
        .padding(.bottom, 10)
    }

    @ViewBuilder
    private func transferRow(_ item: TransferItem, transfers: any TransferQueueing) -> some View {
        VStack(spacing: 5) {
            HStack(spacing: 8) {
                Image(systemName: item.direction == .upload ? "arrow.up" : "arrow.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(transferTint(item.phase))
                Text(item.displayName)
                    .font(Typography.tesseraMono(size: 10))
                    .foregroundStyle(T.fg)
                    .lineLimit(1)
                    .truncationMode(.middle)
                transferDetail(item)
                    .font(Typography.tesseraMono(size: 9.5))
                    .foregroundStyle(T.fgDim)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if item.phase.canCancel {
                    Button {
                        transfers.cancel(item)
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(T.fgDim)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            if let fraction = item.phase.visibleProgressFraction {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(T.fgFaint)
                        if let fraction {
                            Capsule()
                                .fill(T.accent)
                                .frame(width: max(2, geo.size.width * fraction))
                        }
                    }
                }
                .frame(height: 3)
            }
        }
        .padding(.horizontal, 12)
    }

    private func transferTint(_ phase: TransferPhase) -> Color {
        switch phase {
        case .completed: return T.green
        case .failed: return T.red
        case .cancelled: return T.fgDim
        case .queued, .running, .cancelling: return T.accent
        }
    }

    /// A `Text` rather than a `String`: the running-upload case shows a raw
    /// remote path and the failure case a server message, and neither should
    /// be looked up as a key.
    private func transferDetail(_ item: TransferItem) -> Text {
        switch item.phase {
        case .queued: return Text("queued")
        case .running:
            return item.direction == .upload
                ? Text(verbatim: "→ \(item.remotePath)")
                : Text("downloading")
        case .cancelling: return Text("cancelling…")
        case .completed: return Text("done")
        case .failed(let message): return Text(verbatim: message)
        case .cancelled: return Text("cancelled")
        }
    }
}

private extension TransferPhase {
    var canCancel: Bool {
        switch self {
        case .queued, .running: return true
        case .cancelling, .completed, .failed, .cancelled: return false
        }
    }

    var visibleProgressFraction: Double?? {
        switch self {
        case .running(let fraction), .cancelling(let fraction): return .some(fraction)
        case .queued, .completed, .failed, .cancelled: return nil
        }
    }
}

/// SF Symbol for a listing entry. Shared by the outline rows and the path
/// completion dropdown.
private func filesIconName(for entry: RemoteFileEntry) -> String {
    switch entry.kind {
    case .directory: return "folder"
    case .symlink: return "arrow.triangle.turn.up.right.diamond"
    case .other: return "questionmark.square.dashed"
    case .file:
        let ext = (entry.name as NSString).pathExtension.lowercased()
        switch ext {
        case "png", "jpg", "jpeg", "gif", "heic", "webp", "svg", "bmp", "tiff":
            return "photo"
        case "mp4", "mov", "mkv", "avi", "webm":
            return "film"
        case "md", "txt", "log", "rst":
            return "doc.text"
        case "zip", "tar", "gz", "bz2", "xz", "7z", "rar":
            return "shippingbox"
        case "pdf":
            return "doc.richtext"
        default:
            return "doc"
        }
    }
}

/// One outline row, isolated from the panel's own re-render churn.
///
/// The panel body re-evaluates on ordinary session traffic — the cwd poller
/// reports, a transfer finishes, the listing reloads — and SwiftUI builds
/// `.contextMenu`'s items AND its preview eagerly for every row it touches.
/// Handing that rebuilt menu to a LIVE `UIContextMenuInteraction` makes UIKit
/// crossfade the platter (the flicker) and cancel the touch tracking on the
/// item under the finger, so the tap never lands — measured 2026-08-20 on a
/// 220-row listing: every panel pass rebuilt all 52 realized rows, and
/// XCUITest reported the menu item as a zero-size, non-hittable element.
/// `Equatable` + `.equatable()` at the call site is what stops that: unless
/// this row's own data changed, SwiftUI never reaches the menu.
///
/// Every input the row draws from must therefore be a stored, comparable
/// property. Reaching into `controller` for display state inside `body` would
/// both re-register observation and escape the equality check — read it in
/// the parent and pass the value. Actions are the exception: they run at tap
/// time, long after the body, so they may go through `controller`.
private struct FileRowView: View, Equatable {

    /// Which context-menu actions the session wired up. Compared, so a
    /// handler installed later still rebuilds the menu.
    struct MenuCapabilities: Equatable {
        var canPreview = false
        var canDownload = false
        var canShare = false
        var canSendPath = false
    }

    let row: FilesPanelController.Row
    let T: DesignTokens
    let filterActive: Bool
    /// Empty unless the filter is active; drives the match highlight.
    let searchText: String
    /// Panel root — the "src/components/" tag on a flattened match.
    let rootDirectory: String?
    let isExpanded: Bool
    let isLoading: Bool
    let canDrag: Bool
    let capabilities: MenuCapabilities

    /// The panel's single long-lived model object; compared by identity.
    let controller: FilesPanelController
    @Binding var renameTarget: RemoteFileEntry?
    @Binding var renameText: String
    @Binding var deleteTarget: RemoteFileEntry?
    let onMenuPresence: (Bool) -> Void

    /// Bindings and closures are not comparable. They stay out of `==`
    /// because they are stable for the lifetime of this row's identity —
    /// they address the panel's `@State` storage, not a captured snapshot.
    static func == (a: FileRowView, b: FileRowView) -> Bool {
        #if DEBUG
        // Test seam: `TESSERA_FILES_ROW_EQUATABLE=0` forces every comparison
        // to miss, which reinstates the pre-fix behaviour (every panel pass
        // rebuilds every realized row) so the probe can record the
        // bug-present arm from the shipping binary.
        if FilesDiagnosticsEnvironment.rowEquatableDisabled { return false }
        #endif
        return a.row == b.row
            && a.filterActive == b.filterActive
            && a.searchText == b.searchText
            && a.rootDirectory == b.rootDirectory
            && a.isExpanded == b.isExpanded
            && a.isLoading == b.isLoading
            && a.canDrag == b.canDrag
            && a.capabilities == b.capabilities
            && a.controller === b.controller
            && a.T == b.T
    }

    private var entry: RemoteFileEntry { row.entry }

    @ViewBuilder
    var body: some View {
        if FilesDiagnosticsEnvironment.uikitMenuDisabled {
            swiftUIBody
        } else {
            uikitBody
        }
    }

    /// Tap, menu, and drag all live on one transparent UIKit view laid over
    /// the row. SwiftUI's `.contextMenu` repaints its platter for several
    /// frames after presenting — the single flicker just after the menu
    /// opens — where UIKit's own interaction settles inside the presentation
    /// animation. See `FileRowInteraction`.
    private var uikitBody: some View {
        let _ = FilesUIDiagnostics.shared.rowBuild()
        return label
            .accessibilityHidden(true)
            .overlay {
                FileRowInteraction(
                    identifier: "files.row.\(entry.name)",
                    accessibilityLabel: accessibilityDescription,
                    sections: menuSections,
                    onPrimary: primaryAction,
                    onMenuPresence: onMenuPresence,
                    dragProvider: dragProvider,
                    makePreview: FilesDiagnosticsEnvironment.menuPreviewDisabled
                        ? nil
                        : { AnyView(menuPreview) },
                    previewWidth: FilesPanelView.width - 24
                )
            }
    }

    /// The SwiftUI label is hidden from accessibility so the row is one
    /// element, not two — so its description has to be rebuilt here.
    private var accessibilityDescription: String {
        switch entry.kind {
        case .directory:
            return String(
                localized: "\(entry.name), folder",
                comment: "VoiceOver description for a named directory in the remote Files browser"
            )
        case .symlink:
            return String(
                localized: "\(entry.name), link",
                comment: "VoiceOver description for a named symbolic link in the remote Files browser"
            )
        case .other:
            return entry.name
        case .file:
            return meta == "–"
                ? entry.name
                : String(
                    localized: "\(entry.name), \(meta)",
                    comment: "VoiceOver description for a named remote file followed by its localized metadata"
                )
        }
    }

    private func primaryAction() {
        if entry.kind == .directory {
            controller.toggleExpanded(entry)
        } else if entry.kind != .other {
            controller.onPreviewFile?(entry)
        }
    }

    private var dragProvider: (() -> NSItemProvider?)? {
        guard canDrag, !FilesDiagnosticsEnvironment.rowDragDisabled else { return nil }
        return { controller.dragItemProvider(for: entry) }
    }

    /// The menu, as data. UIKit builds the platter from this only when a
    /// menu is actually presented, so a row rebuild can no longer reach a
    /// live `UIMenu` — the repeated flicker is now structurally impossible,
    /// not just short-circuited by `==`.
    private var menuSections: [[FileRowMenuAction]] {
        var primary: [FileRowMenuAction] = []
        if entry.kind != .directory {
            if capabilities.canPreview {
                primary.append(FileRowMenuAction(title: "Quick Look", systemImage: "eye") {
                    controller.onPreviewFile?(entry)
                })
            }
            if capabilities.canDownload {
                primary.append(FileRowMenuAction(
                    title: "Download", systemImage: "arrow.down.circle"
                ) {
                    controller.onDownloadFile?(entry)
                })
            }
            if capabilities.canShare {
                primary.append(FileRowMenuAction(
                    title: "Share…", systemImage: "square.and.arrow.up"
                ) {
                    controller.onShareFile?(entry)
                })
            }
        }
        if capabilities.canSendPath {
            primary.append(FileRowMenuAction(
                title: "Send Path to Terminal", systemImage: "terminal"
            ) {
                controller.onSendPathToTerminal?(entry.path)
            })
        }
        primary.append(FileRowMenuAction(title: "Copy Path", systemImage: "doc.on.doc") {
            UIPasteboard.general.string = entry.path
        })

        let edits = [
            FileRowMenuAction(title: "Rename", systemImage: "pencil") {
                renameText = entry.name
                renameTarget = entry
            },
            FileRowMenuAction(title: "Delete…", systemImage: "trash", isDestructive: true) {
                deleteTarget = entry
            },
        ]
        return [primary, edits]
    }

    @ViewBuilder
    private var swiftUIBody: some View {
        if canDrag, !FilesDiagnosticsEnvironment.rowDragDisabled {
            base.onDrag {
                controller.dragItemProvider(for: entry) ?? NSItemProvider()
            }
        } else {
            base
        }
    }

    @ViewBuilder
    private var base: some View {
        #if DEBUG
        if FilesDiagnosticsEnvironment.menuPreviewDisabled {
            rowButton.contextMenu { menuItems }
        } else {
            rowButton.contextMenu { menuItems } preview: { menuPreview }
        }
        #else
        rowButton.contextMenu { menuItems } preview: { menuPreview }
        #endif
    }

    private var rowButton: some View {
        FilesUIDiagnostics.shared.rowBuild()
        return Button(action: primaryAction) {
            label
        }
        .buttonStyle(.plain)
        // Stable target for UI tests (the visible label folds in the size
        // column, so name-based matching is brittle).
        .accessibilityIdentifier("files.row.\(entry.name)")
    }

    private var label: some View {
        HStack(spacing: 7) {
            if row.depth > 0, !filterActive {
                Spacer().frame(width: CGFloat(row.depth) * 14)
            }
            Group {
                if entry.kind == .directory {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8.5, weight: .semibold))
                        .foregroundStyle(T.fgDim)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                } else {
                    Spacer().frame(width: 9)
                }
            }
            .frame(width: 10)
            Image(systemName: filesIconName(for: entry))
                .font(.system(size: 11))
                .foregroundStyle(entry.isHidden ? T.fgDim : T.fgMuted)
                .frame(width: 14)
            nameText
                .font(Typography.tesseraMono(
                    size: 11, weight: entry.kind == .directory ? .medium : .regular))
                .foregroundStyle(entry.isHidden ? T.fgDim : T.fg)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            if filterActive, row.depth > 0 {
                // Flattened match from an expanded subfolder: show where
                // it lives instead of size (mockup §1).
                Text(parentTag)
                    .font(Typography.tesseraMono(size: 9))
                    .foregroundStyle(T.fgFaint)
                    .lineLimit(1)
                    .truncationMode(.head)
            } else if isLoading {
                ProgressView()
                    .controlSize(.mini)
                    .tint(T.fgDim)
            } else {
                Text(meta)
                    .font(Typography.tesseraMono(size: 9.5))
                    .foregroundStyle(T.fgDim)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4.5)
        .contentShape(Rectangle())
    }

    /// The lifted preview shown with the context menu. Doubles as the
    /// presentation detector: menu ITEMS are bridged to UIKit `UIMenu`
    /// elements and never get view lifecycle, but the preview is a real
    /// hosted SwiftUI view — its `onAppear`/`onDisappear` fire exactly at
    /// present/dismiss, driving the card's opaque backstop. The platter
    /// background also keeps the row readable while lifted (the default
    /// preview is the bare row over the terminal). Sim-verified 2026-07-09
    /// via the `TESSERA_FILES_HARNESS` debug screen.
    ///
    /// NOTE: SwiftUI evaluates this property (and `menuItems`) eagerly
    /// whenever it builds the row — only the `onAppear`/`onDisappear` below
    /// track actual presentation. Never put side effects in the body itself.
    private var menuPreview: some View {
        FilesUIDiagnostics.shared.menuPreviewBuild()
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        return label
            .padding(.vertical, 3)
            .frame(width: FilesPanelView.width - 24)
            .background(T.isLight ? Color(rgbInt: 0xF2F2F7) : Color(rgbInt: 0x1C1C1E), in: shape)
            .overlay { shape.stroke(T.border, lineWidth: 0.5) }
            .modifier(MenuPresenceReporter(report: onMenuPresence))
    }

    /// On the UIKit path the interaction's delegate reports presentation, so
    /// the hosted preview must not report it a second time — a doubled count
    /// keeps the backstop armed past the dismissal animation.
    private struct MenuPresenceReporter: ViewModifier {
        let report: (Bool) -> Void

        @ViewBuilder
        func body(content: Content) -> some View {
            if FilesDiagnosticsEnvironment.uikitMenuDisabled {
                content
                    .onAppear { report(true) }
                    .onDisappear { report(false) }
            } else {
                content
            }
        }
    }

    @ViewBuilder
    private var menuItems: some View {
        let _ = FilesUIDiagnostics.shared.menuBuild()
        if entry.kind != .directory {
            if capabilities.canPreview {
                Button { controller.onPreviewFile?(entry) } label: {
                    Label("Quick Look", systemImage: "eye")
                }
            }
            if capabilities.canDownload {
                Button { controller.onDownloadFile?(entry) } label: {
                    Label("Download", systemImage: "arrow.down.circle")
                }
            }
            if capabilities.canShare {
                Button { controller.onShareFile?(entry) } label: {
                    Label("Share…", systemImage: "square.and.arrow.up")
                }
            }
        }
        if capabilities.canSendPath {
            // Also the Claude Code image-attach gesture (mockup §7's
            // "Attach to Session" accelerator was dropped as redundant
            // — the onboarding tour will teach this instead).
            Button { controller.onSendPathToTerminal?(entry.path) } label: {
                Label("Send Path to Terminal", systemImage: "terminal")
            }
        }
        Button {
            UIPasteboard.general.string = entry.path
        } label: {
            Label("Copy Path", systemImage: "doc.on.doc")
        }
        Divider()
        Button {
            renameText = entry.name
            renameTarget = entry
        } label: {
            Label("Rename", systemImage: "pencil")
        }
        Button(role: .destructive) {
            deleteTarget = entry
        } label: {
            Label("Delete…", systemImage: "trash")
        }
    }

    /// Name label; while filtering, the matched range renders accent.
    private var nameText: Text {
        guard filterActive,
              let range = entry.name.range(of: searchText, options: .caseInsensitive) else {
            return Text(entry.name)
        }
        var attr = AttributedString(entry.name)
        if let attrRange = Range(range, in: attr) {
            attr[attrRange].foregroundColor = T.accent
        }
        return Text(attr)
    }

    private var meta: String {
        switch entry.kind {
        case .directory: return "–"
        case .symlink: return "link"
        case .other: return "–"
        case .file:
            guard let size = entry.size else { return "–" }
            return ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
        }
    }

    /// "src/components/" for a match two levels under the panel root.
    private var parentTag: String {
        guard let root = rootDirectory else { return "" }
        let parent = (entry.path as NSString).deletingLastPathComponent
        guard parent.hasPrefix(root), parent.count > root.count else { return "" }
        return parent.dropFirst(root.count + (root == "/" ? 0 : 1)) + "/"
    }
}

// MARK: - Path completion model (§2, required; quick open reuses it)

/// Debounced completion state for one path field. Pure matching lives
/// in `RemotePathResolver`; this owns only the async fetch + highlight
/// cursor, so the two hosting fields (path bar, quick open) stay in
/// lockstep by construction.
@MainActor
@Observable
final class PathCompletionModel {
    private(set) var candidates: [RemoteFileEntry] = []
    private(set) var context: RemotePathResolver.CompletionContext?
    private(set) var highlightIndex = 0
    /// The field text these candidates were computed FOR — auto-accept
    /// paths must check it so debounce-stale results never rewrite
    /// newer input.
    private(set) var typedSnapshot: String?
    @ObservationIgnored private var task: Task<Void, Never>?

    func isCurrent(for typed: String) -> Bool {
        typedSnapshot == typed
    }

    var highlightedEntry: RemoteFileEntry? {
        candidates.indices.contains(highlightIndex) ? candidates[highlightIndex] : nil
    }

    /// ⏎ auto-accepts only mid-segment (with an empty prefix the
    /// dropdown is just a directory listing and ⏎ must navigate to
    /// what was typed) and only when the dropdown matches the current
    /// field text.
    func shouldAcceptOnReturn(for typed: String) -> Bool {
        !candidates.isEmpty
            && isCurrent(for: typed)
            && !(context?.prefix.isEmpty ?? true)
    }

    /// ~150 ms debounce: imperceptible while typing, coalesces
    /// cold-parent listDirectory fetches into one.
    func update(typed: String, controller: FilesPanelController) {
        task?.cancel()
        task = Task { [weak self, weak controller] in
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled, let self else { return }
            let result = await controller?.completionEntries(forTyped: typed)
            // A superseded (cancelled) fetch must not touch state at
            // all — clearing here would wipe the NEWER task's results
            // when the old fetch loses the race.
            guard !Task.isCancelled else { return }
            guard let result else {
                self.clearResults()
                return
            }
            self.context = result.context
            self.candidates = RemotePathResolver.completions(
                prefix: result.context.prefix, in: result.entries)
            self.typedSnapshot = typed
            self.highlightIndex = 0
        }
    }

    func clear() {
        task?.cancel()
        task = nil
        clearResults()
    }

    private func clearResults() {
        candidates = []
        context = nil
        typedSnapshot = nil
        highlightIndex = 0
    }

    func move(_ delta: Int) {
        guard !candidates.isEmpty else { return }
        highlightIndex = (highlightIndex + delta + candidates.count) % candidates.count
    }

    /// Replacement field text for accepting `entry`: swaps the segment
    /// after the last "/", appending "/" for directories so the user
    /// keeps typing deeper (tab semantics).
    func accept(entry: RemoteFileEntry, typed: String) -> String? {
        let base: String
        if let slash = typed.lastIndex(of: "/") {
            base = String(typed[...slash])
        } else {
            base = ""
        }
        var text = base + entry.name
        if entry.kind == .directory { text += "/" }
        return text
    }
}

/// §2's "pre-filled + fully selected" requirement: SwiftUI only exposes
/// text selection from iOS 18 (`TextField(_:text:selection:)`), so this
/// tiny wrapper owns the `TextSelection` state and selects-all when the
/// field appears. Pre-18 callers fall back to a plain field (cursor at
/// the end) — same flow, one keystroke less convenient.
@available(iOS 18.0, *)
private struct SelectAllOnAppearTextField: View {
    @Binding var text: String
    @State private var selection: TextSelection?

    var body: some View {
        TextField("path", text: $text, selection: $selection)
            .onAppear {
                guard !text.isEmpty else { return }
                selection = TextSelection(range: text.startIndex..<text.endIndex)
            }
    }
}

// MARK: - Preview

#Preview("Files panel — mock host", traits: .fixedLayout(width: 380, height: 760)) {
    let controller = FilesPanelController()
    let bridge = MockFileBridge()
    controller.attach(bridge: bridge)
    controller.open()
    controller.terminalReportedDirectory("/home/mock/projects/dashboard")
    return FilesPanelView(
        controller: controller,
        T: DesignTokens.make(mode: .dark, accent: .blue)
    )
    .background(Color.black)
    .environment(AppearancePreferences())
}
