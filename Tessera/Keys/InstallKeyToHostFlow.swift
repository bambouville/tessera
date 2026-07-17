import SwiftUI
import SwiftData

struct InstallKeyToHostFlow: View {
    enum Step {
        case pickHost
        case confirm(host: PersistedHost)
        case installing(host: PersistedHost)
        case result(host: PersistedHost, outcome: Outcome)
    }

    enum Outcome {
        case success
        case failure(message: String)
    }

    let key: StoredKey
    let onClose: () -> Void

    @Environment(\.designTokens) private var T
    @Environment(AppearancePreferences.self) private var appearance
    @Query(sort: [
        SortDescriptor(\PersistedHost.sortOrder),
        SortDescriptor(\PersistedHost.name)
    ]) private var hosts: [PersistedHost]
    @Query(sort: \StoredKey.createdAt, order: .reverse) private var storedKeys: [StoredKey]

    @State private var step: Step = .pickHost
    @State private var installTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 20) {
                header
                content
            }
            .frame(maxWidth: 560, alignment: .leading)
            .padding(.top, 28)
            .padding(.horizontal, 32)

            Spacer(minLength: 24)

            actions
                .frame(maxWidth: 560)
                .padding(.horizontal, 32)
                .padding(.bottom, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(T.bg.ignoresSafeArea())
        .onDisappear {
            installTask?.cancel()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("copy key to host")
                .font(Typography.tesseraMono(size: 20, weight: .medium))
                .foregroundStyle(T.fg)

            Text(stepLabel)
                .font(Typography.tesseraMono(size: 12))
                .foregroundStyle(T.fgMuted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var content: some View {
        if key.algorithm == .rsa {
            resultHeader(
                symbol: "xmark.shield.fill",
                color: T.red,
                title: "Legacy RSA installation is disabled. Generate an Ed25519 replacement and use a different working credential to install it before retiring this key."
            )
        } else {
            switch step {
            case .pickHost:
                hostPicker

            case .confirm(let host):
                confirmView(host: host)

            case .installing(let host):
                installingView(host: host)

            case .result(let host, let outcome):
                resultView(host: host, outcome: outcome)
            }
        }
    }

    @ViewBuilder
    private var actions: some View {
        if key.algorithm == .rsa {
            HStack {
                Spacer()
                Btn("done", compact: true, action: close)
            }
        } else {
            switch step {
        case .pickHost:
            HStack {
                Spacer()
                Btn("done", compact: true, action: close)
            }

        case .confirm(let host):
            HStack(spacing: 10) {
                Btn("back", compact: true) {
                    step = .pickHost
                }

                Spacer()

                Btn("cancel", compact: true, action: close)

                Btn("install", style: .primary, compact: true) {
                    beginInstall(on: host)
                }
            }

        case .installing:
            EmptyView()

        case .result(let host, let outcome):
            HStack(spacing: 10) {
                switch outcome {
                case .success:
                    Spacer()
                    Btn("done", style: .primary, compact: true, action: close)

                case .failure:
                    Btn("retry", style: .primary, compact: true) {
                        beginInstall(on: host)
                    }

                    Spacer()

                    Btn("done", compact: true, action: close)
                }
            }
        }
        }
    }

    private var hostPicker: some View {
        VStack(alignment: .leading, spacing: 12) {
            if hosts.isEmpty {
                Text("no saved hosts")
                    .font(Typography.tesseraMono(size: 13))
                    .foregroundStyle(T.fgDim)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(T.inputBg)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(T.border, lineWidth: 1)
                    )
            } else {
                ForEach(hosts) { host in
                    Button {
                        step = .confirm(host: host)
                    } label: {
                        hostRow(host)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func confirmView(host: PersistedHost) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("About to install \(displayName(for: key)) on \(displayName(for: host))")
                .font(Typography.tesseraMono(size: 14, weight: .medium))
                .foregroundStyle(T.fg)
                .fixedSize(horizontal: false, vertical: true)

            valueBlock(title: "authorized_keys line", value: key.authorizedKeysLine)
        }
    }

    private func installingView(host: PersistedHost) -> some View {
        HStack(spacing: 12) {
            ProgressView()
                .progressViewStyle(.circular)

            VStack(alignment: .leading, spacing: 4) {
                Text("installing key")
                    .font(Typography.tesseraMono(size: 14, weight: .medium))
                    .foregroundStyle(T.fg)

                Text(displayName(for: host))
                    .font(Typography.tesseraMono(size: 12))
                    .foregroundStyle(T.fgMuted)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(T.inputBg)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(T.border, lineWidth: 1)
        )
    }

    private func resultView(host: PersistedHost, outcome: Outcome) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            switch outcome {
            case .success:
                resultHeader(
                    symbol: "checkmark.circle.fill",
                    color: T.green,
                    title: "Key installed on \(displayName(for: host))"
                )

            case .failure(let message):
                resultHeader(
                    symbol: "xmark.octagon.fill",
                    color: T.red,
                    title: message
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func resultHeader(symbol: String, color: Color, title: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(color)

            Text(title)
                .font(Typography.tesseraMono(size: 14, weight: .medium))
                .foregroundStyle(T.fg)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(T.inputBg)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(T.border, lineWidth: 1)
        )
    }

    private func hostRow(_ host: PersistedHost) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(displayName(for: host))
                .font(Typography.tesseraMono(size: 13, weight: .medium))
                .foregroundStyle(T.fg)
                .lineLimit(1)

            Text(subtitle(for: host))
                .font(Typography.tesseraMono(size: 11))
                .foregroundStyle(T.fgDim)
                .lineLimit(1)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(T.inputBg)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(T.border, lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 6))
    }

    private func valueBlock(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(Typography.tesseraMono(size: 11, weight: .medium))
                .foregroundStyle(T.fgDim)

            ScrollView(.horizontal, showsIndicators: false) {
                Text(value)
                    .font(Typography.tesseraMono(size: 11))
                    .foregroundStyle(T.fgMuted)
                    .lineLimit(1)
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(T.inputBg)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(T.border, lineWidth: 1)
        )
    }

    private var stepLabel: String {
        switch step {
        case .pickHost:
            return "pick host"
        case .confirm:
            return "confirm"
        case .installing:
            return "installing"
        case .result:
            return "result"
        }
    }

    @MainActor
    private func beginInstall(on persistedHost: PersistedHost) {
        guard key.algorithm != .rsa else { return }
        installTask?.cancel()
        step = .installing(host: persistedHost)

        let host = Host(from: persistedHost)
        let keyID = key.id
        let authorizedKeysLine = key.authorizedKeysLine
        let storedKey = configuredStoredKey(for: persistedHost)
        let requireBiometric = requiresBiometricForKeyUse(
            on: persistedHost,
            storedKey: storedKey
        )
        let isSecureEnclave = storedKey?.isSecureEnclave ?? false

        installTask = Task { @MainActor in
            let outcome: Outcome
            do {
                try await RemoteAuthorizedKeysInstaller.install(
                    line: authorizedKeysLine,
                    keyID: keyID,
                    on: host,
                    requireBiometric: requireBiometric,
                    isSecureEnclave: isSecureEnclave
                )
                KeySecurityMetadataStore().recordRemoteInstallation(
                    keyID: keyID,
                    hostID: persistedHost.id,
                    hostLabel: displayName(for: persistedHost),
                    endpoint: "\(persistedHost.address):\(persistedHost.port)"
                )
                outcome = .success
            } catch {
                outcome = .failure(message: userFacingMessage(for: error))
            }

            guard !Task.isCancelled else { return }
            step = .result(host: persistedHost, outcome: outcome)
        }
    }

    private func requiresBiometricForKeyUse(
        on host: PersistedHost,
        storedKey: StoredKey? = nil
    ) -> Bool {
        guard case .key(let keyID) = host.identity?.credentialMode else {
            return false
        }
        let key = storedKey ?? storedKeys.first { $0.id == keyID }
        return KeyOwnerPresencePolicy.isRequired(
            globalPreference: appearance.requireBiometricForKeyUse,
            key: key
        )
    }

    private func configuredStoredKey(for host: PersistedHost) -> StoredKey? {
        guard case .key(let keyID) = host.identity?.credentialMode else {
            return nil
        }
        return storedKeys.first { $0.id == keyID }
    }

    private func close() {
        installTask?.cancel()
        onClose()
    }

    private func userFacingMessage(for error: Error) -> String {
        if let installError = error as? RemoteAuthorizedKeysInstaller.InstallError {
            return installError.errorDescription ?? "Could not install key"
        }
        return error.localizedDescription
    }

    private func displayName(for key: StoredKey) -> String {
        key.name.isEmpty ? "unnamed key" : key.name
    }

    private func displayName(for host: PersistedHost) -> String {
        host.name.isEmpty ? host.address : host.name
    }

    private func subtitle(for host: PersistedHost) -> String {
        let user = host.effectiveUser.isEmpty ? "unknown" : host.effectiveUser
        return "\(user)@\(host.address):\(host.port)"
    }
}
