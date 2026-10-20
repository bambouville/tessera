import Foundation
import TesseraDomainCore

/// iOS storage codec for `PersistedHost.portForwardRulesData`.
///
/// It always *writes* the shared model's own JSON shape, and *reads* two:
/// that shape, and the pre-shared-model iOS shape
/// (`localPort` / `remoteHost` / `remotePort`, no direction, no endpoints).
/// A stored rule must never be lost to the migration, so decoding is
/// per-element: one unreadable rule does not take its neighbours with it.
public enum RuleCodec {
    public static func encode(_ rules: [PortForwardRule]) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(rules)) ?? Data()
    }

    public static func decode(_ data: Data?) -> [PortForwardRule] {
        guard let data, !data.isEmpty else { return [] }
        guard let stored = try? JSONDecoder().decode([StoredRule].self, from: data) else {
            return []
        }
        return stored.compactMap(\.rule)
    }

    /// One persisted rule in either spelling. Failure is contained here rather
    /// than at the array level so a single malformed entry drops alone.
    private struct StoredRule: Decodable {
        let rule: PortForwardRule?

        private enum LegacyKeys: String, CodingKey {
            case id
            case enabled
            case autoStart
            case localPort
            case remoteHost
            case remotePort
            case label
        }

        init(from decoder: Decoder) throws {
            if let current = try? PortForwardRule(from: decoder) {
                rule = current
                return
            }
            guard let values = try? decoder.container(keyedBy: LegacyKeys.self),
                  let id = try? values.decode(UUID.self, forKey: .id),
                  let localPort = try? values.decode(UInt16.self, forKey: .localPort),
                  let remotePort = try? values.decode(UInt16.self, forKey: .remotePort)
            else {
                rule = nil
                return
            }
            // A pre-shared-model iOS rule was always a loopback local forward:
            // the listener bound 127.0.0.1 and the target was the remote pair.
            rule = PortForwardRule.localForward(
                id: id,
                enabled: (try? values.decode(Bool.self, forKey: .enabled)) ?? true,
                autoStart: (try? values.decode(Bool.self, forKey: .autoStart)) ?? true,
                localPort: localPort,
                remoteHost: (try? values.decode(String.self, forKey: .remoteHost)) ?? "localhost",
                remotePort: remotePort,
                label: (try? values.decode(String.self, forKey: .label)) ?? ""
            )
        }
    }
}
