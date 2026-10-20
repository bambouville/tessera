import Foundation
import TesseraDomainCore

// This package is a shim. The forwarding model itself lives in
// `Packages/TesseraCore/Sources/TesseraDomainCore/PortForwarding.swift`,
// shared with Android; everything below is the iOS-side surface over it:
// re-exports so existing call sites keep compiling, the storage codec that
// migrates the legacy iOS blob, and the iOS sandbox validation overlay.

public typealias PortForwardDirection = TesseraDomainCore.PortForwardDirection
public typealias PortForwardEndpoint = TesseraDomainCore.PortForwardEndpoint
public typealias PortForwardRule = TesseraDomainCore.PortForwardRule
public typealias PortForwardRuleError = TesseraDomainCore.PortForwardRuleError
public typealias PortForwardRuleValidator = TesseraDomainCore.PortForwardRuleValidator
public typealias ForwardingTransport = TesseraDomainCore.ForwardingTransport
public typealias ForwardingCapabilities = TesseraDomainCore.ForwardingCapabilities
public typealias ForwardingUnavailableReason = TesseraDomainCore.ForwardingUnavailableReason
public typealias ForwardedWebTarget = TesseraDomainCore.ForwardedWebTarget
public typealias ForwardedWebPolicy = TesseraDomainCore.ForwardedWebPolicy

extension PortForwardRule {
    /// `host:port` for display. A dynamic rule has no target and renders
    /// empty; the iOS editor is local-only this round, so it never shows one.
    public var targetDisplayText: String {
        guard let target else { return "" }
        return "\(target.host):\(target.port)"
    }
}
