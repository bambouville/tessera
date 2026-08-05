import XCTest
import CryptoKit
import PortForwarding
@testable import TmuxControl
@testable import Tessera

#if DEBUG
final class RealHostTransportIntegrationTests: XCTestCase {
    private struct Config: Decodable {
        let stableHost: String
        let chaosHost: String
        let port: Int
        let user: String
        let password: String
        let echoPort: Int
        let localForwardPort: Int

        static func load() throws -> Self {
            guard let encoded = ProcessInfo.processInfo.environment[
                "TESSERA_REAL_HOST_CONFIG_B64"
            ],
            let data = Data(base64Encoded: encoded) else {
                throw XCTSkip(
                    "real-host fixture is opt-in; run scripts/integration/run-integration-tests.sh"
                )
            }
            return try JSONDecoder().decode(Self.self, from: data)
        }
    }

    private enum IntegrationError: Error, CustomStringConvertible {
        case timedOut(String)
        case failed(String)
        case streamEnded(String)

        var description: String {
            switch self {
            case .timedOut(let operation):
                return "timed out: \(operation)"
            case .failed(let message):
                return "session failed: \(message)"
            case .streamEnded(let operation):
                return "output stream ended: \(operation)"
            }
        }
    }

    @MainActor
    func test_liveSSHPasswordTOFUAndPTY() async throws {
        let config = try Config.load()
        await resetConnectionState(endpoint: "\(config.stableHost):\(config.port)")
        let session = SSHSession(host: makeHost(config: config, transport: .ssh))
        defer { session.disconnect() }

        let sawTOFU = try await connect(
            session: session,
            pendingRequest: { session.pendingHostKeyVerification },
            timeout: 20
        )
        XCTAssertTrue(sawTOFU, "an unknown live host must produce a TOFU request")

        let marker = "TESSERA_LIVE_SSH_PTY_OK"
        session.send(Array("printf '\(marker)\\n'\n".utf8))
        let output = try await waitForOutput(
            session.outputStream,
            containing: marker,
            timeout: 10
        )
        XCTAssertTrue(output.contains(marker))

        session.disconnect()
        let reconnect = SSHSession(host: makeHost(config: config, transport: .ssh))
        defer { reconnect.disconnect() }
        let promptedAgain = try await connect(
            session: reconnect,
            pendingRequest: { reconnect.pendingHostKeyVerification },
            timeout: 20
        )
        XCTAssertFalse(promptedAgain, "an accepted live host key must persist")
    }

    @MainActor
    func test_liveMoshPasswordTOFUAndPTY() async throws {
        let config = try Config.load()
        await resetConnectionState(endpoint: "\(config.chaosHost):\(config.port)")
        let host = makeHost(config: config, transport: .mosh, useChaosHost: true)
        let session = MoshSession(host: host)
        defer { session.disconnect() }

        let sawTOFU = try await connect(
            session: session,
            pendingRequest: { session.pendingHostKeyVerification },
            timeout: 35
        )
        XCTAssertTrue(sawTOFU, "mosh bootstrap must use the same live TOFU path")

        let marker = "TESSERA_LIVE_MOSH_PTY_OK"
        session.send(Array("printf '\(marker)\\n'\n".utf8))
        let output = try await waitForOutput(
            session.outputStream,
            containing: marker,
            timeout: 15
        )
        XCTAssertTrue(output.contains(marker))

        session.disconnect()
        let reconnect = MoshSession(host: host)
        defer { reconnect.disconnect() }
        let promptedAgain = try await connect(
            session: reconnect,
            pendingRequest: { reconnect.pendingHostKeyVerification },
            timeout: 35
        )
        XCTAssertFalse(promptedAgain, "mosh bootstrap must reuse accepted trust")
    }

    @MainActor
    func test_liveSSHInformedTOFUMismatchRequiresExplicitUnsafeOverride() async throws {
        let config = try Config.load()
        let endpoint = "\(config.stableHost):\(config.port)"
        await resetConnectionState(endpoint: endpoint)

        var host = makeHost(config: config, transport: .ssh)
        let stalePeerFingerprint = "SHA256:"
            + Data(repeating: 0, count: 32).base64EncodedString()
        host.continuationHostKeyFingerprints[host.id] = stalePeerFingerprint
        host.continuationPeerLabel = "fixture iPad"

        let rejected = SSHSession(host: host)
        rejected.connect()
        let firstRequest = try await waitForHostKeyRequest(
            { rejected.pendingHostKeyVerification },
            timeout: 20
        )
        XCTAssertEqual(firstRequest.peerFingerprint, stalePeerFingerprint)
        XCTAssertEqual(firstRequest.peerLabel, "fixture iPad")
        XCTAssertEqual(firstRequest.peerFingerprintMatches, false)
        firstRequest.reject()
        try await waitUntil("informed TOFU rejection", timeout: 10) {
            if case .failed = rejected.state { return true }
            return false
        }
        rejected.disconnect()
        let fingerprintAfterRejection = await KnownHostsStore.shared.trustedFingerprint(
            for: endpoint
        )
        XCTAssertNil(
            fingerprintAfterRejection,
            "the promoted safe action must not create a local trust pin"
        )

        let overridden = SSHSession(host: host)
        defer { overridden.disconnect() }
        overridden.connect()
        let secondRequest = try await waitForHostKeyRequest(
            { overridden.pendingHostKeyVerification },
            timeout: 20
        )
        XCTAssertEqual(secondRequest.peerFingerprintMatches, false)
        secondRequest.accept()
        try await waitUntil("explicit informed TOFU override", timeout: 20) {
            overridden.state == .connected
        }

        let trusted = await KnownHostsStore.shared.list().first {
            $0.id == endpoint
        }
        XCTAssertNotNil(trusted)
        XCTAssertNil(
            trusted?.matchedPeerLabel,
            "a mismatching peer hint must never be recorded as corroboration"
        )
    }

    @MainActor
    func test_liveSSHWrongPasswordIsClassifiedAsFailure() async throws {
        let config = try Config.load()
        let endpoint = "\(config.stableHost):\(config.port)"
        await resetConnectionState(endpoint: endpoint)
        var host = makeHost(config: config, transport: .ssh)
        host.password = config.password + "-wrong"
        let session = SSHSession(host: host)
        defer { session.disconnect() }

        session.connect()
        let message = try await waitForFailure(
            state: { session.state },
            pendingRequest: { session.pendingHostKeyVerification },
            timeout: 20
        )
        XCTAssertFalse(message.isEmpty)
        XCTAssertTrue(
            message.localizedCaseInsensitiveContains("auth")
                || message.localizedCaseInsensitiveContains("permission")
                || message.localizedCaseInsensitiveContains("credential"),
            "unexpected authentication error: \(message)"
        )
    }

    @MainActor
    func test_liveMoshWrongPasswordIsClassifiedAsFailure() async throws {
        let config = try Config.load()
        let endpoint = "\(config.chaosHost):\(config.port)"
        await resetConnectionState(endpoint: endpoint)
        var host = makeHost(config: config, transport: .mosh, useChaosHost: true)
        host.password = config.password + "-wrong"
        let session = MoshSession(host: host)
        defer { session.disconnect() }

        session.connect()
        let message = try await waitForFailure(
            state: { session.state },
            pendingRequest: { session.pendingHostKeyVerification },
            timeout: 35
        )
        XCTAssertFalse(message.isEmpty)
        XCTAssertTrue(
            message.localizedCaseInsensitiveContains("auth")
                || message.localizedCaseInsensitiveContains("permission")
                || message.localizedCaseInsensitiveContains("credential"),
            "unexpected mosh authentication error: \(message)"
        )
    }

    @MainActor
    func test_liveSSHAndMoshPreserveLargeRawInputPayload() async throws {
        let config = try Config.load()
        let payload = makeInputPayload()
        let expectedDigest = SHA256.hash(data: Data(payload))
            .map { String(format: "%02x", $0) }
            .joined()

        let ssh = SSHSession(host: makeHost(config: config, transport: .ssh))
        defer { ssh.disconnect() }
        _ = try await connect(
            session: ssh,
            pendingRequest: { ssh.pendingHostKeyVerification },
            timeout: 20
        )
        try await assertRawPayload(
            session: ssh,
            payload: payload,
            expectedDigest: expectedDigest,
            label: "ssh",
            timeout: 12
        )
        ssh.disconnect()

        let mosh = MoshSession(
            host: makeHost(config: config, transport: .mosh, useChaosHost: true)
        )
        defer { mosh.disconnect() }
        _ = try await connect(
            session: mosh,
            pendingRequest: { mosh.pendingHostKeyVerification },
            timeout: 35
        )
        try await assertRawPayload(
            session: mosh,
            payload: payload,
            expectedDigest: expectedDigest,
            label: "mosh",
            timeout: 18
        )
    }

    @MainActor
    func test_liveAgentIntegrationInstallAndRuntimeDetection() async throws {
        let config = try Config.load()
        let session = SSHSession(host: makeHost(config: config, transport: .ssh))
        defer { session.disconnect() }
        _ = try await connect(
            session: session,
            pendingRequest: { session.pendingHostKeyVerification },
            timeout: 20
        )

        let suffix = UUID().uuidString.lowercased()
        let home = "/tmp/tessera-agent-center-\(suffix)"
        let tmuxSession = "tessera-agent-\(suffix.prefix(10))"
        let quotedHome = shellQuote(home)
        let prefix = "HOME=\(quotedHome); SHELL=/bin/zsh; umask 002; export HOME SHELL; "
        let integrationVersion = RemoteAgentLifecycleIntegrationInstaller.integrationVersion
        let expectedLoadedVersions = "\(integrationVersion)|\(integrationVersion)"
        let existingCodexHooks = #"{"description":"preserve this user description","hooks":{"SessionStart":[{"matcher":"user","hooks":[{"type":"command","command":"user-session-hook"}]}],"CustomEvent":[{"hooks":[{"type":"command","command":"user-custom-hook"}]}]}}"#
        let existingClaudeSettings = #"{"theme":"dark","permissions":{"allow":["Read"]},"hooks":{"SessionStart":[{"matcher":"user","hooks":[{"type":"command","command":"user-claude-session-hook"}]}]}}"#
        _ = try await session.executeConnectedCommand(
            "rm -rf \(quotedHome); mkdir -p \(quotedHome); "
                + "mkdir -p \(quotedHome)/.codex \(quotedHome)/.claude \(quotedHome)/dotfiles; "
                + "printf '%s\\n' \(shellQuote(existingCodexHooks)) > \(quotedHome)/dotfiles/codex-hooks.json; "
                + "ln -s \(quotedHome)/dotfiles/codex-hooks.json \(quotedHome)/.codex/hooks.json; "
                + "printf '%s\\n' \(shellQuote(existingClaudeSettings)) > \(quotedHome)/dotfiles/claude-settings.json; "
                + "ln -s \(quotedHome)/dotfiles/claude-settings.json \(quotedHome)/.claude/settings.json; "
                + "printf 'existing-bash-without-newline' > \(quotedHome)/.bashrc; "
                + "printf 'existing-zsh-without-newline' > \(quotedHome)/.zshrc"
        )

        var spawnedPIDs: [Int] = []
        do {
            print("TESSERA_AGENT_LIVE_STAGE initial-install")
            try await RemoteAgentLifecycleIntegrationInstaller.install { command in
                try await session.executeConnectedCommand(prefix + command)
            }
            print("TESSERA_AGENT_LIVE_STAGE initial-probe")
            let installation = try await RemoteAgentLifecycleIntegrationInstaller.probe {
                command in
                try await session.executeConnectedCommand(prefix + command)
            }
            XCTAssertEqual(installation, .current)

            let codexMergeOutput = try await session.executeConnectedCommand(
                prefix
                    + "test -L \"$HOME/.codex/hooks.json\" && "
                    + "test \"$(readlink \"$HOME/.codex/hooks.json\")\" = \"$HOME/dotfiles/codex-hooks.json\" && "
                    + "grep -Fq 'preserve this user description' \"$HOME/.codex/hooks.json\" && "
                    + "grep -Fq 'user-session-hook' \"$HOME/.codex/hooks.json\" && "
                    + "grep -Fq 'user-custom-hook' \"$HOME/.codex/hooks.json\" && "
                    + "test \"$(grep -Fo 'codex SessionStart idle session-start' \"$HOME/.codex/hooks.json\" | wc -l | tr -d '[:space:]')\" = 1 && "
                    + "printf 'TESSERA_AGENT_CODEX_MERGE_OK\\n'"
            )
            XCTAssertTrue(
                codexMergeOutput.contains("TESSERA_AGENT_CODEX_MERGE_OK"),
                codexMergeOutput
            )
            let claudeMergeOutput = try await session.executeConnectedCommand(
                prefix
                    + "test -L \"$HOME/.claude/settings.json\" && "
                    + "test \"$(readlink \"$HOME/.claude/settings.json\")\" = \"$HOME/dotfiles/claude-settings.json\" && "
                    + "grep -Fq '\"theme\":\"dark\"' \"$HOME/.claude/settings.json\" && "
                    + "grep -Fq 'user-claude-session-hook' \"$HOME/.claude/settings.json\" && "
                    + "test \"$(grep -Fo 'claude SessionStart idle session-start' \"$HOME/.claude/settings.json\" | wc -l | tr -d '[:space:]')\" = 1 && "
                    + "printf 'TESSERA_AGENT_CLAUDE_MERGE_OK\\n'"
            )
            XCTAssertTrue(
                claudeMergeOutput.contains("TESSERA_AGENT_CLAUDE_MERGE_OK"),
                claudeMergeOutput
            )
            let legacyClaudeOutput = try await session.executeConnectedCommand(
                prefix
                    + "test -r \"$HOME/.config/tessera/claude-agent-hooks.json\" && "
                    + "grep -Fq 'claude SessionStart idle session-start' \"$HOME/.config/tessera/claude-agent-hooks.json\" && "
                    + "grep -Fq 'claude PermissionRequest waitingForInput permission' \"$HOME/.config/tessera/claude-agent-hooks.json\" && "
                    + "printf 'TESSERA_AGENT_CLAUDE_LEGACY_OK\\n'"
            )
            XCTAssertTrue(
                legacyClaudeOutput.contains("TESSERA_AGENT_CLAUDE_LEGACY_OK"),
                legacyClaudeOutput
            )

            print("TESSERA_AGENT_LIVE_STAGE generated-script-syntax")
            let syntaxOutput = try await session.executeConnectedCommand(
                prefix
                    + "/bin/sh -n \"$HOME/.config/tessera/agent-lifecycle-hook.sh\" && "
                    + "/bin/sh -n \"$HOME/.config/tessera/agent-launch.sh\" && "
                    + "/bin/sh -n \"$HOME/.config/tessera/agent-codex-readiness.sh\" && "
                    + "/bin/sh -n \"$HOME/.config/tessera/bin/claude\" && "
                    + "/bin/sh -n \"$HOME/.config/tessera/bin/codex\" && "
                    + "/bin/bash -n \"$HOME/.config/tessera/agent-lifecycle.sh\" && "
                    + "{ if command -v zsh >/dev/null 2>&1; then "
                    + "zsh -n \"$HOME/.config/tessera/agent-lifecycle.sh\"; fi; } && "
                    + "printf 'TESSERA_AGENT_SYNTAX_OK\\n'"
            )
            XCTAssertTrue(syntaxOutput.contains("TESSERA_AGENT_SYNTAX_OK"), syntaxOutput)

            print("TESSERA_AGENT_LIVE_STAGE executable-status")
            _ = try await session.executeConnectedCommand(
                prefix + "chmod 600 \"$HOME/.config/tessera/agent-launch.sh\""
            )
            let nonExecutableInstallation = try await RemoteAgentLifecycleIntegrationInstaller.probe {
                command in
                try await session.executeConnectedCommand(prefix + command)
            }
            XCTAssertEqual(nonExecutableInstallation, .missing)
            _ = try await session.executeConnectedCommand(
                prefix + "chmod 700 \"$HOME/.config/tessera/agent-launch.sh\""
            )
            let restoredInstallation = try await RemoteAgentLifecycleIntegrationInstaller.probe {
                command in
                try await session.executeConnectedCommand(prefix + command)
            }
            XCTAssertEqual(restoredInstallation, .current)

            let rcOutput = try await session.executeConnectedCommand(
                prefix
                    + "test -f \"$HOME/.zshrc\" && "
                    + "grep -qFx 'existing-bash-without-newline' \"$HOME/.bashrc\" && "
                    + "grep -qFx 'existing-zsh-without-newline' \"$HOME/.zshrc\" && "
                    + "grep -qF 'TESSERA-AGENT-LIFECYCLE' \"$HOME/.bashrc\" && "
                    + "grep -qF 'TESSERA-AGENT-LIFECYCLE' \"$HOME/.zshrc\" && "
                    + "test \"$(stat -c %a \"$HOME/.config/tessera\")\" = 700 && "
                    + "test \"$(stat -c %a \"$HOME/.config/tessera/bin\")\" = 700 && "
                    + "printf 'TESSERA_AGENT_RC_OK\\n'"
            )
            XCTAssertTrue(rcOutput.contains("TESSERA_AGENT_RC_OK"))

            // A later, unrelated startup file must not invalidate the shell
            // actually selected by $SHELL.
            _ = try await session.executeConnectedCommand(
                prefix + "printf 'unrelated-bash-config\\n' > \"$HOME/.bashrc\""
            )
            let zshStillCurrent = try await RemoteAgentLifecycleIntegrationInstaller.probe {
                command in
                try await session.executeConnectedCommand(prefix + command)
            }
            XCTAssertEqual(zshStillCurrent, .current)

            // Bash login shells do not necessarily read ~/.bashrc. A repair
            // performed with bash as the configured shell must install and
            // verify the guarded login startup line too.
            print("TESSERA_AGENT_LIVE_STAGE bash-login-install")
            let bashPrefix = "HOME=\(quotedHome); SHELL=/bin/bash; export HOME SHELL; "
            try await RemoteAgentLifecycleIntegrationInstaller.install { command in
                try await session.executeConnectedCommand(bashPrefix + command)
            }
            print("TESSERA_AGENT_LIVE_STAGE bash-login-launch")
            let bashLoginOutput = try await session.executeConnectedCommand(
                bashPrefix
                    + "/bin/bash --login -i -c "
                    + shellQuote(
                        #"printf 'TESSERA_AGENT_BASH_LOGIN=%s|%s\n' "${TESSERA_AGENT_INTEGRATION_VERSION:-}" "${TESSERA_AGENT_SHIM_VERSION:-}""#
                    )
            )
            XCTAssertTrue(
                bashLoginOutput.contains("TESSERA_AGENT_BASH_LOGIN=\(expectedLoadedVersions)")
            )

            // zsh resolves .zshrc relative to ZDOTDIR when set.
            let zdotPrefix = prefix
                + "ZDOTDIR=\"$HOME/custom-zdot\"; export ZDOTDIR; "
            print("TESSERA_AGENT_LIVE_STAGE zdot-install")
            try await RemoteAgentLifecycleIntegrationInstaller.install { command in
                try await session.executeConnectedCommand(zdotPrefix + command)
            }
            print("TESSERA_AGENT_LIVE_STAGE zdot-verify")
            let zdotOutput = try await session.executeConnectedCommand(
                zdotPrefix
                    + "if [ ! -f \"$ZDOTDIR/.zshrc\" ]; then printf 'TESSERA_AGENT_ZDOTDIR_MISSING=%s\\n' \"$ZDOTDIR/.zshrc\"; "
                    + "elif grep -qFx "
                    + shellQuote(RemoteAgentLifecycleIntegrationInstaller.rcMarkerLine)
                    + " \"$ZDOTDIR/.zshrc\"; then printf 'TESSERA_AGENT_ZDOTDIR_OK\\n'; "
                    + "else printf 'TESSERA_AGENT_ZDOTDIR_MARKER_MISSING\\n'; fi"
            )
            XCTAssertTrue(
                zdotOutput.contains("TESSERA_AGENT_ZDOTDIR_OK"),
                zdotOutput
            )

            print("TESSERA_AGENT_LIVE_STAGE inherited-child")
            let childOutput = try await session.executeConnectedCommand(
                prefix
                    + "/bin/bash --noprofile --norc -c "
                    + shellQuote(
                        #". "$HOME/.config/tessera/agent-lifecycle.sh"; exec sleep 20"#
                    )
                    + " >/dev/null 2>&1 & printf 'TESSERA_AGENT_CHILD_PID=%s\\n' \"$!\""
            )
            let childPID = try XCTUnwrap(
                integerValue(after: "TESSERA_AGENT_CHILD_PID=", in: childOutput)
            )
            spawnedPIDs.append(childPID)
            var childShellActive: Bool?
            for _ in 0..<10 where childShellActive != true {
                let childStatus = try await session.executeConnectedCommand(
                    prefix
                        + RemoteAgentLifecycleIntegrationInstaller.makeShellStatusCommand(
                            processIDs: [childPID]
                        )
                )
                childShellActive = RemoteAgentLifecycleIntegrationInstaller.parseShellStatus(
                    childStatus
                )
                if childShellActive != true {
                    try await Task.sleep(nanoseconds: 100_000_000)
                }
            }
            XCTAssertEqual(
                childShellActive,
                true,
                "a foreground child such as vim that inherited the v8 environment must stay ready"
            )

            print("TESSERA_AGENT_LIVE_STAGE stripped-path-child")
            let strippedChildOutput = try await session.executeConnectedCommand(
                prefix
                    + "/bin/bash --noprofile --norc -c "
                    + shellQuote(
                        #". "$HOME/.config/tessera/agent-lifecycle.sh"; PATH=/usr/bin:/bin; export PATH; exec sleep 20"#
                    )
                    + " >/dev/null 2>&1 & printf 'TESSERA_AGENT_STRIPPED_PID=%s\\n' \"$!\""
            )
            let strippedChildPID = try XCTUnwrap(
                integerValue(
                    after: "TESSERA_AGENT_STRIPPED_PID=",
                    in: strippedChildOutput
                )
            )
            spawnedPIDs.append(strippedChildPID)
            let strippedChildStatus = try await session.executeConnectedCommand(
                prefix
                    + RemoteAgentLifecycleIntegrationInstaller.makeShellStatusCommand(
                        processIDs: [strippedChildPID]
                    )
            )
            XCTAssertEqual(
                RemoteAgentLifecycleIntegrationInstaller.parseShellStatus(
                    strippedChildStatus
                ),
                true,
                "a foreground child remains in an activated shell even if it changes PATH: \(strippedChildStatus)"
            )

            print("TESSERA_AGENT_LIVE_STAGE nested-shell")
            // Keep a command after the nested shell so Bash cannot optimize
            // its final child into an `exec` that legitimately preserves the
            // sourced process's PID/start identity.
            let nestedBody = #". "$HOME/.config/tessera/agent-lifecycle.sh"; /bin/bash --noprofile --norc -c 'printf "%s\n" "$$" > "$HOME/nested-shell.pid"; while :; do sleep 1; done'; :"#
            _ = try await session.executeConnectedCommand(
                prefix
                    + "/bin/bash --noprofile --norc -c \(shellQuote(nestedBody)) "
                    + ">/dev/null 2>&1 & printf 'TESSERA_AGENT_NESTED_LAUNCHED\\n'"
            )
            print("TESSERA_AGENT_LIVE_STAGE nested-launched")
            var nestedPID: Int?
            for _ in 0..<10 where nestedPID == nil {
                let output = try await session.executeConnectedCommand(
                    prefix + "cat \"$HOME/nested-shell.pid\" 2>/dev/null || true"
                )
                nestedPID = Int(output.trimmingCharacters(in: .whitespacesAndNewlines))
                if nestedPID == nil { try await Task.sleep(nanoseconds: 100_000_000) }
            }
            let exactNestedPID = try XCTUnwrap(nestedPID)
            print("TESSERA_AGENT_LIVE_STAGE nested-pid")
            spawnedPIDs.append(exactNestedPID)
            let strictNestedCommand =
                RemoteAgentLifecycleIntegrationInstaller.makeShellStatusCommand(
                    processIDs: [exactNestedPID],
                    allowInheritedEnvironment: false
                )
            let strictNestedStatus = try await session.executeConnectedCommand(
                prefix
                    + "/bin/sh -c \(shellQuote(strictNestedCommand)) 2>&1 || true"
            )
            print("TESSERA_AGENT_LIVE_STAGE nested-status")
            XCTAssertEqual(
                RemoteAgentLifecycleIntegrationInstaller.parseShellStatus(strictNestedStatus),
                false,
                "an unsourced nested shell must not be ready merely because it inherited the version: \(strictNestedStatus)"
            )

            // Exercise alias shapes rather than special-casing the physical
            // device's definition. Self-references, `command`, `env`, a
            // differently named shortcut, and a helper function must all keep
            // their arguments while resolving the provider through PATH.
            print("TESSERA_AGENT_LIVE_STAGE alias-matrix")
            _ = try await session.executeConnectedCommand(
                prefix
                    + "mkdir -p \"$HOME/real-bin\"; "
                    + "mkdir -p \"$HOME/real-bin-v2\" \"$HOME/alias-bin\"; "
                    + "ln -sf /bin/echo \"$HOME/real-bin/claude\"; "
                    + "ln -sf /bin/echo \"$HOME/real-bin/codex\"; "
                    + "ln -sf /bin/echo \"$HOME/real-bin-v2/claude\"; "
                    + "ln -sf /bin/echo \"$HOME/real-bin-v2/codex\"; "
                    + "ln -sf \"$HOME/.config/tessera/bin/claude\" \"$HOME/alias-bin/claude\"; "
                    + "ln -sf \"$HOME/.config/tessera/bin/codex\" \"$HOME/alias-bin/codex\""
            )
            let aliasBody = #"PATH="$HOME/real-bin:/usr/bin:/bin"; export PATH; shopt -s expand_aliases; alias claude='claude --allow-dangerously-skip-permissions'; alias codex='codex --version --user-codex-flag'; alias clauded='claude --settings "$HOME/.config/tessera/claude-agent-hooks.json"'; . "$HOME/.config/tessera/agent-lifecycle.sh"; PATH="$HOME/alias-bin:$HOME/real-bin-v2:/usr/bin:/bin"; export PATH; alias claude > "$HOME/alias-definition"; alias clauded > "$HOME/clauded-definition"; eval 'claude --user-claude-flag' > "$HOME/alias-claude-args"; eval 'clauded --resume legacy-session' > "$HOME/alias-clauded-args"; eval 'codex --user-codex-tail' > "$HOME/alias-codex-args"; alias claude='command claude --command-prefix'; alias codex='command codex --version --command-prefix'; eval 'claude --command-tail' > "$HOME/alias-claude-command"; eval 'codex --command-tail' > "$HOME/alias-codex-command"; alias claude='env TESSERA_ALIAS_ENV=claude claude --env-prefix'; alias codex='env TESSERA_ALIAS_ENV=codex codex --version --env-prefix'; eval 'claude --env-tail' > "$HOME/alias-claude-env"; eval 'codex --env-tail' > "$HOME/alias-codex-env"; alias claude='claude --settings "$HOME/custom-claude.json" --custom-settings-prefix'; eval 'claude --custom-settings-tail' > "$HOME/alias-claude-settings"; unalias claude codex; alias tessera_claude='claude --shortcut-prefix'; eval 'tessera_claude --shortcut-tail' > "$HOME/alias-claude-shortcut"; function tessera_codex { command codex --version --function-prefix "$@"; }; tessera_codex --function-tail > "$HOME/alias-codex-function"; env HOME="$HOME/alternate-home" claude --home-change > "$HOME/alias-claude-home-change"; "$HOME/real-bin-v2/claude" --absolute-claude > "$HOME/alias-claude-absolute"; "$HOME/real-bin-v2/codex" --absolute-codex > "$HOME/alias-codex-absolute"; printf '%s|%s|%s\n' "${TESSERA_AGENT_INTEGRATION_VERSION:-}" "${TESSERA_AGENT_SHIM_VERSION:-}" "$PATH" > "$HOME/alias-shell-ready"; exec sleep 20"#
            let aliasOutput = try await session.executeConnectedCommand(
                prefix
                    + "rm -f \"$HOME/alias-shell-ready\"; "
                    + "/bin/bash --noprofile --norc -c \(shellQuote(aliasBody)) "
                    + ">/dev/null 2>&1 & tessera_alias_pid=$!; "
                    + "tessera_attempt=0; while [ ! -f \"$HOME/alias-shell-ready\" ] && [ \"$tessera_attempt\" -lt 120 ]; do tessera_attempt=$((tessera_attempt + 1)); sleep 0.05; done; "
                    + "[ -f \"$HOME/alias-shell-ready\" ] || exit 1; "
                    + "printf 'TESSERA_AGENT_ALIAS_PID=%s\\n' \"$tessera_alias_pid\""
            )
            let aliasPID = try XCTUnwrap(
                integerValue(after: "TESSERA_AGENT_ALIAS_PID=", in: aliasOutput)
            )
            spawnedPIDs.append(aliasPID)
            let aliasStatus = try await session.executeConnectedCommand(
                prefix
                    + RemoteAgentLifecycleIntegrationInstaller.makeShellStatusCommand(
                        processIDs: [aliasPID]
                    )
            )
            XCTAssertEqual(
                RemoteAgentLifecycleIntegrationInstaller.parseShellStatus(aliasStatus),
                true,
                "a preserved alias and an inherited foreground program must remain active"
            )
            let aliasDiagnostics = try await session.executeConnectedCommand(
                prefix
                    + "printf 'ALIAS='; cat \"$HOME/alias-definition\"; "
                    + "printf 'READY='; cat \"$HOME/alias-shell-ready\"; "
                    + "printf 'CLAUDE='; cat \"$HOME/alias-claude-args\"; "
                    + "printf 'CLAUDED_DEF='; cat \"$HOME/clauded-definition\"; "
                    + "printf 'CLAUDED='; cat \"$HOME/alias-clauded-args\"; "
                    + "printf 'CODEX='; cat \"$HOME/alias-codex-args\"; "
                    + "printf 'CLAUDE_COMMAND='; cat \"$HOME/alias-claude-command\"; "
                    + "printf 'CODEX_COMMAND='; cat \"$HOME/alias-codex-command\"; "
                    + "printf 'CLAUDE_ENV='; cat \"$HOME/alias-claude-env\"; "
                    + "printf 'CODEX_ENV='; cat \"$HOME/alias-codex-env\"; "
                    + "printf 'CLAUDE_SETTINGS='; cat \"$HOME/alias-claude-settings\"; "
                    + "printf 'CLAUDE_SHORTCUT='; cat \"$HOME/alias-claude-shortcut\"; "
                    + "printf 'CODEX_FUNCTION='; cat \"$HOME/alias-codex-function\"; "
                    + "printf 'CLAUDE_HOME_CHANGE='; cat \"$HOME/alias-claude-home-change\"; "
                    + "printf 'CLAUDE_ABSOLUTE='; cat \"$HOME/alias-claude-absolute\"; "
                    + "printf 'CODEX_ABSOLUTE='; cat \"$HOME/alias-codex-absolute\""
            )
            XCTAssertTrue(
                aliasDiagnostics.contains("alias claude='claude --allow-dangerously-skip-permissions'"),
                aliasDiagnostics
            )
            XCTAssertTrue(
                aliasDiagnostics.contains("READY=\(expectedLoadedVersions)|"),
                aliasDiagnostics
            )
            XCTAssertTrue(aliasDiagnostics.contains("/alias-bin:"), aliasDiagnostics)
            XCTAssertTrue(aliasDiagnostics.contains("/real-bin-v2:"), aliasDiagnostics)
            XCTAssertTrue(aliasDiagnostics.contains("--allow-dangerously-skip-permissions"), aliasDiagnostics)
            XCTAssertTrue(aliasDiagnostics.contains("--user-claude-flag"), aliasDiagnostics)
            XCTAssertTrue(aliasDiagnostics.contains("--resume legacy-session"), aliasDiagnostics)
            XCTAssertTrue(aliasDiagnostics.contains(".config/tessera/claude-agent-hooks.json"), aliasDiagnostics)
            XCTAssertTrue(aliasDiagnostics.contains("--enable hooks"), aliasDiagnostics)
            XCTAssertTrue(aliasDiagnostics.contains("--user-codex-flag"), aliasDiagnostics)
            XCTAssertTrue(aliasDiagnostics.contains("--user-codex-tail"), aliasDiagnostics)
            for argument in [
                "--command-prefix", "--command-tail", "--env-prefix", "--env-tail",
                "--shortcut-prefix", "--shortcut-tail", "--function-prefix", "--function-tail",
                "--custom-settings-prefix", "--custom-settings-tail", "--home-change",
                "--absolute-claude", "--absolute-codex",
            ] {
                XCTAssertTrue(aliasDiagnostics.contains(argument), aliasDiagnostics)
            }
            XCTAssertEqual(
                aliasDiagnostics.components(separatedBy: "--settings").count - 1,
                3,
                "both explicit user aliases must preserve exactly their own settings flag without Tessera injecting one: \(aliasDiagnostics)"
            )
            XCTAssertGreaterThanOrEqual(
                aliasDiagnostics.components(separatedBy: "--enable hooks").count - 1,
                4,
                aliasDiagnostics
            )

            // A provider-named user function has higher shell precedence.
            // Preserve it byte-for-byte while still marking the shell-level
            // integration as loaded; runtime provider hooks decide whether an
            // agent launched by that function is actually available.
            let functionOutput = try await session.executeConnectedCommand(
                prefix
                    + "/bin/bash --noprofile --norc -c "
                    + shellQuote(
                        #"function claude { printf 'USER_CLAUDE_FUNCTION=%s\n' "$*"; }; . "$HOME/.config/tessera/agent-lifecycle.sh"; claude untouched; typeset -f claude >/dev/null && printf 'TESSERA_AGENT_FUNCTION=%s|%s\n' "${TESSERA_AGENT_INTEGRATION_VERSION:-}" "${TESSERA_AGENT_SHIM_VERSION:-}""#
                    )
            )
            XCTAssertTrue(
                functionOutput.contains("USER_CLAUDE_FUNCTION=untouched")
                    && functionOutput.contains(
                        "TESSERA_AGENT_FUNCTION=\(expectedLoadedVersions)"
                    ),
                functionOutput
            )

            // Preserve the shell's exact PATH topology, including the unusual
            // but valid empty PATH whose sole empty component means cwd.
            print("TESSERA_AGENT_LIVE_STAGE empty-path")
            let emptyPathOutput = try await session.executeConnectedCommand(
                prefix
                    + "/bin/bash --noprofile --norc -c "
                    + shellQuote(
                        #"PATH=''; export PATH; . "$HOME/.config/tessera/agent-lifecycle.sh"; printf 'TESSERA_AGENT_EMPTY_PATH=%s\n' "$PATH""#
                    )
                    + " 2>/dev/null"
            )
            XCTAssertTrue(
                emptyPathOutput.contains(
                    "TESSERA_AGENT_EMPTY_PATH=\(home)/.config/tessera/bin:"
                ),
                emptyPathOutput
            )

            // zsh has different alias expansion and command hashing rules;
            // keep a live-shell proof for its self-referential and `command`
            // forms as well, since it is the default shell on Apple hosts.
            print("TESSERA_AGENT_LIVE_STAGE zsh-alias")
            let zshPath = try await session.executeConnectedCommand(
                prefix + "command -v zsh 2>/dev/null || true"
            ).trimmingCharacters(in: .whitespacesAndNewlines)
            if !zshPath.isEmpty {
                let zshAliasBody = #"PATH="$HOME/real-bin:/usr/bin:/bin"; export PATH; alias claude='claude --zsh-self'; alias codex='command codex --version --zsh-command'; . "$HOME/.config/tessera/agent-lifecycle.sh"; eval 'claude --zsh-tail' > "$HOME/zsh-alias-claude"; eval 'codex --zsh-tail' > "$HOME/zsh-alias-codex"; kill -WINCH $$; sleep 0.05; printf 'safe\n' > "$HOME/zsh-unrelated-winch"; printf '%s|%s|%s\n' "${TESSERA_AGENT_INTEGRATION_VERSION:-}" "${TESSERA_AGENT_SHIM_VERSION:-}" "$PATH" > "$HOME/zsh-alias-ready"; exec sleep 20"#
                let zshAliasOutput = try await session.executeConnectedCommand(
                    prefix
                        + "rm -f \"$HOME/zsh-alias-ready\"; "
                        + "\(shellQuote(zshPath)) -f -c \(shellQuote(zshAliasBody)) "
                        + ">/dev/null 2>&1 & tessera_zsh_alias_pid=$!; "
                        + "tessera_attempt=0; while [ ! -f \"$HOME/zsh-alias-ready\" ] && [ \"$tessera_attempt\" -lt 80 ]; do tessera_attempt=$((tessera_attempt + 1)); sleep 0.05; done; "
                        + "[ -f \"$HOME/zsh-alias-ready\" ] || exit 1; "
                        + "printf 'TESSERA_AGENT_ZSH_ALIAS_PID=%s\\n' \"$tessera_zsh_alias_pid\""
                )
                let zshAliasPID = try XCTUnwrap(
                    integerValue(after: "TESSERA_AGENT_ZSH_ALIAS_PID=", in: zshAliasOutput)
                )
                spawnedPIDs.append(zshAliasPID)
                let zshAliasStatus = try await session.executeConnectedCommand(
                    prefix
                        + RemoteAgentLifecycleIntegrationInstaller.makeShellStatusCommand(
                            processIDs: [zshAliasPID]
                        )
                )
                XCTAssertEqual(
                    RemoteAgentLifecycleIntegrationInstaller.parseShellStatus(zshAliasStatus),
                    true,
                    zshAliasStatus
                )
                let zshAliasDiagnostics = try await session.executeConnectedCommand(
                    prefix
                        + "printf 'READY='; cat \"$HOME/zsh-alias-ready\"; "
                        + "printf 'CLAUDE='; cat \"$HOME/zsh-alias-claude\"; "
                        + "printf 'CODEX='; cat \"$HOME/zsh-alias-codex\"; "
                        + "printf 'WINCH='; cat \"$HOME/zsh-unrelated-winch\""
                )
                XCTAssertTrue(
                    zshAliasDiagnostics.contains("READY=\(expectedLoadedVersions)|"),
                    zshAliasDiagnostics
                )
                XCTAssertTrue(zshAliasDiagnostics.contains("--zsh-self"), zshAliasDiagnostics)
                XCTAssertTrue(zshAliasDiagnostics.contains("--zsh-command"), zshAliasDiagnostics)
                XCTAssertTrue(zshAliasDiagnostics.contains("--zsh-tail"), zshAliasDiagnostics)
                XCTAssertTrue(zshAliasDiagnostics.contains("WINCH=safe"), zshAliasDiagnostics)
                XCTAssertFalse(zshAliasDiagnostics.contains("--settings"), zshAliasDiagnostics)
                XCTAssertTrue(zshAliasDiagnostics.contains("--enable hooks"), zshAliasDiagnostics)
            }

            // A user-owned compound WINCH trap remains byte-for-byte in
            // control. Activation uses process identity and therefore neither
            // replaces the trap nor leaves this otherwise valid shell inactive.
            print("TESSERA_AGENT_LIVE_STAGE compound-winch-trap")
            let compoundTrapBody = #"trap 'printf "user-winch\n" >> "$HOME/compound-winch-fired"; :' WINCH; . "$HOME/.config/tessera/agent-lifecycle.sh"; trap -p WINCH > "$HOME/compound-winch-definition"; printf '%s\n' "$$" > "$HOME/compound-winch-pid"; while :; do sleep 1; done"#
            let compoundTrapLaunch = try await session.executeConnectedCommand(
                prefix
                    + "rm -f \"$HOME/compound-winch-fired\" \"$HOME/compound-winch-pid\"; "
                    + "/bin/bash --noprofile --norc -c \(shellQuote(compoundTrapBody)) "
                    + ">\"$HOME/compound-winch-launch.log\" 2>&1 & "
                    + "tessera_attempt=0; while [ ! -f \"$HOME/compound-winch-pid\" ] && [ \"$tessera_attempt\" -lt 40 ]; do tessera_attempt=$((tessera_attempt + 1)); sleep 0.05; done; "
                    + "if [ -f \"$HOME/compound-winch-pid\" ]; then printf 'TESSERA_AGENT_COMPOUND_TRAP_READY\\n'; "
                    + "else printf 'TESSERA_AGENT_COMPOUND_TRAP_MISSING\\n'; cat \"$HOME/compound-winch-launch.log\" 2>/dev/null || true; fi"
            )
            XCTAssertTrue(
                compoundTrapLaunch.contains("TESSERA_AGENT_COMPOUND_TRAP_READY"),
                compoundTrapLaunch
            )
            let compoundTrapPIDOutput = try await session.executeConnectedCommand(
                prefix + "cat \"$HOME/compound-winch-pid\""
            )
            let compoundTrapPID = try XCTUnwrap(
                Int(compoundTrapPIDOutput.trimmingCharacters(in: .whitespacesAndNewlines))
            )
            spawnedPIDs.append(compoundTrapPID)
            let compoundTrapStatus = try await session.executeConnectedCommand(
                prefix
                    + RemoteAgentLifecycleIntegrationInstaller.makeShellStatusCommand(
                        processIDs: [compoundTrapPID],
                        allowInheritedEnvironment: false
                    )
            )
            XCTAssertEqual(
                RemoteAgentLifecycleIntegrationInstaller.parseShellStatus(compoundTrapStatus),
                true,
                compoundTrapStatus
            )
            let compoundTrapDiagnostics = try await session.executeConnectedCommand(
                prefix
                    + "kill -WINCH \(compoundTrapPID); "
                    + "tessera_attempt=0; while [ ! -s \"$HOME/compound-winch-fired\" ] && [ \"$tessera_attempt\" -lt 40 ]; do tessera_attempt=$((tessera_attempt + 1)); sleep 0.05; done; "
                    + "printf 'TRAP='; cat \"$HOME/compound-winch-definition\"; "
                    + "printf 'FIRED='; cat \"$HOME/compound-winch-fired\" 2>/dev/null || true"
            )
            XCTAssertTrue(
                compoundTrapDiagnostics.contains("user-winch")
                    && compoundTrapDiagnostics.contains("FIRED=user-winch"),
                compoundTrapDiagnostics
            )

            // `exec` preserves PID/start time and the exported activation/PATH.
            // The replacement shell is therefore still integrated even though
            // it did not source an rc file of its own.
            print("TESSERA_AGENT_LIVE_STAGE exec-shell")
            let execShellBody = #". "$HOME/.config/tessera/agent-lifecycle.sh"; exec /bin/bash --noprofile --norc -c ': > "$HOME/exec-shell-ready"; while :; do sleep 1; done'"#
            let execShellOutput = try await session.executeConnectedCommand(
                prefix
                    + "rm -f \"$HOME/exec-shell-ready\"; "
                    + "/bin/bash --noprofile --norc -c \(shellQuote(execShellBody)) "
                    + ">/dev/null 2>&1 & tessera_exec_pid=$!; "
                    + "tessera_attempt=0; while [ ! -f \"$HOME/exec-shell-ready\" ] && [ \"$tessera_attempt\" -lt 20 ]; do tessera_attempt=$((tessera_attempt + 1)); sleep 0.05; done; "
                    + "[ -f \"$HOME/exec-shell-ready\" ] || exit 1; "
                    + "printf 'TESSERA_AGENT_EXEC_PID=%s\\n' \"$tessera_exec_pid\""
            )
            let execShellPID = try XCTUnwrap(
                integerValue(after: "TESSERA_AGENT_EXEC_PID=", in: execShellOutput)
            )
            spawnedPIDs.append(execShellPID)
            let execShellStatus = try await session.executeConnectedCommand(
                prefix
                    + RemoteAgentLifecycleIntegrationInstaller.makeShellStatusCommand(
                        processIDs: [execShellPID],
                        allowInheritedEnvironment: false
                    )
            )
            XCTAssertEqual(
                RemoteAgentLifecycleIntegrationInstaller.parseShellStatus(execShellStatus),
                true,
                "an exec-replaced shell must retain inherited activation"
            )

            // tmux servers outlive this exec channel and therefore retain
            // their original HOME. Pass the isolated fixture home into the
            // pane explicitly instead of relying on update-environment.
            print("TESSERA_AGENT_LIVE_STAGE tmux-marker")
            let tmuxCommand = "env HOME=\(quotedHome) SHELL=/bin/zsh "
                + "/bin/bash --noprofile --norc"
            _ = try await session.executeConnectedCommand(
                prefix
                    + "tmux new-session -d -s \(tmuxSession) \(tmuxCommand); "
                    + "tmux send-keys -t \(tmuxSession):0.0 "
                    + shellQuote(#". "$HOME/.config/tessera/agent-lifecycle.sh"; trap -p WINCH > "$HOME/tmux-winch-trap"; printf '%s\n' "$$" > "$HOME/tmux-shell-pid""#)
                    + " Enter; "
                    + "sleep 1"
            )
            let tmuxOutput = try await session.executeConnectedCommand(
                prefix
                    + "tmux display-message -p -t \(tmuxSession):0.0 "
                    + shellQuote("#{pane_pid}|#{pane_current_command}|#{@tessera_agent_shell}")
            )
            let tmuxFields = try XCTUnwrap(tmuxOutput
                .split(whereSeparator: \.isNewline)
                .last?
                .split(separator: "|", omittingEmptySubsequences: false))
            guard tmuxFields.count == 3 else {
                throw IntegrationError.failed("invalid tmux integration probe: \(tmuxOutput)")
            }
            XCTAssertEqual(String(tmuxFields[1]), "bash")
            let panePID = try XCTUnwrap(Int(tmuxFields[0]))
            let markerFields = tmuxFields[2].split(
                separator: ":",
                omittingEmptySubsequences: false
            )
            XCTAssertEqual(markerFields.count, 3)
            XCTAssertEqual(
                markerFields.first.flatMap { Int($0) },
                RemoteAgentLifecycleIntegrationInstaller.integrationVersion
            )
            XCTAssertEqual(markerFields.dropFirst().first.flatMap { Int($0) }, panePID)
            XCTAssertEqual(
                markerFields.last.flatMap { Int($0) },
                RemoteAgentLifecycleIntegrationInstaller.integrationVersion
            )
            let tmuxStatus = try await session.executeConnectedCommand(
                prefix
                    + RemoteAgentLifecycleIntegrationInstaller.makeShellStatusCommand(
                        processIDs: [panePID]
                    )
            )
            let tmuxProbeDiagnostics = try await session.executeConnectedCommand(
                prefix
                    + "printf 'PANE=%s SHELL=' \(shellQuote(String(panePID))); "
                    + "cat \"$HOME/tmux-shell-pid\" 2>/dev/null || true; "
                    + "printf ' TRAP='; cat \"$HOME/tmux-winch-trap\" 2>/dev/null || true; "
                    + "printf ' MARKER='; cat \"$HOME/.config/tessera/active-shells/\(panePID)\" 2>/dev/null || true"
            )
            XCTAssertEqual(
                RemoteAgentLifecycleIntegrationInstaller.parseShellStatus(tmuxStatus),
                true,
                "\(tmuxStatus) \(tmuxProbeDiagnostics)"
            )

            print("TESSERA_AGENT_LIVE_STAGE concurrent-shell-probes")
            let concurrentProbe =
                RemoteAgentLifecycleIntegrationInstaller.makeShellStatusCommand(
                    processIDs: [panePID],
                    allowInheritedEnvironment: false
                )
            let concurrentOutput = try await session.executeConnectedCommand(
                prefix
                    + "rm -f \"$HOME\"/concurrent-probe.*; tessera_probe="
                    + shellQuote(concurrentProbe)
                    + "; tessera_index=1; while [ \"$tessera_index\" -le 8 ]; do "
                    + "/bin/sh -c \"$tessera_probe\" > \"$HOME/concurrent-probe.$tessera_index\" & "
                    + "tessera_index=$((tessera_index + 1)); done; wait; "
                    + "tessera_passed=$(grep -l '^TESSERA_AGENT_SHELL_STATUS active$' \"$HOME\"/concurrent-probe.* 2>/dev/null | wc -l | tr -d '[:space:]'); "
                    + "printf 'TESSERA_AGENT_CONCURRENT=%s\\n' \"$tessera_passed\""
            )
            XCTAssertTrue(
                concurrentOutput.contains("TESSERA_AGENT_CONCURRENT=8"),
                concurrentOutput
            )

            // The launcher alone must never publish availability: hooks may
            // be disabled or untrusted. Then exercise a provider-owned
            // SessionStart and verify its ancestor PID survives the launcher's
            // exec boundary.
            print("TESSERA_AGENT_LIVE_STAGE production-launcher-no-false-ready")
            _ = try await session.executeConnectedCommand(
                prefix
                    + "tmux set-option -pu -t \(tmuxSession):0.0 @tessera_agent_state >/dev/null 2>&1 || true; "
                    + "tmux respawn-pane -k -t \(tmuxSession):0.0 "
                    + shellQuote(
                        "env HOME=\(quotedHome) \(quotedHome)/.config/tessera/agent-launch.sh codex /bin/sleep 2"
                    )
                    + "; sleep 0.2"
            )
            let launcherOnlyState = try await session.executeConnectedCommand(
                prefix
                    + "tmux show-options -pv -t \(tmuxSession):0.0 @tessera_agent_state 2>/dev/null || true"
            )
            XCTAssertTrue(
                launcherOnlyState.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                launcherOnlyState
            )

            print("TESSERA_AGENT_LIVE_STAGE production-launcher-provider-hook")
            let launchedProviderBody = #"printf '%s\n' "$$" > "$HOME/launcher-provider.pid"; printf '%s' '{"session_id":"launcher-session"}' | "$HOME/.config/tessera/agent-lifecycle-hook.sh" codex SessionStart idle session-start; exec sleep 20"#
            let launchedProviderCommand = "env HOME=\(quotedHome) SHELL=/bin/zsh "
                + "\(quotedHome)/.config/tessera/agent-launch.sh codex "
                + "\(quotedHome)/provider-bin/codex -c \(shellQuote(launchedProviderBody))"
            _ = try await session.executeConnectedCommand(
                prefix
                    + "rm -f \"$HOME/launcher-provider.pid\"; mkdir -p \"$HOME/provider-bin\"; "
                    + "ln -sf /bin/sh \"$HOME/provider-bin/codex\"; "
                    + "tmux respawn-pane -k -t \(tmuxSession):0.0 "
                    + shellQuote(launchedProviderCommand)
                    + "; sleep 1"
            )
            let launcherOutput = try await session.executeConnectedCommand(
                prefix
                    + "printf 'PID='; cat \"$HOME/launcher-provider.pid\"; "
                    + "printf 'STATE='; tmux display-message -p -t \(tmuxSession):0.0 "
                    + shellQuote("#{@tessera_agent_state}")
            )
            let launchedPID = try XCTUnwrap(
                integerValue(after: "PID=", in: launcherOutput)
            )
            let launcherJSON = try XCTUnwrap(
                launcherOutput.split(separator: "\n")
                    .first(where: { $0.hasPrefix("STATE=") })
                    .map { String($0.dropFirst("STATE=".count)) }
            )
            let launcherEvent = try XCTUnwrap(
                AgentLifecycleEvent.decode(json: launcherJSON)
            )
            XCTAssertEqual(launcherEvent.provider, "codex")
            XCTAssertEqual(launcherEvent.event, "SessionStart")
            XCTAssertEqual(launcherEvent.state, .idle)
            XCTAssertEqual(launcherEvent.providerSessionID, "launcher-session")
            XCTAssertEqual(launcherEvent.agentPID, launchedPID)

            // Execute the installed production hook under an actual
            // provider-named ancestor. This covers JSON stdin parsing,
            // provider PID binding, and tmux retained-state publication rather
            // than only comparing the generated shell source as a string.
            print("TESSERA_AGENT_LIVE_STAGE production-hook")
            let fakeAgentBody = #"printf '%s' '{"session_id":"fixture-session","turn_id":"fixture-turn"}' | "$HOME/.config/tessera/agent-lifecycle-hook.sh" codex UserPromptSubmit working agent-turn; exec sleep 20"#
            let fakeAgentCommand = "env HOME=\(quotedHome) SHELL=/bin/zsh "
                + "\(quotedHome)/codex -c \(shellQuote(fakeAgentBody))"
            _ = try await session.executeConnectedCommand(
                prefix
                    + "ln -sf /bin/sh \"$HOME/codex\"; "
                    + "tmux respawn-pane -k -t \(tmuxSession):0.0 "
                    + shellQuote(fakeAgentCommand)
                    + "; sleep 1"
            )
            let lifecycleOutput = try await session.executeConnectedCommand(
                prefix
                    + "tmux display-message -p -t \(tmuxSession):0.0 "
                    + shellQuote("#{@tessera_agent_state}")
            )
            let lifecycleJSON = lifecycleOutput
                .split(whereSeparator: \.isNewline)
                .last
                .map(String.init) ?? ""
            let lifecycleEvent = try XCTUnwrap(AgentLifecycleEvent.decode(json: lifecycleJSON))
            XCTAssertEqual(lifecycleEvent.provider, "codex")
            XCTAssertEqual(lifecycleEvent.event, "UserPromptSubmit")
            XCTAssertEqual(lifecycleEvent.state, .working)
            XCTAssertEqual(lifecycleEvent.providerSessionID, "fixture-session")
            XCTAssertEqual(lifecycleEvent.turnID, "fixture-turn")
            XCTAssertNotNil(lifecycleEvent.agentPID)

            // Exercise the fallback metadata parser rather than assuming
            // Python exists. Neither a child Stop nor its later SubagentStop
            // boundary may overwrite the root Stop/idle pane state, and a new
            // root boundary must clear stale markers.
            print("TESSERA_AGENT_LIVE_STAGE pythonless-hook")
            let minimalBin = "\(quotedHome)/minimal-bin"
            let toolNames = [
                "base64", "cat", "chmod", "date", "dd", "find", "grep", "head",
                "mkdir", "ps", "rm", "sed", "sleep", "tmux", "tr", "tty",
            ].joined(separator: " ")
            _ = try await session.executeConnectedCommand(
                prefix
                    + "mkdir -p \(minimalBin); for tessera_tool in \(toolNames); do "
                    + "tessera_path=$(command -v \"$tessera_tool\" 2>/dev/null || true); "
                    + "[ -n \"$tessera_path\" ] && ln -sf \"$tessera_path\" \(minimalBin)/\"$tessera_tool\"; done; "
                    + "ln -sf /bin/sh \"$HOME/claude\""
            )
            let pythonlessBody = #"hook="$HOME/.config/tessera/agent-lifecycle-hook.sh"; printf '%s' '{"session_id":"root-session"}' | "$hook" claude UserPromptSubmit working agent-turn; printf '%s' '{"session_id":"root-session","agent_id":"child-1"}' | env PATH="$HOME/minimal-bin" "$hook" claude SubagentStart working subagent-start; printf '%s' '{"session_id":"root-session","agent_id":"child-1"}' | env PATH="$HOME/minimal-bin" "$hook" claude Stop idle turn-stopped; printf '%s' '{"session_id":"root-session"}' | "$hook" claude Stop idle turn-stopped; printf '%s' '{"session_id":"root-session","agent_id":"child-1"}' | env PATH="$HOME/minimal-bin" "$hook" claude SubagentStop working subagent-stop; exec sleep 20"#
            let pythonlessCommand = "env HOME=\(quotedHome) SHELL=/bin/zsh "
                + "\(quotedHome)/claude -c \(shellQuote(pythonlessBody))"
            _ = try await session.executeConnectedCommand(
                prefix
                    + "tmux respawn-pane -k -t \(tmuxSession):0.0 "
                    + shellQuote(pythonlessCommand)
                    + "; sleep 1"
            )
            let pythonlessOutput = try await session.executeConnectedCommand(
                prefix
                    + "tmux display-message -p -t \(tmuxSession):0.0 "
                    + shellQuote("#{@tessera_agent_state}")
            )
            let pythonlessJSON = pythonlessOutput
                .split(whereSeparator: \.isNewline)
                .last
                .map(String.init) ?? ""
            let pythonlessEvent = try XCTUnwrap(
                AgentLifecycleEvent.decode(json: pythonlessJSON)
            )
            XCTAssertEqual(pythonlessEvent.event, "Stop")
            XCTAssertEqual(pythonlessEvent.state, .idle)

            let cleanupBody = #"hook="$HOME/.config/tessera/agent-lifecycle-hook.sh"; printf '%s' '{"session_id":"cleanup-session","agent_id":"child-2"}' | env PATH="$HOME/minimal-bin" "$hook" claude SubagentStart working subagent-start; printf '%s' '{"session_id":"cleanup-session"}' | env PATH="$HOME/minimal-bin" "$hook" claude SessionStart idle session-start; if find "$HOME/.config/tessera/active-subagents/$$" -type f -print -quit 2>/dev/null | grep -q .; then printf '%s' '{"session_id":"cleanup-session"}' | "$hook" claude StopFailure unavailable cleanup-failed; else printf '%s' '{"session_id":"cleanup-session"}' | "$hook" claude UserPromptSubmit working cleanup-passed; fi; exec sleep 20"#
            let cleanupCommand = "env HOME=\(quotedHome) SHELL=/bin/zsh "
                + "\(quotedHome)/claude -c \(shellQuote(cleanupBody))"
            _ = try await session.executeConnectedCommand(
                prefix
                    + "tmux respawn-pane -k -t \(tmuxSession):0.0 "
                    + shellQuote(cleanupCommand)
                    + "; sleep 1"
            )
            let cleanupOutput = try await session.executeConnectedCommand(
                prefix
                    + "tmux display-message -p -t \(tmuxSession):0.0 "
                    + shellQuote("#{@tessera_agent_state}")
            )
            let cleanupJSON = cleanupOutput
                .split(whereSeparator: \.isNewline)
                .last
                .map(String.init) ?? ""
            let cleanupEvent = try XCTUnwrap(AgentLifecycleEvent.decode(json: cleanupJSON))
            XCTAssertEqual(cleanupEvent.event, "UserPromptSubmit")
            XCTAssertEqual(cleanupEvent.reason, "cleanup-passed")

            _ = try? await session.executeConnectedCommand(
                "for tessera_pid in \(spawnedPIDs.map(String.init).joined(separator: " ")); do kill \"$tessera_pid\" >/dev/null 2>&1 || true; done; "
                    + "tmux kill-session -t \(tmuxSession) >/dev/null 2>&1 || true; "
                    + "rm -rf \(quotedHome)"
            )
        } catch {
            _ = try? await session.executeConnectedCommand(
                "for tessera_pid in \(spawnedPIDs.map(String.init).joined(separator: " ")); do kill \"$tessera_pid\" >/dev/null 2>&1 || true; done; "
                    + "tmux kill-session -t \(tmuxSession) >/dev/null 2>&1 || true; "
                    + "rm -rf \(quotedHome)"
            )
            throw error
        }
    }

    @MainActor
    func test_generateInstallAndAuthenticateWithEd25519Key() async throws {
        let config = try Config.load()
        let endpoint = "\(config.stableHost):\(config.port)"
        await resetConnectionState(endpoint: endpoint)

        let key = try KeyStore.generateEd25519(
            name: "tessera-live-\(UUID().uuidString.prefix(8))",
            context: ()
        )
        defer { _ = try? KeyStore.deleteKey(forKeyID: key.id) }

        let ledgerSuite = "RealHostTransportIntegrationTests.\(UUID().uuidString)"
        let ledgerDefaults = try XCTUnwrap(UserDefaults(suiteName: ledgerSuite))
        defer { ledgerDefaults.removePersistentDomain(forName: ledgerSuite) }
        let ledger = KeySecurityMetadataStore(
            defaults: ledgerDefaults,
            storageKey: "live-self-revoke"
        )
        let passwordHost = makeHost(config: config, transport: .ssh)
        let ledgerContext = RemoteAuthorizedKeysInstaller.LedgerContext(
            metadata: ledger,
            keyID: key.id,
            hostID: passwordHost.id,
            hostLabel: passwordHost.name,
            endpoint: "\(passwordHost.user)@\(passwordHost.address):\(passwordHost.port)",
            routeIdentity: RemoteAccessRouteIdentity.value(for: passwordHost),
            publicKeyFingerprint: key.canonicalFingerprint,
            authorizedKeysLine: key.authorizedKeysLine
        )

        let installer = SSHSession(host: passwordHost)
        defer { installer.disconnect() }
        _ = try await connect(
            session: installer,
            pendingRequest: { installer.pendingHostKeyVerification },
            timeout: 20
        )
        installer.disconnect()

        // Exercise the production durable install path, including its remote
        // verifier, rather than mutating authorized_keys through the fixture
        // shell directly.
        try await RemoteAuthorizedKeysInstaller.install(
            line: key.authorizedKeysLine,
            keyID: key.id,
            on: passwordHost,
            ledgerContext: ledgerContext
        )
        XCTAssertEqual(
            ledger.record(for: key.id).remoteInstallations.first?.verificationState,
            .verified
        )

        var sshKeyHost = passwordHost
        sshKeyHost.password = ""
        sshKeyHost.storedKeyID = key.id
        var moshKeyHost = makeHost(config: config, transport: .mosh)
        moshKeyHost.password = ""
        moshKeyHost.storedKeyID = key.id

        SSHAuthenticationPolicyStore.shared.resetForTesting()
        let keyedHosts = [sshKeyHost.id: sshKeyHost, moshKeyHost.id: moshKeyHost]
        SSHAuthenticationPolicyStore.shared.configureCurrentPolicyProvider { id, _ in
            guard let host = keyedHosts[id] else { return nil }
            return SSHConnectionPolicyDraft(
                host: host,
                requireBiometric: false,
                isSecureEnclave: false,
                keyAlgorithm: .ed25519
            )
        }
        SSHAuthenticationPolicyStore.shared.registerPersistedHosts(keyedHosts.keys)

        let ssh = SSHSession(host: sshKeyHost)
        _ = try await connect(
            session: ssh,
            pendingRequest: { ssh.pendingHostKeyVerification },
            timeout: 20
        )
        ssh.send(Array("printf 'TESSERA_ED25519_SSH_OK\\n'\n".utf8))
        _ = try await waitForOutput(
            ssh.outputStream,
            containing: "TESSERA_ED25519_SSH_OK",
            timeout: 10
        )
        ssh.disconnect()

        let mosh = MoshSession(host: moshKeyHost)
        _ = try await connect(
            session: mosh,
            pendingRequest: { mosh.pendingHostKeyVerification },
            timeout: 35
        )
        mosh.send(Array("printf 'TESSERA_ED25519_MOSH_OK\\n'\n".utf8))
        _ = try await waitForOutput(
            mosh.outputStream,
            containing: "TESSERA_ED25519_MOSH_OK",
            timeout: 15
        )
        mosh.disconnect()

        // The target key authenticates this connection, then removes itself
        // over the already-established client and verifies absence before the
        // connection closes.
        try await RemoteAuthorizedKeysInstaller.revokeUsingTargetKey(
            line: key.authorizedKeysLine,
            keyID: key.id,
            on: sshKeyHost,
            ledgerContext: ledgerContext
        )
        XCTAssertTrue(ledger.record(for: key.id).remoteInstallations.isEmpty)
        XCTAssertNotNil(ledger.record(for: key.id).lastRemoteRevocationAt)

        let revoked = SSHSession(host: sshKeyHost)
        defer { revoked.disconnect() }
        revoked.connect()
        let failure = try await waitForFailure(
            state: { revoked.state },
            pendingRequest: { revoked.pendingHostKeyVerification },
            timeout: 20
        )
        XCTAssertTrue(
            failure.localizedCaseInsensitiveContains("auth")
                || failure.localizedCaseInsensitiveContains("permission")
                || failure.localizedCaseInsensitiveContains("credential"),
            "revoked key unexpectedly produced a non-auth failure: \(failure)"
        )
    }

    @MainActor
    func test_liveSSHLocalForwardCarriesHTTPAndCountsBytes() async throws {
        let config = try Config.load()
        await resetConnectionState(endpoint: "\(config.stableHost):\(config.port)")
        let rule = PortForwardRule(
            localPort: UInt16(config.localForwardPort),
            remoteHost: "127.0.0.1",
            remotePort: UInt16(config.echoPort),
            label: "fixture-http"
        )
        var host = makeHost(config: config, transport: .ssh)
        host.launchMode = .autoTmux
        host.autoTmux = true
        host.portForwardRules = [rule]
        let session = SSHSession(host: host)
        defer { session.disconnect() }

        _ = try await connect(
            session: session,
            pendingRequest: { session.pendingHostKeyVerification },
            timeout: 20
        )
        try await waitUntil("forwarder listening", timeout: 8) {
            session.portForwarderManager.runningCount == 1
        }

        let url = try XCTUnwrap(
            URL(string: "http://127.0.0.1:\(config.localForwardPort)/probe")
        )
        let (data, response) = try await URLSession.shared.data(from: url)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "TESSERA_FORWARD_OK\n")

        try await waitUntil("forwarder byte accounting", timeout: 5) {
            guard let forwarder = session.portForwarderManager.forwarders[rule.id] else {
                return false
            }
            return forwarder.bytesUp > 0 && forwarder.bytesDown >= data.count
        }
    }

    @MainActor
    func test_liveSSHAndMoshApplyEnvironmentAndStartupSnippet() async throws {
        let config = try Config.load()
        let marker = "TESSERA_PROLOGUE_\(UUID().uuidString.prefix(8))"
        let expected = "\(marker)|space value|snippet-ok|/home/\(config.user)"

        for (transport, useChaosHost) in [(HostTransport.ssh, false), (.mosh, true)] {
            var host = makeHost(
                config: config,
                transport: transport,
                useChaosHost: useChaosHost
            )
            host.envVars = "TESSERA_VALUE='space value'\nTESSERA_HOME=$HOME"
            host.startupSnippet = "export TESSERA_SNIPPET=snippet-ok"
            host.launchCommand =
                "printf '\(marker)|%s|%s|%s\\n' \"$TESSERA_VALUE\" \"$TESSERA_SNIPPET\" \"$TESSERA_HOME\"; "
                + "exec /bin/bash --noprofile --norc"

            if transport == .ssh {
                let session = SSHSession(host: host)
                defer { session.disconnect() }
                _ = try await connect(
                    session: session,
                    pendingRequest: { session.pendingHostKeyVerification },
                    timeout: 20
                )
                var command = HostLaunchPrologue.multilineStdin(
                    envVars: host.envVars,
                    startupSnippet: host.startupSnippet
                ) ?? ""
                command += host.launchCommand ?? ""
                if !command.hasSuffix("\n") { command += "\n" }
                session.send(Array(command.utf8))
                let output = try await waitForOutput(
                    session.outputStream,
                    containing: expected,
                    timeout: 10
                )
                XCTAssertTrue(output.contains(expected))
            } else {
                let session = MoshSession(host: host)
                defer { session.disconnect() }
                _ = try await connect(
                    session: session,
                    pendingRequest: { session.pendingHostKeyVerification },
                    timeout: 35
                )
                let output = try await waitForOutput(
                    session.outputStream,
                    containing: expected,
                    timeout: 15
                )
                XCTAssertTrue(output.contains(expected))
            }
        }
    }

    @MainActor
    func test_liveFileBridgeListsAndRoundTripsFiles() async throws {
        let config = try Config.load()
        let endpoint = "\(config.stableHost):\(config.port)"
        await resetConnectionState(endpoint: endpoint)

        let trustSession = SSHSession(host: makeHost(config: config, transport: .ssh))
        _ = try await connect(
            session: trustSession,
            pendingRequest: { trustSession.pendingHostKeyVerification },
            timeout: 20
        )
        trustSession.disconnect()

        let host = makeHost(config: config, transport: .mosh)
        let bridge = FileBridge(host: host, requireBiometric: false, isSecureEnclave: false)
        defer { Task { await bridge.disconnect() } }
        try await bridge.connect()

        XCTAssertEqual(bridge.state, .connected)
        XCTAssertEqual(bridge.homeDirectory, "/home/\(config.user)")
        let fixturePath = "/home/\(config.user)/fixture-files"
        let fixtureNames = Set(try await bridge.listDirectory(fixturePath).map(\.name))
        XCTAssertTrue(fixtureNames.isSuperset(of: ["visible.txt", ".hidden", "testfile"]))

        let runName = "bridge-\(UUID().uuidString.lowercased())"
        let remoteDirectory = "\(fixturePath)/\(runName)"
        let remoteOriginal = "\(remoteDirectory)/upload.bin"
        let remoteRenamed = "\(remoteDirectory)/renamed.bin"
        let localRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(runName, isDirectory: true)
        try FileManager.default.createDirectory(at: localRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: localRoot) }

        var payload = Data()
        for index in 0..<8_192 {
            payload.append(UInt8(truncatingIfNeeded: index &* 31))
        }
        let uploadURL = localRoot.appendingPathComponent("upload.bin")
        let downloadURL = localRoot.appendingPathComponent("download.bin")
        try payload.write(to: uploadURL)

        try await bridge.createDirectory(remoteDirectory)
        do {
            try await bridge.upload(localURL: uploadURL, to: remoteOriginal, progress: nil)
            try await bridge.rename(from: remoteOriginal, to: remoteRenamed)
            let names = Set(try await bridge.listDirectory(remoteDirectory).map(\.name))
            XCTAssertEqual(names, Set(["renamed.bin"]))
            try await bridge.download(remotePath: remoteRenamed, to: downloadURL, progress: nil)
            XCTAssertEqual(try Data(contentsOf: downloadURL), payload)
            let execOutput = try await bridge.exec(
                "wc -c < \(remoteRenamed)",
                inShell: false
            )
            XCTAssertEqual(execOutput.trimmingCharacters(in: .whitespacesAndNewlines), "8192")
            try await bridge.removeFile(remoteRenamed)
            try await bridge.removeDirectory(remoteDirectory)
        } catch {
            try? await bridge.removeFile(remoteOriginal)
            try? await bridge.removeFile(remoteRenamed)
            try? await bridge.removeDirectory(remoteDirectory)
            throw error
        }
    }

    @MainActor
    func test_liveInlineTmuxControllersHydrateBothFixtureVersions() async throws {
        let config = try Config.load()
        try await assertInlineTmuxHydration(config: config, useChaosHost: false)
        try await assertInlineTmuxHydration(config: config, useChaosHost: true)
    }

    @MainActor
    func test_liveSideChannelTmuxIsolationAndForwarding() async throws {
        let config = try Config.load()
        try await assertSideChannelTmuxIsolation(
            config: config,
            useChaosHost: false,
            localPortOffset: 1
        )
        try await assertSideChannelTmuxIsolation(
            config: config,
            useChaosHost: true,
            localPortOffset: 2
        )
    }

    @MainActor
    func test_liveSSHtmuxAppliesPhoneViewportThenIPadViewport() async throws {
        let config = try Config.load()
        try await assertInlineTmuxViewportHandoff(config: config)
    }

    @MainActor
    func test_liveMoshTmuxAppliesPhoneViewportThenIPadViewport() async throws {
        let config = try Config.load()
        try await assertMoshTmuxViewportHandoff(config: config)
    }

    @MainActor
    private func resetConnectionState(endpoint: String) async {
        SSHAuthenticationPolicyStore.shared.resetForTesting()
        await KnownHostsStore.shared.remove(endpoint: endpoint)
    }

    private func makeHost(
        config: Config,
        transport: HostTransport,
        useChaosHost: Bool = false
    ) -> Host {
        Host(
            name: "Integration \(transport.rawValue)",
            address: useChaosHost ? config.chaosHost : config.stableHost,
            port: config.port,
            user: config.user,
            password: config.password,
            transport: transport,
            autoTmux: false,
            launchMode: .customCommand,
            launchCommand: "exec /bin/bash --noprofile --norc"
        )
    }

    private func makeInputPayload() -> [UInt8] {
        var payload = Array("\u{1B}[200~".utf8)
        let alphabet = Array("0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ\n".utf8)
        while payload.count < 4_096 {
            payload.append(contentsOf: alphabet)
        }
        payload.append(contentsOf: Array("\u{1B}[<0;10;5M\u{1B}[<0;10;5m".utf8))
        payload.append(contentsOf: Array("\u{1B}[201~".utf8))
        return payload
    }

    @MainActor
    private func assertInlineTmuxHydration(
        config: Config,
        useChaosHost: Bool
    ) async throws {
        let host = makeHost(
            config: config,
            transport: .ssh,
            useChaosHost: useChaosHost
        )
        let sessionName = "tessera-inline-\(UUID().uuidString.prefix(10).lowercased())"
        let setupMarker = "TESSERA_TMUX_SETUP_\(UUID().uuidString.prefix(8))"
        let setup = SSHSession(host: host)
        defer { setup.disconnect() }
        _ = try await connect(
            session: setup,
            pendingRequest: { setup.pendingHostKeyVerification },
            timeout: 20
        )
        setup.send(Array(
            ("tmux new-session -d -s \(sessionName) -n shell; "
                + "tmux new-window -d -t \(sessionName) -n editor; "
                + "tmux select-window -t \(sessionName):shell; "
                + "printf '\(setupMarker)\\n'\n").utf8
        ))
        _ = try await waitForOutput(setup.outputStream, containing: setupMarker, timeout: 10)

        let inline = SSHSession(host: host)
        let controller = TmuxController(controlPath: .inline)
        controller.updateClientSize(cols: 120, rows: 40)
        controller.sendBytes = { [weak inline] bytes in inline?.send(bytes) }
        let pump = Task { @MainActor in
            for await bytes in inline.outputStream {
                controller.ingest(bytes)
            }
        }
        defer {
            pump.cancel()
            inline.disconnect()
        }
        _ = try await connect(
            session: inline,
            pendingRequest: { inline.pendingHostKeyVerification },
            timeout: 20
        )
        inline.send(Array("exec tmux -CC attach -t \(sessionName)\n".utf8))

        try await waitUntil("inline tmux hydration", timeout: 15) {
            controller.mode == .tmuxControl
                && Set(controller.windows.compactMap(\.windowName))
                    .isSuperset(of: ["shell", "editor"])
                && controller.activeWindowId != nil
        }
        XCTAssertEqual(controller.windows.count, 2)

        let agentPaneID = try XCTUnwrap(
            controller.renderedPaneId ?? controller.activePaneId,
            "hydrated inline tmux controller must expose an active pane"
        )
        let agentCapture = await AgentSessionSourceFactory.capturePane(
            paneID: agentPaneID
        ) { command in
            await withCheckedContinuation { continuation in
                controller.sendControlCommand(command) { result in
                    continuation.resume(returning: result)
                }
            }
        }
        XCTAssertNotNil(
            agentCapture,
            "Agent Center cursor and capture queries must survive real -CC reply framing"
        )

        // This command also proves the two Agent Center replies drained in
        // FIFO order instead of leaving the controller one response out of
        // phase, which was the physical-iPad disappearance regression.
        controller.sendControlCommand("rename-window -t \(sessionName):shell locked-name")
        try await waitUntil("inline tmux rename", timeout: 8) {
            controller.windows.contains { $0.windowName == "locked-name" }
        }

        let cleanupMarker = "TESSERA_TMUX_CLEAN_\(UUID().uuidString.prefix(8))"
        setup.send(Array(
            ("tmux kill-session -t \(sessionName); printf '\(cleanupMarker)\\n'\n").utf8
        ))
        _ = try await waitForOutput(setup.outputStream, containing: cleanupMarker, timeout: 10)
    }

    @MainActor
    private func assertSideChannelTmuxIsolation(
        config: Config,
        useChaosHost: Bool,
        localPortOffset: Int
    ) async throws {
        let host = makeHost(
            config: config,
            transport: .mosh,
            useChaosHost: useChaosHost
        )
        let prefix = "tessera-side-\(UUID().uuidString.prefix(8).lowercased())"
        let sessionA = "\(prefix)-a"
        let sessionB = "\(prefix)-b"
        let setupMarker = "TESSERA_SIDE_SETUP_\(UUID().uuidString.prefix(8))"
        let setup = SSHSession(host: host)
        defer { setup.disconnect() }
        _ = try await connect(
            session: setup,
            pendingRequest: { setup.pendingHostKeyVerification },
            timeout: 20
        )
        setup.send(Array(
            ("tmux new-session -d -s \(sessionA) -n a-shell; "
                + "tmux new-window -d -t \(sessionA) -n a-editor; "
                + "tmux select-window -t \(sessionA):a-shell; "
                + "tmux new-session -d -s \(sessionB) -n b-shell; "
                + "tmux new-window -d -t \(sessionB) -n b-editor; "
                + "tmux select-window -t \(sessionB):b-shell; "
                + "printf '\(setupMarker)\\n'\n").utf8
        ))
        _ = try await waitForOutput(setup.outputStream, containing: setupMarker, timeout: 10)

        let localPort = try XCTUnwrap(UInt16(exactly: config.localForwardPort + localPortOffset))
        let rule = PortForwardRule(
            localPort: localPort,
            remoteHost: "127.0.0.1",
            remotePort: UInt16(config.echoPort),
            label: "mosh-sidechannel-http"
        )
        let manager = PortForwarderManager()
        let controllerA = TmuxController(controlPath: .sideChannel)
        let controllerB = TmuxController(controlPath: .sideChannel)
        let channelA = TmuxControlChannel(
            host: host,
            sessionName: sessionA,
            initialSize: (120, 40),
            portForwarderManager: manager,
            portForwardRules: [rule]
        )
        let channelB = TmuxControlChannel(
            host: host,
            sessionName: sessionB,
            initialSize: (120, 40)
        )
        controllerA.sendBytes = { [weak channelA] bytes in channelA?.send(bytes) }
        controllerB.sendBytes = { [weak channelB] bytes in channelB?.send(bytes) }
        let pumpA = Task { @MainActor in
            for await bytes in channelA.outputStream { controllerA.ingest(bytes) }
        }
        let pumpB = Task { @MainActor in
            for await bytes in channelB.outputStream { controllerB.ingest(bytes) }
        }
        defer {
            pumpA.cancel()
            pumpB.cancel()
            channelA.disconnect()
            channelB.disconnect()
        }
        channelA.connect()
        channelB.connect()

        try await waitUntil("side-channel tmux hydration", timeout: 15) {
            controllerA.mode == .tmuxControl
                && controllerB.mode == .tmuxControl
                && controllerA.windows.count == 2
                && controllerB.windows.count == 2
                && controllerA.activeWindowId != nil
                && controllerB.activeWindowId != nil
        }
        let activeA = controllerA.activeWindowId
        let activeB = controllerB.activeWindowId
        controllerB.nextWindow()
        try await waitUntil("side-channel session B switch", timeout: 8) {
            controllerB.activeWindowId != activeB
        }
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(
            controllerA.activeWindowId,
            activeA,
            "session B's broadcast tmux notification changed session A"
        )

        try await waitUntil("mosh side-channel forwarder listening", timeout: 8) {
            manager.runningCount == 1
        }
        let url = try XCTUnwrap(URL(string: "http://127.0.0.1:\(localPort)/probe"))
        let (data, response) = try await URLSession.shared.data(from: url)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "TESSERA_FORWARD_OK\n")
        try await waitUntil("mosh side-channel byte accounting", timeout: 5) {
            guard let forwarder = manager.forwarders[rule.id] else { return false }
            return forwarder.bytesUp > 0 && forwarder.bytesDown >= data.count
        }

        let cleanupMarker = "TESSERA_SIDE_CLEAN_\(UUID().uuidString.prefix(8))"
        setup.send(Array(
            ("tmux kill-session -t \(sessionA); "
                + "tmux kill-session -t \(sessionB); "
                + "printf '\(cleanupMarker)\\n'\n").utf8
        ))
        _ = try await waitForOutput(setup.outputStream, containing: cleanupMarker, timeout: 10)
    }

    /// Live acceptance for the cross-device viewport handoff on SSH+tmux.
    /// A phone must resize an existing large session to its physical viewport;
    /// a later iPad client on the same session must expand it again.
    @MainActor
    private func assertInlineTmuxViewportHandoff(config: Config) async throws {
        let host = makeHost(config: config, transport: .ssh)
        await resetConnectionState(endpoint: "\(host.address):\(host.port)")
        let setup = SSHSession(host: host)
        defer { setup.disconnect() }
        _ = try await connect(
            session: setup,
            pendingRequest: { setup.pendingHostKeyVerification },
            timeout: 20
        )

        let sessionName = "tessera-viewport-ssh-\(UUID().uuidString.prefix(8).lowercased())"
        do {
            _ = try await setup.executeConnectedCommand(
                "tmux new-session -d -x 160 -y 50 -s \(sessionName); "
                    + "tmux set-option -t \(sessionName) status off"
            )
            let initialGeometry = try await tmuxGeometry(
                sessionName: sessionName,
                using: setup
            )
            XCTAssertEqual(initialGeometry, TmuxGeometry(cols: 160, rows: 50))

            let phone = SSHSession(host: host)
            let phoneController = TmuxController(
                controlPath: .inline,
                clientSizePolicy: .resizeTmux
            )
            phone.resize(cols: 50, rows: 20)
            phoneController.updateClientSize(cols: 50, rows: 20)
            var phoneOutput = ""
            phoneController.feedTerminal = { bytes in
                phoneOutput += String(decoding: bytes, as: UTF8.self)
            }
            phoneController.sendBytes = { [weak phone] bytes in phone?.send(bytes) }
            let phonePump = Task { @MainActor in
                for await bytes in phone.outputStream {
                    phoneController.ingest(bytes)
                }
            }
            defer {
                phonePump.cancel()
                phone.disconnect()
            }
            _ = try await connect(
                session: phone,
                pendingRequest: { phone.pendingHostKeyVerification },
                timeout: 20
            )
            phone.send(Array("exec tmux -CC attach -t \(sessionName)\n".utf8))
            try await waitForTmuxHydration(
                phoneController,
                operation: "phone inline viewport hydration"
            )
            try await waitForTmuxGeometry(
                TmuxGeometry(cols: 50, rows: 20),
                sessionName: sessionName,
                using: setup,
                operation: "phone inline attach geometry"
            )

            phone.resize(cols: 50, rows: 12)
            phoneController.updateClientSize(cols: 50, rows: 12)
            try await waitForTmuxGeometry(
                TmuxGeometry(cols: 50, rows: 12),
                sessionName: sessionName,
                using: setup,
                operation: "phone inline keyboard geometry"
            )
            phone.resize(cols: 50, rows: 20)
            phoneController.updateClientSize(cols: 50, rows: 20)
            try await waitForTmuxGeometry(
                TmuxGeometry(cols: 50, rows: 20),
                sessionName: sessionName,
                using: setup,
                operation: "phone inline restored geometry"
            )

            let ipad = SSHSession(host: host)
            let ipadController = TmuxController(
                controlPath: .inline,
                clientSizePolicy: .resizeTmux
            )
            ipad.resize(cols: 132, rows: 44)
            ipadController.updateClientSize(cols: 132, rows: 44)
            ipadController.feedTerminal = { _ in }
            ipadController.sendBytes = { [weak ipad] bytes in ipad?.send(bytes) }
            let ipadPump = Task { @MainActor in
                for await bytes in ipad.outputStream {
                    ipadController.ingest(bytes)
                }
            }
            defer {
                ipadPump.cancel()
                ipad.disconnect()
            }
            _ = try await connect(
                session: ipad,
                pendingRequest: { ipad.pendingHostKeyVerification },
                timeout: 20
            )
            ipad.send(Array("exec tmux -CC attach -t \(sessionName)\n".utf8))
            try await waitForTmuxHydration(
                ipadController,
                operation: "iPad inline viewport hydration"
            )
            try await waitForTmuxGeometry(
                TmuxGeometry(cols: 132, rows: 44),
                sessionName: sessionName,
                using: setup,
                operation: "iPad inline attach geometry"
            )

            let marker = "TESSERA_SSH_TMUX_VIEWPORT_\(UUID().uuidString.prefix(8))"
            phoneController.sendInput(Array("printf '\(marker)\\n'\r".utf8))
            try await waitUntil("phone shell liveness after iPad resize", timeout: 10) {
                phoneOutput.contains(marker)
            }
            _ = try await setup.executeConnectedCommand(
                "tmux kill-session -t \(sessionName)"
            )
        } catch {
            _ = try? await setup.executeConnectedCommand(
                "tmux kill-session -t \(sessionName) >/dev/null 2>&1 || true"
            )
            throw error
        }
    }

    /// The same handoff through the production mosh+tmux split. Each device
    /// has a real visible mosh client and a normal SSH `-CC` side channel.
    @MainActor
    private func assertMoshTmuxViewportHandoff(config: Config) async throws {
        let baseHost = makeHost(
            config: config,
            transport: .mosh,
            useChaosHost: true
        )
        await resetConnectionState(endpoint: "\(baseHost.address):\(baseHost.port)")
        let setup = SSHSession(host: baseHost)
        defer { setup.disconnect() }
        _ = try await connect(
            session: setup,
            pendingRequest: { setup.pendingHostKeyVerification },
            timeout: 20
        )

        let sessionName = "tessera-viewport-mosh-\(UUID().uuidString.prefix(8).lowercased())"
        do {
            _ = try await setup.executeConnectedCommand(
                "tmux new-session -d -x 160 -y 50 -s \(sessionName); "
                    + "tmux set-option -t \(sessionName) status off"
            )
            let initialGeometry = try await tmuxGeometry(
                sessionName: sessionName,
                using: setup
            )
            XCTAssertEqual(initialGeometry, TmuxGeometry(cols: 160, rows: 50))

            var pinnedHost = baseHost
            pinnedHost.autoTmux = true
            pinnedHost.launchMode = .pinnedTmux
            pinnedHost.tmuxSessionName = sessionName
            pinnedHost.launchCommand = nil

            let phoneMosh = MoshSession(host: pinnedHost)
            defer { phoneMosh.disconnect() }
            phoneMosh.resize(cols: 50, rows: 20)
            _ = try await connect(
                session: phoneMosh,
                pendingRequest: { phoneMosh.pendingHostKeyVerification },
                timeout: 35
            )
            try await waitForTmuxGeometry(
                TmuxGeometry(cols: 50, rows: 20),
                sessionName: sessionName,
                using: setup,
                operation: "phone visible mosh attach geometry",
                timeout: 15
            )

            let phoneController = TmuxController(
                controlPath: .sideChannel,
                clientSizePolicy: .resizeTmux
            )
            phoneController.updateClientSize(cols: 50, rows: 20)
            let phoneChannel = TmuxControlChannel(
                host: pinnedHost,
                sessionName: sessionName,
                initialSize: (50, 20)
            )
            phoneController.sendBytes = { [weak phoneChannel] bytes in
                phoneChannel?.send(bytes)
            }
            let phonePump = Task { @MainActor in
                for await bytes in phoneChannel.outputStream {
                    phoneController.ingest(bytes)
                }
            }
            defer {
                phonePump.cancel()
                phoneChannel.disconnect()
            }
            phoneChannel.connect()
            try await waitForTmuxHydration(
                phoneController,
                operation: "phone mosh side-channel hydration"
            )

            phoneMosh.resize(cols: 50, rows: 12)
            phoneController.updateClientSize(cols: 50, rows: 12)
            phoneChannel.resize(cols: 50, rows: 12)
            try await waitForTmuxGeometry(
                TmuxGeometry(cols: 50, rows: 12),
                sessionName: sessionName,
                using: setup,
                operation: "phone mosh keyboard geometry"
            )
            phoneMosh.resize(cols: 50, rows: 20)
            phoneController.updateClientSize(cols: 50, rows: 20)
            phoneChannel.resize(cols: 50, rows: 20)
            try await waitForTmuxGeometry(
                TmuxGeometry(cols: 50, rows: 20),
                sessionName: sessionName,
                using: setup,
                operation: "phone mosh restored geometry"
            )

            let ipadMosh = MoshSession(host: pinnedHost)
            defer { ipadMosh.disconnect() }
            ipadMosh.resize(cols: 132, rows: 44)
            _ = try await connect(
                session: ipadMosh,
                pendingRequest: { ipadMosh.pendingHostKeyVerification },
                timeout: 35
            )

            let ipadController = TmuxController(
                controlPath: .sideChannel,
                clientSizePolicy: .resizeTmux
            )
            ipadController.updateClientSize(cols: 132, rows: 44)
            let ipadChannel = TmuxControlChannel(
                host: pinnedHost,
                sessionName: sessionName,
                initialSize: (132, 44)
            )
            ipadController.sendBytes = { [weak ipadChannel] bytes in
                ipadChannel?.send(bytes)
            }
            let ipadPump = Task { @MainActor in
                for await bytes in ipadChannel.outputStream {
                    ipadController.ingest(bytes)
                }
            }
            defer {
                ipadPump.cancel()
                ipadChannel.disconnect()
            }
            ipadChannel.connect()
            try await waitForTmuxHydration(
                ipadController,
                operation: "iPad mosh side-channel hydration"
            )
            try await waitForTmuxGeometry(
                TmuxGeometry(cols: 132, rows: 44),
                sessionName: sessionName,
                using: setup,
                operation: "iPad mosh attach geometry",
                timeout: 15
            )

            let marker = "TESSERA_MOSH_TMUX_VIEWPORT_\(UUID().uuidString.prefix(8))"
            phoneMosh.send(Array("printf '\(marker)\\n'\r".utf8))
            _ = try await waitForOutput(
                phoneMosh.outputStream,
                containing: marker,
                timeout: 15
            )
            try await Task.sleep(nanoseconds: 300_000_000)
            let geometryAfterPhoneInput = try await tmuxGeometry(
                sessionName: sessionName,
                using: setup
            )
            XCTAssertEqual(
                geometryAfterPhoneInput,
                TmuxGeometry(cols: 132, rows: 44),
                "visible phone mosh input reclaimed tmux sizing from the iPad side channel"
            )
            _ = try await setup.executeConnectedCommand(
                "tmux kill-session -t \(sessionName)"
            )
        } catch {
            _ = try? await setup.executeConnectedCommand(
                "tmux kill-session -t \(sessionName) >/dev/null 2>&1 || true"
            )
            throw error
        }
    }

    private struct TmuxGeometry: Equatable {
        let cols: Int
        let rows: Int
    }

    private func tmuxGeometry(
        sessionName: String,
        using session: SSHSession
    ) async throws -> TmuxGeometry {
        let output = try await session.executeConnectedCommand(
            "tmux display-message -p -t \(sessionName):0 '#{window_width}x#{window_height}'"
        )
        for token in output.split(whereSeparator: { $0.isWhitespace }).reversed() {
            let dimensions = token.split(separator: "x", omittingEmptySubsequences: false)
            if dimensions.count == 2,
               let cols = Int(dimensions[0]),
               let rows = Int(dimensions[1]) {
                return TmuxGeometry(cols: cols, rows: rows)
            }
        }
        throw IntegrationError.failed(
            "tmux returned an invalid geometry for \(sessionName): \(output.debugDescription)"
        )
    }

    private func waitForTmuxGeometry(
        _ expected: TmuxGeometry,
        sessionName: String,
        using session: SSHSession,
        operation: String,
        timeout: TimeInterval = 8
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        var lastGeometry: TmuxGeometry?
        while Date() < deadline {
            lastGeometry = try await tmuxGeometry(
                sessionName: sessionName,
                using: session
            )
            if lastGeometry == expected { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        throw IntegrationError.failed(
            "\(operation) expected \(expected.cols)x\(expected.rows), "
                + "got \(lastGeometry?.cols ?? -1)x\(lastGeometry?.rows ?? -1)"
        )
    }

    @MainActor
    private func waitForTmuxHydration(
        _ controller: TmuxController,
        operation: String
    ) async throws {
        try await waitUntil(operation, timeout: 15) {
            controller.mode == .tmuxControl
                && controller.activeWindowId != nil
                && controller.activePaneId != nil
        }
    }

    @MainActor
    private func assertRawPayload<Session: TerminalSession>(
        session: Session,
        payload: [UInt8],
        expectedDigest: String,
        label: String,
        timeout: TimeInterval
    ) async throws {
        let runID = UUID().uuidString.lowercased()
        let output = "/var/lib/tessera-fixture/runs/\(runID)/\(label)-input.json"
        let command = "/usr/local/bin/tessera-fixture-probe capture"
            + " --output \(output)"
            + " --bytes \(payload.count)"
            + " --timeout \(timeout)"
            + " --expect-sha256 \(expectedDigest)"
            + " --mouse --bracketed-paste --alt-screen\n"
        session.send(Array(command.utf8))
        _ = try await waitForOutput(
            session.outputStream,
            containing: "TESSERA_CAPTURE_READY",
            timeout: timeout
        )
        session.send(payload)
        let completion = try await waitForOutput(
            session.outputStream,
            containing: "TESSERA_CAPTURE_COMPLETE",
            timeout: timeout
        )
        XCTAssertTrue(
            completion.contains("verdict=pass"),
            "\(label) PTY payload checksum failed: \(completion.debugDescription)"
        )
    }

    @MainActor
    private func waitUntil(
        _ operation: String,
        timeout: TimeInterval,
        predicate: @escaping @MainActor () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        throw IntegrationError.timedOut(operation)
    }

    @MainActor
    private func waitForHostKeyRequest(
        _ request: @escaping @MainActor () -> HostKeyVerificationRequest?,
        timeout: TimeInterval
    ) async throws -> HostKeyVerificationRequest {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let request = request() { return request }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        throw IntegrationError.timedOut("host-key verification request")
    }

    @MainActor
    private func connect<Session: TerminalSession>(
        session: Session,
        pendingRequest: @escaping @MainActor () -> HostKeyVerificationRequest?,
        timeout: TimeInterval
    ) async throws -> Bool {
        session.connect()
        let deadline = Date().addingTimeInterval(timeout)
        var sawTOFU = false

        while Date() < deadline {
            if let request = pendingRequest() {
                sawTOFU = true
                XCTAssertFalse(request.fingerprint.isEmpty)
                XCTAssertFalse(request.keyType.isEmpty)
                request.accept()
            }

            switch session.state {
            case .connected:
                return sawTOFU
            case .failed(let message):
                throw IntegrationError.failed(message)
            case .idle, .connecting, .disconnected:
                break
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        throw IntegrationError.timedOut("connect \(session.host.transport.rawValue)")
    }

    @MainActor
    private func waitForFailure(
        state: @escaping @MainActor () -> SessionState,
        pendingRequest: @escaping @MainActor () -> HostKeyVerificationRequest?,
        timeout: TimeInterval
    ) async throws -> String {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            pendingRequest()?.accept()
            switch state() {
            case .failed(let message):
                return message
            case .idle, .connecting, .connected, .disconnected:
                break
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        throw IntegrationError.timedOut("authentication failure")
    }

    private func waitForOutput(
        _ stream: AsyncStream<[UInt8]>,
        containing marker: String,
        timeout: TimeInterval
    ) async throws -> String {
        try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask {
                var text = ""
                for await bytes in stream {
                    text += String(decoding: bytes, as: UTF8.self)
                    if text.contains(marker) {
                        return text
                    }
                    if text.utf8.count > 256 * 1024 {
                        text = String(text.suffix(128 * 1024))
                    }
                }
                throw IntegrationError.streamEnded(marker)
            }
            group.addTask {
                try await Task.sleep(
                    nanoseconds: UInt64(timeout * 1_000_000_000)
                )
                throw IntegrationError.timedOut("output marker \(marker)")
            }

            guard let value = try await group.next() else {
                throw IntegrationError.streamEnded(marker)
            }
            group.cancelAll()
            return value
        }
    }

    private func shellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    private func integerValue(after marker: String, in text: String) -> Int? {
        guard let range = text.range(of: marker) else { return nil }
        let digits = text[range.upperBound...].prefix { $0.isNumber }
        return Int(digits)
    }
}
#endif
