import Foundation

public enum RuleCodec {
    public static func encode(_ rules: [PortForwardRule]) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(rules)) ?? Data()
    }

    public static func decode(_ data: Data?) -> [PortForwardRule] {
        guard let data, !data.isEmpty else { return [] }
        return (try? JSONDecoder().decode([PortForwardRule].self, from: data)) ?? []
    }
}
