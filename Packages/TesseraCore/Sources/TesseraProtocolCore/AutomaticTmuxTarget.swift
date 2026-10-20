import Crypto
import Foundation

/// Portable automatic-tmux naming policy used by every Tessera client.
///
/// The host key deliberately excludes a device identifier so iPhone, iPad,
/// macOS, and Android rendezvous in the same server-side tmux session.
public enum AutomaticTmuxTarget {
    public static func hostKey(username: String, hostname: String, port: Int) -> String {
        "\(username)@\(hostname):\(port)"
    }

    public static func sessionName(forHostKey hostKey: String) -> String {
        let digest = SHA256.hash(data: Data(hostKey.utf8))
        let suffix = digest.prefix(4).map { String(format: "%02x", $0) }.joined()
        return "tessera-\(suffix)"
    }

    public static func sessionName(username: String, hostname: String, port: Int) -> String {
        sessionName(forHostKey: hostKey(username: username, hostname: hostname, port: port))
    }
}
