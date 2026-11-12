import SwiftUI
import TesseraArtifactsCore

/// An address being edited in this bar, and what its keys do.
struct ArtifactAddressEditing {
    let entry: ArtifactAddressEntry
    let submit: () -> Void
    let cancel: () -> Void
}

/// Regular widths: show sidebar while it is hidden, back, forward, the
/// address field, reload, share, new tab, tab overview and the tab's
/// actions, one row. A phone: back to the overview, the address and close.
@MainActor
struct ArtifactAddressBar: View {
    @Environment(\.designTokens) private var T
    @Environment(\.duoTitleSwitcher) private var openSwitcher
    @Environment(\.artifactsRevealSidebar) private var revealSidebar
    let store: any ArtifactsBrowserStore
    let tab: ArtifactTab?
    let webModel: ArtifactWebViewModel?
    var compact = false
    var showsOverview = false
    let editing: ArtifactAddressEditing?
    let onEditAddress: () -> Void
    var onNewTab: () -> Void = {}
    var onOverview: () -> Void = {}
    var onBackToOverview: (() -> Void)?
    let onRefresh: () -> Void
    var shareRequest: Binding<ArtifactFileShareRequest?> = .constant(nil)

    var body: some View {
        HStack(spacing: 0) {
            if compact {
                ArtifactChromeButton(symbol: "chevron.left", label: "artifacts overview") {
                    onBackToOverview?()
                }
            } else {
                if let revealSidebar {
                    ArtifactChromeButton(symbol: "line.3.horizontal", label: "show sidebar") { revealSidebar() }
                        .accessibilityIdentifier("artifacts-show-sidebar")
                }
                ArtifactPageHistoryButtons(model: webModel)
            }
            if let editing {
                ArtifactAddressEditor(editing: editing, compact: compact)
            } else {
                address
            }
            if compact {
                // Laptop pose: the tab's title carries the switcher.
                if let openSwitcher, editing == nil {
                    ArtifactChromeButton(symbol: "chevron.down", label: "switcher") { openSwitcher() }
                        .accessibilityIdentifier("artifacts-title-switcher")
                }
                if let tab {
                    ArtifactChromeButton(symbol: "xmark", label: "close tab") { store.close(tab.id) }
                        .accessibilityIdentifier("artifacts-close-\(tab.id)")
                }
            } else {
                regularTrailing
            }
        }
        .padding(.horizontal, compact ? 4 : 8)
        .padding(.vertical, 4)
        .artifactsChromeSurface()
    }

    @ViewBuilder
    private var regularTrailing: some View {
        ArtifactRefreshButton(enabled: canRefresh, action: onRefresh)
        if let tab { ArtifactShareFileButton(store: store, tab: tab, request: shareRequest) }
        ArtifactChromeButton(symbol: "plus", label: "new tab", action: onNewTab)
            .accessibilityIdentifier("artifacts-new-tab")
        ArtifactChromeButton(symbol: "square.grid.2x2", label: "tab overview", enabled: !store.state.tabs.isEmpty,
                             action: onOverview)
            .accessibilityIdentifier("artifacts-show-overview")
            .accessibilityAddTraits(showsOverview ? .isSelected : [])
        if let tab { ArtifactTabMenu(store: store, tab: tab, currentPageURL: webModel?.url) }
    }

    private var canRefresh: Bool {
        tab.map { store.canRefreshOrReconnect($0.id) } ?? false
    }

    private var address: some View {
        Button(action: onEditAddress) {
            VStack(alignment: compact ? .center : .leading, spacing: 3) {
                if let tab {
                    HStack(spacing: 5) {
                        Image(systemName: addressSymbol(tab))
                            .font(.system(size: 10))
                            .foregroundStyle(T.fgMuted)
                        Text(verbatim: compact ? tab.title : "\(tab.hostLabel) · \(ArtifactsBrowserPresentation.location(tab, webURL: webModel?.url))")
                            .font(Typography.tesseraMono(size: compact ? 12 : 11, weight: .medium))
                            .foregroundStyle(T.fg)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    HStack(spacing: 8) {
                        if compact {
                            Text(verbatim: tab.hostLabel)
                                .font(Typography.tesseraMono(size: 9))
                                .foregroundStyle(T.fgDim)
                                .lineLimit(1)
                        }
                        ArtifactCacheBadge(presentation: store.presentation(for: tab.id))
                    }
                } else {
                    Text("host:path or a port")
                        .font(Typography.tesseraMono(size: 12))
                        .foregroundStyle(T.fgDim)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: compact ? .center : .leading)
            .padding(.horizontal, 10)
            .background(T.inputBg, in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(T.border, lineWidth: 0.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("artifacts-address")
        .accessibilityHint(tab == nil ? "open a path or a port in a new tab" : "edit this tab's address")
    }

    private func addressSymbol(_ tab: ArtifactTab) -> String {
        if case let .page(scheme, _, _) = tab.target {
            return scheme == "https" ? "lock" : "arrow.left.arrow.right"
        }
        return ArtifactsBrowserPresentation.kindSymbol(tab)
    }
}

/// The field in the bar's address slot, at the address's size. Laptop pose
/// also types in it under the title with no tab on top, and in a Duo pane.
@MainActor
struct ArtifactAddressEditor: View {
    @Environment(\.designTokens) private var T
    let editing: ArtifactAddressEditing
    let compact: Bool

    var body: some View {
        let entry = editing.entry
        HStack(spacing: 6) {
            ArtifactAddressField(
                text: Binding(get: { entry.input }, set: { entry.input = $0 }),
                placeholder: String(localized: "host:path or a port"),
                focusToken: entry.request.id,
                selectsAll: !entry.carriesDraft,
                onSubmit: editing.submit,
                onCancel: editing.cancel,
                onMove: { entry.moveSelection($0) },
                onEndEditing: editing.cancel
            )
            if entry.isOpening {
                ProgressView().controlSize(.small).frame(width: 28, height: 28)
            }
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, minHeight: 44)
        .background(T.inputBg, in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(T.borderStrong, lineWidth: 0.5))
    }
}

@MainActor
struct ArtifactPageHistoryButtons: View {
    let model: ArtifactWebViewModel?

    var body: some View {
        Group {
            ArtifactChromeButton(symbol: "chevron.left", label: "back", enabled: model?.canGoBack == true) {
                model?.goBack()
            }
            ArtifactChromeButton(symbol: "chevron.right", label: "forward", enabled: model?.canGoForward == true) {
                model?.goForward()
            }
        }
    }
}

struct ArtifactRefreshButton: View {
    let enabled: Bool
    let action: () -> Void

    var body: some View {
        ArtifactChromeButton(symbol: "arrow.clockwise", label: "refresh", enabled: enabled, action: action)
            .accessibilityIdentifier("artifacts-refresh")
    }
}
