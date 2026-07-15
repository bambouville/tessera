import UIKit
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
            return "Shared container is unavailable."
        case .noSupportedItem:
            return "No supported file or image was found."
        case .couldNotEncodeImage:
            return "The image could not be prepared."
        }
    }
}

final class ShareViewController: UIViewController {
    private let rootStack = UIStackView()
    private let statusLabel = UILabel()
    private let fileLabel = UILabel()
    private let targetsStack = UIStackView()
    private let queueButton = UIButton(type: .system)
    private let saveButton = UIButton(type: .system)
    private let discardButton = UIButton(type: .system)
    private var didBeginProcessing = false
    private var preparedInboxURL: URL?
    private var preparedFileURLs: [URL] = []
    private var targets: [UploadTarget] = []
    private var selectedTargetID: UUID?
    private var targetButtons: [UUID: UIButton] = [:]

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        rootStack.translatesAutoresizingMaskIntoConstraints = false
        rootStack.axis = .vertical
        rootStack.alignment = .fill
        rootStack.spacing = 14
        view.addSubview(rootStack)

        statusLabel.text = "Preparing for Tessera..."
        statusLabel.textAlignment = .left
        statusLabel.textColor = .label
        statusLabel.font = .preferredFont(forTextStyle: .headline)
        statusLabel.numberOfLines = 0
        rootStack.addArrangedSubview(statusLabel)

        fileLabel.textColor = .secondaryLabel
        fileLabel.font = .preferredFont(forTextStyle: .subheadline)
        fileLabel.numberOfLines = 1
        fileLabel.lineBreakMode = .byTruncatingMiddle
        fileLabel.isHidden = true
        rootStack.addArrangedSubview(fileLabel)

        targetsStack.axis = .vertical
        targetsStack.alignment = .fill
        targetsStack.spacing = 8
        targetsStack.isHidden = true
        rootStack.addArrangedSubview(targetsStack)

        let actionsStack = UIStackView()
        actionsStack.axis = .horizontal
        actionsStack.alignment = .center
        actionsStack.distribution = .fill
        actionsStack.spacing = 12
        rootStack.addArrangedSubview(actionsStack)

        queueButton.setTitle("Queue upload", for: .normal)
        queueButton.titleLabel?.font = .preferredFont(forTextStyle: .headline)
        queueButton.isHidden = true
        queueButton.addTarget(self, action: #selector(queueTapped), for: .touchUpInside)

        saveButton.setTitle("Save for later", for: .normal)
        saveButton.titleLabel?.font = .preferredFont(forTextStyle: .body)
        saveButton.isHidden = true
        saveButton.addTarget(self, action: #selector(saveTapped), for: .touchUpInside)

        discardButton.setTitle("Discard", for: .normal)
        discardButton.titleLabel?.font = .preferredFont(forTextStyle: .body)
        discardButton.isHidden = true
        discardButton.addTarget(self, action: #selector(discardTapped), for: .touchUpInside)

        actionsStack.addArrangedSubview(saveButton)
        actionsStack.addArrangedSubview(discardButton)
        actionsStack.addArrangedSubview(UIView())
        actionsStack.addArrangedSubview(queueButton)

        NSLayoutConstraint.activate([
            rootStack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            rootStack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            rootStack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 24),
            rootStack.bottomAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -24)
        ])
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
                    discardButton.isHidden = false
                }
            } catch {
                #if DEBUG
                NSLog("[TesseraShareExtension] failed: %@", error.localizedDescription)
                #endif
                statusLabel.text = error.localizedDescription
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
        provider.registeredTypeIdentifiers
            .filter { isSupportedType($0) }
            .sorted { typeScore($0) < typeScore($1) }
    }

    private func isSupportedType(_ identifier: String) -> Bool {
        guard let type = UTType(identifier) else { return false }
        return type.conforms(to: .image)
    }

    private func typeScore(_ identifier: String) -> Int {
        guard let type = UTType(identifier) else { return 100 }
        if type.conforms(to: .image) { return 0 }
        return 100
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
        if fileURLs.count == 1 {
            fileLabel.text = fileURLs[0].lastPathComponent
        } else {
            fileLabel.text = "\(fileURLs.count) items"
        }
        fileLabel.isHidden = false

        targets = loadTargets()
        selectedTargetID = targets.first?.id
        renderTargets()

        if targets.isEmpty {
            statusLabel.text = "Open Tessera once to refresh the host list."
            queueButton.isHidden = true
            saveButton.setTitle("Done", for: .normal)
            saveButton.isHidden = false
        } else {
            statusLabel.text = "Choose the Tessera host for this upload."
            queueButton.isHidden = false
            saveButton.isHidden = true
        }
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

    @MainActor
    private func renderTargets() {
        targetsStack.arrangedSubviews.forEach { view in
            targetsStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        targetButtons.removeAll()

        for target in targets {
            let button = UIButton(type: .system)
            button.contentHorizontalAlignment = .leading
            button.titleLabel?.numberOfLines = 2
            button.titleLabel?.font = .preferredFont(forTextStyle: .body)
            button.layer.cornerRadius = 8
            button.layer.borderWidth = 1
            button.contentEdgeInsets = UIEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
            button.setTitle("\(target.label)\n\(statusText(for: target))", for: .normal)
            button.tag = targets.firstIndex(where: { $0.id == target.id }) ?? 0
            button.addTarget(self, action: #selector(targetTapped(_:)), for: .touchUpInside)
            targetButtons[target.id] = button
            targetsStack.addArrangedSubview(button)
        }

        targetsStack.isHidden = targets.isEmpty
        updateTargetSelection()
    }

    private func statusText(for target: UploadTarget) -> String {
        if target.isActiveSession { return "active session" }
        if target.isConnected { return "connected" }
        if target.isConnecting { return "connecting" }
        if target.isFailed { return "reconnect failed" }
        return "saved host"
    }

    @objc
    @MainActor
    private func targetTapped(_ sender: UIButton) {
        guard targets.indices.contains(sender.tag) else { return }
        selectedTargetID = targets[sender.tag].id
        updateTargetSelection()
    }

    @MainActor
    private func updateTargetSelection() {
        for (id, button) in targetButtons {
            let selected = id == selectedTargetID
            button.layer.borderColor = selected
                ? view.tintColor.cgColor
                : UIColor.separator.cgColor
            button.backgroundColor = selected
                ? view.tintColor.withAlphaComponent(0.12)
                : UIColor.clear
        }
        queueButton.isEnabled = selectedTargetID != nil
    }

    @objc
    @MainActor
    private func queueTapped() {
        guard
            let preparedInboxURL,
            let target = targets.first(where: { $0.id == selectedTargetID })
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
            statusLabel.text = "Could not queue upload: \(error.localizedDescription)"
        }
    }

    @objc
    @MainActor
    private func saveTapped() {
        if targets.isEmpty, let preparedInboxURL {
            try? FileManager.default.removeItem(at: preparedInboxURL)
        }
        extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
    }

    @objc
    @MainActor
    private func discardTapped() {
        if let preparedInboxURL {
            try? FileManager.default.removeItem(at: preparedInboxURL)
        }
        extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
    }
}
