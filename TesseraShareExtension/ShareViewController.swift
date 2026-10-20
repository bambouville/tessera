import UIKit
import SwiftUI
import UniformTypeIdentifiers

private enum ShareInbox {
    static let appGroupID = "group.com.bambouville.TesseraApp"
    static let folderName = "ShareInbox"
    static let targetsFileName = "upload-targets.json"
    static let metadataFileName = "metadata.json"
}

private struct UploadTargetsDocument: Decodable {
    var version: Int
    var updatedAt: Date
    var targets: [UploadTarget]
}

private struct UploadTarget: Decodable {
    var id: UUID
    var label: String
    var isConnected: Bool
    var isConnecting: Bool
    var isActiveSession: Bool
    var isFailed: Bool
    var sessionCwd: String?
}

private struct ShareInboxMetadata: Encodable {
    var version: Int = 1
    var targetHostID: UUID
}

private enum ShareInboxError: LocalizedError {
    case noAppGroupContainer
    case noSupportedItem
    case couldNotEncodeImage

    var errorDescription: String? {
        switch self {
        case .noAppGroupContainer:
            return String(localized: "Shared container is unavailable.")
        case .noSupportedItem:
            return String(localized: "No supported photo, video, or file was found.")
        case .couldNotEncodeImage:
            return String(localized: "The image could not be prepared.")
        }
    }
}

final class ShareViewController: UIViewController {
    private let model = ShareSheetModel()
    private var didBeginProcessing = false
    private var preparedInboxURL: URL?
    private var preparedFileURLs: [URL] = []

    override func viewDidLoad() {
        super.viewDidLoad()
        registerEmbeddedFonts()

        let sheet = ShareSheetRoot(
            model: model,
            statusText: Self.statusText,
            queue: { [weak self] in self?.queueTapped() },
            save: { [weak self] in self?.saveTapped() },
            discard: { [weak self] in self?.discardTapped() }
        )
        let hostingController = UIHostingController(rootView: sheet)
        addChild(hostingController)
        hostingController.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(hostingController.view)
        NSLayoutConstraint.activate([
            hostingController.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hostingController.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            hostingController.view.topAnchor.constraint(equalTo: view.topAnchor),
            hostingController.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        hostingController.didMove(toParent: self)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !didBeginProcessing else { return }
        didBeginProcessing = true

        Task {
            do {
                let itemID = UUID().uuidString
                let inboxDirectory = try makeInboxDirectory(itemID: itemID)
                let copied = try await copyAllAttachments(to: inboxDirectory)
                await MainActor.run {
                    preparedInboxURL = inboxDirectory
                    preparedFileURLs = copied
                    renderPreparedState(fileURLs: copied)
                }
            } catch {
                #if DEBUG
                NSLog("[TesseraShareExtension] failed: %@", error.localizedDescription)
                #endif
                model.phase = .failed(error.localizedDescription)
            }
        }
    }

    private func makeInboxDirectory(itemID: String) throws -> URL {
        guard
            let groupURL = FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: ShareInbox.appGroupID)
        else {
            throw ShareInboxError.noAppGroupContainer
        }
        let directory = groupURL
            .appendingPathComponent(ShareInbox.folderName, isDirectory: true)
            .appendingPathComponent(itemID, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        #if DEBUG
        NSLog("[TesseraShareExtension] inbox prepared id=%@", itemID)
        #endif
        return directory
    }

    private func copyAllAttachments(to inboxDirectory: URL) async throws -> [URL] {
        let extensionItems = (extensionContext?.inputItems as? [NSExtensionItem]) ?? []
        var copiedItems: [URL] = []
        for item in extensionItems {
            for provider in item.attachments ?? [] {
                if let copied = try await copySupportedItem(from: provider, to: inboxDirectory) {
                    #if DEBUG
                    NSLog("[TesseraShareExtension] copied attachment name=%@", copied.lastPathComponent)
                    #endif
                    copiedItems.append(copied)
                }
            }
        }
        if copiedItems.isEmpty {
            throw ShareInboxError.noSupportedItem
        }
        return copiedItems
    }

    private func copySupportedItem(
        from provider: NSItemProvider,
        to inboxDirectory: URL
    ) async throws -> URL? {
        for typeIdentifier in preferredTypeIdentifiers(from: provider) {
            if let copied = try? await copyFileRepresentation(
                from: provider,
                typeIdentifier: typeIdentifier,
                to: inboxDirectory
            ) {
                return copied
            }
            if let copied = try? await copyLoadedItem(
                from: provider,
                typeIdentifier: typeIdentifier,
                to: inboxDirectory
            ) {
                return copied
            }
        }
        return nil
    }

    private func preferredTypeIdentifiers(from provider: NSItemProvider) -> [String] {
        ShareItemTypePolicy.preferredTypeIdentifiers(from: provider.registeredTypeIdentifiers)
    }

    private func copyFileRepresentation(
        from provider: NSItemProvider,
        typeIdentifier: String,
        to inboxDirectory: URL
    ) async throws -> URL? {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadFileRepresentation(forTypeIdentifier: typeIdentifier) { url, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let url else {
                    continuation.resume(returning: nil)
                    return
                }
                do {
                    continuation.resume(
                        returning: try self.copyFile(
                            at: url,
                            typeIdentifier: typeIdentifier,
                            to: inboxDirectory
                        )
                    )
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func copyLoadedItem(
        from provider: NSItemProvider,
        typeIdentifier: String,
        to inboxDirectory: URL
    ) async throws -> URL? {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadItem(forTypeIdentifier: typeIdentifier, options: nil) { item, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                do {
                    switch item {
                    case let url as URL:
                        continuation.resume(
                            returning: try self.copyFile(
                                at: url,
                                typeIdentifier: typeIdentifier,
                                to: inboxDirectory
                            )
                        )
                    case let data as Data:
                        continuation.resume(
                            returning: try self.writeData(
                                data,
                                suggestedName: nil,
                                typeIdentifier: typeIdentifier,
                                to: inboxDirectory
                            )
                        )
                    case let image as UIImage:
                        guard let data = image.pngData() else {
                            throw ShareInboxError.couldNotEncodeImage
                        }
                        continuation.resume(
                            returning: try self.writeData(
                                data,
                                suggestedName: "screenshot.png",
                                typeIdentifier: UTType.png.identifier,
                                to: inboxDirectory
                            )
                        )
                    default:
                        continuation.resume(returning: nil)
                    }
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func copyFile(
        at sourceURL: URL,
        typeIdentifier: String,
        to inboxDirectory: URL
    ) throws -> URL {
        let fallbackName = fallbackFileName(for: typeIdentifier)
        let fileName = safeFileName(sourceURL.lastPathComponent, fallback: fallbackName)
        let destination = uniqueDestination(named: fileName, in: inboxDirectory)
        try FileManager.default.copyItem(at: sourceURL, to: destination)
        return destination
    }

    private func writeData(
        _ data: Data,
        suggestedName: String?,
        typeIdentifier: String,
        to inboxDirectory: URL
    ) throws -> URL {
        let fileName = safeFileName(
            suggestedName ?? fallbackFileName(for: typeIdentifier),
            fallback: fallbackFileName(for: typeIdentifier)
        )
        let destination = uniqueDestination(named: fileName, in: inboxDirectory)
        try data.write(to: destination, options: .atomic)
        return destination
    }

    private func fallbackFileName(for typeIdentifier: String) -> String {
        let fileExtension = UTType(typeIdentifier)?.preferredFilenameExtension ?? "dat"
        return "shared-\(UUID().uuidString).\(fileExtension)"
    }

    private func safeFileName(_ name: String, fallback: String) -> String {
        let candidate = (name as NSString).lastPathComponent
        guard !candidate.isEmpty, candidate != "." else { return fallback }
        return candidate
    }

    private func uniqueDestination(named fileName: String, in directory: URL) -> URL {
        let base = (fileName as NSString).deletingPathExtension
        let ext = (fileName as NSString).pathExtension
        var destination = directory.appendingPathComponent(fileName, isDirectory: false)
        var index = 2
        while FileManager.default.fileExists(atPath: destination.path) {
            let nextName = ext.isEmpty ? "\(base)-\(index)" : "\(base)-\(index).\(ext)"
            destination = directory.appendingPathComponent(nextName, isDirectory: false)
            index += 1
        }
        return destination
    }

    @MainActor
    private func renderPreparedState(fileURLs: [URL]) {
        model.isSingleFile = fileURLs.count == 1
        if fileURLs.count == 1 {
            model.fileLabel = fileURLs[0].lastPathComponent
        } else {
            model.fileLabel = String(localized: "\(fileURLs.count) items")
        }
        model.targets = loadTargets()
        model.selectedTargetID = model.targets.first?.id
        model.phase = .prepared
    }

    private func loadTargets() -> [UploadTarget] {
        guard
            let groupURL = FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: ShareInbox.appGroupID)
        else {
            return []
        }
        let targetsURL = groupURL
            .appendingPathComponent(ShareInbox.folderName, isDirectory: true)
            .appendingPathComponent(ShareInbox.targetsFileName, isDirectory: false)
        guard let data = try? Data(contentsOf: targetsURL) else { return [] }
        do {
            let document = try JSONDecoder().decode(UploadTargetsDocument.self, from: data)
            return document.targets.sorted { lhs, rhs in
                if lhs.isActiveSession != rhs.isActiveSession { return lhs.isActiveSession }
                if lhs.isConnected != rhs.isConnected { return lhs.isConnected }
                if lhs.isConnecting != rhs.isConnecting { return lhs.isConnecting }
                return lhs.label.localizedCaseInsensitiveCompare(rhs.label) == .orderedAscending
            }
        } catch {
            #if DEBUG
            NSLog("[TesseraShareExtension] targets decode failed: %@", error.localizedDescription)
            #endif
            return []
        }
    }

    private static func statusText(for target: UploadTarget) -> String {
        if target.isActiveSession { return String(localized: "active session") }
        if target.isConnected { return String(localized: "connected") }
        if target.isConnecting { return String(localized: "connecting") }
        if target.isFailed { return String(localized: "reconnect failed") }
        return String(localized: "saved host")
    }

    @MainActor
    private func queueTapped() {
        guard
            let preparedInboxURL,
            let target = model.targets.first(where: { $0.id == model.selectedTargetID })
        else {
            saveTapped()
            return
        }

        do {
            let metadata = ShareInboxMetadata(
                targetHostID: target.id
            )
            let data = try JSONEncoder().encode(metadata)
            let metadataURL = preparedInboxURL
                .appendingPathComponent(ShareInbox.metadataFileName, isDirectory: false)
            try data.write(to: metadataURL, options: .atomic)
            #if DEBUG
            NSLog("[TesseraShareExtension] queued upload host=%@", target.id.uuidString)
            #endif
            extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
        } catch {
            model.phase = .failed(String(localized: "Could not queue upload: \(error.localizedDescription)"))
        }
    }

    @MainActor
    private func saveTapped() {
        if model.targets.isEmpty, let preparedInboxURL {
            try? FileManager.default.removeItem(at: preparedInboxURL)
        }
        extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
    }

    @MainActor
    private func discardTapped() {
        if let preparedInboxURL {
            try? FileManager.default.removeItem(at: preparedInboxURL)
        }
        extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
    }
}

/// Presentation state only. Inbox ownership and extension completion stay in
/// ShareViewController, including its existing empty-host cleanup semantics.
@MainActor
private final class ShareSheetModel: ObservableObject {
    enum Phase {
        case preparing
        case prepared
        case failed(String)
    }

    @Published var phase: Phase = .preparing
    @Published var fileLabel: String?
    @Published var isSingleFile = true
    @Published var targets: [UploadTarget] = []
    @Published var selectedTargetID: UUID?
}

private struct ShareSheetRoot: View {
    let model: ShareSheetModel
    let statusText: (UploadTarget) -> String
    let queue: () -> Void
    let save: () -> Void
    let discard: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ShareSheetView(model: model, statusText: statusText, queue: queue, save: save, discard: discard)
            // The environment's default is dark/blue. Match the system scheme
            // using the same factory, without reading app-only preferences.
            .environment(\.designTokens, DesignTokens.make(
                mode: colorScheme == .light ? .light : .dark, accent: .blue
            ))
    }
}

private struct ShareSheetView: View {
    @ObservedObject var model: ShareSheetModel
    let statusText: (UploadTarget) -> String
    let queue: () -> Void
    let save: () -> Void
    let discard: () -> Void
    @Environment(\.designTokens) private var T

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("upload to host")
                        .font(Typography.sheetTitle)
                        .foregroundStyle(T.fg)
                        .accessibilityAddTraits(.isHeader)

                    if let fileLabel = model.fileLabel {
                        fileRow(fileLabel, isSingleFile: model.isSingleFile)
                    }

                    if !model.targets.isEmpty {
                        Text("Host")
                            .font(Typography.tesseraMono(size: 11, weight: .medium))
                            .foregroundStyle(T.fgDim)
                            .padding(.top, 2)
                            .accessibilityAddTraits(.isHeader)
                        VStack(spacing: 6) {
                            ForEach(Array(model.targets.enumerated()), id: \.offset) { index, target in
                                hostRow(target, index: index)
                            }
                        }
                    }

                    statusLine
                        .font(Typography.tesseraMono(size: 11))
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("share.status")
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }

            // Originally these actions appeared only after copying succeeded.
            // With no targets, Done uses saveTapped (which deletes the inbox);
            // with targets, only Discard and Queue upload are visible.
            if case .failed = model.phase, model.fileLabel == nil {
                // Nothing was prepared, so there is nothing to keep or queue.
                HStack(spacing: 10) {
                    Spacer(minLength: 0)
                    Btn(style: .default, action: discard) {
                        Text("Done").frame(minHeight: 24)
                    }
                    .accessibilityIdentifier("share.done")
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 16)
                .background(T.presentationBg)
                .overlay(alignment: .top) {
                    Rectangle().fill(T.border).frame(height: 0.5)
                }
            } else if model.fileLabel != nil {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) {
                        Spacer(minLength: 0)
                        actions(full: false)
                    }
                    .fixedSize(horizontal: true, vertical: false)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    VStack(spacing: 10) {
                        actions(full: true)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 16)
                .background(T.presentationBg)
                .overlay(alignment: .top) {
                    Rectangle().fill(T.border).frame(height: 0.5)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(T.presentationBg)
    }

    private func fileRow(_ label: String, isSingleFile: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: isSingleFile ? "doc" : "doc.on.doc")
                .font(.system(size: 16, weight: .light))
                .foregroundStyle(T.fgMuted)
                .frame(width: 34, height: 34)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(T.border, lineWidth: 0.5))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: label)
                    .font(Typography.tesseraMono(size: 13))
                    .foregroundStyle(T.fg)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if isSingleFile {
                    Text("file")
                        .font(Typography.tesseraMono(size: 11))
                        .foregroundStyle(T.fgMuted)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(T.border, lineWidth: 0.5))
        .accessibilityElement(children: .combine)
    }

    private func hostRow(_ target: UploadTarget, index: Int) -> some View {
        let selected = target.id == model.selectedTargetID
        return Button {
            model.selectedTargetID = target.id
        } label: {
            HStack(spacing: 8) {
                // StatusDot also imports the app's ContinuousMotion policy.
                // This static dot keeps its visual language without pulling
                // app-global motion settings into the extension.
                Circle()
                    .fill(target.isConnected ? T.green : target.isConnecting ? T.amber
                          : target.isFailed ? T.red : T.fgFaint)
                    .frame(width: 6, height: 6)
                    .accessibilityHidden(true)
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        hostLabel(target)
                        Spacer(minLength: 8)
                        hostStatus(target)
                    }
                    .fixedSize(horizontal: true, vertical: false)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    VStack(alignment: .leading, spacing: 4) {
                        hostLabel(target)
                        hostStatus(target)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .frame(minHeight: 44)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(selected ? T.accent : T.border, lineWidth: selected ? 1 : 0.5)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("share.host.\(index)")
    }

    private func hostLabel(_ target: UploadTarget) -> some View {
        Text(verbatim: target.label)
            .font(Typography.tesseraMono(size: 13))
            .foregroundStyle(T.fg)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func hostStatus(_ target: UploadTarget) -> some View {
        Text(verbatim: statusText(target))
            .font(Typography.tesseraMono(size: 11))
            .foregroundStyle(T.fgDim)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var statusLine: some View {
        switch model.phase {
        case .preparing:
            HStack(spacing: 8) {
                ProgressView().tint(T.fgMuted)
                Text("Preparing for Tessera...")
            }
            .foregroundStyle(T.fgMuted)
        case .prepared:
            if model.targets.isEmpty {
                Text("Open Tessera once to refresh the host list.")
                    .foregroundStyle(T.fgMuted)
            } else {
                Text("Choose the Tessera host for this upload.")
                    .foregroundStyle(T.fgMuted)
            }
        case .failed(let message):
            Text(verbatim: message).foregroundStyle(T.red)
        }
    }

    @ViewBuilder
    private func actions(full: Bool) -> some View {
        Btn(style: .default, full: full, action: discard) {
            Text("Discard").frame(minHeight: 24)
        }
        .accessibilityIdentifier("share.discard")

        if model.targets.isEmpty {
            Btn(style: .default, full: full, action: save) {
                Text("Done").frame(minHeight: 24)
            }
            .accessibilityIdentifier("share.save")
        } else {
            Btn(style: .primary, full: full, action: queue) {
                Text("Queue upload")
                    .font(Typography.tesseraMono(size: 13, weight: .semibold))
                    .frame(minHeight: 24)
            }
            .disabled(model.selectedTargetID == nil)
            .opacity(model.selectedTargetID == nil ? 0.4 : 1)
            .accessibilityIdentifier("share.queue")
        }
    }
}
