import SwiftUI
import TesseraArtifactsCore

/// Tabs only, each with its own close. The toolbar row above carries the
/// one new-tab and tab-overview control, and the strip hides with the
/// overview showing.
@MainActor
struct ArtifactTabStrip: View {
    @Environment(\.designTokens) private var T
    let store: any ArtifactsBrowserStore
    let onSelect: (String) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(store.state.tabs) { tab in
                        stripTab(tab)
                            .id(tab.id)
                    }
                }
            }
            .onChange(of: store.state.selectedID, initial: true) { _, id in
                if let id { proxy.scrollTo(id, anchor: .center) }
            }
        }
        // The drawn row is 34 pt. Its controls occupy a 44 pt interaction
        // lane, with five quiet points above and below the tab artwork.
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 44)
        .artifactsChromeSurface()
        .accessibilityIdentifier("artifacts-tab-strip")
    }

    private func stripTab(_ tab: ArtifactTab) -> some View {
        let selected = store.state.selectedID == tab.id
        return HStack(spacing: 0) {
            Button { onSelect(tab.id) } label: {
                HStack(spacing: 7) {
                    Image(systemName: ArtifactsBrowserPresentation.kindSymbol(tab))
                        .font(.system(size: 11))
                    if tab.unseenChange {
                        Circle().fill(T.fg).frame(width: 4, height: 4)
                            .accessibilityLabel("unseen change")
                    }
                    Text(verbatim: tab.title)
                        .font(Typography.tesseraMono(size: 11, weight: selected ? .medium : .regular))
                        .lineLimit(1)
                    Text(verbatim: tab.hostLabel)
                        .font(Typography.tesseraMono(size: 9))
                        .foregroundStyle(T.fgDim)
                        .lineLimit(1)
                    if tab.pinned {
                        Image(systemName: "pin.fill").font(.system(size: 8))
                    }
                }
                .foregroundStyle(selected ? T.fg : T.fgMuted)
                .chromeBarTextCap()
                .padding(.leading, 12)
                .frame(minWidth: 120, maxWidth: 260, minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("artifacts-tab-\(tab.id)")
            .accessibilityAddTraits(selected ? .isSelected : [])
            ArtifactChromeButton(symbol: "xmark", label: "close \(tab.title)") { store.close(tab.id) }
                .accessibilityIdentifier(selected ? "artifacts-close-\(tab.id)" : "artifacts-strip-close-\(tab.id)")
        }
        .background {
            Rectangle().fill(selected ? T.inputBg : T.inputBgSoft)
                .frame(height: 34)
        }
        .overlay(alignment: .trailing) { Rectangle().fill(T.border).frame(width: 0.5, height: 26) }
        .contextMenu { ArtifactTabMenuActions(store: store, tab: tab) }
    }
}

@MainActor
struct ArtifactTabNavigationButtons: View {
    let store: any ArtifactsBrowserStore
    let onSelect: (String) -> Void

    var body: some View {
        Group {
            ArtifactChromeButton(symbol: "chevron.left.square", label: "previous tab", enabled: store.state.tabs.count > 1) {
                move(-1)
            }
            ArtifactChromeButton(symbol: "chevron.right.square", label: "next tab", enabled: store.state.tabs.count > 1) {
                move(1)
            }
        }
    }

    private func move(_ offset: Int) {
        if let id = ArtifactsBrowserPresentation.adjacentTabID(
            tabs: store.state.tabs, selectedID: store.state.selectedID, offset: offset
        ) { onSelect(id) }
    }
}
