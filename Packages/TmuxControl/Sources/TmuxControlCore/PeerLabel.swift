import Foundation

/// How a device that currently holds the shared tmux grid is named in UI.
///
/// The label is policy, not data: a peer's `displayName` is free text written
/// by another install's stamp, and it crosses platforms. "iPad" shown on an
/// Android phone, or "Android-Phone" shown on an iPad, reads as noise rather
/// than as a device, so the only names rendered verbatim are the ones the
/// local platform recognises as its own device classes. Everything else —
/// blank, unparsed, unrecognised — resolves to the same stamp-less fallback,
/// which keeps both ends of a mixed pair saying the same thing.
///
/// Both platforms call this; deriving it privately is what let Android render
/// a raw peer stamp where iOS renders a device class.
public enum TmuxPeerLabel {
    /// What a platform should say about the peer. A *decision*, not a string,
    /// so each platform renders it through its own localisation — collapsing
    /// this to English here is how "sur un autre iPad" became "sur another
    /// iPad".
    public enum Kind: Equatable, Sendable {
        /// A device class this platform knows; render the name.
        case named(String)
        /// A second device of our own class; render "another <name>".
        case anotherOfOwnClass(String)
        /// Blank, unparsed, or another platform's stamp.
        case unknownDevice
    }

    /// - Parameters:
    ///   - peerDisplayName: `displayName` from the peer's authority stamp.
    ///   - selfDisplayName: this device's own stamp name.
    ///   - knownDeviceNames: the device classes this platform stamps, and
    ///     therefore the only foreign names it can render meaningfully.
    public static func resolve(
        peerDisplayName: String?,
        selfDisplayName: String,
        knownDeviceNames: Set<String>
    ) -> Kind {
        guard let peer = nonEmpty(peerDisplayName) else { return .unknownDevice }
        // Two devices of one class: naming the class would claim the session
        // continued on the device you are holding.
        if peer == nonEmpty(selfDisplayName) { return .anotherOfOwnClass(peer) }
        guard knownDeviceNames.contains(peer) else { return .unknownDevice }
        return .named(peer)
    }

    /// English rendering, for callers with no localisation catalogue of their
    /// own. Platforms that localise must switch on `resolve` instead.
    public static func display(
        peerDisplayName: String?,
        selfDisplayName: String,
        knownDeviceNames: Set<String>
    ) -> String {
        switch resolve(
            peerDisplayName: peerDisplayName,
            selfDisplayName: selfDisplayName,
            knownDeviceNames: knownDeviceNames
        ) {
        case .named(let name): return name
        case .anotherOfOwnClass(let name): return "another \(name)"
        case .unknownDevice: return TmuxStamplessPeer.displayName
        }
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
