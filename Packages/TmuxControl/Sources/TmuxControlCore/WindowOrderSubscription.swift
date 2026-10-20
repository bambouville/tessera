import Foundation

/// The live feed of the session's window index and id order. It reads the
/// same from any pane, so it is registered against one (see
/// `TmuxControlSubscriptions`).
public enum TmuxWindowOrderSubscription {
    public static let name = "tessera-window-order"

    /// Each loop entry carries its own trailing separator. The parser accepts
    /// the resulting harmless leading/trailing whitespace but no empty token.
    public static let format =
        "#{W:#{window_index}=#{window_id} ,#{window_index}=#{window_id}* }"

    /// Parse `index=@id` entries, with one optional `*` active-window marker.
    /// The marker is intentionally not returned: active selection is owned by
    /// the topology feed, while this value owns order only.
    public static func parse(_ value: String) -> [(index: Int, id: WindowId)]? {
        if value.isEmpty { return [] }
        guard value.utf8.count <= 16_384 else { return nil }

        let fields = value.split(whereSeparator: { $0 == " " || $0 == "\t" })
        guard fields.count <= 512 else { return nil }

        var seenIndexes = Set<Int>()
        var seenIDs = Set<WindowId>()
        var sawActive = false
        var entries: [(index: Int, id: WindowId)] = []
        entries.reserveCapacity(fields.count)

        for rawField in fields {
            var field = Substring(rawField)
            if field.last == "*" {
                guard !sawActive else { return nil }
                sawActive = true
                field.removeLast()
            }
            guard !field.isEmpty,
                  let separator = field.firstIndex(of: "="),
                  field[field.index(after: separator)...].firstIndex(of: "=") == nil,
                  let index = Int(field[..<separator]),
                  (0...1_000_000).contains(index),
                  let id = WindowId(wireValue: String(field[field.index(after: separator)...])),
                  id.rawValue >= 0,
                  seenIndexes.insert(index).inserted,
                  seenIDs.insert(id).inserted
            else { return nil }
            entries.append((index, id))
        }

        return entries.sorted { $0.index < $1.index }
    }
}
