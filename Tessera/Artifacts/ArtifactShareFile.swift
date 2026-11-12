import SwiftUI
import TesseraArtifactsCore

/// One file handed to the share sheet: a private copy of the complete
/// cached file, under its real name, so a refresh or an eviction while the
/// sheet is up cannot change or remove what is being sent.
struct ArtifactFileShareRequest: Identifiable, Equatable {
    let id = UUID()
    let fileURL: URL
}

enum ArtifactShareStaging {
    static var directory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("artifacts-share", isDirectory: true)
    }

    /// Copies `source` (a clone on APFS) into its own folder and drops the
    /// copies of earlier shares, which their sheets have finished with.
    static func stage(_ source: URL, in root: URL = directory) throws -> URL {
        let manager = FileManager.default
        if let earlier = try? manager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
            for folder in earlier { try? manager.removeItem(at: folder) }
        }
        let folder = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = source.lastPathComponent.isEmpty ? "artifact" : source.lastPathComponent
        let copy = folder.appendingPathComponent(name)
        try manager.copyItem(at: source, to: copy)
        return copy
    }

    static func request(for share: ArtifactFileShare, in root: URL = directory) -> ArtifactFileShareRequest? {
        guard case let .ready(url) = share, let copy = try? stage(url, in: root) else { return nil }
        return ArtifactFileShareRequest(fileURL: copy)
    }
}

/// The toolbar's share control for a file tab. Absent for a page or an
/// agent edit; disabled, with the reason, until the file's copy is whole.
@MainActor
struct ArtifactShareFileButton: View {
    let store: any ArtifactsBrowserStore
    let tab: ArtifactTab
    @Binding var request: ArtifactFileShareRequest?

    var body: some View {
        let share = store.shareableFile(for: tab.id)
        if share != .none {
            ArtifactChromeButton(symbol: "square.and.arrow.up", label: "share file", enabled: share.isReady) {
                request = ArtifactShareStaging.request(for: store.shareableFile(for: tab.id))
            }
            .accessibilityHint(Text(verbatim: share.reason ?? ""))
            .accessibilityIdentifier("artifacts-share-file")
            .systemShareSheet(item: $request) { [$0.fileURL] }
        }
    }
}

extension ArtifactFileShare {
    var isReady: Bool {
        if case .ready = self { return true }
        return false
    }

    var reason: String? {
        if case let .unavailable(reason) = self { return reason }
        return nil
    }
}
