import Citadel
import NIO
import NIOSSH

private enum SmokeFailure: Error, CustomStringConvertible {
    case usage
    case passwordMissing
    case execMismatch(String)
    case ptyMismatch(String)
    case unsupportedHostPlatform

    var description: String {
        switch self {
        case .usage:
            return "usage: CitadelAndroidSmoke <host> <port> <username>"
        case .passwordMissing:
            return "expected the fixture password on standard input"
        case .execMismatch(let output):
            return "exec marker mismatch: \(output)"
        case .ptyMismatch(let output):
            return "PTY marker mismatch: \(output)"
        case .unsupportedHostPlatform:
            return "the host-only control run requires macOS 15 or newer"
        }
    }
}

@main
private struct CitadelAndroidSmoke {
    static func main() async throws {
        do {
            let arguments = CommandLine.arguments
            guard arguments.count == 4, let port = Int(arguments[2]) else {
                throw SmokeFailure.usage
            }
            guard let password = readLine(strippingNewline: true), !password.isEmpty else {
                throw SmokeFailure.passwordMissing
            }

            let client = try await SSHClient.connect(
                host: arguments[1],
                port: port,
                authenticationMethod: .passwordBased(
                    username: arguments[3],
                    password: password
                ),
                hostKeyValidator: .acceptAnything(),
                reconnect: .never,
                connectTimeout: .seconds(15)
            )
            do {
                var execBuffer = try await client.executeCommand(
                    "printf TESSERA_CITADEL_EXEC_OK"
                )
                let execOutput = execBuffer.readString(length: execBuffer.readableBytes) ?? ""
                guard execOutput == "TESSERA_CITADEL_EXEC_OK" else {
                    throw SmokeFailure.execMismatch(execOutput)
                }

                let request = SSHChannelRequestEvent.PseudoTerminalRequest(
                    wantReply: true,
                    term: "xterm-256color",
                    terminalCharacterWidth: 80,
                    terminalRowHeight: 24,
                    terminalPixelWidth: 0,
                    terminalPixelHeight: 0,
                    terminalModes: SSHTerminalModes([:])
                )
                var ptyOutput = ""
                if #available(macOS 15.0, *) {
                    try await client.withPTY(request) { inbound, outbound in
                        try await outbound.changeSize(
                            cols: 132,
                            rows: 43,
                            pixelWidth: 0,
                            pixelHeight: 0
                        )
                        try await outbound.write(
                            ByteBuffer(string: "printf 'TESSERA_CITADEL_PTY_OK\\n'; exit\\n")
                        )
                        for try await event in inbound {
                            var buffer: ByteBuffer
                            switch event {
                            case .stdout(let stdout):
                                buffer = stdout
                            case .stderr(let stderr):
                                buffer = stderr
                            }
                            ptyOutput += buffer.readString(length: buffer.readableBytes) ?? ""
                            if ptyOutput.contains("TESSERA_CITADEL_PTY_OK") {
                                break
                            }
                        }
                    }
                } else {
                    throw SmokeFailure.unsupportedHostPlatform
                }
                guard ptyOutput.contains("TESSERA_CITADEL_PTY_OK") else {
                    throw SmokeFailure.ptyMismatch(ptyOutput)
                }

                try await client.close()
            } catch {
                try? await client.close()
                throw error
            }
            print("TESSERA_CITADEL_ANDROID_SSH_OK exec=1 pty=1 resize=1")
        } catch {
            print("TESSERA_CITADEL_ANDROID_SSH_FAILED: \(error)")
            throw error
        }
    }
}
