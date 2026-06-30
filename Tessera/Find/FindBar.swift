import SwiftUI

/// Slide-in find bar that appears below `SessionTopBar` when
/// `controller.isOpen` is true. Mirrors the v2 chrome look — same
/// `topBarHeight`-driven scale, same `accentSoft` toggled fill, same
/// monospace typography — so the bar reads as part of the top chrome
/// rather than a foreign overlay.
///
/// Layout: a search-icon-prefixed input on the left, three small
/// option toggles (case / whole-word / regex), then ↑ ↓ ✕ icon
/// buttons. The bar respects the user's `topBarHeight` slider via
/// the same `scale = topBarHeight / defaultTopBarHeight` formula
/// `SessionTopBar` uses, so all three chrome strips (top bar, find,
/// accessory) shrink and grow together.
struct FindBar: View {
    @Bindable var controller: FindController
    let horizontalInset: CGFloat
    /// Theme-derived chrome tokens — same value `SessionTopBar`
    /// receives so the bar follows the active TerminalTheme.
    let T: DesignTokens

    @Environment(AppearancePreferences.self) private var appearance
    @FocusState private var inputFocused: Bool

    private var scale: CGFloat {
        max(0.6, CGFloat(appearance.topBarHeight) / CGFloat(AppearancePreferences.defaultTopBarHeight))
    }

    /// Bar height — taller than the top bar by 4pt so the input has
    /// room to breathe but the strip still reads as compact chrome.
    private var barHeight: CGFloat {
        appearance.topBarHeight + 4
    }

    var body: some View {
        HStack(spacing: 10 * scale) {
            input
            optionToggles
            actions
        }
        .padding(.horizontal, horizontalInset)
        .frame(maxWidth: .infinity)
        .frame(height: barHeight)
        .background(T.bg)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(T.border)
                .frame(height: 0.5)
        }
        .onChange(of: controller.isOpen) { _, nowOpen in
            if nowOpen, !controller.query.isEmpty {
                // If the user re-opens the bar with a query already
                // typed, re-scan + jump to the first match instead of
                // making them retype or press Enter.
                controller.updateSearch()
            }
        }
        // Re-focus on every `open()` call (including when the bar was
        // already open and the user pressed ⌘F again or tapped the
        // magnifying glass — `isOpen` wouldn't change in that case so
        // an `onChange(of: isOpen)` wouldn't fire).
        .onChange(of: controller.focusRequestToken) { _, _ in
            inputFocused = true
        }
        .onAppear {
            // Cover the first-show case: when the bar is rendered for
            // the first time, the focus-token onChange hasn't fired
            // yet because there's no prior value to compare against.
            inputFocused = true
        }
        .onChange(of: controller.query) { _, _ in
            controller.updateSearch()
        }
        // Enter / Shift+Enter cycle through matches without losing
        // focus. Returning `.handled` short-circuits SwiftUI's submit
        // pipeline so the TextField doesn't fire its native submit
        // behavior (which would surrender first responder back to the
        // terminal under some iPadOS keyboard configurations).
        .onKeyPress(keys: [.return], phases: .down) { keyPress in
            if keyPress.modifiers.contains(.shift) {
                controller.previous()
            } else {
                controller.next()
            }
            return .handled
        }
        // Esc is not registered as a UIKeyCommand on the terminal
        // container — esc-as-0x1B must keep flowing to the terminal
        // when the find bar is closed. Hooking it here means esc only
        // closes the bar while the find input has first responder.
        .onKeyPress(.escape) {
            controller.close()
            return .handled
        }
    }

    // MARK: - Input

    @ViewBuilder
    private var input: some View {
        HStack(spacing: 8 * scale) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11 * scale))
                .foregroundStyle(T.fgDim)

            TextField("find in scrollback", text: $controller.query)
                .font(Typography.tesseraMono(size: 12 * scale))
                .foregroundStyle(T.fg)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($inputFocused)
                // Submission handled via `.onKeyPress(.return)` below
                // so Enter advances to the next match without dropping
                // focus back to the terminal. `submitLabel(.search)`
                // is purely cosmetic for soft-keyboard users.
                .submitLabel(.search)

            counter
        }
        .padding(.horizontal, 10 * scale)
        .frame(height: 26 * scale)
        .frame(maxWidth: .infinity)
        .background(T.inputBg)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(inputFocused ? T.accent : T.border, lineWidth: inputFocused ? 1 : 0.5)
        )
    }

    @ViewBuilder
    private var counter: some View {
        if controller.query.isEmpty {
            EmptyView()
        } else if controller.matchCount == 0 {
            Text("no matches")
                .font(Typography.tesseraMono(size: 11 * scale))
                .foregroundStyle(T.fgDim)
        } else {
            Text("\(controller.currentMatchIndex) of \(controller.matchCount)")
                .font(Typography.tesseraMono(size: 11 * scale))
                .foregroundStyle(T.fgDim)
                .monospacedDigit()
        }
    }

    // MARK: - Option toggles (Aa / [w] / .*)

    @ViewBuilder
    private var optionToggles: some View {
        HStack(spacing: 2 * scale) {
            toggle(label: "Aa", isOn: controller.caseSensitive, hint: "case sensitive") {
                controller.caseSensitive.toggle()
                controller.updateSearch()
            }
            toggle(label: "[w]", isOn: controller.wholeWord, hint: "whole word") {
                controller.wholeWord.toggle()
                controller.updateSearch()
            }
            toggle(label: ".*", isOn: controller.regex, hint: "regex") {
                controller.regex.toggle()
                controller.updateSearch()
            }
        }
    }

    private func toggle(
        label: String,
        isOn: Bool,
        hint: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(label)
                .font(Typography.tesseraMono(size: 11 * scale, weight: isOn ? .semibold : .regular))
                .foregroundStyle(isOn ? T.accent : T.fgMuted)
                .padding(.horizontal, 7 * scale)
                .frame(height: 22 * scale)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(isOn ? T.accentSoft : Color.clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(hint)
    }

    // MARK: - Action buttons (↑ ↓ ✕)

    @ViewBuilder
    private var actions: some View {
        HStack(spacing: 2 * scale) {
            actionButton(systemName: "arrow.up", label: "previous match") {
                controller.previous()
            }
            actionButton(systemName: "arrow.down", label: "next match") {
                controller.next()
            }
            actionButton(systemName: "xmark", label: "close") {
                controller.close()
            }
        }
    }

    private func actionButton(
        systemName: String,
        label: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 11 * scale, weight: .medium))
                .foregroundStyle(T.fgMuted)
                .frame(width: 24 * scale, height: 22 * scale)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}
