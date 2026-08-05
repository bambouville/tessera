import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import UIKit

struct ImportKeyModal: View {
    var onClose: () -> Void
    var onImported: (StoredKey) -> Void

    @Environment(\.designTokens) private var T
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase

    @State private var name = ""
    @State private var passphrase = ""
    @State private var selectedFileData: Data?
    @State private var selectedFilename: String?
    @State private var protectWithUserPresence: Bool
    @State private var showFileImporter = false
    @State private var importError: String?
    @State private var privacyShielded = false

    private var isPhone: Bool {
        UIDevice.current.userInterfaceIdiom == .phone
    }

    init(
        initialProtection: Bool,
        onClose: @escaping () -> Void,
        onImported: @escaping (StoredKey) -> Void
    ) {
        self.onClose = onClose
        self.onImported = onImported
        _protectWithUserPresence = State(initialValue: initialProtection)
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.6)
                .ignoresSafeArea()
                .onTapGesture(perform: close)

            VStack(alignment: .leading, spacing: 0) {
                Text("import OpenSSH key")
                    .font(Typography.sheetTitle)
                    .foregroundStyle(T.fg)
                    .padding(.bottom, 20)

                Field(label: "name") {
                    Input(text: $name, placeholder: "imported key")
                }

                Field(label: "private-key file") {
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(selectedFilename ?? "no file selected")
                                .font(Typography.tesseraMono(size: 12))
                                .foregroundStyle(selectedFilename == nil ? T.fgDim : T.fg)
                                .lineLimit(1)
                            Text("The key body is never displayed or sent through a keyboard input surface.")
                                .font(Typography.tesseraMono(size: 10))
                                .foregroundStyle(T.fgDim)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        Spacer(minLength: 8)
                        Btn("choose file…", compact: true) {
                            showFileImporter = true
                        }
                    }
                    .padding(12)
                    .background(T.inputBg)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(T.border, lineWidth: 1)
                    )

                    if let importError {
                        Text(importError)
                            .font(Typography.tesseraMono(size: 12))
                            .foregroundStyle(T.red)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 8)
                    }
                }

                Field(label: "source-file passphrase (optional)") {
                    Input(text: $passphrase, placeholder: "", secure: true)

                    Text("This passphrase is used once to decrypt the selected file and is not retained. Tessera stores the imported key under the iOS protection selected below.")
                        .font(Typography.tesseraMono(size: 10))
                        .foregroundStyle(T.fgDim)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 8)
                }

                ToggleRow(
                    title: "require biometrics or passcode",
                    subtitle: "Face ID/Touch ID or passcode whenever Tessera accesses this key",
                    isOn: $protectWithUserPresence
                )
                .padding(.bottom, 20)

                HStack(spacing: 10) {
                    Spacer()
                    Btn("cancel", compact: true, action: close)
                    Btn("import", style: .primary, compact: true) {
                        importKey()
                    }
                }
            }
            .padding(isPhone ? 18 : 28)
            .frame(width: isPhone ? nil : 520)
            .frame(maxWidth: isPhone ? .infinity : nil)
            .background(T.panelBg)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(T.borderStrong, lineWidth: 1)
            )
            .onTapGesture {}
            .padding(.horizontal, isPhone ? 18 : 0)

            if privacyShielded {
                Color.black
                    .ignoresSafeArea()
                    .overlay {
                        Text("private-key import hidden")
                            .font(Typography.tesseraMono(size: 13))
                            .foregroundStyle(.white.opacity(0.8))
                    }
                    .zIndex(100)
                    .transaction { $0.animation = nil }
            }
        }
        // Present the UIKit document picker explicitly. SwiftUI's fileImporter
        // modifier is attached beneath this custom full-screen modal and can
        // silently decline to present on iOS 26.
        .sheet(isPresented: $showFileImporter) {
            OpenSSHKeyDocumentPicker { result in
                showFileImporter = false
                handleFileSelection(result)
            }
            .ignoresSafeArea()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                privacyShielded = UIScreen.main.isCaptured
            } else {
                privacyShielded = true
                clearSecrets()
            }
        }
        .onReceive(NotificationCenter.default.publisher(
            for: UIScreen.capturedDidChangeNotification
        )) { _ in
            let captured = UIScreen.main.isCaptured
            privacyShielded = captured
            if captured { clearSecrets() }
        }
        .onDisappear(perform: clearSecrets)
    }

    private func handleFileSelection(_ result: Result<[URL], Error>) {
        importError = nil
        do {
            guard let url = try result.get().first else { return }
            let accessed = url.startAccessingSecurityScopedResource()
            defer {
                if accessed { url.stopAccessingSecurityScopedResource() }
            }
            let values = try url.resourceValues(forKeys: [.fileSizeKey])
            if let size = values.fileSize, size > 1_048_576 {
                throw ImportSurfaceError.fileTooLarge
            }
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            guard !data.isEmpty, data.count <= 1_048_576 else {
                throw ImportSurfaceError.fileTooLarge
            }
            selectedFileData = data
            selectedFilename = url.lastPathComponent
        } catch {
            clearFileData()
            importError = error.localizedDescription
        }
    }

    private func importKey() {
        guard let selectedFileData else {
            importError = "Choose an OpenSSH private-key file first."
            return
        }
        do {
            let protection: KeyStore.KeyProtection = protectWithUserPresence
                ? .userPresence
                : .deviceUnlocked
            let imported = try KeyStore.importKey(
                data: selectedFileData,
                passphrase: passphrase.isEmpty ? nil : passphrase,
                name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                protection: protection
            )
            imported.requiresBiometric = protectWithUserPresence
            try StoredKeyLifecycle.persistCreatedKey(
                imported,
                boundary: .keyImport,
                persistence: KeyLifecyclePersistence.live(modelContext)
            )

            let metadata = KeySecurityMetadataStore()
            metadata.markBoundaryProtection(
                protectWithUserPresence ? .userPresence : .deviceUnlocked,
                for: imported.id
            )
            metadata.markMaterialIntegrity(
                protectWithUserPresence ? .authenticationRequired : .valid,
                for: imported.id
            )

            clearSecrets()
            onImported(imported)
            onClose()
        } catch {
            passphrase = ""
            importError = error.localizedDescription
        }
    }

    private func close() {
        clearSecrets()
        onClose()
    }

    private func clearFileData() {
        selectedFileData?.resetBytes(in: 0..<(selectedFileData?.count ?? 0))
        selectedFileData = nil
        selectedFilename = nil
    }

    private func clearSecrets() {
        passphrase = ""
        clearFileData()
    }
}

private struct OpenSSHKeyDocumentPicker: UIViewControllerRepresentable {
    let onCompletion: (Result<[URL], Error>) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onCompletion: onCompletion)
    }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(
            forOpeningContentTypes: [.data, .plainText],
            asCopy: true
        )
        picker.delegate = context.coordinator
        picker.allowsMultipleSelection = false
        return picker
    }

    func updateUIViewController(
        _ uiViewController: UIDocumentPickerViewController,
        context: Context
    ) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onCompletion: (Result<[URL], Error>) -> Void

        init(onCompletion: @escaping (Result<[URL], Error>) -> Void) {
            self.onCompletion = onCompletion
        }

        func documentPicker(
            _ controller: UIDocumentPickerViewController,
            didPickDocumentsAt urls: [URL]
        ) {
            onCompletion(.success(urls))
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            onCompletion(.success([]))
        }
    }
}

private enum ImportSurfaceError: LocalizedError {
    case fileTooLarge

    var errorDescription: String? {
        "The selected key file is empty or exceeds the 1 MB safety limit."
    }
}
