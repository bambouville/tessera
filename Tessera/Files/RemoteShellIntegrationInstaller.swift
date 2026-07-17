// Tessera/Files/RemoteShellIntegrationInstaller.swift
// Remote Files feature — stub pending implementation packet.
// Contracts: Tessera/Files/FilesContracts.swift

import Foundation
import Citadel
import NIOCore

struct ShellIntegrationReport: Equatable {
    let scriptPath: String
    let rcFilesUpdated: [String]
}

enum ShellIntegrationInstallError: LocalizedError, Equatable, Sendable {
    case authentication(String)
    case network(String)
    case hostKeyRejected
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
        case .remoteCommandFailed(let stderr):
            let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                return "Could not install Tessera shell integration."
            }
            return "Could not install Tessera shell integration: \(trimmed)"
        case .verificationFailed(let stderr):
            let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                return "Could not verify Tessera shell integration."
            }
            return "Could not verify Tessera shell integration: \(trimmed)"
        }
    }
}

enum RemoteShellIntegrationInstaller {
    static let scriptPath = "~/.config/tessera/osc7.sh"
    static let rcMarkerLine = #"[ -r "$HOME/.config/tessera/osc7.sh" ] && . "$HOME/.config/tessera/osc7.sh" # TESSERA-OSC7"#
    static let embeddedScript = #"""
# Tessera OSC 7 shell integration — safe to delete

__tessera_osc7_percent_encode() {
    local LC_ALL=C
    local LC_CTYPE=C
    local input="${1-}"
    local length i ch byte out

    out=""
    i=0
    length=${#input}
    while [ "$i" -lt "$length" ]; do
        ch="${input:$i:1}"
        case "$ch" in
        [A-Za-z0-9/_.~-])
            out="${out}${ch}"
            ;;
        *)
            byte=$(printf '%d' "'$ch")
            byte=$((byte & 255))
            out="${out}%$(printf '%02X' "$byte")"
            ;;
        esac
        i=$((i + 1))
    done

    printf '%s' "$out"
}

__tessera_osc7() {
    local encoded_path host

    encoded_path="$(__tessera_osc7_percent_encode "${PWD:-}")"
    host="${HOSTNAME:-$(hostname 2>/dev/null)}"
    printf '\033]7;file://%s%s\033\\' "$host" "$encoded_path"
}

__tessera_osc7_register_zsh() {
    case " ${precmd_functions[*]-} " in
    *" __tessera_osc7 "*)
        return
        ;;
    esac

    autoload -Uz add-zsh-hook 2>/dev/null || true
    if whence add-zsh-hook >/dev/null 2>&1; then
        add-zsh-hook precmd __tessera_osc7 2>/dev/null && return
    fi

    precmd_functions+=(__tessera_osc7)
}

__tessera_osc7_register_bash() {
    case ";${PROMPT_COMMAND:-};" in
    *";__tessera_osc7;"*)
        return
        ;;
    esac

    if [ -n "${PROMPT_COMMAND:-}" ]; then
        PROMPT_COMMAND="__tessera_osc7; ${PROMPT_COMMAND}"
    else
        PROMPT_COMMAND="__tessera_osc7"
    fi
}

if [ -n "${ZSH_VERSION-}" ]; then
    __tessera_osc7_register_zsh
elif [ -n "${BASH_VERSION-}" ]; then
    __tessera_osc7_register_bash
fi

__tessera_osc7
"""#

    static var snippetPreview: String {
        """
        \(rcMarkerLine)

        Tessera installs a small shell integration at \(scriptPath) and adds the line above to your bash or zsh startup file so each prompt reports the remote working directory to the app with OSC 7.
        """
    }

    private static let rcMarker = "TESSERA-OSC7"
    private static let verificationMarker = "TESSERA_OSC7_INSTALLED"
    private static let missingMarker = "TESSERA_OSC7_MISSING"
    private static let rcReportPrefix = "TESSERA_OSC7_RC "

    static func install(
        on host: Host,
        requireBiometric: Bool,
        isSecureEnclave: Bool
    ) async throws -> ShellIntegrationReport {
        let chain: EstablishedSSHChain
        do {
            chain = try await withPendingSSHConnectionAttempt {
                try await establishSSHChain(
                    for: host,
                    requireBiometric: requireBiometric,
                    isSecureEnclave: isSecureEnclave,
                    hostKeyPrompt: nil
                )
            }
        } catch {
            throw classifyConnectionError(error)
        }
        let client = chain.client

        let installOutput: String
        do {
            installOutput = try await execute(makeInstallCommand(), on: client)
        } catch {
            await chain.closeAll()
            throw ShellIntegrationInstallError.remoteCommandFailed(
                stderr: commandFailureMessage(error)
            )
        }

        let verificationOutput: String
        do {
            verificationOutput = try await execute(makeVerifyCommand(), on: client)
        } catch {
            await chain.closeAll()
            throw ShellIntegrationInstallError.verificationFailed(
                stderr: commandFailureMessage(error)
            )
        }

        await chain.closeAll()

        guard verificationOutput.contains(verificationMarker) else {
            throw ShellIntegrationInstallError.verificationFailed(stderr: verificationOutput)
        }

        return ShellIntegrationReport(
            scriptPath: scriptPath,
            rcFilesUpdated: rcFiles(from: installOutput)
        )
    }

    static func makeScriptWriteCommand() -> String {
        let script = singleQuotedShellString(embeddedScript)
        return "mkdir -p \"$HOME/.config/tessera\" && printf '%s\\n' \(script) > \"$HOME/.config/tessera/osc7.sh\" && chmod 644 \"$HOME/.config/tessera/osc7.sh\""
    }

    /// Idempotent rc-file append. The `{ grep || echo; }` group mirrors
    /// the authorized-keys installer so the append only runs after the
    /// marker check and stays bound to the intended file.
    static func makeRcAppendCommand(rcFile: String) -> String {
        let marker = singleQuotedShellString(rcMarker)
        let line = singleQuotedShellString(rcMarkerLine)
        let path = shellPath(rcFile)
        return "{ grep -qF \(marker) \(path) || echo \(line) >> \(path); }"
    }

    static func makeVerifyCommand() -> String {
        let marker = singleQuotedShellString(rcMarker)
        let bashPath = shellPath("~/.bashrc")
        let zshPath = shellPath("~/.zshrc")
        return "if [ -f \"$HOME/.config/tessera/osc7.sh\" ] && { grep -qF \(marker) \(bashPath) 2>/dev/null || grep -qF \(marker) \(zshPath) 2>/dev/null; }; then echo \(verificationMarker); else echo \(missingMarker); fi"
    }

    private static func makeInstallCommand() -> String {
        "\(makeScriptWriteCommand()) && \(makeRcInstallCommand())"
    }

    static func makeRcInstallCommand() -> String {
        let bashPath = shellPath("~/.bashrc")
        let zshPath = shellPath("~/.zshrc")
        let bashReport = singleQuotedShellString(rcReportPrefix + "~/.bashrc")
        let zshReport = singleQuotedShellString(rcReportPrefix + "~/.zshrc")
        // When neither rc file exists, create the one matching the user's
        // login shell ($SHELL basename) — creating ~/.bashrc for a zsh
        // login user would install a snippet zsh never sources.
        let createBash = "touch \(bashPath) && \(makeRcAppendCommand(rcFile: "~/.bashrc")) && echo \(bashReport)"
        let createZsh = "touch \(zshPath) && \(makeRcAppendCommand(rcFile: "~/.zshrc")) && echo \(zshReport)"
        return "if [ -e \(bashPath) ] || [ -e \(zshPath) ]; then if [ -e \(bashPath) ]; then \(makeRcAppendCommand(rcFile: "~/.bashrc")) && echo \(bashReport); fi && if [ -e \(zshPath) ]; then \(makeRcAppendCommand(rcFile: "~/.zshrc")) && echo \(zshReport); fi; else case \"${SHELL##*/}\" in zsh) \(createZsh) ;; *) \(createBash) ;; esac; fi"
    }

    private static func rcFiles(from output: String) -> [String] {
        output
            .split(whereSeparator: \.isNewline)
            .compactMap { line -> String? in
                guard line.hasPrefix(rcReportPrefix) else { return nil }
                return String(line.dropFirst(rcReportPrefix.count))
            }
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

    private static func classifyConnectionError(_ error: Error) -> ShellIntegrationInstallError {
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

    private static func shellPath(_ path: String) -> String {
        guard path.hasPrefix("~/") else {
            return singleQuotedShellString(path)
        }

        let suffix = String(path.dropFirst(2))
        return "\"$HOME/\(doubleQuotedShellContent(suffix))\""
    }

    private static func singleQuotedShellString(_ string: String) -> String {
        let escaped = string.replacingOccurrences(of: "'", with: "'\\''")
        return "'\(escaped)'"
    }

    private static func doubleQuotedShellContent(_ string: String) -> String {
        var escaped = ""
        for character in string {
            switch character {
            case "\\":
                escaped += "\\\\"
            case "\"":
                escaped += "\\\""
            case "$":
                escaped += "\\$"
            case "`":
                escaped += "\\`"
            default:
                escaped.append(character)
            }
        }
        return escaped
    }
}
