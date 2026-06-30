import SwiftUI
import SwiftData
import CryptoKit
import UIKit

/// Keys page (M3). Two-pane: 340pt list + detail.
struct KeysPageView: View {
    @Environment(\.designTokens) private var T
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \StoredKey.createdAt, order: .reverse) private var keys: [StoredKey]

    @State private var filterText = ""
    @State private var selectedID: UUID?
    @State private var didDefaultSelection = false
    @State private var showGenerateModal = false
    @State private var showImportModal = false
    @State private var showCopyToHostSheet = false
    @State private var toastText: String?

    private var filteredKeys: [StoredKey] {
        let needle = filterText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return keys }
        return keys.filter { $0.name.localizedCaseInsensitiveContains(needle) }
    }

    private var selectedKey: StoredKey? {
        guard let selectedID else { return nil }
        return keys.first { $0.id == selectedID }
    }

    var body: some View {
        ZStack {
            T.bg.ignoresSafeArea()

            HStack(spacing: 0) {
                leftPane

                Rectangle()
                    .fill(T.border)
                    .frame(width: 1)

                rightPane
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if showGenerateModal {
                GenerateKeyModal(
                    onClose: { showGenerateModal = false },
                    onCreated: { key in
                        selectedID = key.id
                        didDefaultSelection = true
                    }
                )
                .zIndex(10)
            }

            if showImportModal {
                ImportKeyModal(
                    onClose: { showImportModal = false },
                    onImported: { key in
                        selectedID = key.id
                        didDefaultSelection = true
                    }
                )
                .zIndex(10)
            }
        }
        .onAppear(perform: applyInitialSelectionIfNeeded)
        .onChange(of: keys.map(\.id)) { _, _ in
            reconcileSelectionAfterDataChange()
        }
        .sheet(isPresented: $showCopyToHostSheet) {
            if let selectedKey {
                InstallKeyToHostFlow(
                    key: selectedKey,
                    onClose: { showCopyToHostSheet = false }
                )
            }
        }
    }

    private var leftPane: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 8) {
                Text("keys")
                    .font(Typography.tesseraMono(size: 20, weight: .medium))
                    .foregroundStyle(T.fg)

                Spacer()

                Btn("+ generate", compact: true) {
                    showGenerateModal = true
                }

                Btn("import", compact: true) {
                    showImportModal = true
                }
            }
            .padding(.top, 20)
            .padding(.horizontal, 20)
            .padding(.bottom, 12)

            VStack(spacing: 0) {
                Input(text: $filterText, placeholder: "search")
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)

                Rectangle()
                    .fill(T.border)
                    .frame(height: 1)
            }

            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(filteredKeys) { key in
                        keyListRow(key)
                    }
                }
                .padding(8)
            }
        }
        .frame(width: 340)
        .frame(maxHeight: .infinity)
        .background(T.panelBg)
    }

    private var rightPane: some View {
        ZStack {
            if let selectedKey {
                ScrollView {
                    HStack(alignment: .top, spacing: 0) {
                        keyDetail(selectedKey)
                            .frame(maxWidth: 680, alignment: .leading)

                        Spacer(minLength: 0)
                    }
                    .padding(.top, 28)
                    .padding(.horizontal, 40)
                    .padding(.bottom, 40)
                }
            } else {
                placeholder(text: keys.isEmpty ? "no keys yet · generate or import one" : "select a key")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func keyListRow(_ key: StoredKey) -> some View {
        let isSelected = key.id == selectedID

        return Button {
            selectedID = key.id
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(displayName(for: key))
                        .font(Typography.tesseraMono(size: 13))
                        .foregroundStyle(isSelected ? T.accent : T.fg)
                        .lineLimit(1)

                    Spacer(minLength: 8)

                    if key.isSecureEnclave {
                        Tag(text: "secure enclave", color: T.accentSoft)
                    }
                }

                HStack(spacing: 6) {
                    Text("\(key.algorithm.displayName) · \(relativeDate(key.createdAt))")
                        .font(Typography.tesseraMono(size: 11))
                        .foregroundStyle(T.fgDim)
                        .lineLimit(1)

                    Spacer(minLength: 8)

                    if key.requiresBiometric {
                        Tag(text: "face id")
                    }
                }
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? T.inputBg : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
    }

    private func keyDetail(_ key: StoredKey) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(displayName(for: key))
                .font(Typography.tesseraMono(size: 28, weight: .medium))
                .foregroundStyle(T.fg)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 10)

            keyBadges(for: key)
                .padding(.bottom, 8)

            Text("created \(detailDate(key.createdAt))  ·  last used —")
                .font(Typography.tesseraMono(size: 13))
                .foregroundStyle(T.fgDim)
                .padding(.bottom, 28)

            Field(label: "type") {
                staticValue(key.algorithm.displayName, size: 13, color: T.fg)
            }

            Field(label: "fingerprint (sha256)") {
                staticValue(fingerprint(for: key), size: 11, color: T.fgMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Field(label: "public key") {
                staticValue(key.authorizedKeysLine, size: 11, color: T.fgMuted)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)

                if key.isSecureEnclave {
                    enclaveNote(
                        "private key never leaves this device. sync, export, and copy-private-key are disabled."
                    )
                    .padding(.top, 10)
                }

                HStack(spacing: 8) {
                    Btn("copy public key", compact: true) {
                        UIPasteboard.general.string = key.authorizedKeysLine
                        showToast("public key copied")
                    }

                    Btn("share", compact: true) {
                        showToast("share ships later")
                    }

                    Btn("copy to host…", compact: true) {
                        showCopyToHostSheet = true
                    }
                }
                .padding(.top, 10)

                if let toastText {
                    Text(toastText)
                        .font(Typography.tesseraMono(size: 11))
                        .foregroundStyle(T.fgDim)
                        .padding(.top, 8)
                }
            }

            Rectangle()
                .fill(T.border)
                .frame(height: 1)
                .padding(.top, 6)
                .padding(.bottom, 20)

            VStack(spacing: 14) {
                ToggleRow(
                    title: "require face id per use",
                    subtitle: "prompt biometric each time this key signs",
                    isOn: Binding(
                        get: { key.requiresBiometric },
                        set: { newValue in
                            key.requiresBiometric = newValue
                            saveModelContext("saving key biometric toggle")
                        }
                    )
                )

                ToggleRow(
                    title: "agent forwarding",
                    subtitle: "forward this key to remote hosts on demand",
                    isOn: Binding(
                        get: { key.agentForwarding },
                        set: { newValue in
                            key.agentForwarding = newValue
                            saveModelContext("saving key forwarding toggle")
                        }
                    )
                )
            }

            usedBySection(for: key)
                .padding(.top, 34)

            HStack(spacing: 10) {
                Btn("delete key", style: .danger, compact: true) {
                    delete(key)
                }

                if !key.isSecureEnclave {
                    Btn("export private key…", compact: true) {
                    }
                }
            }
            .padding(.top, 40)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func staticValue(_ text: String, size: CGFloat, color: Color) -> some View {
        Text(text)
            .font(Typography.tesseraMono(size: size))
            .foregroundStyle(color)
            .padding(.vertical, 10)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(T.inputBg)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(T.border, lineWidth: 1)
            )
    }

    @ViewBuilder
    private func keyBadges(for key: StoredKey) -> some View {
        HStack(spacing: 8) {
            keyBadge(
                text: badgeAlgorithmName(for: key.algorithm),
                background: T.inputBg,
                border: T.border,
                foreground: T.fg
            )

            if key.isSecureEnclave {
                keyBadge(
                    text: "secure enclave",
                    background: T.accentSoft,
                    border: T.accent,
                    foreground: T.accent
                )
            }

            if key.requiresBiometric {
                keyBadge(
                    text: "face id",
                    background: T.panelBg,
                    border: T.border,
                    foreground: T.fgDim
                )
            }
        }
    }

    private func keyBadge(
        text: String,
        background: Color,
        border: Color,
        foreground: Color
    ) -> some View {
        Text(text.uppercased())
            .font(Typography.tesseraMono(size: 10))
            .tracking(0.6)
            .foregroundStyle(foreground)
            .padding(.vertical, 3)
            .padding(.horizontal, 8)
            .background(background)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(border, lineWidth: 1)
            )
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

    private func badgeAlgorithmName(for algorithm: KeyAlgorithm) -> String {
        switch algorithm {
        case .ed25519:
            return "ed25519"
        case .ecdsaP256:
            return "ecdsa-p256"
        case .rsa:
            return "rsa"
        }
    }

    private func usedBySection(for key: StoredKey) -> some View {
        let hostNames = usedHostNames(for: key)

        return VStack(alignment: .leading, spacing: 10) {
            Text("used by")
                .font(Typography.tesseraMono(size: 13, weight: .medium))
                .foregroundStyle(T.fg)

            if hostNames.isEmpty {
                Text("no hosts use this key yet")
                    .font(Typography.tesseraMono(size: 13))
                    .foregroundStyle(T.fgDim)
            } else {
                FlowTags(names: hostNames)
            }
        }
    }

    private func placeholder(text: String) -> some View {
        VStack {
            Spacer()
            Text(text)
                .font(Typography.tesseraMono(size: 14))
                .foregroundStyle(T.fgDim)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    private func usedHostNames(for key: StoredKey) -> [String] {
        let descriptor = FetchDescriptor<Identity>()
        let identities = (try? modelContext.fetch(descriptor)) ?? []
        let names = identities.flatMap { identity -> [String] in
            guard case .key(let keyID) = identity.credentialMode, keyID == key.id else {
                return []
            }
            return identity.hosts.map { host in
                host.name.isEmpty ? host.address : host.name
            }
        }
        return Array(Set(names)).sorted {
            $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }
    }

    private func fingerprint(for key: StoredKey) -> String {
        let parts = key.authorizedKeysLine.split(separator: " ")
        guard parts.count >= 2,
              let publicKeyData = Data(base64Encoded: String(parts[1]))
        else {
            return "SHA256:—"
        }

        let digest = SHA256.hash(data: publicKeyData)
        return "SHA256:\(Data(digest).base64EncodedString())"
    }

    private func delete(_ key: StoredKey) {
        KeyStore.deleteKey(forKeyID: key.id)
        modelContext.delete(key)
        selectedID = nil
        saveModelContext("deleting key")
    }

    private func displayName(for key: StoredKey) -> String {
        key.name.isEmpty ? "unnamed key" : key.name
    }

    private func relativeDate(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) {
            return "today"
        }
        return date.formatted(.dateTime.month(.abbreviated).day())
    }

    private func detailDate(_ date: Date) -> String {
        date.formatted(.dateTime.year().month(.abbreviated).day())
    }

    private func applyInitialSelectionIfNeeded() {
        guard !didDefaultSelection, selectedID == nil, let first = keys.first else { return }
        selectedID = first.id
        didDefaultSelection = true
    }

    private func reconcileSelectionAfterDataChange() {
        if let selectedID, !keys.contains(where: { $0.id == selectedID }) {
            self.selectedID = nil
        }
        applyInitialSelectionIfNeeded()
    }

    private func saveModelContext(_ action: String) {
        do {
            try modelContext.save()
        } catch {
            DiagnosticLogStore.appendKeys("model-save failed action='\(action)' error='\(error)'")
        }
    }

    private func showToast(_ text: String) {
        toastText = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
            if toastText == text {
                toastText = nil
            }
        }
    }
}

private struct FlowTags: View {
    let names: [String]

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                tagContent
            }

            VStack(alignment: .leading, spacing: 8) {
                tagContent
            }
        }
    }

    @ViewBuilder
    private var tagContent: some View {
        ForEach(names, id: \.self) { name in
            Tag(text: name)
        }
    }
}
