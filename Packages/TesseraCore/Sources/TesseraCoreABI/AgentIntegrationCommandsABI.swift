import Foundation
import TesseraAgentCore

private let agentIntegrationMaximumConfigBytes = 1_048_576
private let agentIntegrationMaximumProbeBytes = 65_536
private let agentIntegrationMaximumConfigReadBytes = 8_388_608

@_cdecl("tessera_agent_host_deployment_command")
public func tesseraAgentHostDeploymentCommand(
    inputBytes: UnsafePointer<UInt8>?, inputCount: Int,
    outputBytes: UnsafeMutablePointer<UInt8>?, outputCapacity: Int
) -> Int32 {
    guard let inputBytes, inputCount > 0, inputCount <= 65_536,
          let request = try? JSONDecoder().decode(AgentHostDeployment.Request.self, from: Data(bytes: inputBytes, count: inputCount)),
          let command = try? AgentHostDeployment.command(request) else { return -1 }
    return agentIntegrationCopyOut(command, outputBytes, outputCapacity)
}

@_cdecl("tessera_agent_projector_diagnostics")
public func tesseraAgentProjectorDiagnostics(
    inputBytes: UnsafePointer<UInt8>?, inputCount: Int,
    outputBytes: UnsafeMutablePointer<UInt8>?, outputCapacity: Int
) -> Int32 {
    guard let inputBytes, inputCount > 0, inputCount <= AgentProjectionRequest.maximumBytes else { return -1 }
    let fields = AgentProjectionDiagnostics.errorFields(stdout: Data(bytes: inputBytes, count: inputCount))
    guard let encoded = agentIntegrationEncoded(fields) else { return -1 }
    return agentIntegrationCopyOut(encoded, outputBytes, outputCapacity)
}

private struct AgentIntegrationDecisionRequest: Codable {
    let observation: AgentIntegrationObservation
    let requestedAction: AgentIntegrationDecisionAction?
}

private struct AgentIntegrationDecisionResponse: Codable {
    let decision: AgentIntegrationDecision
    let showsWarning: Bool
    let effectiveAction: AgentIntegrationDecisionAction?
}

private struct AgentIntegrationInstallationResponse: Codable {
    let kind: AgentIntegrationInstallationKind
    let version: Int?
}

private enum AgentIntegrationInstallOutcomeKind: String, Codable {
    case completed
    case configurationRace
    case failed
}

/// The install decision as it crosses the ABI. The untrusted remote output that
/// produced it deliberately stays on this side: only the bounded reason travels.
private struct AgentIntegrationInstallOutcomeResponse: Codable {
    let kind: AgentIntegrationInstallOutcomeKind
    let reason: String?
}

private struct AgentIntegrationConfigSnapshotResponse: Codable {
    let present: Bool
    let contents: String?
}

private struct AgentIntegrationConfigSnapshotsResponse: Codable {
    let codex: AgentIntegrationConfigSnapshotResponse
    let claude: AgentIntegrationConfigSnapshotResponse
    let kimi: AgentIntegrationConfigSnapshotResponse
}

private func agentIntegrationOutputString(
    bytes: UnsafePointer<UInt8>?,
    count: Int,
    maximum: Int = agentIntegrationMaximumProbeBytes
) -> String? {
    guard let bytes, count > 0, count <= maximum else { return nil }
    return String(bytes: UnsafeBufferPointer(start: bytes, count: count), encoding: .utf8)
}

private func agentIntegrationEncoded<T: Encodable>(_ value: T) -> String? {
    guard let data = try? JSONEncoder().encode(value) else { return nil }
    return String(data: data, encoding: .utf8)
}

private func agentIntegrationCopyOut(
    _ value: String,
    _ outputBytes: UnsafeMutablePointer<UInt8>?,
    _ outputCapacity: Int
) -> Int32 {
    let bytes = Array(value.utf8)
    guard let outputBytes, outputCapacity > 0 else { return Int32(bytes.count) }
    guard bytes.count <= outputCapacity else { return -1 }
    bytes.withUnsafeBytes { raw in
        guard let base = raw.baseAddress else { return }
        outputBytes.update(from: base.assumingMemoryBound(to: UInt8.self), count: bytes.count)
    }
    return Int32(bytes.count)
}

private func agentIntegrationConfig(
    present: Int32,
    bytes: UnsafePointer<UInt8>?,
    count: Int
) -> String?? {
    guard present == 0 || present == 1, count >= 0, count <= agentIntegrationMaximumConfigBytes else {
        return .none
    }
    guard present == 1 else { return .some(nil) }
    guard count == 0 || bytes != nil else { return .none }
    guard let bytes else { return .some("") }
    guard let value = String(bytes: UnsafeBufferPointer(start: bytes, count: count), encoding: .utf8) else {
        return .none
    }
    return .some(value)
}

@_cdecl("tessera_agent_integration_abi_version")
public func tesseraAgentIntegrationABIVersion() -> UInt32 { 2 }

@_cdecl("tessera_agent_integration_abi_max_config_bytes")
public func tesseraAgentIntegrationABIMaxConfigBytes() -> Int { agentIntegrationMaximumConfigBytes }

/// How many install attempts the shared policy allows. Platforms bound their
/// own retry loop with this rather than picking a number of their own.
@_cdecl("tessera_agent_integration_abi_max_install_attempts")
public func tesseraAgentIntegrationABIMaxInstallAttempts() -> Int {
    RemoteAgentLifecycleIntegrationInstaller.maximumInstallAttempts
}

@_cdecl("tessera_agent_integration_check_policy")
public func tesseraAgentIntegrationCheckPolicy(
    consecutiveFailures: UInt32,
    outputBytes: UnsafeMutablePointer<UInt8>?, outputCapacity: Int
) -> Int32 {
    let policy: [String: UInt64] = [
        "currentInstallationFreshnessMilliseconds": AgentIntegrationCheckPolicy.currentInstallationFreshnessMilliseconds,
        "otherInstallationFreshnessMilliseconds": AgentIntegrationCheckPolicy.otherInstallationFreshnessMilliseconds,
        "activityThrottleMilliseconds": AgentIntegrationCheckPolicy.activityThrottleMilliseconds,
        "warningPresentationDelayMilliseconds": AgentIntegrationCheckPolicy.warningPresentationDelayMilliseconds,
        "nextCheckDelayMilliseconds": AgentIntegrationCheckPolicy.nextCheckDelayMilliseconds(consecutiveFailures: Int(consecutiveFailures)),
    ]
    guard let encoded = agentIntegrationEncoded(policy) else { return -1 }
    return agentIntegrationCopyOut(encoded, outputBytes, outputCapacity)
}

@_cdecl("tessera_agent_integration_status_command")
public func tesseraAgentIntegrationStatusCommand(
    outputBytes: UnsafeMutablePointer<UInt8>?, outputCapacity: Int
) -> Int32 {
    agentIntegrationCopyOut(RemoteAgentLifecycleIntegrationInstaller.makeStatusCommand(requireNativeHost: true), outputBytes, outputCapacity)
}

@_cdecl("tessera_agent_integration_codex_hooks_read_command")
public func tesseraAgentIntegrationCodexHooksReadCommand(
    outputBytes: UnsafeMutablePointer<UInt8>?, outputCapacity: Int
) -> Int32 {
    agentIntegrationCopyOut(RemoteAgentLifecycleIntegrationInstaller.makeCodexHooksReadCommand(), outputBytes, outputCapacity)
}

@_cdecl("tessera_agent_integration_claude_settings_read_command")
public func tesseraAgentIntegrationClaudeSettingsReadCommand(
    outputBytes: UnsafeMutablePointer<UInt8>?, outputCapacity: Int
) -> Int32 {
    agentIntegrationCopyOut(RemoteAgentLifecycleIntegrationInstaller.makeClaudeSettingsReadCommand(), outputBytes, outputCapacity)
}

@_cdecl("tessera_agent_integration_kimi_config_read_command")
public func tesseraAgentIntegrationKimiConfigReadCommand(
    outputBytes: UnsafeMutablePointer<UInt8>?, outputCapacity: Int
) -> Int32 {
    agentIntegrationCopyOut(RemoteAgentLifecycleIntegrationInstaller.makeKimiConfigReadCommand(), outputBytes, outputCapacity)
}

@_cdecl("tessera_agent_integration_shell_status_command")
public func tesseraAgentIntegrationShellStatusCommand(
    processIDsBytes: UnsafePointer<UInt8>?, processIDsCount: Int,
    outputBytes: UnsafeMutablePointer<UInt8>?, outputCapacity: Int
) -> Int32 {
    guard let processIDsBytes, processIDsCount > 0, processIDsCount <= 4_096,
          let processIDs = try? JSONDecoder().decode([Int].self, from: Data(bytes: processIDsBytes, count: processIDsCount)),
          processIDs.count <= 128, processIDs.allSatisfy({ $0 > 1 })
    else { return -1 }
    return agentIntegrationCopyOut(
        RemoteAgentLifecycleIntegrationInstaller.makeShellStatusCommand(processIDs: Set(processIDs)),
        outputBytes,
        outputCapacity
    )
}

/// Builds a fixed process-tree discovery program after Core has validated the
/// only two permissible route scopes. The Android route adapter never receives
/// a command-string construction API of its own.
@_cdecl("tessera_agent_integration_process_discovery_command")
public func tesseraAgentIntegrationProcessDiscoveryCommand(
    scopeBytes: UnsafePointer<UInt8>?, scopeCount: Int,
    outputBytes: UnsafeMutablePointer<UInt8>?, outputCapacity: Int
) -> Int32 {
    guard let scopeBytes, scopeCount > 0, scopeCount <= 256,
          let scope = try? JSONDecoder().decode(
              AgentIntegrationProcessDiscoveryScope.self,
              from: Data(bytes: scopeBytes, count: scopeCount)
          )
    else { return -1 }
    return agentIntegrationCopyOut(
        RemoteAgentLifecycleIntegrationInstaller.makeProcessDiscoveryCommand(scope: scope),
        outputBytes,
        outputCapacity
    )
}

/// Parses raw install-probe bytes in Core so every platform gets identical
/// outdated-version bounds and last-exact-frame behavior.
@_cdecl("tessera_agent_integration_parse_status")
public func tesseraAgentIntegrationParseStatus(
    outputInputBytes: UnsafePointer<UInt8>?, outputInputCount: Int,
    outputBytes: UnsafeMutablePointer<UInt8>?, outputCapacity: Int
) -> Int32 {
    guard let output = agentIntegrationOutputString(bytes: outputInputBytes, count: outputInputCount),
          let installation = RemoteAgentLifecycleIntegrationInstaller.parseStatus(output)
    else { return -1 }
    let response: AgentIntegrationInstallationResponse
    switch installation {
    case .missing:
        response = .init(kind: .missing, version: nil)
    case .current:
        response = .init(kind: .current, version: RemoteAgentLifecycleIntegrationInstaller.integrationVersion)
    case let .outdated(version):
        // A malformed arbitrary value must not turn into a valid version fact.
        guard version == nil || (version! >= 1 && version! <= 65_535) else { return -1 }
        response = .init(kind: .outdated, version: version)
    case let .requiresAppUpdate(version):
        guard version == nil || (version! >= 1 && version! <= 65_535) else { return -1 }
        response = .init(kind: .requiresAppUpdate, version: version)
    }
    guard let encoded = agentIntegrationEncoded(response) else { return -1 }
    return agentIntegrationCopyOut(encoded, outputBytes, outputCapacity)
}

/// Classifies one install run in Core so every platform retries on exactly the
/// compare-and-swap race, and reports every other failure as the failure it is.
@_cdecl("tessera_agent_integration_classify_install_output")
public func tesseraAgentIntegrationClassifyInstallOutput(
    outputInputBytes: UnsafePointer<UInt8>?, outputInputCount: Int,
    outputBytes: UnsafeMutablePointer<UInt8>?, outputCapacity: Int
) -> Int32 {
    guard let output = agentIntegrationOutputString(bytes: outputInputBytes, count: outputInputCount)
    else { return -1 }
    let response: AgentIntegrationInstallOutcomeResponse
    switch RemoteAgentLifecycleIntegrationInstaller.classifyInstallOutput(output) {
    case .completed:
        response = .init(kind: .completed, reason: nil)
    case .configurationRace:
        response = .init(kind: .configurationRace, reason: nil)
    case let .failed(reason, _):
        response = .init(kind: .failed, reason: reason.rawValue)
    }
    guard let encoded = agentIntegrationEncoded(response) else { return -1 }
    return agentIntegrationCopyOut(encoded, outputBytes, outputCapacity)
}

@_cdecl("tessera_agent_integration_parse_shell_status")
public func tesseraAgentIntegrationParseShellStatus(
    outputInputBytes: UnsafePointer<UInt8>?, outputInputCount: Int,
    outputBytes: UnsafeMutablePointer<UInt8>?, outputCapacity: Int
) -> Int32 {
    guard let output = agentIntegrationOutputString(bytes: outputInputBytes, count: outputInputCount),
          let active = RemoteAgentLifecycleIntegrationInstaller.parseShellStatus(output),
          let encoded = agentIntegrationEncoded(["active": active])
    else { return -1 }
    return agentIntegrationCopyOut(encoded, outputBytes, outputCapacity)
}

/// Validates the provider hook wire schema and compiled hook capability in
/// Core. Exact-session conformance and process authority remain platform facts
/// checked after this typed event crosses the ABI.
@_cdecl("tessera_agent_integration_parse_lifecycle_event")
public func tesseraAgentIntegrationParseLifecycleEvent(
    inputBytes: UnsafePointer<UInt8>?, inputCount: Int,
    outputBytes: UnsafeMutablePointer<UInt8>?, outputCapacity: Int
) -> Int32 {
    guard let inputBytes, inputCount > 0, inputCount <= agentIntegrationMaximumProbeBytes,
          let event = AgentLifecycleHookEvent.decode(Data(bytes: inputBytes, count: inputCount)),
          let encoded = agentIntegrationEncoded(event)
    else { return -1 }
    return agentIntegrationCopyOut(encoded, outputBytes, outputCapacity)
}

@_cdecl("tessera_agent_integration_parse_configs")
public func tesseraAgentIntegrationParseConfigs(
    outputInputBytes: UnsafePointer<UInt8>?, outputInputCount: Int,
    outputBytes: UnsafeMutablePointer<UInt8>?, outputCapacity: Int
) -> Int32 {
    guard let output = agentIntegrationOutputString(
        bytes: outputInputBytes,
        count: outputInputCount,
        maximum: agentIntegrationMaximumConfigReadBytes
    ), let snapshots = RemoteAgentLifecycleIntegrationInstaller.parseProviderConfigSnapshots(output)
    else { return -1 }
    func response(_ snapshot: RemoteAgentLifecycleIntegrationInstaller.ProviderConfigSnapshot) -> AgentIntegrationConfigSnapshotResponse {
        switch snapshot { case .missing: return .init(present: false, contents: nil); case let .present(contents): return .init(present: true, contents: contents) }
    }
    let payload = AgentIntegrationConfigSnapshotsResponse(
        codex: response(snapshots.codex),
        claude: response(snapshots.claude),
        kimi: response(snapshots.kimi)
    )
    guard let encoded = agentIntegrationEncoded(payload) else { return -1 }
    return agentIntegrationCopyOut(encoded, outputBytes, outputCapacity)
}

/// The Core parser validates the one discovery frame, validates its root when
/// supplied, and resolves foreground shell/unsupported/provider policy.
@_cdecl("tessera_agent_integration_parse_process_discovery")
public func tesseraAgentIntegrationParseProcessDiscovery(
    scopeBytes: UnsafePointer<UInt8>?, scopeCount: Int,
    outputInputBytes: UnsafePointer<UInt8>?, outputInputCount: Int,
    outputBytes: UnsafeMutablePointer<UInt8>?, outputCapacity: Int
) -> Int32 {
    let scope: AgentIntegrationProcessDiscoveryScope?
    if scopeCount == 0 && scopeBytes == nil {
        scope = nil
    } else {
        guard let scopeBytes, scopeCount > 0, scopeCount <= 256,
              let decoded = try? JSONDecoder().decode(
                  AgentIntegrationProcessDiscoveryScope.self,
                  from: Data(bytes: scopeBytes, count: scopeCount)
              )
        else { return -1 }
        scope = decoded
    }
    guard let output = agentIntegrationOutputString(bytes: outputInputBytes, count: outputInputCount),
          let result = RemoteAgentLifecycleIntegrationInstaller.parseProcessDiscovery(output, scope: scope),
          let encoded = agentIntegrationEncoded(result)
    else { return -1 }
    return agentIntegrationCopyOut(encoded, outputBytes, outputCapacity)
}

@_cdecl("tessera_agent_integration_apply_current_shell_command")
public func tesseraAgentIntegrationApplyCurrentShellCommand(
    outputBytes: UnsafeMutablePointer<UInt8>?, outputCapacity: Int
) -> Int32 {
    agentIntegrationCopyOut(RemoteAgentLifecycleIntegrationInstaller.applyToCurrentShellCommand, outputBytes, outputCapacity)
}

@_cdecl("tessera_agent_integration_persist_apply_current_shell_command")
public func tesseraAgentIntegrationPersistApplyCurrentShellCommand(
    outputBytes: UnsafeMutablePointer<UInt8>?, outputCapacity: Int
) -> Int32 {
    agentIntegrationCopyOut(RemoteAgentLifecycleIntegrationInstaller.persistAndApplyToCurrentShellCommand, outputBytes, outputCapacity)
}

/// Builds the exact v9 install command after the shared core has safely merged
/// the three snapshots. `present == 0` means the file was absent; it is not an
/// empty file, and therefore preserves the compare-and-swap safety boundary.
@_cdecl("tessera_agent_integration_install_command")
public func tesseraAgentIntegrationInstallCommand(
    codexPresent: Int32, codexBytes: UnsafePointer<UInt8>?, codexCount: Int,
    claudePresent: Int32, claudeBytes: UnsafePointer<UInt8>?, claudeCount: Int,
    kimiPresent: Int32, kimiBytes: UnsafePointer<UInt8>?, kimiCount: Int,
    outputBytes: UnsafeMutablePointer<UInt8>?, outputCapacity: Int
) -> Int32 {
    guard let existingCodex = agentIntegrationConfig(present: codexPresent, bytes: codexBytes, count: codexCount),
          let existingClaude = agentIntegrationConfig(present: claudePresent, bytes: claudeBytes, count: claudeCount),
          let existingKimi = agentIntegrationConfig(present: kimiPresent, bytes: kimiBytes, count: kimiCount)
    else { return -1 }
    guard let mergedCodex = try? RemoteAgentLifecycleIntegrationInstaller.mergeCodexHooks(existing: existingCodex),
          let mergedClaude = try? RemoteAgentLifecycleIntegrationInstaller.mergeClaudeSettings(existing: existingClaude),
          let mergedKimi = try? RemoteAgentLifecycleIntegrationInstaller.mergeKimiConfig(existing: existingKimi)
    else { return -1 }
    return agentIntegrationCopyOut(
        RemoteAgentLifecycleIntegrationInstaller.makeInstallCommand(
            mergedCodexHooks: mergedCodex,
            expectedCodexHooks: existingCodex,
            mergedClaudeSettings: mergedClaude,
            expectedClaudeSettings: existingClaude,
            mergedKimiConfig: mergedKimi,
            expectedKimiConfig: existingKimi
        ), outputBytes, outputCapacity
    )
}

/// Reduces transport-neutral terminal observations through the same policy
/// imported directly by the Apple app. Android passes only bounded canonical
/// JSON facts and receives semantic state/actions; Kotlin never owns a second
/// integration reducer.
@_cdecl("tessera_agent_integration_resolve")
public func tesseraAgentIntegrationResolve(
    requestBytes: UnsafePointer<UInt8>?, requestCount: Int,
    outputBytes: UnsafeMutablePointer<UInt8>?, outputCapacity: Int
) -> Int32 {
    guard let requestBytes, requestCount > 0, requestCount <= 4_096,
          let request = try? JSONDecoder().decode(
              AgentIntegrationDecisionRequest.self,
              from: Data(bytes: requestBytes, count: requestCount)
          )
    else { return -1 }
    let decision = AgentIntegrationDecisionReducer.resolve(request.observation)
    let response = AgentIntegrationDecisionResponse(
        decision: decision,
        showsWarning: decision.showsWarning,
        effectiveAction: decision.effectiveAction(for: request.requestedAction)
    )
    guard let encoded = try? JSONEncoder().encode(response),
          let output = String(data: encoded, encoding: .utf8)
    else { return -1 }
    return agentIntegrationCopyOut(output, outputBytes, outputCapacity)
}

/// Registry-owned Tier-A classification. Platform code supplies only bounded
/// observed process descriptors; provider names remain compiled Core policy.
@_cdecl("tessera_agent_provider_classify")
public func tesseraAgentProviderClassify(
    bytes: UnsafePointer<UInt8>?, count: Int,
    outputBytes: UnsafeMutablePointer<UInt8>?, outputCapacity: Int
) -> Int32 {
    guard let bytes, count > 0, count <= 128 * 4_096,
          let descriptors = try? JSONDecoder().decode([AgentProcessDescriptor].self, from: Data(bytes: bytes, count: count)),
          descriptors.count <= 128,
          let encoded = try? JSONEncoder().encode(AgentProviderRegistry.builtIn.providers(matching: descriptors).map(\.rawValue)),
          let output = String(data: encoded, encoding: .utf8)
    else { return -1 }
    return agentIntegrationCopyOut(output, outputBytes, outputCapacity)
}

/// Validates a git branch name against the ONE shared launch grammar.
///
/// Public so a platform UI can pre-validate the field and show a field-level
/// message instead of an opaque `invalidLaunch` from the shared launch path.
/// The grammar is ASCII-only and bounded in UTF-8 bytes — a platform-side
/// `isLetterOrDigit`-style Unicode acceptance has already diverged from it
/// once, which is why the check lives here and not in a presenter.
///
/// Returns 1 valid, 0 invalid, -1 for invalid arguments. An empty name is
/// invalid (0), not an argument error.
@_cdecl("tessera_agent_validate_branch")
public func tesseraAgentValidateBranch(
    branchBytes: UnsafePointer<UInt8>?,
    branchCount: Int
) -> Int32 {
    if branchBytes == nil || branchCount == 0 { return 0 }
    guard branchCount > 0, branchCount <= 4_096,
          let branch = String(
              bytes: UnsafeBufferPointer(start: branchBytes!, count: branchCount),
              encoding: .utf8
          )
    else { return -1 }
    return AgentLaunchValidator.isValidBranch(branch) ? 1 : 0
}
