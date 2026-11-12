import SwiftUI

/// A rail glyph for something on screen while it is on. A toggle rather
/// than a button so it reads as pressed, and is announced as selected.
struct RailToggle: View {
    let title: LocalizedStringKey
    let systemImage: String
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Toggle(isOn: Binding(get: { isOn }, set: { _ in action() })) {
            Label(title, systemImage: systemImage)
        }
    }
}

/// The rail's book, pressed while the context is on screen.
struct RailContextToggle: View {
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        RailToggle(title: "context", systemImage: "book", isOn: isOn, action: action)
    }
}

struct RailSessionToolbar: ToolbarContent {
    let sessionID: UUID?
    let actions: SessionRailActions?
    let onBack: () -> Void
    let onOpenPalette: () -> Void
    let onToggleContext: () -> Void
    /// Only two panes have room for the context; one pane shows no book.
    let showsContext: Bool
    /// The context is beside the main pane, so the book reads as pressed.
    var contextShown = false
    let onNewHost: () -> Void

    private var selectedActions: SessionRailActions? {
        RailShellPolicy.sessionActions(for: sessionID, published: actions)
    }

    var body: some ToolbarContent {
        if sessionID != nil {
            ToolbarItem(placement: .cancellationAction) {
                Button("back", systemImage: "chevron.left", action: onBack)
                    .railGlyph()
                    .accessibilityIdentifier("duo-rail-back")
            }

            #if compiler(>=6.4)
            if #available(iOS 27.0, *) {
                prioritizedActions
            } else {
                standardActions
            }
            #else
            standardActions
            #endif
        } else {
            ToolbarItem(placement: .primaryAction) {
                Button("new host", systemImage: "plus", action: onNewHost)
                    .railGlyph()
                    .accessibilityIdentifier("duo-rail-new-host")
            }
        }
    }

    #if compiler(>=6.4)
    @available(iOS 27.0, *)
    @ToolbarContentBuilder
    private var prioritizedActions: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) { switcherButton }
            .visibilityPriority(.high)
        if let actions = selectedActions, actions.canCreateTmuxWindow {
            ToolbarItem(placement: .primaryAction) { newWindowButton(actions) }
                .visibilityPriority(.high)
        }
        if showsContext {
            ToolbarItem(placement: .primaryAction) { contextButton }
                .visibilityPriority(.high)
        }
        if let actions = selectedActions {
            // Often needed, so standard priority: the tabs fold to make room
            // for them, and they go into ⋯ before the items above when the
            // rail is short. At low priority they would never earn a slot.
            ToolbarItem(placement: .primaryAction) { findToggle(actions) }
            ToolbarItem(placement: .primaryAction) { filesToggle(actions) }
            ToolbarOverflowMenu {
                overflowActions(actions).railGlyph()
            }
        }
    }
    #endif

    @ToolbarContentBuilder
    private var standardActions: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) { switcherButton }
        if let actions = selectedActions, actions.canCreateTmuxWindow {
            ToolbarItem(placement: .primaryAction) { newWindowButton(actions) }
        }
        if showsContext {
            ToolbarItem(placement: .primaryAction) { contextButton }
        }
        if let actions = selectedActions {
            ToolbarItem(placement: .secondaryAction) { findToggle(actions) }
            overflowItem(actions)
        }
    }

    private var switcherButton: some View {
        Button("switcher", systemImage: "chevron.down") {
            SessionRailPolicy.openSwitcher(sessionID: sessionID, actions: actions, fallback: onOpenPalette)
        }
            .railGlyph()
            .accessibilityIdentifier("duo-rail-switcher")
    }

    private var contextButton: some View {
        RailContextToggle(isOn: contextShown, action: onToggleContext)
            .railGlyph()
            .accessibilityIdentifier("duo-rail-context")
    }

    private func newWindowButton(_ actions: SessionRailActions) -> some View {
        Button("new tmux window", systemImage: "plus", action: actions.createTmuxWindow)
            .railGlyph()
            .accessibilityIdentifier("duo-rail-new-window")
    }

    private func findToggle(_ actions: SessionRailActions) -> some View {
        RailToggle(title: "find", systemImage: "magnifyingglass", isOn: actions.findOpen,
                   action: actions.toggleFind)
            .railGlyph()
            .accessibilityIdentifier("duo-rail-find")
    }

    private func filesToggle(_ actions: SessionRailActions) -> some View {
        RailToggle(title: "files", systemImage: "folder", isOn: actions.filesOpen,
                   action: actions.toggleFiles)
            .railGlyph()
            .accessibilityIdentifier("duo-rail-files")
    }

    private func overflowItem(_ actions: SessionRailActions) -> some ToolbarContent {
        ToolbarItem(placement: .secondaryAction) {
            Menu {
                filesToggle(actions)
                overflowActions(actions)
            } label: {
                Label("more", systemImage: "ellipsis")
            }
            .railGlyph()
            .accessibilityIdentifier("duo-rail-overflow")
        }
    }

    @ViewBuilder
    private func overflowActions(_ actions: SessionRailActions) -> some View {
        if actions.hasForwarding {
            Button("port forwards", systemImage: "arrow.left.arrow.right", action: actions.showForwarding)
                .accessibilityIdentifier("duo-rail-forwarding")
        }
        if actions.hasContinuity {
            Button("continue on another device", systemImage: "laptopcomputer.and.iphone",
                   action: actions.showContinuity)
                .accessibilityIdentifier("duo-rail-continuity")
        }
        Button("disconnect", systemImage: "xmark", role: .destructive, action: actions.disconnect)
            .accessibilityIdentifier("duo-rail-disconnect")
    }
}

private extension View {
    /// Rail glyphs are monochrome: the back chevron, the actions, a lit toggle
    /// and the ⋯ menu's icons. Set on each item, since a tint on the tab's
    /// content would also take the accent from the tab bar's selection.
    func railGlyph() -> some View { tint(.primary) }
}
