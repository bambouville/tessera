import SwiftUI

/// The one-time authentication surface for a continuation-created host.
/// Password bytes remain in the receiving device and the optional enrollment
/// action carries only this device's public key through the peer-bound stream.
struct CredentialCardView: View {
    @Environment(\.designTokens) private var T

    @Binding var password: String
    let hostName: String
    var errorMessage: String?
    var onAuthorizeFromPeer: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(spacing: 9) {
                Image(systemName: "key.horizontal.fill")
                    .foregroundStyle(T.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("authenticate to \(hostName.isEmpty ? "host" : hostName)")
                        .font(Typography.tesseraMono(size: 12.5, weight: .semibold))
                        .foregroundStyle(T.fg)
                    Text("first time on this device")
                        .font(Typography.tesseraMono(size: 10))
                        .foregroundStyle(T.fgMuted)
                }
            }

            Input(text: $password, placeholder: "password", secure: true)
                .textContentType(.password)

            Text("stored only in this device's keychain — never synced and never sent to the other device")
                .font(Typography.tesseraMono(size: 9.5))
                .foregroundStyle(T.fgDim)
                .fixedSize(horizontal: false, vertical: true)

            if let onAuthorizeFromPeer {
                HStack(spacing: 8) {
                    Rectangle().fill(T.border).frame(height: 0.5)
                    Text("or")
                        .font(Typography.tesseraMono(size: 9.5))
                        .foregroundStyle(T.fgDim)
                    Rectangle().fill(T.border).frame(height: 0.5)
                }

                Button(action: onAuthorizeFromPeer) {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "rectangle.on.rectangle.angled")
                            .foregroundStyle(T.accent)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("authorize this device from your other device")
                                .font(Typography.tesseraMono(size: 10.5, weight: .semibold))
                                .foregroundStyle(T.fg)
                            Text("installs this device's public key over the session already open there — no password moves between devices")
                                .font(Typography.tesseraMono(size: 9.5))
                                .foregroundStyle(T.fgMuted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(11)
                    .background(T.accentSoft)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(T.accent.opacity(0.35), lineWidth: 1)
                    }
                }
                .buttonStyle(.plain)
            }

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(Typography.tesseraMono(size: 9.5))
                    .foregroundStyle(T.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text("after this, continuing is one tap")
                .font(Typography.tesseraMono(size: 9.5))
                .foregroundStyle(T.fgDim)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(T.inputBg)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(T.border, lineWidth: 1)
        }
    }
}
