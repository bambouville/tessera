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

/// Tiny host-side bridge used by the credentialed integration gate. Compiled
/// together with the production installer source so the E2E installs and runs
/// the exact scripts shipped by the app instead of maintaining another copy.
@main
struct AgentIntegrationSourceDump {
    static func main() {
        guard CommandLine.arguments.count >= 2 else {
            FileHandle.standardError.write(Data("usage: dump install-command|status-command|shell-status [pid ...]|persist-shell|hook|launcher|codex-readiness|claude-shim|codex-shim|shell\n".utf8))
            exit(64)
        }
        switch CommandLine.arguments[1] {
        case "install-command":
            print(RemoteAgentLifecycleIntegrationInstaller.makeInstallCommand())
        case "status-command":
            print(RemoteAgentLifecycleIntegrationInstaller.makeStatusCommand())
        case "shell-status":
            let processIDs = Set(CommandLine.arguments.dropFirst(2).compactMap(Int.init))
            print(RemoteAgentLifecycleIntegrationInstaller.makeShellStatusCommand(
                processIDs: processIDs,
                allowInheritedEnvironment: false
            ))
        case "persist-shell":
            print(RemoteAgentLifecycleIntegrationInstaller.persistAndApplyToCurrentShellCommand)
        case "hook":
            print(RemoteAgentLifecycleIntegrationInstaller.hookScript)
        case "launcher":
            print(RemoteAgentLifecycleIntegrationInstaller.launcherScript)
        case "codex-readiness":
            print(RemoteAgentLifecycleIntegrationInstaller.codexReadinessScript)
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
