import SwiftUI
import SwiftData

struct ImportKeyModal: View {
    var onClose: () -> Void
    var onImported: (StoredKey) -> Void

    @Environment(\.designTokens) private var T
    @Environment(\.modelContext) private var modelContext

    @State private var name = ""
    @State private var pemText = ""
    @State private var passphrase = ""
    @State private var importError: String?

    var body: some View {
        ZStack {
            Color.black.opacity(0.6)
                .ignoresSafeArea()
                .onTapGesture(perform: onClose)

            VStack(alignment: .leading, spacing: 0) {
                Text("import key")
                    .font(Typography.tesseraMono(size: 18, weight: .medium))
                    .foregroundStyle(T.fg)
                    .padding(.bottom, 20)

                Field(label: "name") {
                    Input(text: $name, placeholder: "imported key")
                }

                Field(label: "private key (OpenSSH PEM)") {
                    ZStack(alignment: .topLeading) {
                        TextEditor(text: $pemText)
                            .font(Typography.tesseraMono(size: 11))
                            .foregroundStyle(T.fg)
                            .scrollContentBackground(.hidden)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .padding(8)
                            .frame(height: 120)

                        if pemText.isEmpty {
                            Text("paste private key")
                                .font(Typography.tesseraMono(size: 11))
                                .foregroundStyle(T.fgDim)
                                .padding(.horizontal, 13)
                                .padding(.vertical, 16)
                                .allowsHitTesting(false)
                        }
                    }
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

                Field(label: "passphrase (optional)") {
                    Input(text: $passphrase, placeholder: "", secure: true)
                }

                HStack(spacing: 10) {
                    Spacer()

                    Btn("cancel", compact: true, action: onClose)

                    Btn("import", style: .primary, compact: true) {
                        importKey()
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
    }

    private func importKey() {
        do {
            let stored = try KeyStore.importKey(
                pem: pemText.trimmingCharacters(in: .whitespacesAndNewlines),
                passphrase: passphrase.isEmpty ? nil : passphrase,
                name: name.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            modelContext.insert(stored)
            try modelContext.save()
            onImported(stored)
            onClose()
        } catch {
            importError = error.localizedDescription
        }
    }
}
