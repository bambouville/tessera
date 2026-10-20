import Foundation

/// Shell command text for tmux clients, shared by every platform.
///
/// These are pure `String` builders with no platform surface, so they belong
/// in the portable core rather than beside the Apple-only `AutoTmuxScript`.
/// A second copy is exactly how the platforms drifted: an Android mosh attach
/// once asked for `-f ignore-size` unconditionally, which fails outright on
/// tmux < 3.2, while the Apple builder had guarded that flag from the start.
///
/// Every argument is composed by Tessera, never taken from user input, and
/// every session target is single-quoted here so a pinned session name can
/// never break out of its shell word.
public enum AutoTmuxCommands {
    /// Quote a value as one POSIX shell word.
    public static func singleQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Sets `tessera_tmux_ignore_size` to 1 only when the remote tmux
    /// understands client flags (3.2+). A version we cannot parse counts as
    /// unsupported, so an unknown build never receives an unknown option.
    static let ignoreSizeProbe: String =
        "tessera_tmux_v=$(tmux -V 2>/dev/null); "
        + "tessera_tmux_v=${tessera_tmux_v#tmux }; "
        + "tessera_tmux_major=${tessera_tmux_v%%.*}; "
        + "tessera_tmux_tail=${tessera_tmux_v#*.}; "
        + "tessera_tmux_minor=${tessera_tmux_tail%%[!0-9]*}; "
        + "case \"$tessera_tmux_major:$tessera_tmux_minor\" in "
        + "*[!0-9:]*|:*|*:) tessera_tmux_ignore_size=0 ;; "
        + "*) if [ \"$tessera_tmux_major\" -gt 3 ] || "
        + "{ [ \"$tessera_tmux_major\" -eq 3 ] && [ \"$tessera_tmux_minor\" -ge 2 ]; }; "
        + "then tessera_tmux_ignore_size=1; else tessera_tmux_ignore_size=0; fi ;; "
        + "esac; "

    /// Wrap a tmux client command so it asks for `ignore-size` only when the
    /// remote tmux supports the flag; older servers run the same operation
    /// without geometry isolation instead of failing on an unknown option.
    ///
    /// `tmuxCommand` carries the executable, global flags and subcommand;
    /// `arguments` carries the remaining subcommand arguments.
    public static func geometryPreservingClientCommand(
        tmuxCommand: String,
        arguments: String
    ) -> String {
        ignoreSizeProbe
            + "if [ \"$tessera_tmux_ignore_size\" = 1 ]; then "
            + "exec \(tmuxCommand) -f ignore-size \(arguments); "
            + "else exec \(tmuxCommand) \(arguments); fi"
    }

    /// The suffix that names Tessera's private view of a user's tmux session.
    ///
    /// A session already named for Tessera only gains `-view`, so the common
    /// auto-tmux pair reads `tessera-a1b2c3d4` / `tessera-a1b2c3d4-view` in the
    /// user's own `tmux ls`.
    static func viewSessionName(appending suffix: String, to owner: String) -> String {
        var base = owner
        let budget = TmuxSessionName.maximumUTF8Length - suffix.utf8.count
        while base.utf8.count > budget, !base.isEmpty { base.removeLast() }
        return base + suffix
    }

    /// Tessera's private *view* of a tmux session: a second session in the same
    /// session group, sharing every window with `sessionTarget` but carrying its
    /// own options and its own current window.
    ///
    /// tmux scopes `status` — and `destroy-unattached`, and the `@tessera-*`
    /// stamps — to a *session*, never to a client. Setting them on the session
    /// the user asked for set them for **every** client of it, so the terminal
    /// the user had open on another machine lost its status line the moment an
    /// iPad connected, and kept it lost after Tessera left: the option outlives
    /// the client that wrote it. A session group is tmux's own answer, and the
    /// grouping is what keeps this from being a workaround — the windows, their
    /// processes and their scrollback are one shared set, so the two sessions
    /// are two views of the same work, not a copy of it. Every opinion Tessera
    /// holds about presentation and cleanup lands on a session Tessera owns.
    /// Mouse input is enabled on both views: programs in the shared windows
    /// can probe the owner session when deciding whether to capture the mouse.
    ///
    /// A bare `tmux attach` elsewhere still lands on the user's own session:
    /// tmux prefers an unattached session when no target is given, and this one
    /// always has Tessera's client on it (probed on tmux 3.6a).
    public static func moshViewSessionName(for sessionTarget: String) -> String {
        if sessionTarget == "tessera" || sessionTarget.hasPrefix("tessera-") {
            return viewSessionName(appending: "-view", to: sessionTarget)
        }
        return viewSessionName(appending: "-tessera-view", to: sessionTarget)
    }

    /// Enable mouse input for this work session. Codex and other full-screen
    /// programs consult this option before requesting wheel reports.
    /// Session-scoped: this never changes the server's global default.
    public static func enableSessionMouseCommand(sessionTarget: String) -> String {
        "tmux set-option -t \(singleQuoted(sessionTarget)) mouse on"
    }

    /// A retained view can outlive its owner, whose name can then be reused.
    /// Verify the shared group and write by the owner's stable session ID.
    public static func enableGroupedOwnerMouseCommand(
        sessionTarget: String,
        viewTarget: String
    ) -> String {
        let owner = singleQuoted(sessionTarget)
        let view = singleQuoted(viewTarget)
        return "if tessera_tmux_mouse_owner=$(tmux display-message -p -t \(owner) "
            + "'#{session_id} #{session_group}' 2>/dev/null) "
            + "&& [ -n \"${tessera_tmux_mouse_owner#* }\" ] "
            + "&& [ \"${tessera_tmux_mouse_owner#* }\" "
            + "= \"$(tmux display-message -p -t \(view) '#{session_group}')\" ]; "
            + "then tmux set-option -t \"${tessera_tmux_mouse_owner%% *}\" mouse on; fi"
    }

    /// The options Tessera stamps on its own view session, never on the user's.
    ///
    /// `status off` gives the terminal its full height back for Tessera's own
    /// window bar. `destroy-unattached` keeps the view from outliving the
    /// clients that need it, so the user's `tmux ls` returns to just their own
    /// session once Tessera is gone — the windows live in the group, so nothing
    /// is lost with it. See `versionGatedLaunchWords` for why the value is a
    /// variable and not a literal `on`.
    public static func viewSessionOptions(
        viewTarget: String,
        gridAuthorityDeviceID: String?
    ) -> String {
        let visibleClientOption = gridAuthorityDeviceID.map {
            " \\; set-option -F -t \(viewTarget) "
                + "\(TmuxGridAuthority.visibleClientOption(identityID: $0)) "
                + "'#{client_name}|#{client_pid}|#{client_created}'"
        } ?? ""
        return " \\; set-option -t \(viewTarget) status off"
            + " \\; set-option -t \(viewTarget) mouse on"
            + " \\; set-option -t \(viewTarget) destroy-unattached $tessera_tmux_du"
            + visibleClientOption
    }

    /// Declare `Tc` for the mosh client's TERM once per server instead of
    /// appending it again on every connection.
    ///
    /// `set-option -as` appends an array entry unconditionally, so the shipped
    /// command grew the user's server-wide `terminal-overrides` by one
    /// duplicate `xterm-256color:Tc` per launch and never removed one.
    ///
    /// This runs only *after* a session exists, and that ordering is the whole
    /// trick: on a host with no tmux server yet, each command starts a server
    /// of its own and that server exits again the moment it finds it has no
    /// sessions, so an override written before the first session is written to
    /// a server that is already gone. The old chained form got this for free by
    /// riding the same invocation as `new-session`; the read-modify-write
    /// cannot, so it waits for the owner instead. (Probed on tmux 3.6a:
    /// `start-server` alone does not hold a session-less server open.)
    public static let truecolorOverrideOnce =
        "tmux show-options -gv terminal-overrides 2>/dev/null "
        + "| grep -qx 'xterm-256color:Tc' "
        + "|| tmux set-option -as terminal-overrides ',xterm-256color:Tc'; "

    /// Resolve the two version-gated words this launch needs.
    ///
    /// `$tessera_tmux_f` is `-f ignore-size` only where client flags exist
    /// (3.2+), and empty everywhere else, so an older server runs the same
    /// commands unflagged rather than failing on an unknown option.
    ///
    /// `$tessera_tmux_du` is the view session's `destroy-unattached` value.
    /// `keep-last` (3.4+) drops the view once its clients are gone *unless* it
    /// is the last session in its group — so a user who kills the owner
    /// session while Tessera is attached does not lose the windows with it,
    /// which a plain `on` would silently do. An older server takes `off`: the
    /// view lingers in `tmux ls` rather than risking the user's work, and the
    /// next launch reuses it. Both branches are bare words this file wrote, so
    /// they are safe to leave unquoted at the point of use.
    public static func versionGatedLaunchWords(ignoresSize: Bool) -> String {
        ignoreSizeProbe
            + (ignoresSize
                ? "if [ \"$tessera_tmux_ignore_size\" = 1 ]; "
                    + "then tessera_tmux_f='-f ignore-size'; else tessera_tmux_f=''; fi; "
                : "tessera_tmux_f=''; ")
            // Reaching here with ignore_size=1 already proves the version
            // parsed and is at least 3.2, so these comparisons never run on a
            // non-numeric field.
            + "if [ \"$tessera_tmux_ignore_size\" = 1 ] && "
            + "{ [ \"$tessera_tmux_major\" -gt 3 ] || [ \"$tessera_tmux_minor\" -ge 4 ]; }; "
            + "then tessera_tmux_du=keep-last; else tessera_tmux_du=off; fi; "
    }

    /// The visible tmux client a mosh session runs, on Tessera's own view of
    /// the session the user asked for (see `moshViewSessionName`).
    ///
    /// `ignoresSize` attaches it with `ignore-size` so one device's SSP resize
    /// can never yank the shared grid away from a peer; sizing then runs
    /// through the `-CC` side channel, which advertises the device's projected
    /// grid and forces each window onto it. `gridAuthorityDeviceID` stamps a
    /// device-scoped option naming this client, which is how a side channel
    /// later proves which tmux client instance belongs to it.
    ///
    /// The owner session is created **detached** when it is missing, so a first
    /// connection still starts the work session while Tessera keeps its own
    /// client off it. The two branches differ only in the subcommand, which is
    /// why they are collected in `"$@"` rather than written out twice: the
    /// option chain that follows names the view session several times, and a
    /// pinned name may be long.
    public static func moshVisibleClientCommand(
        sessionTarget: String,
        gridAuthorityDeviceID: String? = nil,
        ignoresSize: Bool
    ) -> String {
        let owner = singleQuoted(sessionTarget)
        let view = singleQuoted(moshViewSessionName(for: sessionTarget))
        let body = versionGatedLaunchWords(ignoresSize: ignoresSize)
            + "if tmux -u has-session -t \(view) 2>/dev/null; then "
            + enableGroupedOwnerMouseCommand(
                sessionTarget: sessionTarget,
                viewTarget: moshViewSessionName(for: sessionTarget)
            ) + "; "
            + "set -- attach-session $tessera_tmux_f -t \(view); "
            + "else "
            + "tmux -u has-session -t \(owner) 2>/dev/null "
            + "|| tmux -u new-session -d -s \(owner); "
            + enableSessionMouseCommand(sessionTarget: sessionTarget) + " || exit; "
            + "set -- new-session $tessera_tmux_f -s \(view) -t \(owner); "
            + "fi; "
            + truecolorOverrideOnce
            + "exec tmux -u \"$@\""
            + viewSessionOptions(
                viewTarget: view,
                gridAuthorityDeviceID: gridAuthorityDeviceID
            )
        return "sh -lc \(singleQuoted(body))"
    }

    /// The `-CC` control channel a mosh session opens alongside its visible
    /// client. It joins the same view session, because window selection is a
    /// session-scoped act: a control client in a different session would move
    /// its own current window and leave the visible client where it was.
    ///
    /// Attach-only — the visible client owns creating the view, and a control
    /// channel that raced ahead of it would otherwise create an *ungrouped*
    /// session of the same name and strand the user's windows.
    public static func moshControlChannelCommand(
        sessionTarget: String,
        preserveInitialGeometry: Bool = false
    ) -> String {
        let view = singleQuoted(moshViewSessionName(for: sessionTarget))
        let direct = "exec tmux -CC attach-session -t \(view)"
        // SSP already carries the visible terminal. Receiving the same pane
        // bytes on this metadata/capture channel can leave a geometry fence
        // behind megabytes of redundant output. Pane output is enabled at
        // runtime only while program status is on. Client flags arrived in 3.2;
        // older servers retain their historical unflagged attachment.
        let flags = preserveInitialGeometry ? "no-output,ignore-size" : "no-output"
        return resolvingTmuxOnPath(
            ignoreSizeProbe
                + "if [ \"$tessera_tmux_ignore_size\" = 1 ]; then "
                + "exec tmux -CC attach-session -f \(flags) -t \(view); "
                + "else \(direct); fi"
        )
    }

    /// tmux fixes an attaching client's colour support from its TERM's
    /// terminfo plus `terminal-overrides` alone — it never consults COLORTERM
    /// for the client (probed on tmux 3.4) — and the mosh client's TERM is
    /// `xterm-256color`, whose terminfo has no RGB capability. Declaring Tc
    /// for it before the attach lets pane truecolor reach the device as
    /// truecolor, the same bytes the `-CC` channel passes through raw on
    /// SSH+tmux, rather than the nearest of 256. A server option, so it must
    /// precede `new-session` in the same client invocation: features are
    /// computed when the client's tty opens.
    public static let truecolorClientOverride =
        "set-option -as terminal-overrides ',xterm-256color:Tc' \\;"

    /// The `-CC` control-mode client for a dedicated remote channel (as
    /// opposed to a one-liner typed into an existing login shell).
    ///
    /// The control client is the device's sizing participant: it advertises
    /// the local — for a compact device, projected — grid through
    /// `refresh-client -C` and contends for grid authority, on phones exactly
    /// as on tablets. `preserveInitialGeometry` is the ceded-observer state
    /// only, for a client that has yielded the grid to a larger peer, and must
    /// not be requested at attach time: an observer can neither fit its own
    /// viewport nor take control back.
    public static func controlModeSessionCommand(
        sessionTarget: String,
        preserveInitialGeometry: Bool = false
    ) -> String {
        let target = singleQuoted(sessionTarget)
        let mouseOptions = " \\; set-option -t \(target) mouse on"
        let direct = "exec tmux -CC new-session -A -s \(target)" + mouseOptions
        guard preserveInitialGeometry else { return resolvingTmuxOnPath(direct) }
        return resolvingTmuxOnPath(
            ignoreSizeProbe
                + "if [ \"$tessera_tmux_ignore_size\" = 1 ]; then "
                + "if tmux has-session -t \(target) 2>/dev/null; then "
                + "exec tmux -CC attach-session -f ignore-size -t \(target)\(mouseOptions); "
                + "else exec tmux -CC new-session -s \(target)\(mouseOptions); fi; "
                + "else \(direct); fi"
        )
    }

    /// Run `body` directly when tmux already resolves, and otherwise re-run it
    /// through a **login** shell.
    ///
    /// This command is delivered over an SSH exec channel, which sshd runs as
    /// `$SHELL -c`: non-interactive and non-login, so zsh reads only `.zshenv`
    /// and bash only `.bashrc`. Homebrew's installer writes its `shellenv` to
    /// `.zprofile`, which only a login shell reads — so on a stock macOS host
    /// `tmux` is on the user's PATH in every shell they ever see, and missing
    /// in ours. iOS never hit this because it types its launch into the
    /// session's own interactive login shell; the exec channel is what makes
    /// the delivery differ, so the repair belongs to the command, not to a
    /// platform.
    ///
    /// The probe keeps the common path unchanged: a host that already resolves
    /// tmux — every Linux distribution that ships it in `/usr/bin` — execs it
    /// directly and never pays for a second shell. Only a host that would
    /// otherwise fail outright takes the login-shell branch, so a shell whose
    /// `-l` handling is unusual can cost us nothing that was working before.
    static func resolvingTmuxOnPath(_ body: String) -> String {
        "if command -v tmux >/dev/null 2>&1; then \(body); "
            + "else exec \"${SHELL:-/bin/sh}\" -l -c \(singleQuoted(body)); fi"
    }
}
