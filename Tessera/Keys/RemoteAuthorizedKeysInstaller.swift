import Foundation
import Citadel
import NIOCore

enum RemoteAuthorizedKeysInstaller {
    struct LedgerContext {
        let metadata: KeySecurityMetadataStore
        let keyID: UUID
        let hostID: UUID
        let hostLabel: String
        let endpoint: String
        /// Exact route authorized for this mutation. An omitted value is
        /// retained only for legacy/manual call sites; tracked revocation
        /// fails closed when it cannot prove a match.
        let routeIdentity: String?
        /// Full consent-time routing and credential semantics for sync grants.
        /// Manual installs have no cross-device capability and leave this nil.
        let authorizationSnapshot: SyncDeviceAccessGrantEngine.GrantSnapshot?
        let peerDeviceName: String?
        let direction: KeySecurityRecord.RemoteAccessDirection
        let flow: KeySecurityRecord.RemoteAccessFlow
        let publicKeyFingerprint: String?
        let authorizedKeysLine: String
        private let preserveExistingAuditFields: Bool

        init(
            metadata: KeySecurityMetadataStore = KeySecurityMetadataStore(),
            keyID: UUID,
            hostID: UUID,
            hostLabel: String,
            endpoint: String,
            routeIdentity: String? = nil,
            authorizationSnapshot: SyncDeviceAccessGrantEngine.GrantSnapshot? = nil,
            peerDeviceName: String? = nil,
            direction: KeySecurityRecord.RemoteAccessDirection = .localInstallation,
            flow: KeySecurityRecord.RemoteAccessFlow = .manual,
            publicKeyFingerprint: String? = nil,
            authorizedKeysLine: String,
            preserveExistingAuditFields: Bool = false
        ) {
            self.metadata = metadata
            self.keyID = keyID
            self.hostID = hostID
            self.hostLabel = hostLabel
            self.endpoint = endpoint
            self.routeIdentity = routeIdentity
            self.authorizationSnapshot = authorizationSnapshot
            self.peerDeviceName = peerDeviceName
            self.direction = direction
            self.flow = flow
            self.publicKeyFingerprint = publicKeyFingerprint
            self.authorizedKeysLine = authorizedKeysLine
            self.preserveExistingAuditFields = preserveExistingAuditFields
        }

        func record(_ state: KeySecurityRecord.RemoteInstallationVerificationState) {
            if preserveExistingAuditFields {
                metadata.markRemoteInstallationVerificationState(
                    state,
                    keyID: keyID,
                    hostID: hostID,
                    hostLabel: hostLabel,
                    endpoint: endpoint,
                    routeIdentity: routeIdentity,
                    publicKeyFingerprint: publicKeyFingerprint,
                    authorizedKeysLine: authorizedKeysLine
                )
                return
            }
            metadata.recordRemoteInstallation(
                keyID: keyID,
                hostID: hostID,
                hostLabel: hostLabel,
                endpoint: endpoint,
                routeIdentity: routeIdentity,
                peerDeviceName: peerDeviceName,
                direction: direction,
                flow: flow,
                verificationState: state,
                publicKeyFingerprint: publicKeyFingerprint,
                authorizedKeysLine: authorizedKeysLine
            )
        }

        func markUncertainPreservingAuditFields() {
            metadata.markRemoteInstallationUncertain(
                keyID: keyID,
                hostID: hostID,
                hostLabel: hostLabel,
                endpoint: endpoint,
                routeIdentity: routeIdentity,
                publicKeyFingerprint: publicKeyFingerprint,
                authorizedKeysLine: authorizedKeysLine
            )
        }

        func removeAfterVerifiedRevocation() {
            metadata.removeRemoteInstallation(keyID: keyID, hostID: hostID)
        }
    }

    enum InstallError: LocalizedError, Equatable, Sendable {
        case authentication(String)
        case network(String)
        case hostKeyRejected
        case selfInstall
        case targetKeyRequired
        case routeChanged
        case invalidPublicKey
        case remoteCommandFailed(stderr: String)
        case verificationFailed(stderr: String)

        var errorDescription: String? {
            switch self {
            case .authentication(let message):
                return message.isEmpty ? "Authentication failed" : message
            case .network(let message):
                let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return "Network unreachable" }
                return "Network unreachable: \(trimmed)"
            case .hostKeyRejected:
                return "Host key was not trusted. Connect once first to review it, then retry."
            case .selfInstall:
                return "This host uses this key for authentication. Choose a host identity that uses a different key or password."
            case .targetKeyRequired:
                return "This host is no longer configured to authenticate with the key being revoked."
            case .routeChanged:
                return "This host or jump route changed after authorization. Review the saved route before changing remote access."
            case .invalidPublicKey:
                return "The stored public key is malformed and cannot be revoked safely."
            case .remoteCommandFailed(let stderr):
                let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else {
                    return "Could not write to ~/.ssh/authorized_keys"
                }
                return "Could not write to ~/.ssh/authorized_keys: \(trimmed)"
            case .verificationFailed(let stderr):
                let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else {
                    return "Could not verify ~/.ssh/authorized_keys"
                }
                return "Could not verify ~/.ssh/authorized_keys: \(trimmed)"
            }
        }
    }

    private static let verificationMarker = "TESSERA_KEY_INSTALLED"
    private static let revocationMarker = "TESSERA_KEY_REMOVED"

    static func install(key: StoredKey, on host: Host) async throws {
        try await install(line: key.authorizedKeysLine, keyID: key.id, on: host)
    }

    static func install(
        line authorizedKeysLine: String,
        keyID: UUID,
        on host: Host,
        requireBiometric: Bool = false,
        isSecureEnclave: Bool = false,
        ledgerContext: LedgerContext? = nil
    ) async throws {
        DiagnosticLogStore.appendKeys(
            "install begin key=\(shortID(keyID)) host=\(shortID(host.id)) authKind=\(authKindDescription(for: host, isSecureEnclave: isSecureEnclave)) biometricRequired=\(requireBiometric)"
        )
        do {
            try validateCanInstall(keyID: keyID, on: host)
        } catch {
            DiagnosticLogStore.appendKeys("install rejected key=\(shortID(keyID)) host=\(shortID(host.id)) reason=self-install")
            throw error
        }
        try await install(
            line: authorizedKeysLine,
            on: host,
            targetKeyID: keyID,
            requireBiometric: requireBiometric,
            isSecureEnclave: isSecureEnclave,
            ledgerContext: ledgerContext
        )
    }

    /// Removes the target public key using the host's currently configured
    /// alternate credential. The target private key is never needed or sent.
    static func revoke(
        line authorizedKeysLine: String,
        keyID: UUID,
        on host: Host,
        requireBiometric: Bool = false,
        isSecureEnclave: Bool = false,
        ledgerContext: LedgerContext? = nil
    ) async throws {
        try await revoke(
            line: authorizedKeysLine,
            keyID: keyID,
            on: host,
            requireBiometric: requireBiometric,
            isSecureEnclave: isSecureEnclave,
            ledgerContext: ledgerContext,
            authenticationMode: .alternateCredential
        )
    }

    /// Explicitly authenticates with the key being revoked, then removes and
    /// verifies that same public key over the already-established SSH client.
    /// This is safe for requester-side Device Access cleanup: authentication
    /// finishes before authorized_keys changes, and no reconnect is attempted.
    static func revokeUsingTargetKey(
        line authorizedKeysLine: String,
        keyID: UUID,
        on host: Host,
        requireBiometric: Bool = false,
        isSecureEnclave: Bool = false,
        ledgerContext: LedgerContext? = nil
    ) async throws {
        try await revoke(
            line: authorizedKeysLine,
            keyID: keyID,
            on: host,
            requireBiometric: requireBiometric,
            isSecureEnclave: isSecureEnclave,
            ledgerContext: ledgerContext,
            authenticationMode: .targetKey
        )
    }

    private enum RevocationAuthenticationMode {
        case alternateCredential
        case targetKey
    }

    private static func revoke(
        line authorizedKeysLine: String,
        keyID: UUID,
        on host: Host,
        requireBiometric: Bool,
        isSecureEnclave: Bool,
        ledgerContext: LedgerContext?,
        authenticationMode: RevocationAuthenticationMode
    ) async throws {
        let tracking = ledgerContext ?? defaultLedgerContext(
            line: authorizedKeysLine,
            keyID: keyID,
            host: host
        )
        try validateRevocationAuthentication(
            authenticationMode,
            keyID: keyID,
            on: host
        )
        try validateRevocationRoute(tracking.routeIdentity, on: host)

        let chain: EstablishedSSHChain
        do {
            if await SSHAuthenticationPolicyStore.shared.hasCurrentPolicyProvider {
                await SSHAuthenticationPolicyStore.shared.registerPersistedHost(host.id)
            }
            chain = try await withPendingSSHConnectionAttempt {
                let chain = try await establishSSHChain(
                    for: host,
                    requireBiometric: requireBiometric,
                    isSecureEnclave: isSecureEnclave,
                    hostKeyPrompt: nil
                )
                // The initial UI Host is only a snapshot. The credential that
                // authenticated this socket must still match the requested
                // revocation mode after live policy resolution; nothing has
                // been written yet.
                do {
                    try validateRevocationAuthentication(
                        authenticationMode,
                        keyID: keyID,
                        on: chain.resolvedHost
                    )
                    try validateRevocationRoute(
                        tracking.routeIdentity,
                        on: chain.resolvedHost
                    )
                } catch {
                    await chain.closeAll()
                    throw error
                }
                return chain
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw classifyConnectionError(error)
        }
        let client = chain.client

        do {
            try Task.checkCancellation()
            let revokeCommand = try makeRevokeCommand(line: authorizedKeysLine)
            // This durable downgrade occurs immediately before the first
            // remote mutation. A crash after this point leaves an honest
            // uncertain placement for manual retry/review.
            tracking.markUncertainPreservingAuditFields()
            let output = try await execute(
                revokeCommand,
                on: client
            )
            await chain.closeAll()
            guard output.contains(revocationMarker) else {
                throw InstallError.verificationFailed(stderr: output)
            }
            tracking.removeAfterVerifiedRevocation()
        } catch is CancellationError {
            await chain.closeAll()
            throw CancellationError()
        } catch let error as InstallError {
            await chain.closeAll()
            throw error
        } catch {
            await chain.closeAll()
            throw InstallError.remoteCommandFailed(
                stderr: commandFailureMessage(error)
            )
        }
    }

    static func install(
        line authorizedKeysLine: String,
        on host: Host,
        targetKeyID: UUID,
        requireBiometric: Bool = false,
        isSecureEnclave: Bool = false,
        ledgerContext: LedgerContext? = nil
    ) async throws {
        let startedAt = Date()
        let tracking = ledgerContext ?? defaultLedgerContext(
            line: authorizedKeysLine,
            keyID: targetKeyID,
            host: host
        )
        try validateInstallationAuthorization(tracking, on: host)
        let chain: EstablishedSSHChain
        do {
            DiagnosticLogStore.appendKeys("install step=auth-resolve host=\(shortID(host.id))")
            if await SSHAuthenticationPolicyStore.shared.hasCurrentPolicyProvider {
                await SSHAuthenticationPolicyStore.shared.registerPersistedHost(host.id)
            }
            chain = try await withPendingSSHConnectionAttempt {
                DiagnosticLogStore.appendKeys(
                    "install step=connect host=\(shortID(host.id)) hops=\(host.jumpChain.count + 1)"
                )
                let chain = try await establishSSHChain(
                    for: host,
                    requireBiometric: requireBiometric,
                    isSecureEnclave: isSecureEnclave,
                    hostKeyPrompt: nil
                )
                do {
                    try validateCanInstall(keyID: targetKeyID, on: chain.resolvedHost)
                    try validateInstallationAuthorization(
                        tracking,
                        on: chain.resolvedHost
                    )
                } catch {
                    await chain.closeAll()
                    throw error
                }
                return chain
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            DiagnosticLogStore.appendKeys(
                "install failed step=auth-resolve host=\(shortID(host.id)) durationMs=\(durationMs(since: startedAt)) error='\(error)'"
            )
            throw classifyConnectionError(error)
        }
        let client = chain.client

        do {
            try Task.checkCancellation()
            DiagnosticLogStore.appendKeys("install step=append-key host=\(shortID(host.id))")
            tracking.record(.uncertain)
            _ = try await execute(
                makeInstallCommand(line: authorizedKeysLine),
                on: client
            )
        } catch is CancellationError {
            await chain.closeAll()
            throw CancellationError()
        } catch {
            await chain.closeAll()
            DiagnosticLogStore.appendKeys(
                "install failed step=append-key host=\(shortID(host.id)) durationMs=\(durationMs(since: startedAt)) error='\(error)'"
            )
            throw InstallError.remoteCommandFailed(
                stderr: commandFailureMessage(error)
            )
        }

        let verificationOutput: String
        do {
            try Task.checkCancellation()
            DiagnosticLogStore.appendKeys("install step=verify host=\(shortID(host.id))")
            verificationOutput = try await execute(
                makeVerifyCommand(line: authorizedKeysLine),
                on: client
            )
        } catch is CancellationError {
            await chain.closeAll()
            throw CancellationError()
        } catch {
            await chain.closeAll()
            DiagnosticLogStore.appendKeys(
                "install failed step=verify host=\(shortID(host.id)) durationMs=\(durationMs(since: startedAt)) error='\(error)'"
            )
            throw InstallError.verificationFailed(
                stderr: commandFailureMessage(error)
            )
        }

        await chain.closeAll()

        guard verificationOutput.contains(verificationMarker) else {
            DiagnosticLogStore.appendKeys(
                "install failed step=verify-marker host=\(shortID(host.id)) durationMs=\(durationMs(since: startedAt)) outputBytes=\(verificationOutput.utf8.count)"
            )
            throw InstallError.verificationFailed(stderr: verificationOutput)
        }
        tracking.record(.verified)
        DiagnosticLogStore.appendKeys(
            "install result=success host=\(shortID(host.id)) durationMs=\(durationMs(since: startedAt))"
        )
    }

    /// Idempotent install. The `{ grep || echo; }` group is load-bearing:
    /// without the braces, bash parses `A && B && C && grep || echo` as
    /// `((A && B && C && grep) || echo)` (left-to-right associativity of
    /// equal-precedence && / ||), so a failed mkdir/touch/chmod would
    /// still trigger the `echo` and append into a broken state. Grouping
    /// the idempotency check requires the prep chain first, then runs
    /// the `grep || echo` pair as a single conditional unit.
    static func makeInstallCommand(line: String) -> String {
        let quotedLine = singleQuotedShellString(line)
        return "mkdir -m 700 -p ~/.ssh && touch ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys && { grep -qxF \(quotedLine) ~/.ssh/authorized_keys || echo \(quotedLine) >> ~/.ssh/authorized_keys; }"
    }

    /// Verification command. The marker pair (`TESSERA_KEY_INSTALLED` /
    /// `TESSERA_KEY_MISSING`) is wrapped in an `if/then/else` rather
    /// than `&& A || B` so an unrelated failure of the success-branch
    /// echo cannot silently fall through to the missing-marker path.
    static func makeVerifyCommand(line: String) -> String {
        let quotedLine = singleQuotedShellString(line)
        return "if grep -qxF \(quotedLine) ~/.ssh/authorized_keys; then echo \(verificationMarker); else echo TESSERA_KEY_MISSING; fi"
    }

    /// Rewrites authorized_keys by semantic public-key identity rather than the
    /// mutable full line. Options and comments may change without changing the
    /// algorithm + SSH wire blob that authorizes access. The awk tokenizer
    /// treats whitespace inside double-quoted options as data and refuses to
    /// match an unterminated quote, so malformed remote lines are preserved.
    static func makeRevokeCommand(line: String) throws -> String {
        guard let identity = authorizedKeyIdentity(from: line) else {
            throw InstallError.invalidPublicKey
        }

        let type = singleQuotedShellString(identity.type)
        let blob = singleQuotedShellString(identity.blob)
        let removeScript = semanticKeyAWKPrelude
            + " { tessera_result=tessera_matches($0, tessera_fields); if (tessera_result!=1) print $0 }"
        let verifyScript = semanticKeyAWKPrelude
            + " { tessera_result=tessera_matches($0, tessera_fields); if (tessera_result!=0) tessera_found=1 }"
            + " END { print tessera_found ? \"TESSERA_KEY_STILL_PRESENT\" : \"\(revocationMarker)\" }"

        return "umask 077; mkdir -m 700 -p ~/.ssh && touch ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys && tmp=\"$HOME/.ssh/.authorized_keys.tessera.$$\" && awk -v tessera_type=\(type) -v tessera_blob=\(blob) '\(removeScript)' ~/.ssh/authorized_keys > \"$tmp\" && chmod 600 \"$tmp\" && mv \"$tmp\" ~/.ssh/authorized_keys && awk -v tessera_type=\(type) -v tessera_blob=\(blob) '\(verifyScript)' ~/.ssh/authorized_keys"
    }

    /// Testable mirror of the remote semantic matcher. The target is required
    /// to be a structurally valid SSH public-key line; malformed candidate
    /// lines simply do not match and are retained remotely.
    static func line(
        _ candidate: String,
        referencesSameKeyAs target: String
    ) throws -> Bool {
        guard let targetIdentity = authorizedKeyIdentity(from: target) else {
            throw InstallError.invalidPublicKey
        }
        return authorizedKeyIdentity(from: candidate) == targetIdentity
    }

    static func singleQuotedShellString(_ string: String) -> String {
        let escaped = string.replacingOccurrences(of: "'", with: "'\\''")
        return "'\(escaped)'"
    }

    private struct AuthorizedKeyIdentity: Equatable {
        let type: String
        let blob: String
    }

    /// POSIX-awk compatible tokenizer. Quotes are retained in option tokens so
    /// a key-looking string inside `command="..."` cannot become a match.
    private static let semanticKeyAWKPrelude = #"""
    function tessera_is_key_type(value) {
        return value ~ /^(ssh-|ecdsa-|sk-)[-A-Za-z0-9@._+]+$/
    }
    function tessera_token_status(fields, count) {
        if (count==1 && substr(fields[1], 1, 1)=="#") return 2
        if (count==2 && tessera_is_key_type(fields[1])) {
            return fields[1]==tessera_type && fields[2]==tessera_blob ? 1 : 2
        }
        if (count==2 && !tessera_is_key_type(fields[2])) return 2
        if (count==3 && tessera_is_key_type(fields[2])) {
            return fields[2]==tessera_type && fields[3]==tessera_blob ? 1 : 2
        }
        if (count>=3) return 2
        return 0
    }
    function tessera_matches(line, fields,    count, i, c, token, quoted, escaped, key, status) {
        for (key in fields) delete fields[key]
        count=0; token=""; quoted=0; escaped=0
        for (i=1; i<=length(line); i++) {
            c=substr(line, i, 1)
            if (escaped) { token=token c; escaped=0; continue }
            if (quoted && c=="\\") { token=token c; escaped=1; continue }
            if (c=="\"") { token=token c; quoted=!quoted; continue }
            if (!quoted && (c==" " || c=="\t" || c=="\r")) {
                if (token!="") {
                    fields[++count]=token; token=""
                    status=tessera_token_status(fields, count)
                    if (status==1) return 1
                    if (status==2) return 0
                }
            } else { token=token c }
        }
        if (quoted || escaped) {
            if (index(line, tessera_type) && index(line, tessera_blob)) return -1
            return 0
        }
        if (token!="") {
            fields[++count]=token
            status=tessera_token_status(fields, count)
            if (status==1) return 1
        }
        return 0
    }
    """#

    private static func authorizedKeyIdentity(from line: String) -> AuthorizedKeyIdentity? {
        var tokens: [String] = []
        var token = ""
        var quoted = false
        var escaped = false

        func completedIdentity() -> (complete: Bool, identity: AuthorizedKeyIdentity?) {
            if tokens.count == 1, tokens[0].hasPrefix("#") {
                return (true, nil)
            }
            if tokens.count == 2, isAuthorizedKeyType(tokens[0]) {
                let type = tokens[0]
                guard publicKeyBlob(tokens[1], declaresType: type) else {
                    return (true, nil)
                }
                return (true, AuthorizedKeyIdentity(type: type, blob: tokens[1]))
            }
            if tokens.count == 2, !isAuthorizedKeyType(tokens[1]) {
                return (true, nil)
            }
            if tokens.count == 3, isAuthorizedKeyType(tokens[1]) {
                let type = tokens[1]
                guard publicKeyBlob(tokens[2], declaresType: type) else {
                    return (true, nil)
                }
                return (true, AuthorizedKeyIdentity(type: type, blob: tokens[2]))
            }
            return (tokens.count >= 3, nil)
        }

        for character in line {
            if escaped {
                token.append(character)
                escaped = false
                continue
            }
            if quoted, character == "\\" {
                token.append(character)
                escaped = true
                continue
            }
            if character == "\"" {
                token.append(character)
                quoted.toggle()
                continue
            }
            if !quoted, character.isWhitespace {
                if !token.isEmpty {
                    tokens.append(token)
                    token.removeAll(keepingCapacity: true)
                    let result = completedIdentity()
                    if result.complete { return result.identity }
                }
            } else {
                token.append(character)
            }
        }

        guard !quoted, !escaped else { return nil }
        if !token.isEmpty {
            tokens.append(token)
            let result = completedIdentity()
            if result.complete { return result.identity }
        }
        return nil
    }

    private static func isAuthorizedKeyType(_ value: String) -> Bool {
        let prefix: String
        if value.hasPrefix("ssh-") {
            prefix = "ssh-"
        } else if value.hasPrefix("ecdsa-") {
            prefix = "ecdsa-"
        } else if value.hasPrefix("sk-") {
            prefix = "sk-"
        } else {
            return false
        }
        guard value.utf8.count > prefix.utf8.count else { return false }
        return value.utf8.allSatisfy { byte in
            (byte >= 48 && byte <= 57)
                || (byte >= 65 && byte <= 90)
                || (byte >= 97 && byte <= 122)
                || byte == 45
                || byte == 64
                || byte == 46
                || byte == 95
                || byte == 43
        }
    }

    /// Confirms the base64 is an SSH public-key wire blob whose first string is
    /// the declared algorithm. This rejects placeholders and arbitrary base64
    /// before any target-controlled value reaches the remote shell command.
    private static func publicKeyBlob(_ blob: String, declaresType type: String) -> Bool {
        guard blob.unicodeScalars.allSatisfy({
            CharacterSet.alphanumerics.contains($0)
                || "+/=".unicodeScalars.contains($0)
        }), let data = Data(base64Encoded: blob), data.count >= 4 else {
            return false
        }

        let length = data.prefix(4).reduce(0) { partial, byte in
            (partial << 8) | Int(byte)
        }
        guard length > 0, length <= data.count - 4,
              let declared = String(
                data: data.subdata(in: 4..<(4 + length)),
                encoding: .utf8
              ) else { return false }
        return declared == type
    }

    static func validateCanInstall(keyID: UUID, on host: Host) throws {
        guard host.storedKeyID != keyID else {
            throw InstallError.selfInstall
        }
    }

    static func validateCanSelfRevoke(keyID: UUID, on host: Host) throws {
        guard host.storedKeyID == keyID else {
            throw InstallError.targetKeyRequired
        }
    }

    /// Device Access revocation only needs the target private key when that is
    /// still the credential configured for this host. If the user has since
    /// switched the host to a password or another key, the ordinary revoke
    /// path must use that alternate credential instead.
    static func shouldRevokeUsingTargetKey(keyID: UUID, on host: Host) -> Bool {
        host.storedKeyID == keyID
    }

    /// A tracked remote-access mutation may only touch its exact destination
    /// and ordered jump route. Legacy records have no such proof and therefore
    /// require manual recovery.
    static func validateRevocationRoute(
        _ expectedRouteIdentity: String?,
        on host: Host
    ) throws {
        guard let expectedRouteIdentity,
              expectedRouteIdentity == RemoteAccessRouteIdentity.value(for: host)
        else {
            throw InstallError.routeChanged
        }
    }

    static func validateInstallationAuthorization(
        _ context: LedgerContext,
        on host: Host
    ) throws {
        try validateRevocationRoute(context.routeIdentity, on: host)
        guard !context.metadata.hasConflictingRemoteInstallation(
            keyID: context.keyID,
            hostID: context.hostID,
            routeIdentity: context.routeIdentity,
            publicKeyFingerprint: context.publicKeyFingerprint,
            authorizedKeysLine: context.authorizedKeysLine,
            direction: context.direction
        ) else {
            throw InstallError.routeChanged
        }
        guard context.flow == .manual
                || context.authorizationSnapshot?.matchesResolvedHost(host) == true
        else {
            throw InstallError.routeChanged
        }
    }

    private static func validateRevocationAuthentication(
        _ mode: RevocationAuthenticationMode,
        keyID: UUID,
        on host: Host
    ) throws {
        switch mode {
        case .alternateCredential:
            try validateCanInstall(keyID: keyID, on: host)
        case .targetKey:
            try validateCanSelfRevoke(keyID: keyID, on: host)
        }
    }

    private static func defaultLedgerContext(
        line: String,
        keyID: UUID,
        host: Host
    ) -> LedgerContext {
        LedgerContext(
            keyID: keyID,
            hostID: host.id,
            hostLabel: host.name.isEmpty ? "\(host.address):\(host.port)" : host.name,
            endpoint: "\(host.user)@\(host.address):\(host.port)",
            routeIdentity: RemoteAccessRouteIdentity.value(for: host),
            publicKeyFingerprint: KeyStore.canonicalFingerprint(
                forAuthorizedKeysLine: line
            ),
            authorizedKeysLine: line,
            preserveExistingAuditFields: true
        )
    }

    private static func execute(_ command: String, on client: SSHClient) async throws -> String {
        var output = try await client.executeCommand(
            command,
            maxResponseSize: 64 * 1024,
            mergeStreams: true,
            inShell: true
        )
        let bytes = output.readBytes(length: output.readableBytes) ?? []
        return String(decoding: bytes, as: UTF8.self)
    }

    private static func classifyConnectionError(_ error: Error) -> InstallError {
        // Unwrap hop-attributed failures so per-kind handling (host key,
        // auth) still applies; keep the hop label on message cases.
        if let hopError = error as? SSHChainHopError {
            let classified = classifyConnectionError(hopError.underlying)
            switch classified {
            case .authentication(let message):
                return .authentication("Jump host \(hopError.hopLabel): \(message)")
            case .network(let message):
                return .network("Jump host \(hopError.hopLabel): \(message)")
            default:
                return classified
            }
        }
        switch error {
        case let error as InstallError:
            return error

        case is HostKeyRejectedError:
            return .hostKeyRejected

        case let error as AuthResolutionError:
            return .authentication(error.errorDescription ?? "Authentication failed")

        case is AuthenticationFailed:
            return .authentication("Authentication failed")

        case let error as SSHClientError:
            switch error {
            case .unsupportedPasswordAuthentication:
                return .authentication("The server does not accept password authentication.")
            case .unsupportedPrivateKeyAuthentication:
                return .authentication("The server does not accept public-key authentication.")
            case .unsupportedHostBasedAuthentication:
                return .authentication("The server does not accept host-based authentication.")
            case .allAuthenticationOptionsFailed:
                return .authentication("Authentication failed")
            case .channelCreationFailed:
                return .network("Failed to open the SSH exec channel.")
            }

        case let error as CitadelError:
            switch error {
            case .unauthorized:
                return .authentication("Authentication failed")
            default:
                return .network(describeSSHError(error))
            }

        default:
            return .network(describeSSHError(error))
        }
    }

    private static func commandFailureMessage(_ error: Error) -> String {
        if let commandFailed = error as? SSHClient.CommandFailed {
            return "Remote command failed with exit status \(commandFailed.exitCode)."
        }
        return describeSSHError(error)
    }

    private static func shortID(_ id: UUID) -> String {
        String(id.uuidString.prefix(8))
    }

    private static func durationMs(since start: Date) -> Int {
        max(0, Int(Date().timeIntervalSince(start) * 1_000))
    }

    private static func authKindDescription(for host: Host, isSecureEnclave: Bool) -> String {
        if isSecureEnclave {
            return "secure-enclave"
        }
        if host.storedKeyID != nil {
            return "key"
        }
        if !host.password.isEmpty {
            return "password"
        }
        return "unknown"
    }
}
