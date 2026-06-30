import SwiftUI
import SwiftData

struct GenerateKeyModal: View {
    var onClose: () -> Void
    var onCreated: (StoredKey) -> Void

    @Environment(\.designTokens) private var T
    @Environment(\.modelContext) private var modelContext

    @State private var name = ""
    @State private var algorithm: KeyAlgorithm = .ed25519
    @State private var enclave = false
    @State private var errorText: String?

    var body: some View {
        ZStack {
            Color.black.opacity(0.6)
                .ignoresSafeArea()
                .onTapGesture(perform: onClose)

            VStack(alignment: .leading, spacing: 0) {
                Text("generate key")
                    .font(Typography.tesseraMono(size: 18, weight: .medium))
                    .foregroundStyle(T.fg)
                    .padding(.bottom, 20)

                Field(label: "name") {
                    Input(text: $name, placeholder: "my new key")

                    if let errorText {
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
                            title: "ECDSA",
                            subtitle: "NIST curve"
                        )
                    }
                }

                enclaveOptions

                HStack(spacing: 10) {
                    Spacer()

                    Btn("cancel", compact: true, action: onClose)

                    Btn("generate", style: .primary, compact: true) {
                        generate()
                    }
                }
            }
            .padding(28)
            .frame(width: 480)
            .background(T.panelBg)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(T.borderStrong, lineWidth: 1)
            )
            .onTapGesture {}
        }
        .onChange(of: name) { _, _ in
            if errorText == "name is required" {
                errorText = nil
            }
        }
        .onChange(of: algorithm) { _, newAlgorithm in
            if newAlgorithm != .ecdsaP256 {
                enclave = false
            }
        }
    }

    @ViewBuilder
    private var enclaveOptions: some View {
        if algorithm == .ecdsaP256 {
            VStack(spacing: 0) {
                Rectangle()
                    .fill(T.border)
                    .frame(height: 1)

                ToggleRow(
                    title: "store in secure enclave",
                    subtitle: "key never leaves this device",
                    isOn: $enclave
                )
                .padding(.vertical, 12)

                if enclave {
                    enclaveNote(
                        "private key never leaves this device. you cannot export or back up this key — losing the device loses the key. tessera's biometric gate still applies if 'require face id per use' is on."
                    )
                    .padding(.bottom, 12)
                }

                Rectangle()
                    .fill(T.border)
                    .frame(height: 1)
            }
            .padding(.top, -2)
            .padding(.bottom, 20)
        } else {
            Text("ed25519 keys are stored in the iOS keychain. the enclave option appears when ECDSA is selected.")
                .font(Typography.tesseraMono(size: 11))
                .foregroundStyle(T.fgDim)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, -2)
                .padding(.bottom, 20)
        }
    }

    private func algorithmCard(algorithm: KeyAlgorithm, title: String, subtitle: String) -> some View {
        let selected = self.algorithm == algorithm

        return Button {
            self.algorithm = algorithm
            if algorithm != .ecdsaP256 {
                enclave = false
            }
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
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            errorText = "name is required"
            return
        }

        do {
            let stored: StoredKey
            switch algorithm {
            case .ed25519:
                stored = try KeyStore.generateEd25519(name: trimmedName, context: modelContext)
            case .ecdsaP256:
                stored = try KeyStore.generateP256(name: trimmedName, enclave: enclave)
            case .rsa:
                errorText = "RSA generation is not supported"
                return
            }

            modelContext.insert(stored)
            try modelContext.save()
            onCreated(stored)
            onClose()
        } catch {
            errorText = error.localizedDescription
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
