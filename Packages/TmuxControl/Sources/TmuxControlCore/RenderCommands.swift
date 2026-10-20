import Foundation

/// Wire commands used to obtain an authoritative tmux render.
///
/// The renderer's metadata format and capture command spellings must be
/// identical for every client. In particular, captures deliberately use raw
/// `-e -N` rows rather than `-J`: joining hard-wrapped rows loses trailing
/// coloured cells, which makes a later repaint geometrically different from
/// the tmux pane it represents.
public enum RenderCommands {
    /// The fixed, tab-separated state response consumed by
    /// `TmuxRenderedPaneStateParser`.
    ///
    /// Keep `alternate_on` at index 6. The parser accepts the seven-field
    /// legacy prefix, but every new query must request the complete modern
    /// shape so repaint assembly can restore modes and alternate screens.
    public static let renderedPaneMetadataFormat = [
        "#{pane_id}",
        "#{cursor_x}",
        "#{cursor_y}",
        "#{pane_title}",
        "#{window_name}",
        "#{host}",
        "#{alternate_on}",
        "#{history_size}",
        "#{scroll_region_upper}",
        "#{scroll_region_lower}",
        "#{cursor_flag}",
        "#{insert_flag}",
        "#{keypad_cursor_flag}",
        "#{keypad_flag}",
        "#{wrap_flag}",
        "#{mouse_standard_flag}",
        "#{mouse_button_flag}",
        "#{mouse_all_flag}",
        "#{mouse_sgr_flag}",
        "#{origin_flag}",
        "#{alternate_saved_x}",
        "#{alternate_saved_y}",
        "#{pane_width}",
        "#{pane_height}",
    ].joined(separator: "\t")

    /// The tag a FIFO synchronisation probe prints back.
    ///
    /// `display-message -p` echoes a literal with no `#{...}` expansion, so the
    /// reply is exactly one line and exactly this marker. Nothing else the
    /// ledger asks for can answer with it, which is what makes the probe
    /// recognisable by content rather than by queue position.
    public static let fifoSyncTag = "__tessera_fifo_sync__"

    /// Marker text for probe `sequence`.
    public static func fifoSyncMarker(sequence: UInt64) -> String {
        "\(fifoSyncTag)-\(sequence)"
    }

    /// Ask the server to echo a marker so the reply FIFO can be realigned.
    public static func fifoSync(marker: String) -> String {
        "display-message -p '\(marker)'"
    }

    /// Read render metadata for a pane or window target.
    ///
    /// `target` must be a trusted tmux object id, normally `PaneId` or
    /// `WindowId`. Those ids serialize as `%<number>` and `@<number>` and
    /// therefore need no additional shell quoting, matching the existing
    /// control-mode commands exactly.
    public static func renderedPaneMetadata<Target: CustomStringConvertible>(
        target: Target
    ) -> String {
        "display-message -p -t \(target.description) '\(renderedPaneMetadataFormat)'"
    }

    /// Capture the visible pane grid. This is also the settled scrub capture
    /// after a deep replay.
    public static func viewport<Target: CustomStringConvertible>(target: Target) -> String {
        "capture-pane -p -e -N -t \(target.description)"
    }

    /// Capture primary-screen history together with the current visible grid.
    public static func deepPrimary<Target: CustomStringConvertible>(
        target: Target,
        depth: Int
    ) -> String {
        "capture-pane -p -e -N -S -\(nonnegative(depth)) -t \(target.description)"
    }

    /// Capture only the history above an alternate screen. The live alternate
    /// grid is collected separately with ``viewport(target:)``.
    public static func deepAltHistory<Target: CustomStringConvertible>(
        target: Target,
        depth: Int
    ) -> String {
        "capture-pane -p -e -N -S -\(nonnegative(depth)) -E -1 -t \(target.description)"
    }

    /// Capture the saved primary grid while tmux is displaying an alternate
    /// screen. An absent saved primary is a valid empty response.
    public static func savedPrimary<Target: CustomStringConvertible>(target: Target) -> String {
        "capture-pane -p -e -N -a -q -t \(target.description)"
    }

    /// Capture mosh+tmux scrollback. It intentionally has no `-E`: the reply
    /// includes the live rows so it can replace the complete target surface.
    public static func moshHistory<Target: CustomStringConvertible>(
        target: Target,
        depth: Int
    ) -> String {
        "capture-pane -p -e -N -S -\(nonnegative(depth)) -t \(target.description)"
    }

    /// Configure tmux's output-flow pause interval. The established default
    /// is five seconds; negative input has the same zero clamp as the existing
    /// render capture callers.
    public static func pauseAfter(seconds: Int = 5) -> String {
        "refresh-client -f pause-after=\(nonnegative(seconds))"
    }

    /// Preserve pause-after while switching the metadata channel's pane stream.
    public static func sideChannelPaneOutput(enabled: Bool) -> String {
        enabled ? "refresh-client -f '!no-output'" : "refresh-client -f no-output"
    }

    /// Resume a pane paused by tmux's `pause-after` flow control.
    public static func continuePane(_ paneID: PaneId) -> String {
        "refresh-client -A '\(paneID.description):continue'"
    }

    private static func nonnegative(_ value: Int) -> Int {
        max(0, value)
    }
}
