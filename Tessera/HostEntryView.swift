import SwiftUI

/// Minimal host entry form. No persistence yet — edits feed straight
/// into a binding the parent owns.
///
/// v1 cosmetic: bare-bones fields on a zero-chrome black background to
/// match §3.5. Visual polish, host groups, import from ~/.ssh/config,
/// and Keychain-backed credential storage come later.
struct HostEntryView: View {
    @Binding var host: Host
    var onConnect: () -> Void

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(alignment: .leading, spacing: 20) {
                Text("Tessera")
                    .font(.system(.largeTitle, design: .monospaced, weight: .semibold))
                    .foregroundStyle(.white)

                Text("new session")
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.5))

                Spacer().frame(height: 12)

                field("host", text: $host.address, placeholder: "127.0.0.1")
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .textContentType(.URL)

                HStack(spacing: 16) {
                    field("user", text: $host.user, placeholder: NSUserName())
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .textContentType(.username)
                        .frame(maxWidth: .infinity)

                    portField
                        .frame(width: 120)
                }

                secureField("password", text: $host.password, placeholder: "••••••••")
                    .textContentType(.password)

                autoTmuxToggle

                Spacer().frame(height: 12)

                Button(action: onConnect) {
                    HStack {
                        Text("connect")
                            .font(.system(.body, design: .monospaced, weight: .semibold))
                        Spacer()
                        Image(systemName: "arrow.right")
                    }
                    .foregroundStyle(.black)
                    .padding(.vertical, 14)
                    .padding(.horizontal, 20)
                    .frame(maxWidth: .infinity)
                    .background(connectEnabled ? Color.white : Color.white.opacity(0.3))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .disabled(!connectEnabled)
                .keyboardShortcut(.return, modifiers: [.command])

                Spacer()
            }
            .padding(.horizontal, 36)
            .padding(.vertical, 48)
            .frame(maxWidth: 560, alignment: .leading)
        }
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
    }

    private var connectEnabled: Bool {
        // A host is required; username/password may be empty and will
        // fail at auth time with a clear message from the server.
        !host.address.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Toggle for §3.2 auto-tmux on connect (default on). When
    /// enabled, Tessera sends a one-line shell snippet on connect
    /// that attaches to (or creates) a per-host tmux session and
    /// drops straight into control mode.
    private var autoTmuxToggle: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("auto-resume tmux")
                    .font(.system(.footnote, design: .monospaced, weight: .medium))
                    .foregroundStyle(.white.opacity(0.85))
                Text("attach to a per-host tmux session on connect")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.45))
            }
            Spacer()
            Toggle("", isOn: $host.autoTmux)
                .labelsHidden()
                .tint(.white.opacity(0.6))
        }
        .padding(.vertical, 4)
    }

    private var portField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("port")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.white.opacity(0.5))

            TextField(
                "22",
                value: $host.port,
                formatter: NumberFormatter.port
            )
            .font(.system(.body, design: .monospaced))
            .foregroundStyle(.white)
            .keyboardType(.numberPad)
            .padding(10)
            .background(Color.white.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }

    private func field(
        _ label: String,
        text: Binding<String>,
        placeholder: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.white.opacity(0.5))

            TextField(placeholder, text: text)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.white)
                .padding(10)
                .background(Color.white.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }

    private func secureField(
        _ label: String,
        text: Binding<String>,
        placeholder: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.white.opacity(0.5))

            SecureField(placeholder, text: text)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.white)
                .padding(10)
                .background(Color.white.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }
}

private extension NumberFormatter {
    static var port: NumberFormatter {
        let f = NumberFormatter()
        f.numberStyle = .none
        f.minimum = 1
        f.maximum = 65535
        f.allowsFloats = false
        return f
    }
}
