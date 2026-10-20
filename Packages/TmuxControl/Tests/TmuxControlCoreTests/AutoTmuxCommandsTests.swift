import XCTest
@testable import TmuxControlCore

final class AutoTmuxCommandsTests: XCTestCase {
    func testGeometryPreservingWrapperGatesTheFlagOnTmuxThreeTwo() {
        let command = AutoTmuxCommands.geometryPreservingClientCommand(
            tmuxCommand: "tmux -u attach-session",
            arguments: "-t target"
        )

        XCTAssertTrue(command.contains("tmux -V 2>/dev/null"))
        XCTAssertTrue(command.contains("[ \"$tessera_tmux_major\" -gt 3 ]"))
        XCTAssertTrue(command.contains("[ \"$tessera_tmux_minor\" -ge 2 ]"))
        XCTAssertTrue(command.contains("exec tmux -u attach-session -f ignore-size -t target"))
        // An unparseable or older version runs the same operation rather than
        // failing on an option the server does not know.
        XCTAssertTrue(command.contains("else exec tmux -u attach-session -t target"))
    }

    /// The bug this replaced: `status` is a tmux *session* option, so turning
    /// it off on the session the user asked for turned it off for every client
    /// of that session — including a terminal open on another machine — and
    /// left it off after Tessera was gone. Presentation and cleanup options
    /// belong on Tessera's view session.
    func testMoshVisibleClientKeepsPresentationOptionsOnItsView() {
        let command = AutoTmuxCommands.moshVisibleClientCommand(
            sessionTarget: "main",
            gridAuthorityDeviceID: "ipad-1",
            ignoresSize: true
        )

        for option in ["status", "destroy-unattached", "@tessera-visible-ipad-1"] {
            XCTAssertFalse(
                command.contains("set-option -t '\\''main'\\'' \(option)"),
                "\(option) must never be set on the user's own session"
            )
            XCTAssertTrue(
                command.contains("-t '\\''main-tessera-view'\\'' \(option)"),
                "\(option) belongs on Tessera's view session"
            )
        }
        // Mouse input is enabled for programs that probe the work session.
        let ownerMentions = command.components(separatedBy: "'\\''main'\\''").count - 1
        XCTAssertEqual(ownerMentions, 5, command)
        XCTAssertTrue(command.contains("has-session -t '\\''main'\\''"))
        XCTAssertTrue(command.contains("new-session -d -s '\\''main'\\''"))
    }

    func testMouseInputIsEnabledOnEveryControlModeAttachBranch() {
        for preservesGeometry in [false, true] {
            let command = AutoTmuxCommands.controlModeSessionCommand(
                sessionTarget: "main",
                preserveInitialGeometry: preservesGeometry
            )
            XCTAssertTrue(command.contains("set-option -t 'main' mouse on"), command)
            XCTAssertFalse(command.contains("set-option -g"), command)
            // Every exec branch must apply the policy to the same session.
            for branch in command.components(separatedBy: "exec tmux -CC").dropFirst() {
                XCTAssertTrue(branch.contains("set-option -t"), branch)
                XCTAssertTrue(branch.contains("mouse on"), branch)
            }
        }
    }

    func testMoshEnablesMouseOnTheWorkAndViewSessions() {
        let command = AutoTmuxCommands.moshVisibleClientCommand(
            sessionTarget: "main",
            ignoresSize: true
        )
        XCTAssertTrue(command.contains("set-option -t '\\''main'\\'' mouse on"), command)
        XCTAssertTrue(command.contains("set-option -t '\\''main-tessera-view'\\'' mouse on"), command)
        XCTAssertFalse(command.contains("set-option -g"), command)
    }

    func testRetainedMoshViewChecksTheOwnersGroupBeforeChangingMouse() {
        let command = AutoTmuxCommands.enableGroupedOwnerMouseCommand(
            sessionTarget: "shared", viewTarget: "$7"
        )
        let write = "tmux set-option -t \"${tessera_tmux_mouse_owner%% *}\" mouse on"
        XCTAssertTrue(command.contains("-t 'shared' '#{session_id} #{session_group}'"), command)
        XCTAssertTrue(command.contains("[ -n \"${tessera_tmux_mouse_owner#* }\" ]"), command)
        XCTAssertTrue(command.contains("-t '$7' '#{session_group}'"), command)
        XCTAssertTrue(command.contains(write), command)
        XCTAssertFalse(command.contains("set-option -t 'shared'"), command)
        guard let groupCheck = command.range(of: "-t '$7' '#{session_group}'"),
              let mutation = command.range(of: write) else { return XCTFail(command) }
        XCTAssertLessThan(groupCheck.upperBound, mutation.lowerBound)
    }

    func testMoshViewSessionNameStaysAValidSessionName() {
        XCTAssertEqual(AutoTmuxCommands.moshViewSessionName(for: "main"), "main-tessera-view")
        // A session already named for Tessera does not say so twice.
        XCTAssertEqual(
            AutoTmuxCommands.moshViewSessionName(for: "tessera-abc12345"),
            "tessera-abc12345-view"
        )
        XCTAssertEqual(AutoTmuxCommands.moshViewSessionName(for: "tessera"), "tessera-view")
        // A pinned name at the limit is trimmed rather than pushed past it.
        let longest = String(repeating: "a", count: TmuxSessionName.maximumUTF8Length)
        let derived = AutoTmuxCommands.moshViewSessionName(for: longest)
        XCTAssertTrue(TmuxSessionName.isValid(derived), derived)
        XCTAssertTrue(derived.hasSuffix("-tessera-view"))
    }

    func testMoshVisibleClientAttachesAnExistingViewAndOnlyCreatesItOtherwise() {
        let command = AutoTmuxCommands.moshVisibleClientCommand(
            sessionTarget: "tessera-abc12345",
            ignoresSize: true
        )

        XCTAssertTrue(command.contains("has-session -t '\\''tessera-abc12345-view'\\''"))
        XCTAssertTrue(command.contains("set -- attach-session $tessera_tmux_f"))
        XCTAssertTrue(
            command.contains(
                "set -- new-session $tessera_tmux_f -s '\\''tessera-abc12345-view'\\'' "
                    + "-t '\\''tessera-abc12345'\\''"
            )
        )
        // One option chain, applied to whichever subcommand ran.
        XCTAssertTrue(command.contains("exec tmux -u \"$@\""))
        XCTAssertEqual(command.components(separatedBy: "status off").count - 1, 1)
    }

    /// `keep-last` (tmux 3.4+) drops the view once its clients leave *unless*
    /// it is the last session holding the windows — a plain `on` would take a
    /// user's running work with it if they had killed the owner session
    /// meanwhile. An older server takes `off` rather than an unknown value.
    func testViewSessionCleanupNeverOutlivesTheWindowsItShares() {
        let command = AutoTmuxCommands.moshVisibleClientCommand(
            sessionTarget: "main",
            ignoresSize: true
        )

        XCTAssertTrue(command.contains("tessera_tmux_du=keep-last"))
        XCTAssertTrue(command.contains("tessera_tmux_du=off"))
        XCTAssertTrue(command.contains("[ \"$tessera_tmux_minor\" -ge 4 ]"))
        XCTAssertTrue(command.contains("destroy-unattached $tessera_tmux_du"))
        XCTAssertFalse(command.contains("destroy-unattached on"))
    }

    func testMoshVisibleClientIgnoresSizeAndKeepsItsWordSafe() {
        let command = AutoTmuxCommands.moshVisibleClientCommand(
            sessionTarget: "tessera-abc12345",
            ignoresSize: true
        )

        XCTAssertTrue(command.hasPrefix("sh -lc '"))
        XCTAssertTrue(command.hasSuffix("'"))
        XCTAssertTrue(command.contains("tmux -V 2>/dev/null"))
        XCTAssertTrue(command.contains("tessera_tmux_f='\\''-f ignore-size'\\''"))
        // The device's own grid is authoritative at bootstrap; nothing waits
        // on an inherited server geometry.
        XCTAssertFalse(command.contains("stty size"))
        // Every apostrophe inside the outer word must be part of a `'\\''`
        // escape, or the remote shell ends the command early and the rest of
        // it lands as unquoted argv.
        let body = String(command.dropFirst("sh -lc '".count).dropLast())
        XCTAssertFalse(body.replacingOccurrences(of: #"'\''"#, with: "").contains("'"))
        // The remote route refuses an over-long command line at connect; a
        // regression should be a red test, not a throw on the user's first
        // launch.
        XCTAssertLessThanOrEqual(command.count, 2_048)
    }

    /// A tmux server exits as soon as it finds it has no sessions, so a
    /// read-modify-write of a server option before the first session is
    /// written to a server that is already gone (probed on 3.6a). The old
    /// chained form rode `new-session`'s own invocation and never had to care.
    func testTruecolorOverrideIsWrittenOnlyOnceAndOnlyAfterASessionExists() {
        let command = AutoTmuxCommands.moshVisibleClientCommand(
            sessionTarget: "main",
            ignoresSize: false
        )

        XCTAssertTrue(command.contains("grep -qx '\\''xterm-256color:Tc'\\''"))
        XCTAssertEqual(
            command.components(separatedBy: "set-option -as terminal-overrides").count - 1,
            1
        )
        guard let ownerRange = command.range(of: "new-session -d -s '\\''main'\\''"),
              let overrideRange = command.range(of: "show-options -gv terminal-overrides")
        else { return XCTFail(command) }
        XCTAssertTrue(ownerRange.upperBound < overrideRange.lowerBound, command)
    }

    /// Window selection is session-scoped: a control client sitting in the
    /// user's session would move its own current window and leave the visible
    /// client where it was.
    func testMoshControlChannelJoinsTheSameViewSessionAndOnlyAttaches() {
        let command = AutoTmuxCommands.moshControlChannelCommand(sessionTarget: "main")

        XCTAssertTrue(command.contains("tmux -CC attach-session -t 'main-tessera-view'"))
        // Attach-only: a control channel that raced ahead of the visible client
        // would otherwise create an ungrouped session of the same name.
        XCTAssertFalse(command.contains("new-session"))
        // The exec channel is not a login shell, so the same PATH repair the
        // inline control command uses has to apply here.
        XCTAssertTrue(command.hasPrefix("if command -v tmux >/dev/null 2>&1; then "))
    }

    func testMoshControlChannelSuppressesRedundantOutputOnlyWithSupportedClientFlags() {
        for preservesGeometry in [false, true] {
            let command = AutoTmuxCommands.moshControlChannelCommand(
                sessionTarget: "main",
                preserveInitialGeometry: preservesGeometry
            )
            let flags = preservesGeometry ? "no-output,ignore-size" : "no-output"
            XCTAssertTrue(command.contains("[ \"$tessera_tmux_minor\" -ge 2 ]"), command)
            XCTAssertTrue(command.contains("exec tmux -CC attach-session -f \(flags) -t 'main-tessera-view'"), command)
            XCTAssertTrue(command.contains("else exec tmux -CC attach-session -t 'main-tessera-view'"), command)
            XCTAssertFalse(AutoTmuxCommands.controlModeSessionCommand(
                sessionTarget: "main", preserveInitialGeometry: preservesGeometry
            ).contains("no-output"))
        }
    }

    func testMoshVisibleClientStampsTheDeviceScopedClientOption() {
        let command = AutoTmuxCommands.moshVisibleClientCommand(
            sessionTarget: "tessera-abc12345",
            gridAuthorityDeviceID: "android-1",
            ignoresSize: false
        )

        XCTAssertTrue(command.contains(TmuxGridAuthority.visibleClientOption(identityID: "android-1")))
        XCTAssertTrue(command.contains("#{client_name}|#{client_pid}|#{client_created}"))
    }

    func testControlModeAttachParticipatesInSizingByDefault() {
        let command = AutoTmuxCommands.controlModeSessionCommand(sessionTarget: "tessera-abc12345")

        XCTAssertTrue(command.contains("exec tmux -CC new-session -A -s 'tessera-abc12345'"))
        XCTAssertFalse(command.contains("ignore-size"))
    }

    /// sshd runs an exec channel as `$SHELL -c`: non-login, so zsh never reads
    /// `.zprofile` — which is exactly where Homebrew puts its `shellenv`. A
    /// macOS host whose tmux is on every PATH the user can see reported
    /// `command not found` to us and killed the session. A host that already
    /// resolves tmux must keep execing it directly, with no second shell.
    func testControlModeFallsBackToALoginShellOnlyWhenTmuxDoesNotResolve() {
        let command = AutoTmuxCommands.controlModeSessionCommand(sessionTarget: "tessera-abc12345")

        XCTAssertTrue(command.hasPrefix("if command -v tmux >/dev/null 2>&1; then "))
        XCTAssertTrue(command.contains("else exec \"${SHELL:-/bin/sh}\" -l -c "))
        // The direct branch is first and unwrapped: hosts that work today must
        // not start paying for an extra shell.
        let directRange = command.range(of: "then exec tmux -CC")
        let fallbackRange = command.range(of: "else exec \"${SHELL")
        XCTAssertNotNil(directRange)
        XCTAssertNotNil(fallbackRange)
        if let directRange, let fallbackRange {
            XCTAssertTrue(directRange.lowerBound < fallbackRange.lowerBound)
        }
    }

    /// The geometry-preserving form probes `tmux -V` and `has-session` before
    /// it attaches, so all of it has to run where tmux resolves — not just the
    /// final exec.
    func testGeometryPreservingLaunchIsAlsoPathRepaired() {
        let command = AutoTmuxCommands.controlModeSessionCommand(
            sessionTarget: "tessera-abc12345",
            preserveInitialGeometry: true
        )

        XCTAssertTrue(command.hasPrefix("if command -v tmux >/dev/null 2>&1; then "))
        XCTAssertTrue(command.contains("else exec \"${SHELL:-/bin/sh}\" -l -c "))
        XCTAssertTrue(command.contains("tessera_tmux_v=$(tmux -V"))
    }

    func testControlModePreservesGeometryOnlyForAnExistingSession() {
        let command = AutoTmuxCommands.controlModeSessionCommand(
            sessionTarget: "tessera-abc12345",
            preserveInitialGeometry: true
        )

        XCTAssertTrue(command.contains("tmux has-session -t 'tessera-abc12345'"))
        XCTAssertTrue(command.contains("attach-session -f ignore-size -t 'tessera-abc12345'"))
        // Creating the session leaves nothing to preserve, so that client sizes
        // normally.
        XCTAssertTrue(command.contains("else exec tmux -CC new-session -s 'tessera-abc12345'"))
        XCTAssertTrue(command.contains("else exec tmux -CC new-session -A -s 'tessera-abc12345'"))
    }

    func testSessionTargetCannotBreakOutOfItsShellWord() {
        let command = AutoTmuxCommands.controlModeSessionCommand(
            sessionTarget: "evil'; rm -rf /; echo '"
        )

        // Quoted twice on the fallback branch — once for the inner command,
        // once to carry that command as a single `-c` argument. Verified in a
        // real shell: the target arrives as one argv entry on both branches and
        // nothing inside it executes.
        XCTAssertTrue(
            command.contains("then exec tmux -CC new-session -A -s 'evil'\\''; rm -rf /; echo '\\'''")
        )
        XCTAssertTrue(
            command.contains(
                "else exec \"${SHELL:-/bin/sh}\" -l -c "
                    + "'exec tmux -CC new-session -A -s '\\''evil'\\''\\'\\'''\\''; "
                    + "rm -rf /; echo '\\''\\'\\'''\\'''\\''"
            )
        )
    }
}
