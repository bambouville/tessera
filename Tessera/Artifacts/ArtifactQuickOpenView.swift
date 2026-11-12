import SwiftUI
import TesseraArtifactsCore

/// A phone's address entry, in a sheet above the keyboard: the open field
/// for a new tab, or a tab's address to edit. The toolbar's inline field on
/// wider layouts shares its entry and rows.
@MainActor
struct ArtifactQuickOpenView: View {
    @Environment(\.designTokens) private var T
    @Environment(\.dismiss) private var dismiss
    @State private var entry: ArtifactAddressEntry
    let store: any ArtifactsBrowserStore
    let onOpened: (String) -> Void

    init(store: any ArtifactsBrowserStore, request: ArtifactAddressEditRequest, onOpened: @escaping (String) -> Void) {
        self.store = store
        self.onOpened = onOpened
        _entry = State(initialValue: ArtifactAddressEntry(request))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            field
            ArtifactAddressSuggestionList(store: store, entry: entry) { suggestion in
                entry.submit(suggestion, store: store, onOpened: opened, onKeep: { dismiss() })
            }
        }
        .background(T.presentationBg)
        .presentationBackground(T.presentationBg)
        .accessibilityIdentifier("artifacts-quick-open")
        .onAppear { entry.updateSuggestions(store) }
        .onChange(of: entry.input) { _, _ in entry.updateSuggestions(store) }
        .onChange(of: entry.suggestionSnapshot.revision) { _, _ in entry.updateSuggestions(store) }
        .onDisappear { entry.cancel() }
    }

    private var title: LocalizedStringKey {
        if case .navigate = entry.request.placement { return "edit address" }
        return "new tab"
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(Typography.sheetTitle)
                    .foregroundStyle(T.fg)
                if let host = store.quickOpenHosts.first(where: { $0.id == entry.request.currentHostID }) {
                    Text("on \(host.label)")
                        .font(Typography.tesseraMono(size: 10))
                        .foregroundStyle(T.fgDim)
                }
            }
            Spacer()
            Button("cancel") { dismiss() }
                .font(Typography.tesseraMono(size: 12))
                .foregroundStyle(T.fgMuted)
                .frame(minWidth: 60, minHeight: 44)
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
    }

    private var field: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13))
                .foregroundStyle(T.fgDim)
            ArtifactAddressField(
                text: Binding(get: { entry.input }, set: { entry.input = $0 }),
                placeholder: String(localized: "host:path or a port"),
                focusToken: entry.request.id,
                selectsAll: !entry.carriesDraft,
                onSubmit: submit,
                onCancel: { dismiss() },
                onMove: { entry.moveSelection($0) },
                identifier: "artifacts-quick-open-input"
            )
            .frame(minHeight: 44)
            if entry.isOpening {
                ProgressView().controlSize(.small).frame(width: 44, height: 44)
            } else {
                ArtifactChromeButton(symbol: "arrow.turn.down.left", label: "open", enabled: entry.canSubmit, action: submit)
            }
        }
        .padding(.leading, 12)
        .frame(minHeight: 44)
        .background(T.inputBg, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(T.border, lineWidth: 0.5))
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func submit() {
        entry.submit(store, onOpened: opened, onKeep: { dismiss() })
    }

    private func opened(_ id: String) {
        onOpened(id)
        dismiss()
    }
}
