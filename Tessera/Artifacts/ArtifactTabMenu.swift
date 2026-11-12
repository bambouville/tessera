import SwiftUI
import TesseraArtifactsCore
import UIKit

@MainActor
struct ArtifactTabMenu: View {
    @Environment(\.designTokens) private var T
    let store: any ArtifactsBrowserStore
    let tab: ArtifactTab
    var currentPageURL: URL?
    /// Where no toolbar row carries the share control, as on a phone, the
    /// file's share lives in this menu, its sheet anchored on the menu.
    var shareRequest: Binding<ArtifactFileShareRequest?>?

    var body: some View {
        if let shareRequest {
            menu(onShareFile: {
                shareRequest.wrappedValue = ArtifactShareStaging.request(for: store.shareableFile(for: tab.id))
            })
            .systemShareSheet(item: shareRequest) { [$0.fileURL] }
        } else {
            menu(onShareFile: nil)
        }
    }

    private func menu(onShareFile: (() -> Void)?) -> some View {
        Menu {
            ArtifactTabMenuActions(store: store, tab: tab, currentPageURL: currentPageURL, onShareFile: onShareFile)
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 16))
                .foregroundStyle(T.fgMuted)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("tab actions")
        .accessibilityIdentifier("artifacts-tab-menu")
    }
}

@MainActor
struct ArtifactTabMenuActions: View {
    let store: any ArtifactsBrowserStore
    let tab: ArtifactTab
    var currentPageURL: URL?
    var onShareFile: (() -> Void)?

    var body: some View {
        if let onShareFile {
            let share = store.shareableFile(for: tab.id)
            if share != .none {
                Button(action: onShareFile) {
                    Label("share file", systemImage: "square.and.arrow.up")
                    if let reason = share.reason { Text(verbatim: reason) }
                }
                .disabled(!share.isReady)
                .accessibilityIdentifier("artifacts-menu-share-file")
            }
        }
        Button {
            store.setPinned(tab.id, !tab.pinned)
        } label: {
            if tab.pinned { Label("unpin tab", systemImage: "pin.slash") }
            else { Label("pin tab", systemImage: "pin") }
        }
        if store.canKeepAsRule(tab.id) {
            Button { store.keepAsRule(tab.id) } label: {
                Label("keep as a rule", systemImage: "arrow.left.arrow.right")
            }
        }
        ShareLink(item: ArtifactsBrowserPresentation.shareValue(tab, webURL: currentPageURL)) {
            Label("share link", systemImage: "square.and.arrow.up")
        }
        Button {
            UIPasteboard.general.string = ArtifactsBrowserPresentation.copyValue(tab, webURL: currentPageURL)
        } label: {
            Label("copy path", systemImage: "doc.on.doc")
        }
        Divider()
        Button(role: .destructive) { store.close(tab.id) } label: {
            Label("close tab", systemImage: "xmark")
        }
        Button(role: .destructive) { store.closeAll(hostID: tab.hostID) } label: {
            Label("close all on \(tab.hostLabel)", systemImage: "xmark.square")
        }
    }
}
