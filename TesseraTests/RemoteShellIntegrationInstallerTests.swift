import XCTest
@testable import Tessera

final class RemoteShellIntegrationInstallerTests: XCTestCase {
    func test_makeRcAppendCommand_containsMarkerGuardAndAppend() {
        let command = RemoteShellIntegrationInstaller.makeRcAppendCommand(
            rcFile: "~/.bashrc"
        )

        XCTAssertEqual(
            command,
            #"{ grep -qF 'TESSERA-OSC7' "$HOME/.bashrc" || echo '[ -r "$HOME/.config/tessera/osc7.sh" ] && . "$HOME/.config/tessera/osc7.sh" # TESSERA-OSC7' >> "$HOME/.bashrc"; }"#
        )
        XCTAssertTrue(command.contains("grep -qF 'TESSERA-OSC7'"))
        XCTAssertTrue(command.contains(" >> "))
        XCTAssertFalse(command.contains(" > "))
    }

    func test_makeRcAppendCommand_escapesSingleQuoteInLiteralPath() {
        let command = RemoteShellIntegrationInstaller.makeRcAppendCommand(
            rcFile: "/tmp/alice's rc"
        )

        XCTAssertTrue(command.contains(#"'/tmp/alice'\''s rc'"#))
        XCTAssertTrue(command.contains("grep -qF 'TESSERA-OSC7'"))
        XCTAssertTrue(command.contains(" >> "))
    }

    func test_makeScriptWriteCommand_writesSingleQuotedScriptUnderConfigDirectory() {
        let command = RemoteShellIntegrationInstaller.makeScriptWriteCommand()

        XCTAssertTrue(command.contains(#"mkdir -p "$HOME/.config/tessera""#))
        XCTAssertTrue(command.contains("printf '%s\\n'"))
        XCTAssertTrue(command.contains(#"> "$HOME/.config/tessera/osc7.sh""#))
        XCTAssertTrue(command.contains(#"chmod 644 "$HOME/.config/tessera/osc7.sh""#))
        XCTAssertTrue(command.contains("# Tessera OSC 7 shell integration — safe to delete"))
        XCTAssertTrue(command.contains(#"printf '\''%d'\''"#))
    }

    func test_makeVerifyCommand_checksScriptAndMarkerThenEchoesInstallMarker() {
        let command = RemoteShellIntegrationInstaller.makeVerifyCommand()

        XCTAssertTrue(command.contains(#"[ -f "$HOME/.config/tessera/osc7.sh" ]"#))
        XCTAssertTrue(command.contains("grep -qF 'TESSERA-OSC7'"))
        XCTAssertTrue(command.contains(#""$HOME/.bashrc""#))
        XCTAssertTrue(command.contains(#""$HOME/.zshrc""#))
        XCTAssertTrue(command.contains("TESSERA_OSC7_INSTALLED"))
    }

    func test_embeddedScript_containsShellRegistrationAndEncoder() {
        let script = RemoteShellIntegrationInstaller.embeddedScript

        XCTAssertTrue(script.contains("# Tessera OSC 7 shell integration — safe to delete"))
        XCTAssertTrue(script.contains("__tessera_osc7_percent_encode()"))
        XCTAssertTrue(script.contains(#"[A-Za-z0-9/_.~-])"#))
        XCTAssertTrue(script.contains("byte=$((byte & 255))"))
        XCTAssertTrue(script.contains("add-zsh-hook precmd __tessera_osc7"))
        XCTAssertTrue(script.contains("precmd_functions+=(__tessera_osc7)"))
        XCTAssertTrue(script.contains(#"PROMPT_COMMAND="__tessera_osc7; ${PROMPT_COMMAND}""#))
    }

    func test_embeddedScript_hasOneOsc7EmissionAndEndsWithImmediateEmit() {
        let script = RemoteShellIntegrationInstaller.embeddedScript

        XCTAssertEqual(occurrences(of: "]7;file://", in: script), 1)
        XCTAssertTrue(
            script.trimmingCharacters(in: .whitespacesAndNewlines)
                .hasSuffix("__tessera_osc7")
        )
    }

    func test_makeRcInstallCommand_createsRcMatchingLoginShellWhenNoneExists() {
        let command = RemoteShellIntegrationInstaller.makeRcInstallCommand()

        // Existing rc files are appended to; when NEITHER exists the
        // created file must follow $SHELL (zsh login user must not get
        // a ~/.bashrc that zsh never sources).
        XCTAssertTrue(command.contains(#"case "${SHELL##*/}" in zsh)"#))
        XCTAssertTrue(command.contains(#"touch "$HOME/.zshrc""#))
        XCTAssertTrue(command.contains(#"touch "$HOME/.bashrc""#))
        XCTAssertTrue(command.contains("TESSERA_OSC7_RC ~/.zshrc"))
        XCTAssertTrue(command.contains("TESSERA_OSC7_RC ~/.bashrc"))
    }

    func test_snippetPreview_containsMarkerLine() {
        XCTAssertTrue(
            RemoteShellIntegrationInstaller.snippetPreview.contains(
                RemoteShellIntegrationInstaller.rcMarkerLine
            )
        )
    }

    func test_agentLifecycleHookUsesImmediateOSCAndRetainedTmuxOptionWithoutJQ() {
        let script = RemoteAgentLifecycleIntegrationInstaller.hookScript

        XCTAssertEqual(
            RemoteAgentLifecycleIntegrationInstaller.integrationVersion,
            AgentLifecycleEvent.supportedVersion
        )
        XCTAssertTrue(script.contains("TESSERA_AGENT_INTEGRATION_VERSION=8"))
        XCTAssertTrue(script.contains("\"agentPid\":"))
        XCTAssertTrue(script.contains("@tessera_agent_state"))
        XCTAssertTrue(script.contains("]1337;TesseraAgentState="))
        XCTAssertTrue(script.contains("tmux display-message -p -t"))
        XCTAssertTrue(script.contains("ps -o tty="))
        XCTAssertTrue(script.contains(#"metadata="$(python3 -c"#))
        XCTAssertTrue(script.contains("dd bs=4096 count=16"))
        XCTAssertFalse(script.contains(#"input="$(cat"#))
        XCTAssertTrue(script.contains("json.load(sys.stdin)"))
        XCTAssertTrue(script.contains(#"data.get("session_id", "")"#))
        XCTAssertTrue(script.contains(#"data.get("turn_id", "")"#))
        XCTAssertTrue(script.contains(#"data.get("permission_mode", "")"#))
        XCTAssertTrue(script.contains(#"data.get("agent_id", "")"#))
        XCTAssertTrue(script.contains(#"sed -n 's/.*"agent_id""#))
        XCTAssertTrue(script.contains(#"SessionStart|SessionEnd|WrapperExit)"#))
        XCTAssertFalse(script.contains("TESSERA_AGENT_LAUNCH_PID"))
        XCTAssertTrue(script.contains("TESSERA_AGENT_VERIFIED_PROVIDER_PID"))
        XCTAssertTrue(script.contains(#"codex:SessionStart:verified-trusted-empty-composer:"$PPID""#))
        XCTAssertTrue(script.contains(#"codex:SessionStart:verified-configured-empty-composer:"$PPID""#))
        XCTAssertTrue(script.contains("reason=%s phase=%s"))
        XCTAssertTrue(script.contains(#"rm -rf "$subagent_dir""#))
        XCTAssertTrue(script.contains(#"if [ "$event" != SubagentStop ]"#))
        XCTAssertTrue(script.contains(#"SubagentStop)"#))
        XCTAssertTrue(script.contains("preserve both the retained pane state"))
        XCTAssertTrue(script.contains(#"PermissionRequest:*|Notification:waitingForInput)"#))
        XCTAssertTrue(script.contains("time.time_ns()"))
        XCTAssertTrue(script.contains("printf '%.256s'"))
        XCTAssertTrue(script.contains("printf '%.64s'"))
        XCTAssertFalse(script.contains("jq"))
        XCTAssertFalse(
            script.split(whereSeparator: \.isNewline).contains {
                $0.trimmingCharacters(in: .whitespaces) == "printf '%s\\n' \"$payload\""
            },
            "hook protocol must never write payload JSON to stdout"
        )
    }

    func test_agentLifecycleClaudeSettingsAreValidAndCoverBlockingLifecycle() throws {
        let data = try XCTUnwrap(
            RemoteAgentLifecycleIntegrationInstaller.claudeSettings.data(using: .utf8)
        )
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let hooks = try XCTUnwrap(object["hooks"] as? [String: Any])

        for event in ["SessionStart", "SubagentStart", "SubagentStop", "UserPromptSubmit", "PermissionRequest", "Notification", "Stop", "StopFailure", "SessionEnd"] {
            XCTAssertNotNil(hooks[event], "missing Claude lifecycle hook \(event)")
        }
    }

    func test_agentLifecycleCodexHooksAreValidAndCoverBlockingLifecycle() throws {
        let hooksData = try XCTUnwrap(
            RemoteAgentLifecycleIntegrationInstaller.codexHooks.data(using: .utf8)
        )
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: hooksData) as? [String: Any]
        )
        let hooks = try XCTUnwrap(object["hooks"] as? [String: Any])
        for event in ["SessionStart", "SubagentStart", "SubagentStop", "UserPromptSubmit", "PermissionRequest", "Stop"] {
            XCTAssertNotNil(hooks[event], "missing Codex lifecycle hook \(event)")
        }
        let sessionStartGroups = try XCTUnwrap(
            hooks["SessionStart"] as? [[String: Any]]
        )
        XCTAssertEqual(
            sessionStartGroups.first?["matcher"] as? String,
            "startup|resume|clear|compact",
            "all documented Codex thread-reset sources must refresh lifecycle state"
        )
    }

    func test_agentLifecycleCodexHookMergePreservesUserGroupsAndReplacesOnlyTesseraHandlers() throws {
        let existing = #"{"customTopLevel":{"enabled":true},"hooks":{"SessionStart":[{"matcher":"user","hooks":[{"type":"command","command":"user-session-hook"},{"type":"command","command":"\"$HOME/.config/tessera/agent-lifecycle-hook.sh\" codex SessionStart idle obsolete"}]}],"CustomEvent":[{"hooks":[{"type":"command","command":"user-custom-hook"}]}]}}"#
        let merged = try RemoteAgentLifecycleIntegrationInstaller.mergeCodexHooks(existing: existing)
        let mergedData = try XCTUnwrap(merged.data(using: .utf8))
        let root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: mergedData) as? [String: Any]
        )
        XCTAssertEqual(
            (root["customTopLevel"] as? [String: Any])?["enabled"] as? Bool,
            true
        )
        let hooks = try XCTUnwrap(root["hooks"] as? [String: Any])
        let customGroups = try XCTUnwrap(hooks["CustomEvent"] as? [[String: Any]])
        XCTAssertEqual(customGroups.count, 1)
        let sessionGroups = try XCTUnwrap(hooks["SessionStart"] as? [[String: Any]])
        let commands = sessionGroups.flatMap { group in
            (group["hooks"] as? [[String: Any]] ?? []).compactMap { $0["command"] as? String }
        }
        XCTAssertTrue(commands.contains("user-session-hook"))
        XCTAssertEqual(commands.filter { $0.contains("agent-lifecycle-hook.sh") }.count, 1)
        XCTAssertTrue(commands.contains { $0.contains("SessionStart idle session-start") })
        XCTAssertFalse(commands.contains { $0.contains("obsolete") })
    }

    func test_agentLifecycleClaudeSettingsMergePreservesEveryUnrelatedSettingAndHook() throws {
        let existing = #"{"theme":"dark","permissions":{"allow":["Read"]},"hooks":{"SessionStart":[{"matcher":"user","hooks":[{"type":"command","command":"user-session-hook"},{"type":"command","command":"\"$HOME/.config/tessera/agent-lifecycle-hook.sh\" claude SessionStart idle obsolete"}]}],"CustomEvent":[{"hooks":[{"type":"command","command":"user-custom-hook"}]}]}}"#
        let merged = try RemoteAgentLifecycleIntegrationInstaller.mergeClaudeSettings(
            existing: existing
        )
        let data = try XCTUnwrap(merged.data(using: .utf8))
        let root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertEqual(root["theme"] as? String, "dark")
        XCTAssertEqual(
            (root["permissions"] as? [String: Any])?["allow"] as? [String],
            ["Read"]
        )
        let hooks = try XCTUnwrap(root["hooks"] as? [String: Any])
        XCTAssertNotNil(hooks["CustomEvent"])
        let groups = try XCTUnwrap(hooks["SessionStart"] as? [[String: Any]])
        let commands = groups.flatMap {
            ($0["hooks"] as? [[String: Any]] ?? []).compactMap { $0["command"] as? String }
        }
        XCTAssertTrue(commands.contains("user-session-hook"))
        XCTAssertEqual(commands.filter { $0.contains("agent-lifecycle-hook.sh") }.count, 1)
        XCTAssertTrue(commands.contains { $0.contains("SessionStart idle session-start") })
        XCTAssertFalse(commands.contains { $0.contains("obsolete") })
    }

    func test_agentLifecycleCodexHookSnapshotRoundTripsUTF8AndRejectsErrors() {
        let contents = #"{"hooks":{"SessionStart":[]},"label":"héllo"}"#
        let encoded = Data(contents.utf8).base64EncodedString()
        XCTAssertEqual(
            RemoteAgentLifecycleIntegrationInstaller.parseCodexHooksSnapshot(
                "banner\nTESSERA_AGENT_CODEX_HOOKS present:\(encoded)\n"
            ),
            .present(contents)
        )
        XCTAssertEqual(
            RemoteAgentLifecycleIntegrationInstaller.parseCodexHooksSnapshot(
                "TESSERA_AGENT_CODEX_HOOKS missing\n"
            ),
            .missing
        )
        XCTAssertNil(
            RemoteAgentLifecycleIntegrationInstaller.parseCodexHooksSnapshot(
                "TESSERA_AGENT_CODEX_HOOKS error:dangling-symlink\n"
            )
        )
        XCTAssertEqual(
            RemoteAgentLifecycleIntegrationInstaller.parseClaudeSettingsSnapshot(
                "TESSERA_AGENT_CLAUDE_SETTINGS present:\(encoded)\n"
            ),
            .present(contents)
        )
    }

    func test_agentLifecycleInstallCommandAtomicallyMergesBothOfficialUserConfigs() {
        let command = RemoteAgentLifecycleIntegrationInstaller.makeInstallCommand()

        XCTAssertTrue(command.contains("grep -qFx"))
        XCTAssertTrue(command.contains(RemoteAgentLifecycleIntegrationInstaller.rcMarkerLine))
        XCTAssertTrue(command.contains("agent-lifecycle-hook.sh"))
        XCTAssertTrue(command.contains("agent-launch.sh"))
        XCTAssertTrue(command.contains("agent-codex-readiness.sh"))
        XCTAssertTrue(command.contains("$HOME/.config/tessera/bin/claude"))
        XCTAssertTrue(command.contains("$HOME/.config/tessera/bin/codex"))
        XCTAssertTrue(command.contains(#"${CLAUDE_CONFIG_DIR:-$HOME/.claude}"#))
        XCTAssertTrue(command.contains("settings.json"))
        XCTAssertTrue(command.contains(#"${CODEX_HOME:-$HOME/.codex}"#))
        XCTAssertTrue(command.contains("hooks.json"))
        XCTAssertTrue(command.contains(RemoteAgentLifecycleIntegrationInstaller.codexHooksRaceMarker))
        XCTAssertTrue(command.contains(RemoteAgentLifecycleIntegrationInstaller.claudeSettingsRaceMarker))
        XCTAssertTrue(command.contains("realpath"))
        XCTAssertTrue(command.contains("readlink -f"))
        XCTAssertTrue(command.contains(RemoteAgentLifecycleIntegrationInstaller.verificationMarker))
        XCTAssertTrue(command.contains(#"${ZDOTDIR:-$HOME}/.zshrc"#))
        XCTAssertTrue(command.contains(#"$HOME/.bash_profile"#))
        XCTAssertTrue(command.contains(#"$HOME/.bash_login"#))
        XCTAssertTrue(command.contains(RemoteAgentLifecycleIntegrationInstaller.bashLoginMarkerLine))
        XCTAssertTrue(command.contains(#"chmod 700 "$HOME/.config/tessera" "$HOME/.config/tessera/bin""#))
        XCTAssertTrue(command.contains("tail -c 1"))
        XCTAssertTrue(command.contains(#"printf '\n' >> "$tessera_append_file""#))
        XCTAssertTrue(command.contains("$HOME/.config/tessera/claude-agent-hooks.json"))
        XCTAssertTrue(command.contains("claude-agent-hooks.json.tessera.$$"))
        XCTAssertTrue(command.contains(#"rm -f "$HOME/.config/tessera/codex-hooks-installed.json""#))
        XCTAssertFalse(command.contains(#"rm -f "$HOME/.config/tessera/claude-agent-hooks.json""#))
        XCTAssertTrue(command.contains("agent-lifecycle-hook.sh.tessera.$$"))
        XCTAssertTrue(command.contains(#"mv -f "$HOME/.config/tessera/agent-lifecycle-hook.sh.tessera.$$" "$HOME/.config/tessera/agent-lifecycle-hook.sh""#))
        XCTAssertFalse(command.contains("$HOME/.codex/config"))

        guard let supportFiles = command.range(
            of: #"mkdir -p "$HOME/.config/tessera/bin""#
        )?.lowerBound,
        let codexConfig = command.range(
            of: "tessera_codex_hooks_home="
        )?.lowerBound,
        let claudeConfig = command.range(
            of: "tessera_claude_settings_home="
        )?.lowerBound else {
            XCTFail("install command omitted an ordered publication stage")
            return
        }
        XCTAssertLessThan(supportFiles, codexConfig)
        XCTAssertLessThan(codexConfig, claudeConfig)
    }

    func test_agentLifecycleStatusProbeIsReadOnlyAndVersioned() {
        let command = RemoteAgentLifecycleIntegrationInstaller.makeStatusCommand()

        XCTAssertTrue(command.contains("TESSERA_AGENT_INTEGRATION_STATUS"))
        XCTAssertTrue(command.contains("TESSERA_AGENT_INSTALL_DIAG"))
        XCTAssertTrue(command.contains("TESSERA_AGENT_HOST_DIAG"))
        XCTAssertTrue(command.contains("agent-lifecycle-hook.sh"))
        XCTAssertTrue(command.contains("agent-launch.sh"))
        XCTAssertTrue(command.contains("agent-codex-readiness.sh"))
        XCTAssertTrue(command.contains("codex_hooks_target="))
        XCTAssertTrue(command.contains("claude_settings_target="))
        XCTAssertTrue(command.contains("agent-lifecycle.sh"))
        XCTAssertTrue(command.contains("grep -qFx"))
        XCTAssertTrue(command.contains("cksum"))
        XCTAssertTrue(command.contains("agent-lifecycle-hook.sh\\\" codex SessionStart idle session-start"))
        XCTAssertTrue(command.contains("agent-lifecycle-hook.sh\\\" claude SessionStart idle session-start"))
        XCTAssertFalse(command.contains(#"$HOME/.config/tessera/agent-lifecycle-hook.sh\" codex SessionStart"#))
        XCTAssertFalse(command.contains("$(cat \"$hook\")"))
        XCTAssertFalse(command.contains("cmp -s"))
        XCTAssertFalse(command.contains(RemoteAgentLifecycleIntegrationInstaller.hookScript))
        XCTAssertLessThan(command.utf8.count, 16_000)
        XCTAssertFalse(command.contains(#"mkdir -p "$HOME/.config/tessera" &&"#))
        XCTAssertFalse(command.contains(#"chmod 700 "$HOME/.config/tessera/agent-lifecycle-hook.sh""#))
        XCTAssertTrue(command.contains(#"[ ! -x "$hook" ]"#))
        XCTAssertTrue(command.contains(#"[ ! -x "$launcher" ]"#))
        XCTAssertTrue(command.contains(#"[ ! -x "$codex_readiness" ]"#))
        XCTAssertTrue(command.contains(#"[ ! -x "$claude_shim" ]"#))
        XCTAssertTrue(command.contains(#"[ ! -x "$codex_shim" ]"#))
        XCTAssertTrue(command.contains(#"[ ! -r "$claude_legacy" ]"#))
        XCTAssertTrue(command.contains(#"tessera_primary_rc="$tessera_zshrc""#))
        XCTAssertTrue(command.contains(#"-perm -020 -o -perm -002"#))
        XCTAssertTrue(command.contains("codex-readiness-diagnostics.log"))
        XCTAssertTrue(command.contains("agent-lifecycle-diagnostics.log"))
    }

    func test_agentLifecycleStatusChecksumMatchesPOSIXCksum() {
        XCTAssertEqual(
            RemoteAgentLifecycleIntegrationInstaller.posixChecksumAndLength("123456789"),
            "930766865:9"
        )
        XCTAssertEqual(
            RemoteAgentLifecycleIntegrationInstaller.posixChecksumAndLength("abc\n"),
            "1112837078:4"
        )
    }

    func test_agentLifecycleStatusParserDistinguishesInstallationStates() {
        let marker = RemoteAgentLifecycleIntegrationInstaller.statusMarker

        XCTAssertEqual(
            RemoteAgentLifecycleIntegrationInstaller.parseStatus("banner\n\(marker) missing\n"),
            .missing
        )
        XCTAssertEqual(
            RemoteAgentLifecycleIntegrationInstaller.parseStatus("\(marker) current\n"),
            .current
        )
        XCTAssertEqual(
            RemoteAgentLifecycleIntegrationInstaller.parseStatus("\(marker) outdated:4\n"),
            .outdated(version: 4)
        )
        XCTAssertEqual(
            RemoteAgentLifecycleIntegrationInstaller.parseStatus("\(marker) outdated:\n"),
            .outdated(version: nil)
        )
        XCTAssertNil(RemoteAgentLifecycleIntegrationInstaller.parseStatus("login banner only"))
    }

    func test_agentLifecycleHelpDisclosureShowsEveryRemoteArtifact() {
        let source = RemoteAgentLifecycleIntegrationInstaller.disclosedSource

        XCTAssertTrue(source.contains("~/.config/tessera/agent-lifecycle-hook.sh"))
        XCTAssertTrue(source.contains(RemoteAgentLifecycleIntegrationInstaller.hookScript))
        XCTAssertTrue(source.contains("~/.config/tessera/agent-launch.sh"))
        XCTAssertTrue(source.contains(RemoteAgentLifecycleIntegrationInstaller.launcherScript))
        XCTAssertTrue(source.contains("~/.config/tessera/agent-codex-readiness.sh"))
        XCTAssertTrue(source.contains(RemoteAgentLifecycleIntegrationInstaller.codexReadinessScript))
        XCTAssertTrue(source.contains("~/.config/tessera/bin/claude"))
        XCTAssertTrue(source.contains(RemoteAgentLifecycleIntegrationInstaller.claudeShimScript))
        XCTAssertTrue(source.contains("~/.config/tessera/bin/codex"))
        XCTAssertTrue(source.contains(RemoteAgentLifecycleIntegrationInstaller.codexShimScript))
        XCTAssertTrue(source.contains("${CLAUDE_CONFIG_DIR:-~/.claude}/settings.json"))
        XCTAssertTrue(source.contains(RemoteAgentLifecycleIntegrationInstaller.claudeSettings))
        XCTAssertTrue(source.contains("~/.config/tessera/agent-lifecycle.sh"))
        XCTAssertTrue(source.contains(RemoteAgentLifecycleIntegrationInstaller.shellIntegration))
        XCTAssertTrue(source.contains(RemoteAgentLifecycleIntegrationInstaller.rcMarkerLine))
    }

    func test_agentShellActivationIsVersionedAndBoundToExactShellProcess() {
        let integration = RemoteAgentLifecycleIntegrationInstaller.shellIntegration

        XCTAssertTrue(integration.contains("TESSERA_AGENT_INTEGRATION_VERSION=8"))
        XCTAssertTrue(integration.contains("active-shells"))
        XCTAssertTrue(integration.contains(#"/proc/$$/stat"#))
        XCTAssertTrue(integration.contains("ps -o lstart= -p $$"))
        XCTAssertTrue(integration.contains("@tessera_agent_shell"))
        XCTAssertFalse(integration.contains("trap "))
        XCTAssertFalse(integration.contains("kill -WINCH"))
        XCTAssertFalse(integration.contains("function claude {"))
        XCTAssertFalse(integration.contains("function codex {"))
        XCTAssertTrue(integration.contains("TESSERA_AGENT_SUPPORT_DIR"))
        XCTAssertTrue(integration.contains("$TESSERA_AGENT_INTEGRATION_VERSION:$$:$TESSERA_AGENT_SHIM_VERSION"))
        XCTAssertTrue(integration.contains("printf '%s|%s|%s\\n'"))
        let shimSetup = integration.range(of: #"PATH="$_tessera_agent_bin_dir:$_tessera_agent_clean_path""#)
        let readinessProof = integration.range(of: "printf '%s|%s|%s\\n'")
        XCTAssertNotNil(shimSetup)
        XCTAssertNotNil(readinessProof)
        if let shimSetup, let readinessProof {
            XCTAssertLessThan(
                shimSetup.lowerBound,
                readinessProof.lowerBound,
                "the readiness proof must be published only after shim setup"
            )
        }
    }

    func test_agentShellStatusProbeUsesOnlyValidatedNumericPIDs() {
        let command = RemoteAgentLifecycleIntegrationInstaller.makeShellStatusCommand(
            processIDs: [42, 7, -1, 0]
        )

        XCTAssertTrue(command.contains("for tessera_pid in 7 42"))
        XCTAssertTrue(command.contains("active-shells/$tessera_pid"))
        XCTAssertTrue(command.contains(#"/proc/$tessera_pid/environ"#))
        XCTAssertTrue(command.contains("grep -qFx 'TESSERA_AGENT_INTEGRATION_VERSION=8'"))
        XCTAssertTrue(command.contains("grep -qFx 'TESSERA_AGENT_SHIM_VERSION=8'"))
        XCTAssertFalse(command.contains("TESSERA_AGENT_CLAUDE_WRAPPER_VERSION"))
        XCTAssertFalse(command.contains("TESSERA_AGENT_CODEX_WRAPPER_VERSION"))
        XCTAssertFalse(command.contains("command -v claude"))
        XCTAssertFalse(command.contains("command -v codex"))
        XCTAssertFalse(command.contains("tessera_process_path"))
        XCTAssertTrue(command.contains(#"$start|8"#))
        XCTAssertFalse(command.contains("kill -WINCH"))
        XCTAssertFalse(command.contains(".challenge."))
        XCTAssertTrue(command.contains("tessera_proof=process-identity"))
        XCTAssertTrue(command.contains("ps -o lstart="))
        XCTAssertTrue(command.contains("TESSERA_AGENT_SHELL_DIAG"))
        XCTAssertTrue(command.contains("proof=%s candidates=%s markers=%s identities=%s"))
        XCTAssertTrue(command.contains("TESSERA_AGENT_SHELL_STATUS"))
        XCTAssertFalse(command.contains("-1"))
    }

    func test_agentShellStrictProbeRejectsInheritedEnvironmentFallback() {
        let command = RemoteAgentLifecycleIntegrationInstaller.makeShellStatusCommand(
            processIDs: [42],
            allowInheritedEnvironment: false
        )

        XCTAssertTrue(command.contains("active-shells/$tessera_pid"))
        XCTAssertFalse(command.contains(#"/proc/$tessera_pid/environ"#))
        XCTAssertFalse(command.contains("ps eww"))
    }

    func test_agentShellStatusParserDistinguishesActiveInactiveAndNoise() {
        let marker = RemoteAgentLifecycleIntegrationInstaller.shellStatusMarker

        XCTAssertEqual(
            RemoteAgentLifecycleIntegrationInstaller.parseShellStatus("banner\n\(marker) active\n"),
            true
        )
        XCTAssertEqual(
            RemoteAgentLifecycleIntegrationInstaller.parseShellStatus("\(marker) inactive\n"),
            false
        )
        XCTAssertNil(RemoteAgentLifecycleIntegrationInstaller.parseShellStatus("banner only"))
    }

    func test_agentShellDiagnosticParserAcceptsOnlyContentFreeCounters() {
        let marker = RemoteAgentLifecycleIntegrationInstaller.shellDiagnosticMarker
        XCTAssertEqual(
            RemoteAgentLifecycleIntegrationInstaller.parseShellDiagnostic(
                "banner\n\(marker) proof=process-identity candidates=2 markers=1 identities=1\n"
            ),
            "proof=process-identity candidates=2 markers=1 identities=1"
        )
        XCTAssertNil(
            RemoteAgentLifecycleIntegrationInstaller.parseShellDiagnostic(
                "\(marker) proof=none path=/private/user\n"
            )
        )
    }

    func test_agentHostDiagnosticParserAcceptsOnlyBoundedContentFreeFields() {
        let marker = RemoteAgentLifecycleIntegrationInstaller.hostDiagnosticMarker
        let detail = "readiness=trusted lifecycleProvider=codex lifecycleEvent=SessionStart lifecycleState=idle lifecycleReason=verified-trusted-empty-composer lifecyclePhase=resolved agentPid=present pane=present terminal=present tmuxState=written terminalEmission=written"
        XCTAssertEqual(
            RemoteAgentLifecycleIntegrationInstaller.parseHostDiagnostic(
                "banner\n\(marker) \(detail)\n"
            ),
            detail
        )
        XCTAssertNil(
            RemoteAgentLifecycleIntegrationInstaller.parseHostDiagnostic(
                "\(marker) \(detail) path=/private/user prompt=secret\n"
            )
        )
        XCTAssertNil(
            RemoteAgentLifecycleIntegrationInstaller.parseHostDiagnostic(
                "\(marker) readiness=surprising lifecycleProvider=codex lifecycleEvent=SessionStart lifecycleState=idle lifecycleReason=session-start lifecyclePhase=resolved agentPid=present pane=present terminal=present\n"
            )
        )
    }

    func test_agentInstallationDiagnosticParserAcceptsOnlyBoundedComponentStates() {
        let marker = RemoteAgentLifecycleIntegrationInstaller.installationDiagnosticMarker
        let detail = "files=present configs=present rc=current permissions=secure cksum=available hook=match launcher=match codexReadiness=match claudeShim=match codexShim=match integration=match claudeLegacy=match codexHooks=match codexResume=match claudeHooks=match"
        XCTAssertEqual(
            RemoteAgentLifecycleIntegrationInstaller.parseInstallationDiagnostic(
                "banner\n\(marker) \(detail)\n"
            ),
            detail
        )
        XCTAssertNil(
            RemoteAgentLifecycleIntegrationInstaller.parseInstallationDiagnostic(
                "\(marker) \(detail) path=/private/user prompt=secret\n"
            )
        )
        XCTAssertNil(
            RemoteAgentLifecycleIntegrationInstaller.parseInstallationDiagnostic(
                "\(marker) files=present configs=present rc=current permissions=world-writable\n"
            )
        )
    }

    func test_agentLifecycleShimsPreserveAliasesArgumentsAndUseActiveConfigLayers() {
        let integration = RemoteAgentLifecycleIntegrationInstaller.shellIntegration
        let claudeShim = RemoteAgentLifecycleIntegrationInstaller.claudeShimScript
        let codexShim = RemoteAgentLifecycleIntegrationInstaller.codexShimScript
        let codexReadiness = RemoteAgentLifecycleIntegrationInstaller.codexReadinessScript

        XCTAssertFalse(integration.contains("TESSERA_AGENT_ORIGINAL_PATH"))
        XCTAssertTrue(integration.contains(#"_tessera_agent_remaining_path="${PATH:-}""#))
        XCTAssertTrue(integration.contains(#"PATH="$_tessera_agent_bin_dir:$_tessera_agent_clean_path""#))
        XCTAssertTrue(integration.contains(#"[ "$_tessera_agent_clean_path_started" -eq 1 ]"#))
        XCTAssertTrue(integration.contains("TESSERA_AGENT_SHIM_VERSION=8"))
        XCTAssertTrue(integration.contains(#"if [ "$_tessera_agent_path_entry" != "$_tessera_agent_bin_dir" ]"#))
        XCTAssertTrue(integration.contains("TESSERA_AGENT_SHIM_DIR"))
        XCTAssertFalse(integration.contains("unalias claude"))
        XCTAssertFalse(integration.contains("unalias codex"))
        XCTAssertFalse(integration.contains("function claude {"))
        XCTAssertFalse(integration.contains("function codex {"))
        XCTAssertFalse(integration.contains("allow-dangerously-skip-permissions"))
        XCTAssertEqual(occurrences(of: "unset -f claude", in: integration), 1)
        XCTAssertEqual(occurrences(of: "unset -f codex", in: integration), 1)
        XCTAssertTrue(integration.contains("4|5"))
        XCTAssertTrue(integration.contains("typeset -f claude"))
        XCTAssertTrue(integration.contains("typeset -f codex"))
        XCTAssertTrue(integration.contains("unset TESSERA_AGENT_CLAUDE_WRAPPER_VERSION TESSERA_AGENT_CODEX_WRAPPER_VERSION"))
        XCTAssertTrue(claudeShim.contains(#"remaining_path="${PATH:-}""#))
        XCTAssertTrue(claudeShim.contains(#"candidate="$search_dir/claude""#))
        XCTAssertTrue(claudeShim.contains(#"[ "$candidate" -ef "$shim_path" ]"#))
        XCTAssertTrue(claudeShim.contains("Tessera Agent Center Claude shim"))
        XCTAssertTrue(claudeShim.contains(#"dd if="$candidate" bs=512 count=1"#))
        XCTAssertTrue(claudeShim.contains(#"[ "$candidate_is_tessera_shim" -eq 1 ]"#))
        XCTAssertFalse(claudeShim.contains("--settings"))
        XCTAssertTrue(claudeShim.contains(#"shim_path="$0""#))
        XCTAssertTrue(claudeShim.contains("readlink"))
        XCTAssertTrue(claudeShim.contains("shim_link_depth"))
        XCTAssertTrue(claudeShim.contains(#"provider_path="$(CDPATH= cd -- "$candidate_dir" 2>/dev/null && pwd -P)/$candidate_name""#))
        XCTAssertTrue(claudeShim.contains("TESSERA_AGENT_SUPPORT_DIR"))
        XCTAssertTrue(claudeShim.contains(#"support_dir="${shim_dir%/*}""#))
        XCTAssertFalse(claudeShim.contains(#"${TESSERA_AGENT_SUPPORT_DIR:-"#))
        XCTAssertTrue(claudeShim.contains(#""$@""#))
        XCTAssertTrue(codexShim.contains(#"remaining_path="${PATH:-}""#))
        XCTAssertTrue(codexShim.contains(#"candidate="$search_dir/codex""#))
        XCTAssertTrue(codexShim.contains(#"[ "$candidate" -ef "$shim_path" ]"#))
        XCTAssertTrue(codexShim.contains("Tessera Agent Center Codex shim"))
        XCTAssertTrue(codexShim.contains(#"dd if="$candidate" bs=512 count=1"#))
        XCTAssertTrue(codexShim.contains(#"[ "$candidate_is_tessera_shim" -eq 1 ]"#))
        XCTAssertTrue(codexShim.contains(#"shim_path="$0""#))
        XCTAssertTrue(codexShim.contains("shim_link_depth"))
        XCTAssertTrue(codexShim.contains(#"provider_path="$(CDPATH= cd -- "$candidate_dir" 2>/dev/null && pwd -P)/$candidate_name""#))
        XCTAssertTrue(codexShim.contains("TESSERA_AGENT_SUPPORT_DIR"))
        XCTAssertTrue(codexShim.contains(#"support_dir="${shim_dir%/*}""#))
        XCTAssertFalse(codexShim.contains(#"${TESSERA_AGENT_SUPPORT_DIR:-"#))
        XCTAssertTrue(codexShim.contains("--enable hooks"))
        XCTAssertTrue(codexShim.contains("agent-codex-readiness.sh"))
        XCTAssertTrue(codexShim.contains("TESSERA_AGENT_CODEX_BOOTSTRAP_PROOF"))
        XCTAssertTrue(codexShim.contains(#"2) TESSERA_AGENT_CODEX_BOOTSTRAP_PROOF="$TESSERA_AGENT_INTEGRATION_VERSION:configured""#))
        XCTAssertFalse(codexShim.contains("plugin marketplace add"))
        XCTAssertFalse(codexShim.contains("plugin add"))
        XCTAssertFalse(codexShim.contains("hooks.PermissionRequest="))
        XCTAssertFalse(codexShim.contains("--profile"))
        XCTAssertFalse(codexShim.contains("$HOME/.codex/hooks.json"))
        XCTAssertTrue(codexShim.contains(#""$@""#))
        XCTAssertFalse(claudeShim.contains("dangerously-bypass-hook-trust"))
        XCTAssertFalse(codexShim.contains("dangerously-bypass-hook-trust"))
        XCTAssertTrue(codexReadiness.contains(#"{"id":2,"method":"hooks/list""#))
        XCTAssertTrue(codexReadiness.contains(#"agent-lifecycle-hook.sh\" codex SessionStart idle session-start"#))
        XCTAssertTrue(codexReadiness.contains("eventName"))
        XCTAssertTrue(codexReadiness.contains("sessionStart"))
        XCTAssertTrue(codexReadiness.contains("startup\\|resume\\|clear\\|compact"))
        XCTAssertTrue(codexReadiness.contains("handler-disabled"))
        XCTAssertTrue(codexReadiness.contains("handler-untrusted"))
        XCTAssertTrue(codexReadiness.contains("codex_readiness_diagnostic handler-untrusted\nexit 2"))
        XCTAssertTrue(codexReadiness.contains("isManaged"))
        XCTAssertTrue(codexReadiness.contains(#"session_record="$("#))
        XCTAssertTrue(codexReadiness.contains(#"printf '%s\n' "$session_record""#))
        XCTAssertTrue(codexReadiness.contains("mkfifo"))
        XCTAssertTrue(codexReadiness.contains("initialize-timeout"))
        XCTAssertTrue(codexReadiness.contains("hooks-list-timeout"))
        XCTAssertFalse(codexReadiness.contains("sleep 0.25"))
        XCTAssertFalse(codexReadiness.contains("sleep 0.5"))
        XCTAssertTrue(codexReadiness.contains("--profile"))
        XCTAssertTrue(codexReadiness.contains("--cd"))
        XCTAssertTrue(codexReadiness.contains("-p?*"))
        XCTAssertTrue(codexReadiness.contains("-C?*"))
        XCTAssertTrue(codexReadiness.contains("-c?*"))
        XCTAssertTrue(codexReadiness.contains("--strict-config"))
        XCTAssertTrue(codexReadiness.contains("disabled-by-arguments"))
        XCTAssertTrue(codexReadiness.contains("dangerously-bypass-hook-trust"))
    }

    func test_agentProviderLauncherRequiresExactCodexReadinessProofAndExecsExactlyOnce() {
        let launcher = RemoteAgentLifecycleIntegrationInstaller.launcherScript

        XCTAssertTrue(launcher.contains("TESSERA_AGENT_INTEGRATION_VERSION=8"))
        XCTAssertTrue(launcher.contains(#"case "$provider" in claude|codex)"#))
        XCTAssertEqual(occurrences(of: #"exec "$@""#, in: launcher), 1)
        XCTAssertTrue(launcher.contains("TESSERA_AGENT_CODEX_BOOTSTRAP_PROOF"))
        XCTAssertTrue(launcher.contains(#"support_dir="${0%/*}""#))
        XCTAssertFalse(launcher.contains(#"${TESSERA_AGENT_SUPPORT_DIR:-"#))
        XCTAssertTrue(launcher.contains("agent-lifecycle-hook.sh"))
        XCTAssertTrue(launcher.contains("verified-trusted-empty-composer"))
        XCTAssertTrue(launcher.contains("verified-configured-empty-composer"))
        XCTAssertTrue(launcher.contains(#"TESSERA_AGENT_VERIFIED_PROVIDER_PID="$$""#))
        XCTAssertFalse(launcher.contains("WrapperStart"))
        XCTAssertFalse(launcher.contains("TESSERA_AGENT_LAUNCH_PID"))
        XCTAssertFalse(launcher.contains("dangerously-bypass-hook-trust"))
    }

    func test_agentPersistentActivationTargetsTheActualInteractiveShell() {
        let command = RemoteAgentLifecycleIntegrationInstaller
            .persistAndApplyToCurrentShellCommand

        XCTAssertTrue(command.contains(#"[ -n "${ZSH_VERSION:-}" ]"#))
        XCTAssertTrue(command.contains(#"${ZDOTDIR:-$HOME}/.zshrc"#))
        XCTAssertTrue(command.contains(#"[ -n "${BASH_VERSION:-}" ]"#))
        XCTAssertTrue(command.contains(#"$HOME/.bashrc"#))
        XCTAssertTrue(command.contains(#"$HOME/.bash_profile"#))
        XCTAssertTrue(command.contains(RemoteAgentLifecycleIntegrationInstaller.rcMarkerLine))
        XCTAssertTrue(command.contains(RemoteAgentLifecycleIntegrationInstaller.bashLoginMarkerLine))
        XCTAssertTrue(command.contains(RemoteAgentLifecycleIntegrationInstaller.applyToCurrentShellCommand))
        XCTAssertTrue(command.contains("grep -qFx"))
        XCTAssertTrue(command.contains("tail -c 1"))
    }

    private func occurrences(of needle: String, in haystack: String) -> Int {
        var count = 0
        var searchRange = haystack.startIndex..<haystack.endIndex
        while let range = haystack.range(of: needle, range: searchRange) {
            count += 1
            searchRange = range.upperBound..<haystack.endIndex
        }
        return count
    }
}
