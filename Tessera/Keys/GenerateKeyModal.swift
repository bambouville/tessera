import SwiftUI
import SwiftData
import UIKit

@Observable
final class GenerateKeyDraft {
    var name = ""
    var algorithm: KeyAlgorithm = .ed25519
    var protectWithUserPresence = false
    var errorText: String?

    func reset(initialProtection: Bool) {
        name = ""
        algorithm = .ed25519
        protectWithUserPresence = initialProtection
        errorText = nil
    }

    func clear() {
        name = ""
        errorText = nil
    }
}

struct GenerateKeyModal: View {
    @Bindable var draft: GenerateKeyDraft
    var onClose: () -> Void
    var onCreated: (StoredKey) -> Void

    @Environment(\.designTokens) private var T
    @Environment(\.modelContext) private var modelContext

    private var isPhone: Bool {
        UIDevice.current.userInterfaceIdiom == .phone
    }

    init(
        draft: GenerateKeyDraft,
        onClose: @escaping () -> Void,
        onCreated: @escaping (StoredKey) -> Void
    ) {
        self.draft = draft
        self.onClose = onClose
        self.onCreated = onCreated
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.6)
                .ignoresSafeArea()
                .onTapGesture(perform: onClose)

            VStack(alignment: .leading, spacing: 0) {
                Text("generate key")
                    .font(Typography.sheetTitle)
                    .foregroundStyle(T.fg)
                    .padding(.bottom, 20)

                Field(label: "name") {
                    Input(text: $draft.name, placeholder: "my new key")

                    if let errorText = draft.errorText {
                        Text(errorText)
                            .font(Typography.tesseraMono(size: 12))
                            .foregroundStyle(T.red)
                            .padding(.top, 8)
                    }
                }

                Field(label: "algorithm") {
                    LazyVGrid(
                        columns: [
                            GridItem(.flexible(), spacing: 8),
                            GridItem(.flexible(), spacing: 8)
                        ],
                        spacing: 8
                    ) {
                        algorithmCard(
                            algorithm: .ed25519,
                            title: "Ed25519",
                            subtitle: "fast, modern default"
                        )

                        algorithmCard(
                            algorithm: .ecdsaP256,
                            title: "P-256 Enclave",
                            subtitle: "device-bound"
                        )
                    }
                }

                protectionOptions

                HStack(spacing: 10) {
                    Spacer()

                    Btn("cancel", compact: true, action: onClose)

                    Btn("generate", style: .primary, compact: true) {
                        generate()
                    }
                }
            }
            .padding(isPhone ? 18 : 28)
            .frame(width: isPhone ? nil : 480)
            .frame(maxWidth: isPhone ? .infinity : nil)
            .background(T.panelBg)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(T.borderStrong, lineWidth: 1)
            )
            .onTapGesture {}
            .padding(.horizontal, isPhone ? 18 : 0)
        }
        .onChange(of: draft.name) { _, _ in
            if draft.errorText == "name is required" {
                draft.errorText = nil
            }
        }
    }

    @ViewBuilder
    private var protectionOptions: some View {
        if draft.algorithm == .ecdsaP256 {
            VStack(spacing: 0) {
                Rectangle()
                    .fill(T.border)
                    .frame(height: 1)

                enclaveNote(
                    "P-256 keys are generated in the Secure Enclave. They cannot be exported or moved to another device. Install a separate recoverable Ed25519 key before relying on this credential."
                )
                .padding(.vertical, 12)

                Rectangle()
                    .fill(T.border)
                    .frame(height: 1)
            }
            .padding(.top, -2)
        } else {
            Text("Ed25519 keys are stored in the iOS Keychain and can be exported as a passphrase-encrypted standard OpenSSH recovery file.")
                .font(Typography.tesseraMono(size: 11))
                .foregroundStyle(T.fgDim)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, -2)
        }

        ToggleRow(
            title: "require biometrics or passcode",
            subtitle: "Face ID/Touch ID or passcode whenever Tessera accesses this key",
            isOn: $draft.protectWithUserPresence
        )
        .padding(.vertical, 12)

        Text(draft.algorithm == .ecdsaP256
            ? "The key remains hardware-bound. Tessera enforces this authentication setting before key use, so you can change it later."
            : "This protection is enforced by iOS at the key boundary. It is separate from the recovery-file passphrase.")
            .font(Typography.tesseraMono(size: 10))
            .foregroundStyle(T.fgDim)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.bottom, 20)
    }

    private func algorithmCard(algorithm: KeyAlgorithm, title: String, subtitle: String) -> some View {
        let selected = draft.algorithm == algorithm

        return Button {
            draft.algorithm = algorithm
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(Typography.tesseraMono(size: 12, weight: .medium))
                    .foregroundStyle(T.fg)

                Text(subtitle)
                    .font(Typography.tesseraMono(size: 10))
                    .foregroundStyle(T.fgDim)
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? T.accentSoft : T.panelBg)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(selected ? T.accent : T.border, lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
    }

    private func generate() {
        let trimmedName = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            draft.errorText = "name is required"
            return
        }

        do {
            let softwareProtection: KeyStore.KeyProtection = draft.protectWithUserPresence
                ? .userPresence
                : .deviceUnlocked
            let stored: StoredKey
            switch draft.algorithm {
            case .ed25519:
                stored = try KeyStore.generateEd25519(
                    name: trimmedName,
                    context: modelContext,
                    protection: softwareProtection
                )
            case .ecdsaP256:
                // Secure Enclave access-control flags are immutable. Keep the
                // key hardware-bound but device-unlocked, then enforce the
                // user's mutable preference through Tessera's shared key-use
                // authorization gate.
                stored = try KeyStore.generateP256(
                    name: trimmedName,
                    enclave: true,
                    protection: .deviceUnlocked
                )
            case .rsa:
                draft.errorText = "RSA generation is not supported"
                return
            }
            stored.requiresBiometric = draft.protectWithUserPresence

            try StoredKeyLifecycle.persistCreatedKey(
                stored,
                boundary: .generation,
                persistence: KeyLifecyclePersistence.live(modelContext)
            )
            let metadata = KeySecurityMetadataStore()
            let boundaryProtection: KeyBoundaryProtection =
                draft.algorithm == .ecdsaP256
                    ? .deviceUnlocked
                    : (draft.protectWithUserPresence ? .userPresence : .deviceUnlocked)
            metadata.markBoundaryProtection(
                boundaryProtection,
                for: stored.id
            )
            metadata.markMaterialIntegrity(
                boundaryProtection == .userPresence ? .authenticationRequired : .valid,
                for: stored.id
            )
            onCreated(stored)
            onClose()
        } catch {
            draft.errorText = error.localizedDescription
        }
    }

    private func enclaveNote(_ text: String) -> some View {
        Text(text)
            .font(Typography.tesseraMono(size: 11))
            .foregroundStyle(T.fgDim)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.leading, 10)
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(T.accent)
                    .frame(width: 2)
            }
    }
}
