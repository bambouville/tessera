import Foundation
import Citadel
import NIOCore
import TesseraSessionCore
import TmuxControl
import TmuxControlCore

struct MoshBootstrapGeometry: Equatable, Sendable {
    let sessionID: String
    let sessionCreated: Int64
    let windowID: String
    let cols: Int
    let rows: Int

    fileprivate var verificationToken: String {
        "\(sessionID),\(sessionCreated),\(windowID),\(cols),\(rows)"
    }
}

struct MoshBootstrapResult: Equatable, Sendable {
    let udpPort: Int
    let base64Key: String
    let serverPID: Int?
    /// OS family parsed from a side-channel probe run on the bootstrap
    /// SSH client right before it's closed. `nil` when the probe fails
    /// or the parser can't classify the output. Mosh sessions consume
    /// this and republish via `@Published var detectedOSHint`.
    let detectedOSHint: String?
    /// Passive configuration assessment from the same bootstrap SSH client.
    /// It never changes bootstrap success or failure semantics.
    let networkPathAssessment: NetworkPathAssessment
    /// Live destination address and topology actually used by the bootstrap
    /// SSH chain. Mosh's UDP driver and its SSH-fallback policy must use this
    /// snapshot, not the session's potentially stale construction-time Host.
    let targetAddress: String?
    let jumpChainHopCount: Int
    /// Existing tmux grid captured over the bootstrap SSH connection before
    /// mosh starts. Compact continuation clients seed and hold this virtual
    /// size so their physical viewport never mutates the shared tmux session.
    let preservedTmuxGeometry: MoshBootstrapGeometry?

    init(
        udpPort: Int,
        base64Key: String,
        serverPID: Int?,
        detectedOSHint: String?,
        networkPathAssessment: NetworkPathAssessment = .unavailable,
        targetAddress: String? = nil,
        jumpChainHopCount: Int = 0,
        preservedTmuxGeometry: MoshBootstrapGeometry? = nil
    ) {
        self.udpPort = udpPort
        self.base64Key = base64Key
        self.serverPID = serverPID
        self.detectedOSHint = detectedOSHint
        self.networkPathAssessment = networkPathAssessment
        self.targetAddress = targetAddress
        self.jumpChainHopCount = jumpChainHopCount
        self.preservedTmuxGeometry = preservedTmuxGeometry
    }
}

/// The authenticated SSH route owned by one raw-mosh session.
///
/// Mosh's terminal traffic remains UDP.  This lease exists solely so
/// session-owned features can open bounded child exec channels. Initially this
/// is the bootstrap route; `MoshSession` may renew SSH independently after a
/// network failure, validating the original route/account without restarting
/// mosh-server. It closes the lease when the UDP session or read attempt ends.
struct MoshBootstrapConnection: @unchecked Sendable {
    let result: MoshBootstrapResult
    private let chain: EstablishedSSHChain

    init(result: MoshBootstrapResult, chain: EstablishedSSHChain) {
        self.result = result
        self.chain = chain
    }

    var client: SSHClient { chain.client }
    var resolvedHost: Host { chain.resolvedHost }

    func close() async {
        await chain.closeAll()
    }
}

enum MoshBootstrapError: Error, Equatable, LocalizedError, Sendable {
    case authenticationFailed(String)
    case connectionFailed(String)
    case hostKeyRejected(hopLabel: String?)
    case missingServer
    case missingConnect
    case malformedConnect
    case remoteCommandFailed(exitCode: Int)

    var errorDescription: String? {
        switch self {
        case .authenticationFailed(let reason):
            return reason
        case .connectionFailed(let reason):
            return reason
        case .hostKeyRejected(let hopLabel):
            if let hopLabel {
                return HostKeyRejectionMessage.jumpHost(hopLabel)
            }
            return HostKeyRejectionMessage.server
        case .missingServer:
            return String(localized: "Could not start mosh: the remote host does not have `mosh-server` installed or on PATH.")
        case .missingConnect:
            return String(localized: "Could not start mosh: `mosh-server` never printed a MOSH CONNECT line.")
        case .malformedConnect:
            return String(localized: "Could not start mosh: `mosh-server` printed a malformed MOSH CONNECT line.")
        case .remoteCommandFailed(let exitCode):
            return String(localized: "Could not start mosh: the remote bootstrap command failed with exit status \(exitCode).")
        }
    }
}

extension MoshBootstrapError {
    /// Lift the portable grammar's classification onto the app's localized
    /// error. The grammar deliberately carries no transcript, so nothing to
    /// redact crosses this boundary.
    init(_ failure: MoshBootstrapGrammarFailure) {
        switch failure {
        case .missingServer:
            self = .missingServer
        case .missingConnect:
            self = .missingConnect
        case .malformedConnect:
            self = .malformedConnect
        }
    }
}

/// The single boundary for removing live mosh session credentials from text
/// before it reaches either unified logging or Tessera's diagnostic file.
///
/// Bootstrap parser errors intentionally retain no transcript at all. This
/// remains defense in depth for errors produced below Citadel and for future
/// diagnostic call sites that receive remote command output.
///
/// The patterns and their order live in
/// `TesseraSessionCore.SensitiveDataRedaction`; this is the app-facing name
/// for them. `redact` applies the mosh subset only — the same two patterns it
/// always did — because its output can still reach a user-facing failure
/// message, where the host you failed to reach is information the user is
/// entitled to. The wider `credentialAssignment` / `endpointIdentifier`
/// stages of the shared list are for sinks that keep no user-facing text.
enum SensitiveDataRedactor {
    static func redact(_ text: String) -> String {
        SensitiveDataRedaction.redactTransportDetail(text)
    }

    static func bootstrapTranscriptSummary(stdout: String, stderr: String) -> String {
        SensitiveDataRedaction.bootstrapTranscriptSummary(
            stdout: stdout,
            stderr: stderr
        )
    }
}

enum MoshBootstrap {
    typealias SessionNameResolver = (Host) -> String

    static func bootstrap(
        host: Host,
        requireBiometric: Bool = false,
        isSecureEnclave: Bool = false,
        hostKeyPrompt: HostKeyVerificationPrompt? = nil,
        preserveTmuxGeometry: Bool = false,
        visibleTmuxClientIgnoresSize: Bool = false,
        gridAuthorityDeviceID: String? = nil,
        sessionNameResolver: SessionNameResolver = HostRuntimeStateStore.sessionName(for:)
    ) async throws -> MoshBootstrapResult {
        let connection = try await bootstrapRetainingConnection(
            host: host,
            requireBiometric: requireBiometric,
            isSecureEnclave: isSecureEnclave,
            hostKeyPrompt: hostKeyPrompt,
            preserveTmuxGeometry: preserveTmuxGeometry,
            visibleTmuxClientIgnoresSize: visibleTmuxClientIgnoresSize,
            gridAuthorityDeviceID: gridAuthorityDeviceID,
            sessionNameResolver: sessionNameResolver
        )
        await connection.close()
        return connection.result
    }

    /// Variant for the raw-mosh session owner.  Unlike `bootstrap`, it hands
    /// back the bootstrap route instead of throwing it away after key
    /// exchange.  Callers must own and close the result; no other code may
    /// create a route merely to inspect an Agent Center source.
    static func bootstrapRetainingConnection(
        host: Host,
        requireBiometric: Bool = false,
        isSecureEnclave: Bool = false,
        hostKeyPrompt: HostKeyVerificationPrompt? = nil,
        preserveTmuxGeometry: Bool = false,
        visibleTmuxClientIgnoresSize: Bool = false,
        gridAuthorityDeviceID: String? = nil,
        sessionNameResolver: SessionNameResolver = HostRuntimeStateStore.sessionName(for:)
    ) async throws -> MoshBootstrapConnection {
        // The bootstrap SSH ride (and only this ride) carries the mosh key
        // exchange; it goes through the shared jump-chain establisher so a
        // bastioned host can still launch mosh-server. The subsequent UDP
        // flow is direct device→host and cannot traverse the chain — the
        // session layer detects unreachable servers and falls back.
        let chain: EstablishedSSHChain
        do {
            chain = try await establishSSHChain(
                for: host,
                requireBiometric: requireBiometric,
                isSecureEnclave: isSecureEnclave,
                hostKeyPrompt: hostKeyPrompt
            )
        } catch {
            throw classifyConnectionError(error)
        }
        let client = chain.client

        do {
            let preservedTmuxGeometry = try await preservedTmuxGeometry(
                for: host,
                enabled: preserveTmuxGeometry,
                sessionNameResolver: sessionNameResolver,
                on: client
            )
            let transcript = try await executeBootstrapCommand(
                bootstrapCommand(
                    for: host,
                    preserveTmuxGeometry: preserveTmuxGeometry,
                    preservedTmuxGeometry: preservedTmuxGeometry,
                    visibleTmuxClientIgnoresSize: visibleTmuxClientIgnoresSize,
                    gridAuthorityDeviceID: gridAuthorityDeviceID,
                    sessionNameResolver: sessionNameResolver
                ),
                on: client
            )
            // Probe the OS family before returning the bootstrap client.
            // Any error returns nil and the result simply lacks a detected
            // hint. The raw-mosh owner may retain this same authenticated
            // route for bounded child execs; it is never a new connection.
            let detection = await OSDetectionProbe.run(on: client)
            if transcriptSuggestsMissingServer(transcript) {
                throw MoshBootstrapError.missingServer
            }
            let parsed = try parseConnectResponse(
                stdout: transcript.stdout,
                stderr: transcript.stderr
            )
            return MoshBootstrapConnection(
                result: MoshBootstrapResult(
                    udpPort: parsed.udpPort,
                    base64Key: parsed.base64Key,
                    serverPID: parsed.serverPID,
                    detectedOSHint: detection?.osHint,
                    networkPathAssessment: detection?.networkPathAssessment ?? .unavailable,
                    targetAddress: chain.resolvedHost.address,
                    jumpChainHopCount: chain.resolvedHost.jumpChain.count,
                    preservedTmuxGeometry: preservedTmuxGeometry
                ),
                chain: chain
            )
        } catch let error as RemoteCommandFailure {
            await chain.closeAll()
            let transcriptSummary = SensitiveDataRedactor.bootstrapTranscriptSummary(
                stdout: error.transcript.stdout,
                stderr: error.transcript.stderr
            )
            MoshDiagnostics.log(
                "bootstrap remote-command failed exit=\(error.exitCode) transcript=\(transcriptSummary)"
            )
            if transcriptSuggestsMissingServer(error.transcript) {
                throw MoshBootstrapError.missingServer
            }
            throw MoshBootstrapError.remoteCommandFailed(
                exitCode: error.exitCode
            )
        } catch let error as BootstrapCommandFailure {
            await chain.closeAll()
            let transcriptSummary = SensitiveDataRedactor.bootstrapTranscriptSummary(
                stdout: error.transcript.stdout,
                stderr: error.transcript.stderr
            )
            MoshDiagnostics.log(
                "bootstrap command failed type=\(String(describing: type(of: error.underlying))) detail=\(SensitiveDataRedactor.redact(String(describing: error.underlying))) transcript=\(transcriptSummary)"
            )
            if transcriptSuggestsMissingServer(error.transcript) {
                throw MoshBootstrapError.missingServer
            }
            throw MoshBootstrapError.connectionFailed(
                MoshSession.userFacingStartupFailureMessage(
                    from: SensitiveDataRedactor.redact(describeSSHError(error.underlying))
                )
            )
        } catch let error as MoshBootstrapError {
            await chain.closeAll()
            throw error
        } catch {
            await chain.closeAll()
            MoshDiagnostics.log(
                "bootstrap exec-phase failed type=\(String(describing: type(of: error))) detail=\(SensitiveDataRedactor.redact(String(describing: error)))"
            )
            throw MoshBootstrapError.connectionFailed(
                MoshSession.userFacingStartupFailureMessage(
                    from: SensitiveDataRedactor.redact(describeSSHError(error))
                )
            )
        }
    }

    static func bootstrapCommand(
        for host: Host,
        preserveTmuxGeometry: Bool = false,
        preservedTmuxGeometry: MoshBootstrapGeometry? = nil,
        visibleTmuxClientIgnoresSize: Bool = false,
        gridAuthorityDeviceID: String? = nil,
        sessionNameResolver: SessionNameResolver = HostRuntimeStateStore.sessionName(for:)
    ) -> String {
        MoshBootstrapGrammar.serverNewCommand(
            launchCommand: launchCommand(
                for: host,
                preserveTmuxGeometry: preserveTmuxGeometry,
                preservedTmuxGeometry: preservedTmuxGeometry,
                visibleTmuxClientIgnoresSize: visibleTmuxClientIgnoresSize,
                gridAuthorityDeviceID: gridAuthorityDeviceID,
                sessionNameResolver: sessionNameResolver
            )
        )
    }

    static func launchCommand(
        for host: Host,
        preserveTmuxGeometry: Bool = false,
        preservedTmuxGeometry: MoshBootstrapGeometry? = nil,
        visibleTmuxClientIgnoresSize: Bool = false,
        gridAuthorityDeviceID: String? = nil,
        sessionNameResolver: SessionNameResolver = HostRuntimeStateStore.sessionName(for:)
    ) -> String? {
        let prologue = HostLaunchPrologue.inlineForArgv(
            envVars: host.envVars,
            startupSnippet: host.startupSnippet
        )

        switch host.launchMode {
        case .autoTmux:
            let inner = tmuxLaunchCommand(
                sessionName: sessionNameResolver(host),
                preserveTmuxGeometry: preserveTmuxGeometry,
                preservedTmuxGeometry: preservedTmuxGeometry,
                visibleTmuxClientIgnoresSize: visibleTmuxClientIgnoresSize,
                gridAuthorityDeviceID: gridAuthorityDeviceID
            )
            return wrap(inner: inner, prologue: prologue)

        case .pinnedTmux:
            let sessionName = resolvedTmuxSessionName(
                for: host,
                sessionNameResolver: sessionNameResolver
            ) ?? sessionNameResolver(host)
            let inner = tmuxLaunchCommand(
                sessionName: sessionName,
                preserveTmuxGeometry: preserveTmuxGeometry,
                preservedTmuxGeometry: preservedTmuxGeometry,
                visibleTmuxClientIgnoresSize: visibleTmuxClientIgnoresSize,
                gridAuthorityDeviceID: gridAuthorityDeviceID
            )
            return wrap(inner: inner, prologue: prologue)

        case .customCommand:
            let command = host.launchCommand ?? ""
            guard !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                // Fallback: no launch command, but the user asked for
                // exports / startup snippet — pass them through `sh -lc`
                // so mosh still has *something* to exec.
                guard let prologue else { return nil }
                let body = prologue + "exec $SHELL -l"
                return "sh -lc \(singleQuotedShellString(body))"
            }
            // The custom-command path was already wrapped in `sh -lc`;
            // splice the prologue inside the same single-quoted argv
            // so user exports run before the custom command.
            let body = (prologue ?? "") + command
            return "sh -lc \(singleQuotedShellString(body))"
        }
    }

    /// Wrap a tmux launch command in `sh -lc` only when there's a
    /// prologue to inject; otherwise return the bare command so
    /// `mosh-server new -- tmux ...` keeps the existing argv shape.
    private static func wrap(inner: String, prologue: String?) -> String {
        guard let prologue else { return inner }
        let body = prologue + "exec " + inner
        return "sh -lc \(singleQuotedShellString(body))"
    }

    private static func tmuxLaunchCommand(
        sessionName: String,
        preserveTmuxGeometry: Bool,
        preservedTmuxGeometry: MoshBootstrapGeometry?,
        visibleTmuxClientIgnoresSize: Bool,
        gridAuthorityDeviceID: String?
    ) -> String {
        let visibleClientOption = gridAuthorityDeviceID.map {
            TmuxController.gridAuthorityVisibleClientOption(identityID: $0)
        }
        guard preserveTmuxGeometry else {
            // Shared with Android: one builder owns the bytes both platforms
            // send, so the ignore-size gating cannot drift between them again.
            return AutoTmuxCommands.moshVisibleClientCommand(
                sessionTarget: sessionName,
                gridAuthorityDeviceID: gridAuthorityDeviceID,
                ignoresSize: visibleTmuxClientIgnoresSize
            )
        }

        // `ignore-size` does not stop the only attached tmux client from
        // defining its own view. For an existing session, wait until mosh has
        // applied the compact client's first *preserved* Resize to both its
        // terminal emulator and child PTY, then attach. Setting the child PTY
        // early with `stty` would leave mosh's emulator at its 80x24 default
        // while tmux emitted a wider first frame, permanently clipping it.
        //
        // The probe token includes stable tmux object ids and session creation
        // time. Attach by session id, not the user-facing name, and verify the
        // exact token immediately before exec. If the probed session/window
        // disappeared or changed meanwhile, fail without touching a newly
        // created or unrelated same-name session. A phone-created session has
        // no token and is created only if the name is still absent.
        // Presentation and cleanup options belong to Tessera's own view.
        // Mouse input is also enabled on the owner: full-screen programs in
        // the shared windows can consult its option before capturing input.
        let ownerTarget = singleQuotedShellString(sessionName)
        let viewTarget = singleQuotedShellString(
            AutoTmuxCommands.moshViewSessionName(for: sessionName)
        )
        let body: String
        if let geometry = preservedTmuxGeometry {
            let identityTarget = singleQuotedShellString(geometry.sessionID)
            let expected = singleQuotedShellString(geometry.verificationToken)
            let format = singleQuotedShellString(
                "#{session_id},#{session_created},#{window_id},#{window_width},#{window_height}"
            )
            let readCurrent = "tmux -u display-message -p -t \(identityTarget) \(format)"
            let verify = "current=$(\(readCurrent)) && [ \"$current\" = \(expected) ]"
            // Only change the owner if it still shares the verified view's
            // windows. The owner can be killed and its name reused while this
            // view keeps the original work alive.
            let enableOwnerMouse = AutoTmuxCommands.enableGroupedOwnerMouseCommand(
                sessionTarget: sessionName,
                viewTarget: geometry.sessionID
            )
            let waitForResize = "attempts=0; matched=0; while [ \"$attempts\" -lt 200 ]; do "
                + "attempts=$((attempts + 1)); "
                + "set -- $(stty size 2>/dev/null) || exit 76; "
                + "if [ \"$1\" = \"\(geometry.rows)\" ] && [ \"$2\" = \"\(geometry.cols)\" ]; then matched=1; break; fi; "
                + "sleep 0.05; done; "
                + "[ \"$matched\" = 1 ] || exit 77"
            let attach = "exec tmux -u attach-session $tessera_tmux_f -t \(identityTarget) "
                + "\\; set-option -F -t \(identityTarget) @tessera-size-owner '#{client_name}'"
                + AutoTmuxCommands.viewSessionOptions(
                    viewTarget: identityTarget,
                    gridAuthorityDeviceID: gridAuthorityDeviceID
                )
            // The probed session is proof a server is already up, so the
            // read-modify-write override cannot land on one that exits again
            // before the client attaches.
            body = AutoTmuxCommands.versionGatedLaunchWords(ignoresSize: true)
                + AutoTmuxCommands.truecolorOverrideOnce
                + "if tmux -u has-session -t \(identityTarget) 2>/dev/null; then "
                + verify + " && "
                + waitForResize + " && "
                + verify + " && "
                + "{ \(enableOwnerMouse); } && "
                + attach + "; "
                + "else exit 75; fi"
        } else {
            // Creating our own view leaves nothing of *ours* to preserve, but
            // the owner's windows are another matter: joining a session that
            // already exists must not resize its work to this compact client,
            // so the view is created with `ignore-size` in that case and
            // without it — free to adopt the client's grid — only when this
            // launch is what started the owner.
            let attach = "exec tmux -u new-session $tessera_tmux_f "
                + "-s \(viewTarget) -t \(ownerTarget) "
                + "\\; set-option -F -t \(viewTarget) @tessera-size-owner '#{client_name}'"
                + AutoTmuxCommands.viewSessionOptions(
                    viewTarget: viewTarget,
                    gridAuthorityDeviceID: gridAuthorityDeviceID
                )
            body = AutoTmuxCommands.versionGatedLaunchWords(ignoresSize: true)
                + "if tmux -u has-session -t \(viewTarget) 2>/dev/null; then exit 75; fi; "
                + "if tmux -u has-session -t \(ownerTarget) 2>/dev/null; then :; "
                + "else tmux -u new-session -d -s \(ownerTarget); tessera_tmux_f=''; fi; "
                + AutoTmuxCommands.enableSessionMouseCommand(sessionTarget: sessionName)
                + " || exit; "
                + AutoTmuxCommands.truecolorOverrideOnce
                + attach
        }
        return "sh -lc \(singleQuotedShellString(body))"
    }

    private static func preservedTmuxGeometry(
        for host: Host,
        enabled: Bool,
        sessionNameResolver: SessionNameResolver,
        on client: SSHClient
    ) async throws -> MoshBootstrapGeometry? {
        guard enabled else { return nil }
        guard let sessionName = resolvedTmuxSessionName(
            for: host,
            sessionNameResolver: sessionNameResolver
        ) else { return nil }

        // Probe the session this device will actually attach to — Tessera's
        // own view — not the user's session. They share windows, so the grid is
        // the same, but the identity token is the view's and the launch verifies
        // it against exactly that session id.
        let target = singleQuotedShellString(
            AutoTmuxCommands.moshViewSessionName(for: sessionName)
        )
        let format = singleQuotedShellString(
            "#{session_id},#{session_created},#{window_id},#{window_width},#{window_height}"
        )
        let transcript = try await executeBootstrapCommand(
            "printf '\\ntessera-geometry:'; "
                + "if tmux -u has-session -t \(target) 2>/dev/null; then "
                + "tmux -u display-message -p -t \(target) \(format); "
                + "else printf 'missing\\n'; fi",
            on: client
        )
        return try parsePreservedTmuxGeometryProbe(transcript.stdout)
    }

    static func parsePreservedTmuxGeometryProbe(
        _ output: String
    ) throws -> MoshBootstrapGeometry? {
        let marker = "tessera-geometry:"
        guard let markerRange = output.range(of: marker, options: .backwards) else {
            throw MoshBootstrapError.connectionFailed(
                String(
                    localized: "Could not read the existing tmux session size without changing it.",
                    comment: "mosh bootstrap could not probe an existing tmux session"
                )
            )
        }
        let suffix = output[markerRange.upperBound...]
        let payload = suffix.split(whereSeparator: \.isNewline).first?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if payload == "missing" { return nil }
        let fields = payload.split(separator: ",", omittingEmptySubsequences: false)
        guard fields.count == 5,
              fields[0].first == "$",
              fields[0].count > 1,
              fields[0].dropFirst().allSatisfy({ $0.isNumber }),
              let sessionCreated = Int64(fields[1]),
              sessionCreated > 0,
              fields[2].first == "@",
              fields[2].count > 1,
              fields[2].dropFirst().allSatisfy({ $0.isNumber }),
              let cols = Int(fields[3]),
              let rows = Int(fields[4]),
              (1...10_000).contains(cols),
              (1...10_000).contains(rows)
        else {
            throw MoshBootstrapError.connectionFailed(
                String(
                    localized: "The existing tmux session reported an invalid size.",
                    comment: "mosh bootstrap read an unusable tmux session geometry"
                )
            )
        }
        return MoshBootstrapGeometry(
            sessionID: String(fields[0]),
            sessionCreated: sessionCreated,
            windowID: String(fields[2]),
            cols: cols,
            rows: rows
        )
    }

    static func resolvedTmuxSessionName(
        for host: Host,
        sessionNameResolver: SessionNameResolver = HostRuntimeStateStore.sessionName(for:)
    ) -> String? {
        switch host.launchMode {
        case .autoTmux:
            return sessionNameResolver(host)

        case .pinnedTmux:
            let trimmed = host.tmuxSessionName?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return isShellSafeSessionName(trimmed)
                ? trimmed
                : sessionNameResolver(host)

        case .customCommand:
            return nil
        }
    }

    /// Every `MOSH CONNECT` rule — the strict literal prefix, the four-field
    /// shape, the port range, the 22-character key with optional padding, and
    /// the detached-PID banner — lives in `MoshBootstrapGrammar` so Android
    /// cannot drift from it. This only lifts the result into the app's type.
    static func parseConnectResponse(
        stdout: String,
        stderr: String = ""
    ) throws -> MoshBootstrapResult {
        do {
            let parsed = try MoshBootstrapGrammar.parseConnectResponse(
                stdout: stdout,
                stderr: stderr
            )
            return MoshBootstrapResult(
                udpPort: parsed.udpPort,
                base64Key: parsed.base64Key,
                serverPID: parsed.serverPID,
                detectedOSHint: nil
            )
        } catch let failure as MoshBootstrapGrammarFailure {
            throw MoshBootstrapError(failure)
        }
    }

    private static func classifyConnectionError(_ error: Error) -> MoshBootstrapError {
        MoshDiagnostics.log(
            "bootstrap connect-phase failed type=\(String(describing: type(of: error))) detail=\(SensitiveDataRedactor.redact(String(describing: error)))"
        )
        // Unwrap hop-attributed failures so per-kind handling (host key,
        // auth, retry classification) still applies; keep the hop label on
        // message cases.
        if let hopError = error as? SSHChainHopError {
            let classified = classifyConnectionError(hopError.underlying)
            switch classified {
            case .authenticationFailed(let message):
                return .authenticationFailed("Jump host \(hopError.hopLabel): \(message)")
            case .connectionFailed(let message):
                return .connectionFailed("Jump host \(hopError.hopLabel): \(message)")
            case .hostKeyRejected:
                return .hostKeyRejected(hopLabel: hopError.hopLabel)
            default:
                return classified
            }
        }
        switch error {
        case is HostKeyRejectedError:
            return .hostKeyRejected(hopLabel: nil)

        case let error as AuthResolutionError:
            return .authenticationFailed(
                SensitiveDataRedactor.redact(error.errorDescription ?? describeSSHError(error))
            )

        case is AuthenticationFailed:
            return .authenticationFailed(String(localized: "Authentication failed.", comment: "SSH auth failure"))

        case let error as SSHClientError:
            switch error {
            case .unsupportedPasswordAuthentication:
                return .authenticationFailed(String(localized: "The server does not accept password authentication.", comment: "SSH auth failure"))
            case .unsupportedPrivateKeyAuthentication:
                return .authenticationFailed(String(localized: "The server does not accept public-key authentication.", comment: "SSH auth failure"))
            case .unsupportedHostBasedAuthentication:
                return .authenticationFailed(String(localized: "The server does not accept host-based authentication.", comment: "SSH auth failure"))
            case .allAuthenticationOptionsFailed:
                return .authenticationFailed(String(localized: "Authentication failed.", comment: "SSH auth failure"))
            case .channelCreationFailed:
                return .connectionFailed(String(localized: "Failed to open the SSH exec channel.", comment: "SSH channel failure"))
            }

        case let error as CitadelError:
            switch error {
            case .unauthorized:
                return .authenticationFailed(String(localized: "Authentication failed.", comment: "SSH auth failure"))
            default:
                return .connectionFailed(SensitiveDataRedactor.redact(describeSSHError(error)))
            }

        default:
            return .connectionFailed(SensitiveDataRedactor.redact(describeSSHError(error)))
        }
    }

    static func isShellSafeSessionName(_ name: String) -> Bool {
        guard !name.isEmpty, name.utf8.count <= 256 else { return false }
        let allowed = CharacterSet(
            charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_."
        )
        return name.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    private static func singleQuotedShellString(_ string: String) -> String {
        MoshBootstrapGrammar.singleQuotedShellString(string)
    }

    private static func transcriptSuggestsMissingServer(
        _ transcript: CommandTranscript
    ) -> Bool {
        MoshBootstrapGrammar.transcriptSuggestsMissingServer(
            stdout: transcript.stdout,
            stderr: transcript.stderr
        )
    }

    private static func executeBootstrapCommand(
        _ command: String,
        on client: SSHClient
    ) async throws -> CommandTranscript {
        let streams = try await client.executeCommandPair(command)

        async let stdoutResult = collectBootstrapStream(streams.stdout)
        async let stderrResult = collectBootstrapStream(streams.stderr)

        let (stdout, stdoutError) = await stdoutResult
        let (stderr, stderrError) = await stderrResult
        let transcript = CommandTranscript(
            stdout: String(decoding: stdout, as: UTF8.self),
            stderr: String(decoding: stderr, as: UTF8.self)
        )

        if let error = firstBootstrapStreamError(
            stdoutError: stdoutError,
            stderrError: stderrError
        ) {
            if let error = error as? SSHClient.CommandFailed {
                throw RemoteCommandFailure(
                    exitCode: error.exitCode,
                    transcript: transcript
                )
            }
            throw BootstrapCommandFailure(
                underlying: error,
                transcript: transcript
            )
        }
        return transcript
    }

    private static func collectBootstrapStream(
        _ stream: AsyncThrowingStream<ByteBuffer, Error>
    ) async -> (Data, Error?) {
        var data = Data()
        do {
            for try await buffer in stream {
                append(buffer, to: &data)
            }
            return (data, nil)
        } catch {
            return (data, error)
        }
    }

    private static func firstBootstrapStreamError(
        stdoutError: Error?,
        stderrError: Error?
    ) -> Error? {
        if let commandFailed = stdoutError as? SSHClient.CommandFailed {
            return commandFailed
        }
        if let commandFailed = stderrError as? SSHClient.CommandFailed {
            return commandFailed
        }
        return stdoutError ?? stderrError
    }

    private static func append(_ buffer: ByteBuffer, to data: inout Data) {
        var buffer = buffer
        if let bytes = buffer.readBytes(length: buffer.readableBytes) {
            data.append(contentsOf: bytes)
        }
    }
}

private struct CommandTranscript: Equatable, Sendable {
    let stdout: String
    let stderr: String
}

private struct RemoteCommandFailure: Error {
    let exitCode: Int
    let transcript: CommandTranscript
}

private struct BootstrapCommandFailure: Error {
    let underlying: Error
    let transcript: CommandTranscript
}
