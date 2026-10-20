import Foundation
import Darwin

/// The production source also has convenience overloads for the app's
/// FileBridge. The host dumper never calls them; this compile-only shape keeps
/// the single source file self-contained without pulling the iOS SSH stack
/// into a tiny command-line tool.
final class FileBridge {
    func connect() async throws {}
    func exec(_ command: String, inShell: Bool) async throws -> String { "" }
}

/// The same input fields used by native composer assessment. Keeping captured
/// SGR and cursor coordinates together lets host tests exercise the production
/// guard rather than a second prompt-row regular expression.
private struct ComposerAssessmentRequest: Decodable {
    let provider: String
    let visibleText: String
    let cursorLine: String?
    let text: String?
    let cursorRow: Int?
    let cursorColumn: Int?
    let cursorVisible: Bool?
    let requireEmpty: Bool?
    let queueWhenWorking: Bool?
    let bracketedPasteEnabled: Bool?
    let screen: TerminalScreenEvidence?
}

/// Tiny host-side bridge used by the credentialed integration gate. Compiled
/// together with the production installer source so the E2E installs and runs
/// the exact scripts shipped by the app instead of maintaining another copy.
@main
struct AgentIntegrationSourceDump {
    static func main() async throws {
        guard CommandLine.arguments.count >= 2 else {
            FileHandle.standardError.write(Data("usage: dump install-command|status-command|read-codex|read-claude|read-kimi|shell-status [pid ...]|persist-shell|hook|launcher|projector|semantic-launcher|process-proof|codex-readiness|claude-shim|codex-shim|shell|composer-assess < request.json\n".utf8))
            exit(64)
        }
        switch CommandLine.arguments[1] {
        case "composer-assess":
            // Match the native ABI budget, including optional physical cells.
            let limit = 2 * 1_024 * 1_024
            var data = Data()
            while data.count <= limit {
                guard let chunk = try FileHandle.standardInput.read(upToCount: min(65_536, limit + 1 - data.count)),
                      !chunk.isEmpty else { break }
                data.append(chunk)
            }
            guard !data.isEmpty, data.count <= limit,
                  let request = try? JSONDecoder().decode(ComposerAssessmentRequest.self, from: data)
            else {
                FileHandle.standardError.write(Data("invalid composer assessment request\n".utf8))
                exit(65)
            }
            let text = request.text ?? ""
            let queue = request.queueWhenWorking == true
            let safety = AgentComposerEvidence.safety(provider: request.provider, visibleText: request.visibleText,
                cursorRow: request.cursorRow, cursorColumn: request.cursorColumn, cursorVisible: request.cursorVisible,
                requireEmpty: request.requireEmpty == true, queueWhenWorking: queue, text: text, screen: request.screen)
            let assessment: String
            switch safety {
            case .readyReturn: assessment = "readyReturn"
            case .readyTab: assessment = "readyTab"
            case .blocked: assessment = "blocked"
            case .occupied: assessment = "occupied"
            case .unavailable: assessment = "unavailable"
            }
            let presence: String
            switch AgentComposerEvidence.presence(provider: request.provider, visibleText: request.visibleText,
                cursorLine: request.cursorLine, text: text, cursorRow: request.cursorRow) {
            case .present: presence = "present"
            case .absent: presence = "absent"
            case .unavailable: presence = "unavailable"
            }
            let submissionKey = AgentComposerEvidence.submissionKey(provider: request.provider,
                visibleText: request.visibleText, cursorLine: request.cursorLine, text: text,
                queueWhenWorking: queue, cursorRow: request.cursorRow)
            let insertion = AgentTextInsertion.bytes(provider: request.provider, text: text,
                bracketedPasteEnabled: request.bracketedPasteEnabled == true)
            let output: [String: Any] = [
                "assessment": assessment,
                "presence": presence,
                "submissionKey": submissionKey.map { $0 == .tab ? "tab" : "return" } as Any? ?? NSNull(),
                "insertionBase64": insertion?.base64EncodedString() as Any? ?? NSNull(),
                "shape": AgentComposerEvidence.diagnosticShape(provider: request.provider,
                    visibleText: request.visibleText, cursorRow: request.cursorRow, cursorColumn: request.cursorColumn,
                    cursorVisible: request.cursorVisible, screen: request.screen),
            ]
            let encoded = try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys])
            FileHandle.standardOutput.write(encoded)
            FileHandle.standardOutput.write(Data("\n".utf8))
        case "install-local":
            guard ProcessInfo.processInfo.environment["TESSERA_ALLOW_LOCAL_AGENT_INSTALL"] == "1" else { exit(64) }
            try await RemoteAgentLifecycleIntegrationInstaller.install { command in
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/bin/sh")
                process.arguments = ["-c", command]
                let output = Pipe()
                process.standardOutput = output
                process.standardError = output
                try process.run()
                let data = output.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                guard process.terminationStatus == 0 else { throw NSError(domain: "LocalAgentInstall", code: Int(process.terminationStatus)) }
                return String(decoding: data, as: UTF8.self)
            }
            print("TESSERA_AGENT_INTEGRATION_INSTALLED current")
        case "install-command":
            print(RemoteAgentLifecycleIntegrationInstaller.makeInstallCommand())
        case "status-command":
            print(RemoteAgentLifecycleIntegrationInstaller.makeStatusCommand())
        case "read-codex":
            print(RemoteAgentLifecycleIntegrationInstaller.makeCodexHooksReadCommand())
        case "read-claude":
            print(RemoteAgentLifecycleIntegrationInstaller.makeClaudeSettingsReadCommand())
        case "read-kimi":
            print(RemoteAgentLifecycleIntegrationInstaller.makeKimiConfigReadCommand())
        case "shell-status":
            let processIDs = Set(CommandLine.arguments.dropFirst(2).compactMap(Int.init))
            print(RemoteAgentLifecycleIntegrationInstaller.makeShellStatusCommand(
                processIDs: processIDs,
                allowInheritedEnvironment: false
            ))
        case "process-discovery":
            guard let value = CommandLine.arguments.dropFirst(2).first,
                  let pid = Int(value), pid > 1 else { exit(64) }
            print(RemoteAgentLifecycleIntegrationInstaller.makeProcessDiscoveryCommand(scope: .rootProcess(pid)))
        case "persist-shell":
            print(RemoteAgentLifecycleIntegrationInstaller.persistAndApplyToCurrentShellCommand)
        case "hook":
            print(RemoteAgentLifecycleIntegrationInstaller.hookScript)
        case "launcher":
            print(RemoteAgentLifecycleIntegrationInstaller.launcherScript)
        case "projector":
            print(RemoteAgentLifecycleIntegrationInstaller.projectorScript)
        case "semantic-launcher":
            print(RemoteAgentLifecycleIntegrationInstaller.semanticLaunchScript)
        case "process-proof":
            print(RemoteAgentLifecycleIntegrationInstaller.processProofScript)
        case "codex-readiness":
            print(RemoteAgentLifecycleIntegrationInstaller.codexReadinessScript)
        case "codex-recovery":
            print(RemoteAgentLifecycleIntegrationInstaller.codexConversationRecoveryScript)
        case "claude-shim":
            print(RemoteAgentLifecycleIntegrationInstaller.claudeShimScript)
        case "codex-shim":
            print(RemoteAgentLifecycleIntegrationInstaller.codexShimScript)
        case "shell":
            print(RemoteAgentLifecycleIntegrationInstaller.shellIntegration)
        default:
            FileHandle.standardError.write(Data("unknown dump request\n".utf8))
            exit(64)
        }
    }
}
