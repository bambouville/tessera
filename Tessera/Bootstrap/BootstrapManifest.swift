import Foundation
import TesseraProtocolCore

public typealias BootstrapHostTransport = TesseraProtocolCore.BootstrapHostTransport
public typealias BootstrapHostLaunchMode = TesseraProtocolCore.BootstrapHostLaunchMode
public typealias BootstrapAuthenticationHint = TesseraProtocolCore.BootstrapAuthenticationHint
typealias BootstrapOptionalTransfer = TesseraProtocolCore.BootstrapOptionalTransfer
public typealias BootstrapIdentityDescriptor = TesseraProtocolCore.BootstrapIdentityDescriptor
public typealias BootstrapPortForwardRule = TesseraProtocolCore.BootstrapPortForwardRule
public typealias BootstrapHostDescriptor = TesseraProtocolCore.BootstrapHostDescriptor
public typealias BootstrapKnownHostDescriptor = TesseraProtocolCore.BootstrapKnownHostDescriptor
public typealias BootstrapJumpLink = TesseraProtocolCore.BootstrapJumpLink
public typealias BootstrapAppearanceSettings = TesseraProtocolCore.BootstrapAppearanceSettings
public typealias BootstrapGeneralSettings = TesseraProtocolCore.BootstrapGeneralSettings
public typealias BootstrapManifestError = TesseraProtocolCore.BootstrapManifestError
public typealias BootstrapManifest = TesseraProtocolCore.BootstrapManifestV2
typealias ApprovedBootstrapManifest = TesseraProtocolCore.ApprovedBootstrapManifestV2

extension TesseraProtocolCore.BootstrapManifestError: @retroactive LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let version):
            return String(localized: "Unsupported bootstrap manifest version \(version).")
        case .encodedSizeExceeded(let actual, let maximum):
            return String(localized: "Bootstrap manifest is \(actual) bytes; maximum is \(maximum).")
        case .tooManyHosts(let count):
            return String(localized: "Bootstrap manifest contains too many hosts (\(count)).")
        case .tooManyIdentities(let count):
            return String(localized: "Bootstrap manifest contains too many identities (\(count)).")
        case .tooManyJumpChains(let count):
            return String(localized: "Bootstrap manifest contains too many jump-chain links (\(count)).")
        case .tooManyKnownHosts(let count):
            return String(localized: "Bootstrap manifest contains too many known-host records (\(count)).")
        case .duplicateIdentityID(let id):
            return String(localized: "Bootstrap manifest repeats identity \(id).")
        case .invalidIdentity(let id, let field):
            return String(localized: "Bootstrap identity \(id) has an invalid \(field).")
        case .duplicateHostID(let id):
            return String(localized: "Bootstrap manifest repeats host \(id).")
        case .invalidHost(let id, let field):
            return String(localized: "Bootstrap host \(id) has an invalid \(field).")
        case .duplicateJumpLink(let id):
            return String(localized: "Bootstrap manifest repeats the jump link for \(id).")
        case .danglingJumpLink(let id):
            return String(localized: "Bootstrap jump link references missing host \(id).")
        case .cyclicJumpChain(let id):
            return String(localized: "Bootstrap jump chain contains a cycle at \(id).")
        case .jumpChainTooDeep(let id):
            return String(localized: "Bootstrap jump chain for \(id) is too deep.")
        case .duplicateKnownHost(let id):
            return String(localized: "Bootstrap manifest repeats the known-host record for \(id).")
        case .invalidKnownHost(let id, let field):
            return String(localized: "Bootstrap known-host record \(id) has an invalid \(field).")
        case .invalidAppearance(let field):
            return String(localized: "Bootstrap appearance field \(field) is invalid.")
        case .invalidSettings(let field):
            return String(localized: "Bootstrap setting \(field) is invalid.")
        case .unselectedOptionalField(let field):
            return String(localized: "Bootstrap optional field \(field) was not approved for transfer.")
        case .malformedJSON:
            return String(localized: "Bootstrap manifest is not a JSON object.")
        case .unknownField(let path, let field):
            return String(localized: "Bootstrap manifest contains unknown field \(path).\(field).")
        }
    }
}

/// Checked-in classification for properties on Apple persistence models.
/// This is deliberately an app concern; the wire schema itself lives only in
/// `BootstrapManifestV2`.
public enum BootstrapFieldDisposition: String, Hashable, Sendable {
    case syncable
    case explicitNearbyOptIn
    case neverSyncs
}

public enum BootstrapSyncClassification {
    public static let persistedHost: [String: BootstrapFieldDisposition] = [
        "id": .syncable,
        "name": .syncable,
        "address": .syncable,
        "port": .syncable,
        "autoTmux": .neverSyncs,
        "transportRaw": .syncable,
        "launchModeRaw": .syncable,
        "tmuxSessionName": .syncable,
        "launchCommand": .explicitNearbyOptIn,
        "tags": .syncable,
        "osHint": .syncable,
        "notes": .explicitNearbyOptIn,
        "envVars": .explicitNearbyOptIn,
        "startupSnippet": .explicitNearbyOptIn,
        "portForwardRulesData": .syncable,
        "user": .syncable,
        "sortOrder": .syncable,
        "identity": .syncable,
    ]

    public static let identity: [String: BootstrapFieldDisposition] = [
        "id": .syncable,
        "name": .syncable,
        "user": .syncable,
        "credentialMode": .neverSyncs,
        "hosts": .syncable,
    ]

    public static let hostJumpLink: [String: BootstrapFieldDisposition] = [
        "hostID": .syncable,
        "jumpHostID": .syncable,
    ]

    public static let appearancePreferences: [String: BootstrapFieldDisposition] = [
        "mode": .syncable,
        "accent": .syncable,
        "customAccentRGB": .syncable,
        "terminalFontID": .syncable,
        "fontSize": .syncable,
        "topBarHeight": .neverSyncs,
        "handoffSessionsEnabled": .neverSyncs,
        "chromeMaterial": .syncable,
        "cursorStyle": .syncable,
        "cursorBlink": .syncable,
        "scrollbackLines": .syncable,
        "smoothScrollingEnabled": .neverSyncs,
        "smoothScrollingSpeed": .neverSyncs,
        "sessionRestorePolicy": .neverSyncs,
        "terminalThemeID": .syncable,
        "terminalBackgroundUsesImage": .neverSyncs,
        "terminalBackgroundImageID": .neverSyncs,
        "terminalBackgroundDim": .neverSyncs,
        "terminalBackgroundFillMode": .neverSyncs,
        "terminalBackgroundBlur": .neverSyncs,
        "naturalTextEditingEnabled": .neverSyncs,
        "showAccessoryBar": .neverSyncs,
        "resizeTerminalWithKeyboard": .neverSyncs,
        "programStatusEnabled": .neverSyncs,
        "accessoryBarKeys": .syncable,
        "modifierBehavior": .syncable,
        "modifierNotation": .syncable,
        "filesReaperDays": .syncable,
        "filesDefaultDestination": .syncable,
        "requireFaceIDToUnlock": .neverSyncs,
        "autoLockMinutes": .neverSyncs,
        "lockWhenBackgrounded": .neverSyncs,
        "hideContentInAppSwitcher": .neverSyncs,
        "requireBiometricForKeyUse": .neverSyncs,
        "bellSoundEnabled": .syncable,
        "bellVisualEnabled": .syncable,
        "bellNotificationEnabled": .syncable,
        "agentCenterNotificationsEnabled": .neverSyncs,
        "agentCenterEnabled": .syncable,
        "agentScrollLockClaudeCodeEnabled": .neverSyncs,
        "agentScrollLockCodexEnabled": .neverSyncs,
        "swipePadEnabled": .neverSyncs,
        "swipePadCorner": .neverSyncs,
        "swipePadSize": .neverSyncs,
        "swipePadLastX": .neverSyncs,
        "swipePadLastY": .neverSyncs,
        "voiceDictationEnabled": .neverSyncs,
        "voiceCommitOnSilence": .neverSyncs,
        "voiceAppendReturn": .neverSyncs,
        "voiceWaveformOnPuck": .neverSyncs,
        "hasSeenWelcome": .neverSyncs,
    ]
}
