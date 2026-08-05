import SwiftUI
import UIKit
import TmuxControl

enum ContinuationOverlayPhase: Equatable, Sendable {
    case resolving
    case connecting
    case attached
    case failed(String)
}

struct ContinuationOverlayPresentation: Identifiable, Equatable, Sendable {
    let id: UUID
    let descriptor: SessionActivityDescriptor
    var phase: ContinuationOverlayPhase

    init(
        id: UUID = UUID(),
        descriptor: SessionActivityDescriptor,
        phase: ContinuationOverlayPhase = .resolving
    ) {
        self.id = id
        self.descriptor = descriptor
        self.phase = phase
    }
}

struct ContinuationOverlayView: View {
    let presentation: ContinuationOverlayPresentation
    let onDismiss: () -> Void

    @Environment(\.designTokens) private var T

    var body: some View {
        Group {
            if presentation.phase == .attached {
                attachedToast
            } else {
                blockingOverlay
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var blockingOverlay: some View {
        ZStack {
            Color.black.opacity(0.58)
                .ignoresSafeArea()

            VStack(spacing: 16) {
                statusIcon

                Text(title)
                    .font(Typography.tesseraMono(size: 16, weight: .semibold))
                    .foregroundStyle(T.fg)

                Text("\(presentation.descriptor.name) · \(presentation.descriptor.user)@\(presentation.descriptor.address):\(presentation.descriptor.port)")
                    .font(Typography.tesseraMono(size: 11))
                    .foregroundStyle(T.fgMuted)
                    .multilineTextAlignment(.center)

                details

                if canDismiss {
                    Btn(
                        "close",
                        style: .default,
                        full: true,
                        action: onDismiss
                    )
                }
            }
            .padding(22)
            .frame(maxWidth: 420)
            .background(T.panelBg)
            .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .stroke(T.borderStrong, lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.45), radius: 24, y: 12)
            .padding(24)
        }
    }

    private var attachedToast: some View {
        VStack {
            Spacer()
            HStack(spacing: 9) {
                Image(systemName: "rectangle.on.rectangle")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(T.fgMuted)

                Text(title)
                    .font(Typography.tesseraMono(size: 11.5, weight: .medium))
                    .foregroundStyle(T.fg)

                Circle()
                    .fill(T.green)
                    .frame(width: 6, height: 6)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial)
            .clipShape(Capsule())
            .overlay {
                Capsule()
                    .stroke(T.borderStrong, lineWidth: 0.5)
            }
            .shadow(color: .black.opacity(0.28), radius: 12, y: 6)
            .padding(.horizontal, 20)
            .padding(.bottom, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch presentation.phase {
        case .resolving, .connecting:
            ProgressView()
                .tint(T.accent)
                .controlSize(.large)
        case .attached:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 34, weight: .medium))
                .foregroundStyle(T.green)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 34, weight: .medium))
                .foregroundStyle(T.amber)
        }
    }

    private var title: String {
        switch presentation.phase {
        case .resolving:
            return "preparing \(actionGerund)"
        case .connecting:
            return actionGerund
        case .attached:
            return presentation.descriptor.continuationAction == .continueSession
                ? "attached · other device stays attached"
                : "reconnected on this device"
        case .failed:
            return "could not \(presentation.descriptor.continuationAction.label.lowercased())"
        }
    }

    private var actionGerund: String {
        presentation.descriptor.continuationAction == .continueSession
            ? "continuing from your other device"
            : "reconnecting from your other device"
    }

    @ViewBuilder
    private var details: some View {
        switch presentation.phase {
        case .failed(let message):
            Text(message)
                .tesseraSansScaled(size: 12)
                .foregroundStyle(T.fgMuted)
                .multilineTextAlignment(.center)
        default:
            VStack(alignment: .leading, spacing: 6) {
                if let tmux = presentation.descriptor.tmuxSessionName {
                    detailRow("tmux attach", tmux)
                    detailRow("geometry", "fits this device")
                } else {
                    detailRow("remote shell", "new session")
                }
                detailRow("transport", presentation.descriptor.transport.rawValue)
                detailRow("credentials", "stay on each device")
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(T.inputBg)
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(T.border, lineWidth: 1)
            }
        }
    }

    private func detailRow(_ key: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(key)
                .foregroundStyle(T.fgDim)
            Spacer(minLength: 8)
            Text(value)
                .foregroundStyle(T.fgMuted)
                .multilineTextAlignment(.trailing)
        }
        .font(Typography.tesseraMono(size: 10.5))
    }

    private var canDismiss: Bool {
        switch presentation.phase {
        case .failed: true
        case .resolving, .connecting, .attached: false
        }
    }
}

// MARK: - Grid authority (continuity takeover)

/// Stable per-install identity stamped into the tmux `@tessera_authority`
/// option when this device takes the shared grid. The display name is what
/// the *other* device's takeover card shows ("continued on iPhone"), so it
/// stays a generic device-class label, never the user-assigned device name.
enum GridAuthorityDeviceIdentity {
    private static let idKey = "TesseraGridAuthorityDeviceID"

    static func current() -> TmuxController.GridAuthorityIdentity {
        let defaults = UserDefaults.standard
        let id: String
        if let existing = defaults.string(forKey: idKey), !existing.isEmpty {
            id = existing
        } else {
            id = UUID().uuidString
            defaults.set(id, forKey: idKey)
        }
        return .init(id: id, displayName: selfDisplayName)
    }

    static var selfDisplayName: String {
        UIDevice.current.userInterfaceIdiom == .phone ? "iPhone" : "iPad"
    }
}

/// Full-terminal veil shown while another device holds the shared tmux grid.
/// Mounted as a ZStack sibling above the terminal surface (like
/// `SessionLaunchOverlay`), so it blurs only the terminal — top bar and
/// sidebar stay live. Tap anywhere, the pill, or any hardware key reclaims;
/// taking focus here also moves first responder off the terminal, which is
/// what suppresses keystrokes from reaching the shared PTY while yielded.
struct ContinuedElsewhereOverlay: View {
    let T: DesignTokens
    /// Stamp display name of the device holding the grid.
    let peerDisplayName: String
    /// True from the take-back gesture until confirmed geometry/repaint (or
    /// until the claim timeout folds the spinner back).
    let isReclaiming: Bool
    let onTakeBack: () -> Void

    @FocusState private var captureKeys: Bool
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(AppearancePreferences.self) private var appearance

    /// "iPhone" stays "iPhone"; a peer of our own device class reads
    /// "another iPad" so two iPads never claim the session continued on
    /// the device you are holding.
    private var peerLabel: String {
        peerDisplayName == GridAuthorityDeviceIdentity.selfDisplayName
            ? "another \(peerDisplayName)"
            : peerDisplayName
    }

    private var glyphName: String {
        switch peerDisplayName {
        case "iPhone": return "iphone"
        case "iPad": return "ipad.landscape"
        default: return "display"
        }
    }

    private var cardShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
    }

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.ultraThinMaterial)
                .overlay(Color.black.opacity(0.30))
            card
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture {
            guard !isReclaiming else { return }
            onTakeBack()
        }
        .focusable()
        .focusEffectDisabled()
        .focused($captureKeys)
        .onKeyPress { _ in
            guard !isReclaiming else { return .handled }
            onTakeBack()
            return .handled
        }
        .onAppear { captureKeys = true }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            isReclaiming
                ? "Taking back control of this session."
                : "Session continued on \(peerLabel). Double-tap to take back control."
        )
        .accessibilityAddTraits(.isButton)
    }

    private var card: some View {
        VStack(spacing: 0) {
            if isReclaiming {
                ProgressView()
                    .tint(T.fgMuted)
                    .padding(.bottom, 14)
            } else {
                Image(systemName: glyphName)
                    .font(.system(size: 38, weight: .light))
                    .foregroundStyle(T.fgMuted)
                    .modifier(ContinuedElsewhereBreathing())
                    .padding(.bottom, 14)
            }

            Text(isReclaiming ? "taking back control…" : "continued on \(peerLabel)")
                .font(Typography.tesseraMono(size: 15, weight: .medium))
                .foregroundStyle(T.fg)

            if !isReclaiming {
                Text("This session is being controlled from another device.")
                    .tesseraSansScaled(size: 12.5)
                    .foregroundStyle(T.fgMuted)
                    .multilineTextAlignment(.center)
                    .padding(.top, 7)

                Button(action: onTakeBack) {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.uturn.backward")
                            .font(.system(size: 12, weight: .medium))
                        Text("take back control")
                            .font(.system(size: 12.5, weight: .medium))
                    }
                    .foregroundStyle(T.fg)
                    .padding(.horizontal, 16)
                    .frame(height: 34)
                    .floatingGlass(
                        appearance.chromeMaterial,
                        tint: T.sidebarBg,
                        solidFill: T.inputBg,
                        in: Capsule()
                    )
                    .overlay {
                        Capsule().stroke(T.borderStrong, lineWidth: 0.5)
                    }
                }
                .buttonStyle(.plain)
                .padding(.top, 18)

                Text(
                    CompactLayout.isPhone(horizontalSizeClass)
                        ? "tap anywhere"
                        : "tap anywhere · or press any key"
                )
                .font(Typography.tesseraMono(size: 10.5))
                .foregroundStyle(T.fgFaint)
                .padding(.top, 11)
            }
        }
        .padding(.top, 26)
        .padding(.bottom, 22)
        .padding(.horizontal, 34)
        .frame(maxWidth: 340)
        .floatingGlass(
            appearance.chromeMaterial,
            tint: T.sidebarBg,
            solidFill: T.panelBg,
            in: cardShape
        )
        .overlay {
            cardShape.stroke(T.borderStrong, lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.45), radius: 24, y: 12)
        .padding(24)
    }
}

private struct ContinuedElsewhereBreathing: ViewModifier {
    @State private var dim = false

    func body(content: Content) -> some View {
        content
            .opacity(dim ? 0.55 : 1)
            .animation(
                .easeInOut(duration: 1.3).repeatForever(autoreverses: true),
                value: dim
            )
            .onAppear { dim = true }
    }
}

/// Bottom-center capsule confirming an automatic take-back (the peer
/// detached while this device was yielded). Mirrors the continuation
/// "attached" toast styling.
struct GridAuthorityReturnedToast: View {
    let T: DesignTokens
    let departedPeerLabel: String?

    var body: some View {
        VStack {
            Spacer()
            HStack(spacing: 9) {
                Image(systemName: "checkmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(T.green)
                Text(
                    departedPeerLabel.map { "\($0) left — control returned here" }
                        ?? "control returned here"
                )
                .font(Typography.tesseraMono(size: 11.5, weight: .medium))
                .foregroundStyle(T.fg)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial)
            .clipShape(Capsule())
            .overlay {
                Capsule().stroke(T.borderStrong, lineWidth: 0.5)
            }
            .shadow(color: .black.opacity(0.28), radius: 12, y: 6)
            .padding(.bottom, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
    }
}
