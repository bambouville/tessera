# Tessera integration regression suite

This is the opt-in suite derived from `docs/manual-testing-matrix.md`. It uses
two disposable Linux VPS fixtures plus a dedicated iPad simulator; it never
connects through UI automation and never touches the user's existing simulator
or local Mac SSH/tmux setup.

## One-time fixture setup

Copy `fixture.env.example` to the gitignored `fixture.env` and set:

- a stable VPS address (tmux 3.4 fixture);
- a chaos/compatibility VPS address (tmux 3.6a fixture);
- the root SSH control key and port;
- the isolated app-facing SSH port/user values (the defaults are 2222 and
  `tessera`).

Both hosts are assumed disposable. Provisioning installs sshd, mosh, SFTP,
tmux, htop/vim, a loopback-only HTTP forwarding target, deterministic PTY/file
fixtures, and a restricted no-tmux user. Root port 22 remains the control plane;
Tessera tests use the isolated app endpoint.

```sh
./scripts/integration/provision-fixtures.sh
./scripts/integration/verify-fixtures.sh
```

Generated client keys, passwords, known-host databases, simulator identifiers,
DerivedData, captures, and reports stay under ignored `.state/` and `out/`.

## Jump-host lane (opt-in)

`jump/` holds a second, independent fixture pair for jump-host (ProxyJump)
coverage: a public bastion droplet and a target droplet whose app-facing sshd
is nftables-restricted to accept **only** the bastion (control port 22 stays
open). The target also runs a loopback-only sshd (multi-hop) and a
loopback-only HTTP endpoint (forward-through-chain), and drops mosh's UDP
range by default (`tessera-jump-mosh allow|block|status` toggles it on the
target).

```sh
cp scripts/integration/jump/jump.env.example scripts/integration/jump/jump.env  # fill in droplets
./scripts/integration/jump/provision-jump-fixtures.sh   # provisions + verifies topology (12 checks)
./scripts/integration/jump/run-jump-transport-tests.sh  # live app-level jump tests
```

When `jump/jump.env` exists, `run-integration-tests.sh` picks the lane up
automatically as the `app_jump_host_transports` case; without it the case is
skipped. Distinct per-hop credentials are generated under `.state/jump/` so
credential reuse across hops fails loudly.

## Run

```sh
# Normal comprehensive run.
./scripts/integration/run-integration-tests.sh

# Re-provision both disposable hosts first.
./scripts/integration/run-integration-tests.sh --provision

# Deterministic/capture development when Codex evaluation is unavailable.
./scripts/integration/run-integration-tests.sh --no-ai-visual

# Add the credentialed local Codex + Claude Code lifecycle gate. This uses
# isolated tmux sockets, safe print-only tool approvals, and no shell-config
# mutation. Both CLIs must already be authenticated on this Mac.
TESSERA_RUN_REAL_AGENT_E2E=1 ./scripts/integration/run-integration-tests.sh

# Run only that provider gate (optionally set
# TESSERA_REAL_AGENT_PROVIDERS=codex or =claude while diagnosing one lane).
TESSERA_RUN_REAL_AGENT_E2E=1 ./scripts/integration/run-real-agent-e2e.sh
```

The normal execution order is an invariant:

1. Build/install only on dedicated test simulators: `Tessera Visual Integration Tests` for recordings and `Tessera Integration Tests` for deterministic lanes. Separating them prevents unrelated unit-test installs from terminating the app mid-capture.
2. Capture every visual case and finalize one evidence manifest.
3. Start exactly one ephemeral, read-only `codex exec` process with every image
   attached and the complete manifest in the same prompt.
4. Run deterministic host, app, migration, terminal-cell, SFTP, forwarding,
   tmux, and scroll checks while that one review runs in the background.
5. Join both lanes into `report.json`, then shut down the dedicated simulator.

The evaluator has no write permission, uses a strict JSON schema, and must
return exactly one verdict per captured case. A missing, duplicate, or extra
case fails review validation.

## Automated boundaries

| Matrix area | Coverage | Automated assertion |
|---|---|---|
| C1, C2, HK1, KS1/KS5 | substantial | Live password and generated Ed25519 auth over SSH and mosh; TOFU fingerprint/type; accepted-key persistence; wrong-password classification; idempotent install and revoke. Biometric/Secure Enclave remain device-only. |
| C4, C5, W1, W3, W4 | substantial | Real SSH+tmux inline control and mosh+tmux side-channel control hydrate against tmux 3.4 and 3.6a; real window names/renames; two control clients on one server remain session-isolated; SSH and mosh env/startup prologues execute remotely. |
| C6 | fixture boundary | A restricted app user on each host has no tmux executable, providing the deterministic fallback endpoint. Banner presentation remains a UI/manual assertion. |
| K1, K5 | transport boundary | SSH and mosh PTYs preserve an exact multi-KiB payload containing bracketed-paste, SGR mouse, alternate-screen, newline, and printable-byte sequences; the remote SHA-256 oracle verifies every byte. |
| S1 | live visual + wiring | One continuous recording per transport drives real primary scrollback on SSH, SSH+tmux, mosh, and mosh+tmux; external Metal-aware screenshots prove tail → older numbered history → tail. The host-free surface remains a fast offset/wiring assertion. Physical trackpad feel remains manual. |
| S6 | live visual | The same four live sessions grade htop mouse-wheel scrolling in both directions. SSH, SSH+tmux, and mosh+tmux also grade Vim `mouse=a` wheel forwarding; plain-mosh Vim is diagnostic-only because the fixture cannot reliably advance real htop while it owns that PTY. A 3x3 evidence sheet per transport is evaluated in the one aggregate review. Plain-mosh Vim and physical feel remain manual. |
| S9 | correctness oracle | Real `RepaintAssembly` bytes feed a headless SwiftTerm with 36 deep colored row pairs at two widths; every retained short row must end in default background, not a BCE-colored tail. |
| F1, F7 | backend + visual | Tessera's real `FileBridge` lists hidden/extension-less fixtures and performs mkdir/upload/rename/download/exec/delete with byte equality; the Files-card capture checks visible geometry and content. Quick Look/share sheets remain manual. |
| F12 | visual/timing | A complete context-menu recording, event markers, frame contact sheet, stills, and per-frame signal statistics are evaluated in the aggregate visual review. |
| PF1 | substantial | Real HTTP traffic and byte counters are verified on SSH/SSH+tmux's primary client and mosh+tmux's long-lived SSH side channel. |
| MO4 | host oracle | Both hosts enforce a bounded post-test `mosh-server` process count. Real device lifecycle/roaming remains manual. |
| A1, A5, G3 | visual | A normalized landscape terminal-canvas capture checks full bleed, top chrome, fullscreen geometry, and stale-width seams. |
| O1 | visual | All eight forced onboarding steps are captured together and reviewed for step identity, clipping, footer layout, spotlights, and illustration integrity. |
| AG1 | visual + deterministic + live host + credentialed providers | A connection-free Agent Center capture reviews plan approval, just-finished, working, idle, and unavailable groups; separate needs-input/finished/total sidebar counters; off-screen top-bar aggregation; current-window suppression; provider-session/task identity; meaningful viewport excerpts; parsed buttons; address attribution; and inline controls. Focused tests cover the five-minute completion transition, attention acknowledgement and exact jump routing, split-window visibility, foreground/background transitions, bounded new-shell detection convergence, automatic-classifier false-positive rejection, strict shell versus inherited-child proof, lifecycle/subagent-first submission verification, background refresh budgets, separate Return failures, routing, and tmux acknowledgments. The ordinary programmatic lane compiles the production installer source, syntax-checks every generated script, executes fresh bash and ZDOTDIR-zsh installs, proves idempotent persistent activation, validates the legacy explicit-Claude-settings compatibility file, and drives configured/untrusted, trusted, and disabled handler states through a deterministic Codex app-server contract double. A disposable SSH/tmux fixture separately verifies exact v7 artifacts, executable shims/launcher/hook status, lossless Codex hook merging through a preserved symlink, no-newline rc repair, bash-login/ZDOTDIR startup, generic bash/zsh aliases/functions, post-source PATH changes, symlinked shim aliases, concurrent identity probes, arbitrary preserved WINCH traps, bounded Python-free hook parsing, and inherited runtime markers. The opt-in local gate launches the actually installed Codex and Claude Code in isolated tmux servers and requires PID-bound provider `SessionStart`, `idle → working → idle`, plus `working → waitingForInput → working → idle` around a real safe permission request. Codex additionally exercises its exact enabled-but-not-yet-trusted configured bootstrap before the first prompt, fresh hook review, active hook tables before and after relaunch, its machine-readable trusted+enabled `hooks/list` proof for the pre-thread empty composer, and the real `/plan` flow whose `Stop(idle)` boundary is correlated with the subsequently painted three-option plan-approval dialog. The gate covers every state on Tessera's immediate OSC path, retained state while blocked, the visible approval UI, a production-equivalent staged text/semantic-Return boundary, final completion, and a content-free host diagnostic summary. Raw terminal capture is deleted after producing a content-free state trace; the plan-approval screen is retained as provider-contract evidence. |
| MG1 | partial, high value | A disposable on-disk SwiftData store containing all three models and the `[String]` field is closed, reopened through the migration plan, and value-checked. Archived previous-release stores and physical upgrades remain release gates. |

The ordinary ~660 unit/package tests remain the fast per-change lane. This
suite runs only the new matrix-derived offline oracles plus the opt-in live and
visual boundaries, avoiding a duplicate full unit pass.

## Artifacts

Each run is written to `scripts/integration/out/<UTC-run-id>/`:

- `visual/aggregate-manifest.json` and `image-list.txt` — the one AI bundle;
- `visual/codex-events.jsonl` and `codex-review.json` — evaluator trace/result;
- `visual/cases/` — stills, recordings, contact sheets, event logs, and metrics;
- `programmatic/results.json` and `programmatic/logs/` — one record per check;
- `programmatic/*.xcresult` — focused Xcode result bundles;
- `report.json` — aggregate verdict and both lane statuses.

## Intentionally manual

Physical trackpad latency/feel, deep mosh-overlay paging continuity, plain-mosh
Vim `mouse=a`, network roaming,
background/lock survival, Secure Enclave and real Face ID, hardware-keyboard
chords intercepted by Simulator, dictation, Stage Manager, cross-app drag/share,
pointer-triggered context menus, and real previous-release/device upgrades stay
in the manual matrix. Simulator coverage is not reported as proof of those
device-only properties.
