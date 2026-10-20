import CryptoKit
import Foundation
import XCTest
@testable import TesseraAgentCore

/// A host is shared by every Tessera build that reaches it. These run the
/// generated programs against a private HOME, so the transitions are proven
/// on the shell that executes them rather than by inspecting command text.
final class AgentIntegrationVersioningTests: XCTestCase {
    private typealias Installer = RemoteAgentLifecycleIntegrationInstaller
    private var home: URL!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("tessera-versioning-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    // MARK: - Version discipline

    /// Changing any installed byte without a new `integrationVersion` makes
    /// two different installations claim one version, and apps that disagree
    /// about which is current overwrite each other on every connection.
    func testInstalledContentMatchesItsRecordedVersion() {
        let version = Installer.integrationVersion
        let fingerprint = Self.integrationContentFingerprint()
        let release = Installer.IntegrationRelease(
            fingerprint: fingerprint,
            eventVersion: Installer.lifecycleEventVersion,
            nativeRevision: AgentHostBuildRevision.sourceSHA256
        )
        if let recorded = Installer.integrationReleases[version] {
            // The fingerprint covers the version number itself, so the entry
            // for the next version can only be printed after the bump.
            XCTAssertEqual(
                recorded, release,
                "Installed integration content changed under a released version. Set integrationVersion to \(version + 1), then record the entry this test prints; never edit an existing entry."
            )
        } else {
            XCTFail("Record in integrationReleases: \(version): .init(fingerprint: \"\(fingerprint)\", eventVersion: \(release.eventVersion), nativeRevision: \"\(release.nativeRevision)\"),")
        }
        let fingerprints = Installer.integrationReleases.values.map(\.fingerprint)
        XCTAssertEqual(Set(fingerprints).count, fingerprints.count, "Two versions cannot share one content fingerprint")
        XCTAssertEqual(Installer.integrationReleases.keys.max(), version)
        XCTAssertLessThanOrEqual(Installer.integrationCompatibleFrom, version)
    }

    /// An app older than the hook's event schema reads a newer installation
    /// as current yet drops every event it sends; the floor must exclude it.
    func testCompatibilityFloorCoversTheHookEventSchema() {
        for version in Installer.integrationCompatibleFrom...Installer.integrationVersion {
            // An unrecorded version is reported by the fingerprint test.
            guard let release = Installer.integrationReleases[version] else { continue }
            XCTAssertEqual(
                release.eventVersion, Installer.lifecycleEventVersion,
                "An app at integration \(version) predates this hook's event schema: raise integrationCompatibleFrom"
            )
        }
    }

    /// Every release since `shellIntegrationCompatibleFrom` counts an open
    /// shell it did not load as active, so a changed agent-lifecycle.sh must
    /// raise that floor; otherwise shells holding the old script's state
    /// would never be asked to reload it.
    func testShellFloorCoversTheShellScript() {
        let digest = SHA256.hash(data: Data(Installer.shellIntegration(version: 0).utf8))
        let fingerprint = digest.map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(
            "\(Installer.shellIntegrationCompatibleFrom) \(fingerprint)", Self.shellScriptAtFloor,
            "agent-lifecycle.sh changed: set shellIntegrationCompatibleFrom to \(Installer.integrationVersion) and shellScriptAtFloor to \"\(Installer.integrationVersion) \(fingerprint)\""
        )
        XCTAssertEqual(Installer.shellIntegration, Installer.shellIntegration(version: Installer.integrationVersion))
        XCTAssertLessThanOrEqual(Installer.integrationCompatibleFrom, Installer.shellIntegrationCompatibleFrom)
        XCTAssertLessThanOrEqual(Installer.shellIntegrationCompatibleFrom, Installer.integrationVersion)
    }

    /// agent-lifecycle.sh is unchanged apart from its version since 10.
    private static let shellScriptAtFloor = "10 3f0c943440dbfef122d3c49347e6da7aa04c5f716b8713e4b8783920e5a72000"

    func testHookSerializesPanePublicationBeforeCodexClaims() throws {
        let hook = Installer.hookScript
        XCTAssertTrue(hook.contains("tessera_agent_foreground_status()"))
        XCTAssertTrue(hook.contains(#"tmux show-options -pqv -t "$pane" @tessera_agent_state"#))
        let paneLock = try XCTUnwrap(hook.range(of: #"lock=exclusive(os.path.join(directory,"pane-"+key+".delivery.lock"))"#))
        let pidLock = try XCTUnwrap(hook.range(of: #"lock=exclusive(os.path.join(directory,str(pid)+".delivery.lock"))"#))
        let retainedRead = try XCTUnwrap(hook.range(of: #"retained=json.loads(command(["tmux","show-options""#))
        XCTAssertLessThan(paneLock.lowerBound, pidLock.lowerBound)
        XCTAssertLessThan(pidLock.lowerBound, retainedRead.lowerBound)
        XCTAssertTrue(hook.contains("#{pid}:#{socket_path}"))
        XCTAssertTrue(hook.contains("600000000000"))
        XCTAssertTrue(hook.contains(#"elif stale: tmux_state="stale""#))
        XCTAssertTrue(hook.contains("tmux_state=deferred"))
        XCTAssertTrue(hook.contains("terminal_emission=deferred"))
        XCTAssertTrue(hook.contains(#"if defer_pane: tmux_state="deferred""#))
        XCTAssertTrue(hook.contains(#"if defer_pane: emission="deferred""#))
    }

    func testProcessProofAddsOptionalForegroundOwnership() {
        let proof = Installer.processProofScript
        XCTAssertTrue(proof.contains(#"request.get("requireForeground") is True and is_foreground is False"#))
        XCTAssertTrue(proof.contains(#"fail("backgroundProcess")"#))
        XCTAssertTrue(proof.contains(#""foreground":is_foreground"#))
        XCTAssertTrue(proof.contains("pgid > 0 and tpgid > 0 else None"))
    }

    func testCodexRecoveryFollowsTheExactNativeLauncherChild() {
        let recovery = Installer.codexConversationRecoveryScript
        XCTAssertTrue(recovery.contains("def is_codex_launcher(pid):"))
        XCTAssertTrue(recovery.contains("def native_codex_child(pid, start_token):"))
        XCTAssertTrue(recovery.contains("if len(candidates) != 1:"))
        XCTAssertTrue(recovery.contains("child_lock = observer_lock(child_pid)"))
        XCTAssertTrue(recovery.contains("watch_loop(child_pid, child_start, bootstrap=child_pid != pid)"))
        XCTAssertTrue(Installer.hookScript.contains(#"if previous is not None: sys.exit(3)"#))
    }

    func testHostDiagnosticProbeAndParserPreserveDeferredPublication() throws {
        let detail = "readiness=none lifecycleProvider=codex lifecycleEvent=SessionStart lifecycleState=idle lifecycleReason=session-start lifecyclePhase=resolved agentPid=present pane=present terminal=present tmuxState=deferred terminalEmission=deferred"
        XCTAssertEqual(Installer.parseHostDiagnostic("\(Installer.hostDiagnosticMarker) \(detail)"), detail)
        try FileManager.default.createDirectory(at: tesseraDirectory, withIntermediateDirectories: true)
        let diagnostic = "0 provider=codex event=SessionStart state=idle reason=session-start phase=resolved agentPid=present pane=present terminal=present tmuxState=deferred terminalEmission=deferred\n"
        try Data(diagnostic.utf8).write(to: tesseraDirectory.appendingPathComponent("agent-lifecycle-diagnostics.log"))
        XCTAssertEqual(Installer.parseHostDiagnostic(try run(Installer.makeStatusCommand())), detail)
    }

    func testHostDiagnosticProbeAndParserPreserveStalePublication() throws {
        let detail = "readiness=none lifecycleProvider=claude lifecycleEvent=SessionEnd lifecycleState=unavailable lifecycleReason=session-ended lifecyclePhase=resolved agentPid=present pane=present terminal=present tmuxState=stale terminalEmission=written"
        XCTAssertEqual(Installer.parseHostDiagnostic("\(Installer.hostDiagnosticMarker) \(detail)"), detail)
        try FileManager.default.createDirectory(at: tesseraDirectory, withIntermediateDirectories: true)
        let diagnostic = "0 provider=claude event=SessionEnd state=unavailable reason=session-ended phase=resolved agentPid=present pane=present terminal=present tmuxState=stale terminalEmission=written\n"
        try Data(diagnostic.utf8).write(to: tesseraDirectory.appendingPathComponent("agent-lifecycle-diagnostics.log"))
        XCTAssertEqual(Installer.parseHostDiagnostic(try run(Installer.makeStatusCommand())), detail)
    }

    func testHookPublishesEventSchemaSeparatelyFromInstallationVersion() throws {
        let hook = Installer.hookScript
        XCTAssertTrue(hook.contains("\nTESSERA_AGENT_INTEGRATION_VERSION=\(Installer.integrationVersion)\n"))
        XCTAssertTrue(hook.contains("\nTESSERA_AGENT_INTEGRATION_COMPATIBLE_FROM=\(Installer.integrationCompatibleFrom)\n"))
        XCTAssertTrue(hook.contains("\nTESSERA_AGENT_EVENT_VERSION=\(Installer.lifecycleEventVersion)\n"))
        XCTAssertTrue(hook.contains(#""rootAgentId":"%s"}' "$TESSERA_AGENT_EVENT_VERSION""#))
        XCTAssertFalse(hook.contains(#"}' "$TESSERA_AGENT_INTEGRATION_VERSION""#))
        XCTAssertTrue(AgentLifecycleEnvelope.compatibleVersions.contains(Installer.lifecycleEventVersion))
        var stamped = 0
        for (_, _, path, contents, _) in Installer.ownedFiles {
            for line in contents.components(separatedBy: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                for key in ["TESSERA_AGENT_INTEGRATION_VERSION=", "TESSERA_AGENT_SHIM_VERSION="] where trimmed.hasPrefix(key) {
                    XCTAssertEqual(trimmed, key + String(Installer.integrationVersion), path)
                    stamped += 1
                }
            }
        }
        XCTAssertGreaterThanOrEqual(stamped, 7, "every versioned script must stamp integrationVersion")
    }

    // MARK: - Installation probe

    func testProbeTransitionsAcrossInstallationVersions() throws {
        XCTAssertEqual(try status(), .missing)

        let installOutput = try run(Installer.makeInstallCommand())
        XCTAssertEqual(Installer.classifyInstallOutput(installOutput), .completed, installOutput)
        XCTAssertEqual(try status(), .current)

        // An older installation is this app's to update.
        try rewriteHook(version: Installer.integrationVersion - 1, floor: nil)
        XCTAssertEqual(try status(), .outdated(version: Installer.integrationVersion - 1))

        // Same version, different bytes: a damaged install is repaired.
        try rewriteHook(version: Installer.integrationVersion, floor: Installer.integrationCompatibleFrom, extra: "# edited\n")
        XCTAssertEqual(try status(), .outdated(version: Installer.integrationVersion))

        // A complete newer installation that admits this app is used as is.
        try rewriteHook(version: Installer.integrationVersion + 1, floor: Installer.integrationVersion)
        XCTAssertEqual(try status(), .current)
        XCTAssertTrue(try run(Installer.makeStatusCommand()).contains("\(Installer.statusMarker) newer:\(Installer.integrationVersion + 1)"))

        // One missing what this app runs cannot be repaired here without a
        // downgrade: a file the floor promised is gone, so only the newer app
        // (or updating this one) can fix it.
        try FileManager.default.removeItem(at: tesseraDirectory.appendingPathComponent("agent-launch.sh"))
        XCTAssertEqual(try status(), .requiresAppUpdate(version: Installer.integrationVersion + 1))

        // A newer installation that no longer admits this app is left alone.
        try rewriteHook(version: Installer.integrationVersion + 1, floor: Installer.integrationVersion + 1)
        XCTAssertEqual(try status(), .requiresAppUpdate(version: Installer.integrationVersion + 1))

        // Without a floor, a newer installation admits only its own version.
        try rewriteHook(version: Installer.integrationVersion + 1, floor: nil)
        XCTAssertEqual(try status(), .requiresAppUpdate(version: Installer.integrationVersion + 1))
    }

    func testInstallRefusesToReplaceANewerInstallation() throws {
        try FileManager.default.createDirectory(at: tesseraDirectory, withIntermediateDirectories: true)
        let newer = Installer.integrationVersion + 1
        try rewriteHook(version: newer, floor: Installer.integrationVersion)
        let hookBefore = try Data(contentsOf: hookURL)

        let output = try run(Installer.makeInstallCommand())

        XCTAssertEqual(Installer.classifyInstallOutput(output), .failed(reason: .newerInstalled, detail: output))
        XCTAssertTrue(output.contains("\(Installer.newerInstallationMarker) \(newer)"))
        XCTAssertEqual(try Data(contentsOf: hookURL), hookBefore)
        for name in ["agent-launch.sh", "agent-lifecycle.sh", "bin/claude"] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: tesseraDirectory.appendingPathComponent(name).path), name)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent(".codex/hooks.json").path))
    }

    func testInterruptedNewerInstallationIsNotReportedCurrent() throws {
        XCTAssertEqual(Installer.classifyInstallOutput(try run(Installer.makeInstallCommand())), .completed)
        try rewriteHook(version: Installer.integrationVersion + 1, floor: Installer.integrationVersion)
        // Provider configs follow the manifest; a run that stopped there left
        // them to the newer app.
        try FileManager.default.removeItem(at: home.appendingPathComponent(".codex/hooks.json"))
        XCTAssertEqual(try status(), .requiresAppUpdate(version: Installer.integrationVersion + 1))
    }

    func testOnlyTheOwnersRegularManifestCanClaimANewerVersion() async throws {
        let newer = Installer.integrationVersion + 1
        XCTAssertEqual(Installer.classifyInstallOutput(try run(Installer.makeInstallCommand())), .completed)
        // The status command's own diagnostic line must parse: a hand-built
        // fixture once hid two fields the real line carries.
        XCTAssertNotNil(Installer.parseInstallationDiagnostic(try run(Installer.makeStatusCommand())))

        // The owner decides the directory's mode: a umask 0002 host writes it
        // group-writable, and a manifest there still counts. A newer install
        // that admits this app is honoured, never repaired down.
        try rewriteHook(version: newer, floor: Installer.integrationVersion)
        try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: tesseraDirectory.path)
        XCTAssertEqual(try status(), .current)
        XCTAssertTrue(try run(Installer.makeStatusCommand()).contains("\(Installer.statusMarker) newer:\(newer)"))
        let refused = try run(Installer.makeInstallCommand())
        XCTAssertEqual(Installer.classifyInstallOutput(refused), .failed(reason: .newerInstalled, detail: refused))
        XCTAssertEqual(try installedVersionLine(), "TESSERA_AGENT_INTEGRATION_VERSION=\(newer)")
        try rewriteHook(version: Installer.integrationVersion, floor: Installer.integrationCompatibleFrom, extra: "# edited\n")
        try await Installer.install { try self.run($0) }
        XCTAssertEqual(try status(), .current)
        XCTAssertEqual(try installedVersionLine(), "TESSERA_AGENT_INTEGRATION_VERSION=\(Installer.integrationVersion)")

        // A symlinked manifest is not a manifest.
        try rewriteHook(version: newer, floor: Installer.integrationVersion)
        let elsewhere = home.appendingPathComponent("elsewhere.sh")
        try FileManager.default.moveItem(at: hookURL, to: elsewhere)
        try FileManager.default.createSymbolicLink(at: hookURL, withDestinationURL: elsewhere)
        XCTAssertNotEqual(try status(), .current)
        try await Installer.install { try self.run($0) }
        XCTAssertEqual(try status(), .current)

        // An implausible version is no version.
        try rewriteHook(version: 99_999, floor: 99_999)
        XCTAssertEqual(try status(), .outdated(version: nil))
        try await Installer.install { try self.run($0) }
        XCTAssertEqual(try status(), .current)
    }

    func testInstallKeepsANewerManifestThatLandsMidInstall() throws {
        let newer = Installer.integrationVersion + 1
        let command = Installer.makeInstallCommand()
        let compareAndSwap = "{ " + Installer.installedVersionProbe
        let halves = command.components(separatedBy: compareAndSwap)
        XCTAssertEqual(halves.count, 2, "the manifest write re-checks the installed version")
        // Another device's newer install completes while this one runs.
        let race = "printf '%s\\n' 'TESSERA_AGENT_INTEGRATION_VERSION=\(newer)' 'TESSERA_AGENT_INTEGRATION_COMPATIBLE_FROM=\(Installer.integrationVersion)' > \"$HOME/.config/tessera/agent-lifecycle-hook.sh\" && "

        let output = try run(halves[0] + race + compareAndSwap + halves[1])

        XCTAssertEqual(Installer.classifyInstallOutput(output), .failed(reason: .newerInstalled, detail: output))
        XCTAssertEqual(try installedVersionLine(), "TESSERA_AGENT_INTEGRATION_VERSION=\(newer)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent(".codex/hooks.json").path),
                       "provider configs stay the newer app's")
    }

    func testInstallUpgradesAnOlderInstallation() async throws {
        try await Installer.install { try self.run($0) }
        try rewriteHook(version: Installer.integrationVersion - 1, floor: nil)
        XCTAssertEqual(try status(), .outdated(version: Installer.integrationVersion - 1))

        try await Installer.install { try self.run($0) }

        XCTAssertEqual(try status(), .current)
    }

    func testStatusParserMapsNewerAndUnsupportedInstallations() {
        let marker = Installer.statusMarker
        XCTAssertEqual(Installer.parseStatus("\(marker) newer:12\n"), .current)
        XCTAssertEqual(Installer.parseStatus("\(marker) unsupported:12\n"), .requiresAppUpdate(version: 12))
        XCTAssertEqual(Installer.parseStatus("\(marker) unsupported:\n"), .requiresAppUpdate(version: nil))
        XCTAssertEqual(Installer.parseStatus("\(marker) unsupported:99999\n"), .requiresAppUpdate(version: nil))
        XCTAssertEqual(Installer.parseStatus("\(marker) outdated:+9\n"), .outdated(version: nil))
        XCTAssertEqual(Installer.parseStatus("\(marker) outdated:0\n"), .outdated(version: nil))
        XCTAssertEqual(Installer.parseStatus("\(marker) outdated:9\n"), .outdated(version: 9))
    }

    // MARK: - Shell activation probe

    func testShellMarkerFromAnyReleaseSinceTheShellFloorProvesActivation() throws {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["30"]
        try child.run()
        defer { child.terminate(); child.waitUntilExit() }
        let pid = Int(child.processIdentifier)
        let start = try processStart(pid)
        let markers = tesseraDirectory.appendingPathComponent("active-shells")
        try FileManager.default.createDirectory(at: markers, withIntermediateDirectories: true)
        let marker = markers.appendingPathComponent(String(pid))
        let command = Installer.makeShellStatusCommand(processIDs: [pid], allowInheritedEnvironment: false)
        // The probe runs in the user's login shell; ksh93 reads a bare `|` in
        // a pattern as alternation.
        let shells = ["/bin/sh", "/bin/dash", "/bin/bash", "/bin/zsh", "/bin/ksh"]
            .filter { FileManager.default.isExecutableFile(atPath: $0) }
        XCTAssertGreaterThanOrEqual(shells.count, 2)
        for shell in shells {
            func active(_ contents: String) throws -> Bool? {
                try Data((contents + "\n").utf8).write(to: marker)
                return Installer.parseShellStatus(try run(command, shell: shell))
            }
            let current = Installer.integrationVersion
            let floor = Installer.shellIntegrationCompatibleFrom
            XCTAssertEqual(try active("\(current)|\(start)|\(current)"), true, shell)
            XCTAssertEqual(try active("\(current + 1)|\(start)|\(current + 1)"), true, shell)
            // A shell loaded before this release's update holds the same state.
            XCTAssertEqual(try active("\(floor)|\(start)|\(floor)"), true, shell)
            XCTAssertEqual(try active("\(floor - 1)|\(start)|\(floor - 1)"), false, shell)
            XCTAssertEqual(try active("\(current)|\(start)|\(current + 1)"), false, shell)
            XCTAssertEqual(try active("\(current)|ps:Thu Jan  1 00:00:00 1970|\(current)"), false, shell)
            XCTAssertEqual(try active("x\(current)|\(start)|x\(current)"), false, shell)
        }
    }

    /// The field case: a shell that sourced an older release's
    /// agent-lifecycle.sh before its host was updated. It holds everything
    /// this release's script would give it, so it must not be reported as
    /// inactive; a shell from before the floor still must be.
    func testShellThatLoadedAnOlderReleaseStaysActiveAfterAnUpdate() throws {
        let bin = tesseraDirectory.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        for shim in ["claude", "codex"] {
            let url = bin.appendingPathComponent(shim)
            try Data("#!/bin/sh\n".utf8).write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
        let script = tesseraDirectory.appendingPathComponent("agent-lifecycle.sh")
        let floor = Installer.shellIntegrationCompatibleFrom
        let shells = ["/bin/bash", "/bin/zsh"].filter { FileManager.default.isExecutableFile(atPath: $0) }
        XCTAssertFalse(shells.isEmpty)
        for shell in shells {
            for (loaded, expected) in [(floor, true), (floor - 1, false)] {
                try Data(Installer.shellIntegration(version: loaded).utf8).write(to: script)
                // Source that release's script, then stay alive as an open
                // shell would. Never inherit the runner's tmux pane: the
                // script would mark it.
                let child = Process()
                child.executableURL = URL(fileURLWithPath: shell)
                child.arguments = ["-c", #". "$HOME/.config/tessera/agent-lifecycle.sh"; exec sleep 30"#]
                var environment = ProcessInfo.processInfo.environment
                environment["HOME"] = home.path
                for key in ["TMUX", "TMUX_PANE", "TESSERA_AGENT_INTEGRATION_VERSION", "TESSERA_AGENT_SHIM_VERSION"] {
                    environment[key] = nil
                }
                child.environment = environment
                try child.run()
                defer { child.terminate(); child.waitUntilExit() }
                let pid = Int(child.processIdentifier)
                let marker = tesseraDirectory.appendingPathComponent("active-shells/\(pid)")
                let deadline = Date().addingTimeInterval(10)
                while (try? String(contentsOf: marker, encoding: .utf8))?.hasPrefix("\(loaded)|") != true, Date() < deadline {
                    Thread.sleep(forTimeInterval: 0.05)
                }
                XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path), "\(shell) never sourced release \(loaded)")
                for inherited in [false, true] {
                    let command = Installer.makeShellStatusCommand(processIDs: [pid], allowInheritedEnvironment: inherited)
                    XCTAssertEqual(Installer.parseShellStatus(try run(command)), expected,
                                   "\(shell) loaded \(loaded), inherited environment \(inherited)")
                }
            }
        }
    }

    // MARK: - Native host

    func testNativeActivationNeverReplacesANewerIntegrationsHost() throws {
        try FileManager.default.createDirectory(at: tesseraDirectory, withIntermediateDirectories: true)
        let request = AgentHostDeployment.Request(
            operation: "activate", upload: String(repeating: "a", count: 32),
            sha256: String(repeating: "b", count: 64), bytes: 16
        )
        let command = try AgentHostDeployment.command(request)
        let payload = try XCTUnwrap(command.components(separatedBy: "<<'TESSERA_ARTIFACT_REQUEST'\n").last?.components(separatedBy: "\n").first)
        let stamped = try JSONDecoder().decode(AgentHostDeployment.Request.self, from: XCTUnwrap(Data(base64Encoded: payload)))
        XCTAssertEqual(stamped.integration, Installer.integrationVersion)

        try rewriteHook(version: Installer.integrationVersion + 1, floor: Installer.integrationVersion)
        XCTAssertTrue(try deployment(payload: payload).contains("newerIntegrationInstalled"))

        // The same activation proceeds past the guard (and fails later only
        // because this fixture staged no artifact) for an older host.
        try rewriteHook(version: Installer.integrationVersion - 1, floor: nil)
        let older = try deployment(payload: payload)
        XCTAssertFalse(older.contains("newerIntegrationInstalled"), older)
        XCTAssertTrue(older.contains("FileNotFoundError"), older)
    }

    // MARK: - Fixtures

    private var tesseraDirectory: URL { home.appendingPathComponent(".config/tessera") }
    private var hookURL: URL { tesseraDirectory.appendingPathComponent("agent-lifecycle-hook.sh") }

    private func status() throws -> AgentLifecycleHostInstallation? {
        Installer.parseStatus(try run(Installer.makeStatusCommand()))
    }

    /// Replaces the installed hook's version header, which is what another
    /// Tessera build would have written there.
    private func rewriteHook(version: Int, floor: Int?, extra: String = "") throws {
        var lines = Installer.hookScript.components(separatedBy: "\n").filter {
            !$0.hasPrefix("TESSERA_AGENT_INTEGRATION_VERSION=")
                && !$0.hasPrefix("TESSERA_AGENT_INTEGRATION_COMPATIBLE_FROM=")
        }
        var header = ["TESSERA_AGENT_INTEGRATION_VERSION=\(version)"]
        if let floor { header.append("TESSERA_AGENT_INTEGRATION_COMPATIBLE_FROM=\(floor)") }
        lines.insert(contentsOf: header, at: 4)
        try Data((lines.joined(separator: "\n") + "\n" + extra).utf8).write(to: hookURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: hookURL.path)
    }

    private func installedVersionLine() throws -> String? {
        try String(contentsOf: hookURL, encoding: .utf8).components(separatedBy: "\n")
            .first { $0.hasPrefix("TESSERA_AGENT_INTEGRATION_VERSION=") }
    }

    private func run(_ command: String, shell: String = "/bin/sh") throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-c", command]
        process.currentDirectoryURL = home
        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = home.path
        environment["SHELL"] = "/bin/zsh"
        environment["ZDOTDIR"] = home.path
        for key in ["CODEX_HOME", "CLAUDE_CONFIG_DIR", "KIMI_CODE_HOME", "TESSERA_AGENT_INTEGRATION_VERSION", "TESSERA_AGENT_SHIM_VERSION"] {
            environment[key] = nil
        }
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    /// Runs the deployment program with its account lookup pointed at the
    /// fixture HOME; the program resolves home from the password database,
    /// never from `$HOME`.
    private func deployment(payload: String) throws -> String {
        let program = home.appendingPathComponent("deploy.py")
        try Data(AgentHostDeployment.program.utf8).write(to: program)
        let wrapper = "import pwd,sys\nclass Account: pw_dir=sys.argv[1]\npwd.getpwuid=lambda uid: Account\nsys.argv=sys.argv[:1]\nexec(compile(open(\(Self.pythonQuoted(program.path))).read(),'deploy','exec'))"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", "-c", wrapper, home.path]
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = output
        try process.run()
        input.fileHandleForWriting.write(Data((payload + "\n").utf8))
        try input.fileHandleForWriting.close()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    private func processStart(_ pid: Int) throws -> String {
        let value = try run("ps -o lstart= -p \(pid) | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'")
            .trimmingCharacters(in: .newlines)
        XCTAssertFalse(value.isEmpty)
        return "ps:" + value
    }

    private static func pythonQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'") + "'"
    }

    /// Everything an install writes that another build must not mistake for
    /// its own: support files, provider hook blocks, startup lines, and the
    /// bundled native host.
    static func integrationContentFingerprint() -> String {
        var parts = Installer.ownedFiles.map { "\($0.2)\n\($0.3)" }
        parts.append(Installer.codexHooks)
        parts.append(Installer.claudeSettings)
        parts.append(Installer.kimiHooksBlock)
        parts.append(Installer.rcMarkerLine)
        parts.append(Installer.bashLoginMarkerLine)
        parts.append(AgentHostBuildRevision.sourceSHA256)
        parts += AgentHostBuildRevision.artifacts.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
        let digest = SHA256.hash(data: Data(parts.joined(separator: "\n\u{0}\n").utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
