# Agent Center ingestion rework — implementation plan

Status: **implementation authorized; capability probe completed; implementation in progress**.
Date: 2026-09-12.
Planning worktree: `.worktrees/agent-center-performance`.
Branch: `codex/agent-center-performance`.
Planning baseline: `353397b11bebaa8d1def14128836bb5165a864ed`;
original worktree base: `94d65a0cc562fd6e7048bb1fa4e1e12cb233e591`.
The primary checkout has advanced and contains unrelated changes. Reconcile
affected interfaces against then-current main before implementation; do not
overwrite or merge unrelated work. The user authorized implementation on
2026-09-12 and explicitly removed compatibility requirements for the unshipped
Tessera ingestion protocol. Historical provider formats and safety regressions
remain required coverage, not legacy Tessera protocol obligations.

## 1. Outcome and scope

Make opening, following, and scrolling large conversations fast without
memory use growing with transcript size. Ship one precompiled host helper,
connected through an existing authenticated SSH side channel. Its lifetime is
bounded by its client leases, not a permanently installed daemon. The service
is shared across apps/devices for the same active host-session scope and lives
while any client lease remains. Installation of its
executable may persist; its process need not. This replaces the first draft's
incorrect per-app service cardinality.

The three conversation operations are:

| Operation | User experience | Contract |
|---|---|---|
| Bootstrap | Open a thread and show useful recent content promptly | Bounded newest window, older cursor, live checkpoint |
| Ranged history | Scroll upward for older content | Records before a stable anchor; does not change the live checkpoint |
| Subscription | Keep list summaries or an open conversation current | Slow summary polling or fast transcript updates, delivered as events |

Include iOS/iPadOS and Android, plain SSH, SSH+tmux, mosh, and mosh+tmux.
Use one ingestion implementation across transports; only acquiring the SSH
side channel is transport-specific. Do not route this protocol through the
terminal PTY, tmux screen, or Mosh display stream.

Non-goals: a cloud service; accounts/telemetry; permanently running host service;
owning or resuming the user's provider session; new send/interrupt behavior;
full archive indexing/search redesign; copying whole conversations into an app
database. Preserve existing actions, attention, search, and receipt contracts.

## 2. Evidence and unresolved assumptions

The existing [ingestion report](research/agent-center-ingestion-2026-09-11.md)
and [cold-page report](research/agent-center-cold-first-page-2026-09-11.md)
are the baseline, not performance guarantees for this design:

- Largest Codex snapshot: 376.9 MB; median cold model readiness 21.743 s.
  Largest Claude snapshot: 46.5 MB; median 0.254 s. Three trials each,
  application-state cold and filesystem-cache warm, on the development Mac.
- That endpoint includes the real Apple decoder and shared reducer, but not
  discovery, SSH/network, device layout, or first paint. No measured 60+ s
  unprofiled cold baseline was established. A different 29.528 s helper sample
  is not comparable evidence of an optimization.
- The helper already bounds retained memory, but rescans history. Keeping its
  interpreter alive alone does not solve this. Native parser controls are
  not complete replacement projectors.
- Earlier read-only Codex probes observed roughly 2–4 ms history reads on
  smaller paginated sessions. They did not establish equivalent performance
  on the largest legacy store. A separate read-server did not reliably receive
  native events for the actively running external CLI, and its runtime status
  was not authoritative. Reproduce these findings in a checked-in harness.

Official OpenAI documentation makes stored history pagination experimental and
store-dependent; `thread/read` is not a subscription. Capability detection,
not a version string alone, selects the reader. [Codex App Server](https://learn.chatgpt.com/docs/app-server)

Implementation probe clarification: Codex 0.154.0 `thread/list` filters out
empty-preview rows, including populated subagent histories. Native discovery
therefore merges authorized transcript locations with listed native IDs; a
known lifecycle/native ID absent from the list must be confirmed by an exact
`thread/read(includeTurns:false)` response, never accepted solely from caller
input or by hydrating full history. The private corpus verifies this path for
all 612 populated native histories. Truly unknown native-only empty-preview
threads remain a discovery gap in this upstream API; do not claim its listing
is an exhaustive database inventory. [Versioned upstream list filter](https://github.com/openai/codex/blob/rust-v0.154.0/codex-rs/state/src/runtime/threads.rs#L1357)

Claude 2.1.269 real-provider probes verified interactive `MessageDisplay`
streaming in both synchronous and async command hooks. Eleven synchronous and
eight async batches each reconstructed the exact `Stop` text, with contiguous
indices and exactly one final batch. Headless hooks delivered complete text,
prompt, lifecycle, and Read tool events. Display identifiers are not canonical
transcript identifiers. See the [probe report](research/agent-center-claude-hooks-2026-09-12.md)
for measurements, limits, and the hook-plus-transcript recommendation.

## 3. Host process, deployment, and connection ownership

### 3.1 Shared service, discovery, and lifecycle

Proposed executable: `tessera-agent-host`, installed through the existing
explicit integration install/update flow. Each app starts its lightweight
`connect --stdio` relay over its own authenticated SSH exec channel. The relay
connects to the existing shared service through a private Unix-domain socket,
or starts it once if absent. Only the service performs ingestion, maintains
indexes/caches, and owns provider read-server children. A second relay is not
a second ingestion server. No TCP listener, public port, systemd unit, launch
agent, root permission, or runtime compiler is required.

Proposed native baseline: C++17 with pinned simdjson, matching the parser
candidate already measured. This is a review decision, not a claim that raw
DOM parsing solves oversized records. Reuse the native parser; port only the
bounded projection/framing logic that the parser does not provide. Benchmark
and fuzz the complete reader before freezing that choice. [simdjson](https://simdjson.org/)

Initial release artifacts: Linux x86_64/aarch64 and macOS x86_64/arm64, with
explicit minimum OS/libc/CPU requirements and no assumption of AVX2. Validate
Linux glibc and musl support or report an unsupported target; do not quietly
download dependencies or compile on the host. Bundle signed/checksummed
artifacts with the app's distribution resources and upload the selected one
through authenticated SSH. Audit licenses, notices, binary size, and release
packaging before enabling distribution.

Use user-owned, non-world-writable versioned installation paths. Verify
artifact identity before atomic activation; preserve the previous executable
for rollback and let running processes finish on their original version.

Cardinality is **one shared service per active host-session scope**, not per
Tessera app, SSH transport connection, device, or SSH key. Resolve scope on the
host from remote OS user, execution namespace/environment, and canonical
host-session/provider-root scope. App-local host/session UUIDs and SSH key
fingerprints must not fragment the same remote scope. Pixel and iPad using
different authorized keys for the same remote account/session reuse the service.
Different remote users or genuinely isolated host environments do not share it.
Multiple terminal routes within one scope multiplex through the same service;
tmux pane IDs remain route metadata, not a reason to spawn a server per pane.

For active-pane custom provider homes, the fixed SSH exec command consumes a
bounded initial hello before selecting the scope. A Core-issued route supplies
only a process ID, never a provider-root path. The helper verifies the live
same-UID process and start identity, retains only `CODEX_HOME` and
`CLAUDE_CONFIG_DIR`, and wipes the temporary environment buffer before forking.
Linux additionally requires matching mount/PID/user namespaces and filesystem
root. A PID reused before the first kernel sample is not detected by this
bracketing; route freshness remains mandatory, and no action authority comes
from context selection.

The authenticated hello returns an opaque `contextScope` lookup token. Keep
this token in app memory across background/carrier teardown so an exited
provider does not prevent ranged-history reconnection. Restoration accepts
only an existing private, same-UID scope witness; canonical roots, namespaces,
permissions, link count and full scope identity are revalidated. Tokens are
not bearer credentials and never bypass SSH authentication. They cannot
recover a never-observed custom root after the originating process is gone.
Retained token aliases are bounded to 128 per app-owned session and active
scope connections to eight; closed and abandoned openings do not consume the
latter budget. Merge new aliases only into already-admitted matching service
epochs, and reject conflicting exact Core thread identities across sessions.

Implement discover-or-start under a host-local exclusive lock in a private
runtime directory. The winning service holds the singleton lock for its
lifetime; racing relays recheck and attach. Validate directory/socket ownership,
type, permissions, and peer identity; never trust a PID file alone. Recover
stale owned socket metadata only under the lock; do not unlink or kill an
unverified object/process. The service must survive its first SSH relay closing
without inheriting that relay's stdin/lifetime as its supervisor.

Each app connection has its own lease, request IDs, authorization context,
subscriptions, acknowledgments, history cursors, and output queue. Readers and
eligible caches are shared; delivery and cursors are not. Aggregate highest
interest across clients for each thread, so a backgrounded Pixel cannot
downgrade the iPad's fast subscription. Disconnecting one client cancels only
its work/demand, not reads still needed by another client.

Proposed lifecycle: heartbeat every 10 s; a client's lease expires after 30 s
without renewal; best-effort release on shutdown/suspension. Retain the service
and shared provider children while any valid lease remains. After the last
lease is released/expires, a 30 s idle grace permits quick reconnection; then
exit and reap owned children, releasing the owned socket/lock safely. New
connections race safely with idle shutdown. Never stop the user's Codex,
Claude, OpenCode, or Pi process. Mobile background execution is not assumed.

| Example | Required result |
|---|---|
| Pixel connects first, iPad connects next | Two authenticated client relays, one ingestion service and shared readers |
| Pixel backgrounds/expires while iPad remains active | Only Pixel's lease/demand expires; iPad continues uninterrupted |
| Both apps background and their leases expire | Service exits after idle grace; no permanent watcher remains |
| Either app returns before the last lease/grace expires | Reuse the same service; independent catch-up for that app |
| An app returns after the service exited | Start exactly one fresh service; resume if validated, otherwise bootstrap |

When a carrier disappears, fence its responses and reconnect through another
already-authorized carrier if available; never initiate a new user host
connection to keep ingestion alive. A new service epoch invalidates stale
replay tokens. Protocol negotiation detects mismatched clients; supporting the
old unshipped Tessera protocol is not required. An incompatible app must not
start a competing service under a version-specific socket or kill the existing
one: report capability mismatch and require an explicit integration update.
Switch the service binary when idle,
or through a separately authorized coordinated restart, not on second-app attach.

### 3.2 Authentication, authorization, and sensitive-data security

The recommended v1 authentication design is **SSH-authenticated access through
a same-user local relay**, not a network API with an independently distributed
bearer token. SSH authenticates the remote account and protects the remote
channel; existing host-key verification authenticates the host to Tessera.
That does not by itself secure the new local socket or authorize every request.
[OpenSSH authentication and transport](https://man.openbsd.org/ssh.1)

Trust path: Tessera → verified authenticated SSH exec → fixed installed relay
running as the remote user → protected Unix socket → same-user service.

Required controls:

1. **No network endpoint.** Do not bind even a localhost TCP fallback: other
   local users may reach it. If socket transport/peer verification is unsupported,
   fail closed with an unsupported-host explanation; do not weaken auth.
2. **OS-enforced local identity.** Use a service-owned mode-0700 runtime
   directory and restrictive socket permissions, created with a safe umask.
   Verify peer UID on both service and relay using platform-supported kernel
   credentials (Linux `SO_PEERCRED`, macOS/BSD equivalent). Reject wrong-user
   peers before accepting protocol requests. Permissions alone are not assumed
   portable across Unix platforms. Test each released OS implementation.
   [Unix socket credentials](https://man7.org/linux/man-pages/man7/unix.7.html),
   [BSD peer identity](https://man.openbsd.org/getpeereid.3)
3. **Server-owned scope.** Resolve allowed provider roots and thread handles
   in the authenticated remote-user context; canonicalize and safely open paths
   without traversal/symlink races. A client-supplied user name, host ID,
   provider root, cursor, or file path cannot expand access. Do not relay
   arbitrary shell commands or arbitrary App Server methods.
4. **Read-only ingestion.** Allowlist inventory/history/subscription operations;
   exclude provider control, filesystem writes, shell execution, and attachment
   exfiltration URLs. Existing send/interrupt paths retain their separate proof
   and authorization. Treat transcript content as untrusted data, never commands.
5. **Client separation.** Bind subscription/replay/cancel IDs to the accepted
   connection and server-issued lease. A self-asserted app/device ID is a
   diagnostic label, not identity or authorization. Another connection cannot
   cancel, acknowledge, consume, or renew someone else's lease. Resume requires
   fresh authenticated attachment and validation of cursor scope/generation.
6. **Bounded exposure.** Apply per-client and global quotas before allocation,
   isolate slow consumers, and bound diagnostics. Runtime files, temporary
   indexes, and test artifacts are user-private. No transcript bodies, prompts,
   tool output, credentials, or private paths in routine logs/telemetry/git.
   Avoid content-bearing crash dumps where controllable; disclose OS-level dump
   limits rather than claiming secure erasure of RAM or storage.
7. **Installation integrity.** Verify signed/checksummed bundled artifacts,
   private ownership, and non-writable executable parent paths. No secret in
   command-line arguments, environment dumps, socket names, or discovery files.
   Never use forwarded SSH-agent access as service authentication.

Threat boundary: v1 authorizes the **remote OS account**, not a hardware device
independently of that account. Root or another process already controlling the
same UID can generally read the original transcript files and impersonate a
same-user relay; this design does not promise isolation from that adversary.
A shared token stored under that same UID would not create such isolation.
Supporting restricted SSH accounts, stronger device-specific grants/revocation,
or direct TCP/WebSocket access would need a separately reviewed identity and
capability design. Existing key restrictions/forced-command policy must be
honored; unsupported exec access is not bypassed. SSH-key revocation prevents
new authentication but is not claimed to terminate existing SSH sessions.

Mandatory security review/test gate: wrong UID; socket squatting and symlink
swap; forged scope/cursor/client IDs; cross-client cancellation/replay; stale
service epoch; malformed/oversized frames; shared-service flood/queue fairness;
expired lease; incompatible client; and read requests attempting provider
mutation. Perform this review before the first real-data multi-client milestone.

### 3.3 Jump hosts and multi-hop routes

The service, relay, socket, provider children, and transcript reads belong on
the **final destination host**, not a bastion. Use the existing terminal
session's destination SSH client/route owner to open the fixed relay command.
Do not shell out to `ssh` on the bastion, copy destination keys there, require
agent forwarding, or introduce a separate direct-to-target connection.
Jump connections forward transport to the final destination; hop identity and
destination identity remain distinct. [OpenSSH ProxyJump](https://man.openbsd.org/ssh_config#ProxyJump)

- Preserve destination host-key validation and distinct credentials/host-key
  decisions for every hop. A trusted bastion is not proof of a trusted target.
  The final SSH encryption/authentication terminates at the target, not the
  relay on a bastion. The bastion can disrupt traffic; do not promise availability
  or protection of routing metadata from it.
- Reuse existing nested SSH forwarding channels. Install/update and reconnect
  use the same approved chain, even if target DNS/IP is only reachable from the
  last hop. No direct DNS/reachability prerequisite or public helper port.
- Separate **route identity** from **service scope**. Pixel through bastion A
  and iPad through bastion B (or direct SSH) may attach to the same verified
  destination/account/session service. Do not key the remote singleton by
  bastion IP, chain length, forwarded local port, or app-local host UUID.
  Conversely, never merge different targets because they share a bastion or
  happen to advertise the same hostname. Resolve scope on the authenticated
  target; keep client-side carrier/host-trust fencing independent.
- A failed/rekeyed hop invalidates that client's delivery route, not another
  client's lease. Preserve existing route-owner cancellation semantics so
  closing the ingestion exec does not close terminal, forwarding, sibling exec,
  or shared hop connections. Reattachment uses a new connection epoch.
- Mosh and mosh+tmux still use the destination SSH side channel for ingestion.
  Existing Mosh UDP routing/fallback policy is unchanged: ProxyJump support for
  SSH does not imply UDP is tunnelled. If Mosh remains usable while SSH is down,
  show ingestion stale and reconnect only through the session's approved policy.
- No service installation, sockets, transcripts, credentials, or plaintext
  ingestion logs are left on intermediate hops. Report hop-specific auth/trust/
  forwarding errors without falling back to insecure/direct access.

Extend the existing `scripts/integration/jump/` lane on both platforms: direct,
one-hop, and multi-hop; distinct credentials per hop; target reachable only
through bastion; wrong key at each hop; denied forwarding; disconnect/rekey
during bootstrap/history/live; Mosh UDP available/unavailable; and two clients
reaching one destination via different routes. Assert one destination service,
zero bastion services, continued delivery to the unaffected client, and complete
test-owned cleanup. A skipped jump-host lane does not satisfy this release gate.

## 4. Protocol v3

The initial design used v2. Atomic revision resegmentation makes the wire
contract v3: both apps require `window.partitions`, and a different version
is rejected before client admission. References to the new v2 architecture
below describe this same replacement architecture, now negotiated as v3;
they do not require a second compatibility stack.

Use bounded JSON envelopes over duplex stdin/stdout, with a four-byte
big-endian byte length. Diagnostics go to separately bounded stderr. Maximum
envelope: 64 KiB including metadata; maximum logical page: 256 KiB and 100
normalized records, split across envelopes as needed. Reject an advertised
oversized frame before allocating it. Validate aggregate page bytes too.
If one normalized record exceeds an envelope, use explicitly numbered record
fragments, bound their aggregate size, and validate only after reassembly;
never splice arbitrary JSON fragments into otherwise valid envelopes.

Replace the unshipped v1 ingestion path with the new contract; do not maintain
dual protocol reducers, old cursors, or per-refresh compatibility reads. Every
request carries a request ID; responses carry service epoch, connection epoch,
and source generation. Every subscription event also carries subscription ID and sequence.
Neither an opaque cursor nor a thread ID grants filesystem or action authority.

| Message | Important fields / behavior |
|---|---|
| `hello` | Protocol range, service identity/epoch, authenticated scope, helper build, provider capabilities, enforced limits, server-issued client lease |
| `inventory` | Bounded thread discovery; opaque thread handles resolved within allowed roots |
| `bootstrap` | Thread handle, page budget; captures a consistent boundary and issues a short-lived catch-up token |
| `history` | Thread handle, `before` cursor, budget; exclusive anchor, chronological response order |
| `subscribe` | Thread handle, `slow`/`fast`, bootstrap token or last acknowledged checkpoint |
| `setInterest` / `unsubscribe` | Change delivery priority or release subscription and its state |
| `page.begin` / `page.records` / `page.end` | Correlated transaction; end validates record/byte counts and publishes cursors |
| `update` | Bounded upsert/remove/summary batches; stable record IDs and monotonically advancing revisions |
| `ack` / `cancel` / `heartbeat` | Applied checkpoint, request cancellation, connection lease renewal |
| `reset` / `resyncRequired` / `error` | Explicit discontinuity, expired replay/cursor, capability or bounded-read failure |

Publish each page atomically at validated `page.end`, without waiting for
process EOF. Do not display incomplete pages as successful results. A broken
connection does not invalidate previously committed pages; mark freshness stale.
Cancellation is request-scoped within the authenticated client, not service-wide.
Bound outstanding requests and ensure cancellation cannot publish a late page
into a different thread.

Bootstrap returns `olderCursor`, `liveCheckpoint`, source generation,
`hasOlder`, and completeness/truncation metadata. History returns a new older
cursor only. Cursors bind provider, source identity/generation, position, and
projection version; validate their lengths and context. They must not depend
on display row indices or timestamps alone.

Ranged history supports both `before` and `after`. Bounded clients evict the
opposite end while scrolling; an exclusive after cursor is therefore required
to recover evicted newer content without gaps. Arbitrary timestamp ranges and
`around` remain out of scope. A cursor must either advance or return an explicit
terminal/error state; an empty visible page may still advance across
non-display records.

### Bounded viewport, live head, and revision coverage

Maintain a contiguous viewport of at most four page segments (400 records,
1 MiB normalized content), independently from a live-head segment (100 records,
256 KiB). Reserve one 256 KiB pending transaction per client/thread. Derived
client content has its own byte budget; all ceilings apply simultaneously.
The visible anchor segment is pinned. Evict only whole offscreen segments from
the end opposite navigation, before atomically publishing the new page and
both recovery cursors. A page that cannot fit must not advance a cursor.

Each immutable segment has an opaque ID, source generation, first/last stable
record IDs and orders, exclusive before/after cursors, and hasOlder/hasNewer.
The client ACK names its retained viewport segment IDs, retained head segment,
and window version. Host retention changes only after that ACK. Pending pages
and duplicate ACKs are bounded and idempotent; retained segment cursors are
pinned rather than expired by an unrelated FIFO.

Native revisions cover exactly those retained segments, reread from their
local provider anchors, not by scanning from the live tail across evicted
history. No autonomous host oldest-record eviction may silently reduce that
coverage. While the viewport is detached, updates advance the separate head
and receipt lane without appending across a missing interval into history.
Both UIs paginate at both edges and preserve the stable visible block/pixel
anchor. A historical window's last row is not the conversation's newest row;
live previews and outgoing messages belong to the live-head lane.

## 5. Bootstrap, live handoff, and consistency

1. Resolve identity through existing validated discovery/lifecycle evidence.
   Show available title/status metadata without waiting for transcript work.
2. Establish a source boundary and a bounded catch-up lease before reading the
   newest window. For JSONL this includes file identity and complete-record
   offset; native APIs use their supported cursors plus an overlapping re-read.
3. Emit the first useful bounded page. The client displays it immediately,
   then subscribes using its catch-up token. Writes during bootstrap are
   replayed, reconciled by stable IDs, or explicitly require resynchronization.
4. Let the client ask for older pages until roughly two viewports of coalesced
   visible content are filled. Limit automatic fill to five page requests and
   a 1 MiB total response budget; stop when either budget is reached. Manual
   scrolling may continue. The host does not guess pixel height.
5. Keep history and live state independent. Prepending history must not replace
   a newer live revision. Sequence/revision checks reject duplicates and stale
   records, including responses from an old carrier or retired selection.

Do not claim an atomic provider snapshot if the provider offers none. Test
overlap/reconciliation under concurrent writes; when continuity cannot be
established, return reset/resync rather than silently omitting records.
Live catch-up scans must reach their saved boundary, not just compare the
newest page: a burst larger than that page must not skip intermediate items.

A source replacement, truncation, incompatible schema, or branch change can
invalidate cursors. Send a reasoned reset, retain the last displayed window
as stale until replacement data is ready, and restore the scroll anchor if
the record still exists. No infinite automatic retry on an invalid cursor.

For supported append-only JSONL writers, rely on an explicit append contract
within a source generation, with stat/file identity and bounded anchor checks.
This does **not** detect arbitrary same-size edits in an unread old prefix.
Remove whole-prefix hashing from ordinary refresh only with this contract
documented. If strict arbitrary-edit detection is required, it is a separate
cost/consistency decision; an incremental hash cannot prove unseen bytes.

## 6. Provider work

### Codex

- Prefer `thread/list` and lightweight `thread/read` for discovery/metadata,
  without loading full turns. Preserve existing process/lifecycle evidence
  for mapping a stored thread to the user's live terminal pane.
- Capability-probe `thread/items/list` and `thread/turns/list`; fetch newest
  items first, walk backward within the page budget, and normalize provider
  IDs/revisions. Test ordering and cursor validity during writes.
- **Freshness correction from implementation probes:** a supported,
  identity-checked canonical rollout takes precedence over materialized App
  Server history. Codex 0.154.0's paginated response has no materialization
  ordinal/freshness witness; private finite-clone and synthetic production
  probes demonstrate that successfully returned native pages can omit later
  persisted messages and revisions. Discovery remains App Server assisted;
  native pagination remains a capability for genuinely absent or unmarked
  rollouts, not an assertion that its store is current. Never resume/mutate
  the user's provider to force materialization.
  Probe only the first record (8 MiB explicit header cap), never scan an
  unfinished tail merely to select authority. Reauthorize archive relocation,
  fail closed on ambiguous/invalid identity, and require a fresh bootstrap when
  an existing native window acquires canonical authority. Summary previews use
  the same canonical ownership/lineage/replay selection as pages, with shared
  bounded indexes and dependency revalidation. Retain in-flight metadata
  prefixes across worker yields; capacity exhaustion is explicit, not repeated
  cold restarts or stale/native substitution. Cold summary index construction
  must be measured separately from warm metadata polling.
- Start at most one read-only stdio App Server child per relevant Codex
  environment. Allowlist read methods. Do not call resume/start/steer/interrupt
  or modify provider configuration to make observation work.
- Slow mode polls metadata/summaries; fast mode polls bounded newest items
  and mutable tail records, advancing/catching up without missing bursts
  larger than one page. Do not repeatedly fetch every turn with full items.
- Do not depend on the file-watch experiment for delivery. Native event use
  can be added only for a proven attachable endpoint and verified semantics.
- Treat stored transcript state and live working/idle evidence separately;
  `notLoaded`, a quiet file, or a reconstructed interrupted turn is not proof
  that the external CLI is idle. Retain existing authoritative lifecycle hooks.
- If pagination is unsupported, use the native JSONL adapter where semantics
  are supported; otherwise explicitly expose the bounded legacy path. Never
  silently substitute a full-history App Server response on the fast path.

### Claude Code and supported JSONL harnesses

- **Fast mode: async observational hooks plus canonical tail reconciliation.**
  Install a bounded native command sender through the explicit integration
  install flow, preserving unrelated user hooks. `MessageDisplay` provides
  assistant text batches; `UserPromptSubmit` supplies prompt events;
  `PreToolUse`/`PostToolBatch` provide tool identities and model-facing results;
  lifecycle/Stop/StopFailure events wake status and reconciliation. These are
  capability-gated, not assumed on older Claude versions. Existing sessions
  without the hook configuration continue via tail/watch/stat reconciliation.
  [Claude hook reference](https://code.claude.com/docs/en/hooks)
- The hook connects only to the existing private same-user socket. It emits
  no stdout, performs no model/display transformation, starts no service,
  renews no client lease, and writes no spool. A missing service is a cheap
  successful no-op. Bound stdin and socket work to 100 ms and 64 KiB; oversize
  sends a small reconciliation hint, never truncated JSON. Async is preferred
  to avoid holding the terminal display, but is lossy at process teardown.
- Treat pushed display text as a provisional overlay keyed by session,
  turn, display-message ID, and batch index. Dedupe by index; bound reorder
  buffers, accept empty final batches, and detect gaps. Never equate display
  IDs with transcript UUIDs/API message IDs. Reconcile to canonical assistant
  records at turn completion and periodic checkpoints; retire provisional
  text atomically, rather than adding duplicate bubbles. Ambiguity, overflow,
  restart, missing hooks, or out-of-order completion causes canonical reread.
  Tool hooks may also be incomplete/oversized, so they cannot replace history.
- Bootstrap and ranged history remain bounded canonical file reads. Hooks
  cannot backfill old sessions or recover events while all apps were away.
  File/directory notifications accelerate reconciliation; stat polling remains
  the safety net. Slow subscriptions remain host-side polling as requested,
  with hook hints coalesced until the next scheduled slow update.
- Before implementation, evaluate official read-only session interfaces as a
  semantic reference and bounded-read candidate. Do not assume a documented
  result limit bounds underlying disk reads or startup memory. Claude's docs
  explicitly call raw JSONL entry formats internal and version-dependent;
  there is no stable exhaustive raw schema established by this research.
  Keep a versioned compatibility adapter and type coverage inventory.
  [Claude session storage](https://code.claude.com/docs/en/sessions),
  [official session-message interface](https://code.claude.com/docs/en/agent-sdk/python#get_session_messages)
- Discover paths using existing validated roots and bindings. Seek backward
  in fixed-size chunks, frame complete JSONL records, and stop once the page
  budget is satisfied. Reuse the saved offset for the next older range.
- Parse forward from the complete-record checkpoint for live updates. Watch
  files/directories to wake reads, reconcile with stat polling, and reopen
  safely on replacement. Defer incomplete trailing records, including UTF-8
  split across writes. Never allocate an unbounded `readline` buffer.
- Use a capped normal-record parser path. For oversized records, a bounded
  streaming projection path skips embedded binary/image data, retains bounded
  needed text/identity fields, and emits valid normalized objects with explicit
  truncation metadata. Do not truncate raw JSON and pass it to a DOM parser.
  If a record cannot be projected within the contract, report a visible
  unsupported/truncated record; do not silently lose it or label it malformed
  merely because it is large. Differential-test this path against the current
  projector and fuzz strings, escapes, nesting, and image payload boundaries.
- Preserve parent/branch relationships and tool-call identities. Tail bytes
  alone are not a generic conversation model. Build only required sparse
  metadata/indexes, under quotas, and report partial/unavailable semantics if
  a bounded read cannot resolve the active branch; do not present wrong history.

### OpenCode

Assumption: the earlier “openclaude” reference meant OpenCode; another harness
would need its own capability assessment. OpenCode has HTTP read APIs and SSE.
Use the existing instance when an endpoint and credentials are already known;
do not launch a second session-owning server or expose an unauthenticated port.
[OpenCode server documentation](https://opencode.ai/docs/server/)

Probe bounded history capability separately from SSE support: a `limit`
parameter alone does not prove older-range pagination. Use the existing
read-only SQLite adapter as the historical fallback with keyset ordering,
schema checks, and bounded transactions. Honor SQLite locking/WAL semantics;
do not copy just the database file while ignoring its WAL. In v1, slow mode
still polls; fast mode may use SSE with catch-up after reconnect.

Implemented probe-driven baseline (OpenCode 1.18.29): the passive adapter uses
native kernel notifications on the authorized SQLite WAL, with bounded polling
for missed events or WAL replacement. This provides fast committed updates
without discovering HTTP credentials, starting another OpenCode server, or
installing provider plugins. No SSE attachment is claimed for an instance
whose endpoint/credentials are not supplied. HTTP/SSE remains an optional
adapter for explicitly available endpoints, not a prerequisite for passive
local-session support. Legacy keysets follow the actual message and part
indexes (not a nonexistent session-wide part-time index); neighboring-ID
witnesses detect interior insertions and require explicit resynchronization.

### Pi and remaining providers

Pi RPC has structured live events, but `get_messages` returns all messages;
its on-disk sessions contain parent-linked branches and compaction entries.
These are not equivalent to bounded passive attachment.
[Pi RPC](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/rpc.md),
[session format](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/session-format.md)

Replace per-refresh snapshot-copy/process-start/full-message reads with a
branch-aware file adapter where validated. Use an existing RPC connection
only when actually available and authorized; no speculative attach support.
Separate displayed historical conversation from compacted model context.
Resolve parent IDs through a quota-limited sparse index; first-paint behavior
on old branches is an explicit benchmark, not an assumed suffix optimization.

Inventory every provider currently supported by Tessera, including Kimi and
Tier-C adapters. Implement and test equivalent read semantics or retain a
clearly identified provider-format adapter using the new ingestion contract.
Do not retain the old Tessera transport as a compatibility mechanism.
Codex/Claude can ship first behind provider
gates; do not remove working providers to claim migration complete.

Kimi's implemented adapter uses the official 0.41.0 wire 1.4/1.5 display-history
reducer as its semantic reference, not a raw suffix of authored messages.
Exact membership in the fixed-root session index authorizes main and child
agent wire files; tombstones revoke existing handles. Bootstrap, history,
search and fast file subscriptions share the bounded canonical replay index.
Both apps require `kimi.wire.v1.4-v1.5`. The public schema fixture covers all
60 durable record types; private full-host testing additionally compares
selected content/order and audits every complete physical record for unknown
or unparsed content. [Pinned official wire manifest](https://github.com/MoonshotAI/kimi-code/blob/95478e8c7ba248fd2470d5bb151555ec7fedd19d/packages/agent-core-v2/docs/wire-manifest.d.ts)

## 7. Scheduling, resource limits, and client UX

Proposed initial defaults, to tune in the acceptance runs:

| Resource/policy | Default |
|---|---|
| Slow subscription | Poll every 5 s with jitter; summary/status only, no full transcript projection |
| Fast Codex subscription | Poll every 500 ms while working/unknown; back off to 2 s only with reliable idle evidence |
| Fast JSONL subscription | File wakeups plus 1 s reconciliation poll |
| Concurrency | At most two expensive provider reads per helper; one mutating reader task per thread |
| Logical page | At most 100 normalized records / 256 KiB; wire envelopes at most 64 KiB |
| Parsed normal-record input | 1 MiB cap; larger records use bounded streaming projection |
| Per-thread cached normalized content | 2 MiB, LRU with visible-window pinning |
| Helper normalized cache | 32 MiB across all threads |
| Outbound backlog | 2 MiB total per connection; overflow invalidates affected replay and requests resync |
| Shared delivery memory | 8 MiB total across clients, including catch-up/replay; one stalled app cannot exhaust service memory |
| Attached clients | At most 8 concurrent client leases per service; explicit busy response above this limit |
| Sparse index (implemented tuning) | 16 MiB accounted metadata per cache family: Codex, shared Claude/Pi, Kimi; 48 MiB aggregate plus bounded cache-container overhead; no disk transcript/index spool |
| Outstanding requests | 16 per client / 64 total; fair queuing, cancellation, and per-request deadlines |

The initial sparse-index proposal was 16 MiB for the entire helper. The
implemented independent provider caches each retain a 16 MiB budget (24 entries
maximum); do not describe that as a 16 MiB aggregate or an OS RSS limit. A single
Codex index may use 8 MiB (the largest audited selected history needs about
6.4 MB); Claude/Pi and Kimi indexes each admit at most 4 MiB. Eviction respects
active/pending history pins and capacity failure remains explicit. This tuning
keeps one provider's retained metadata independent of another's; actual helper,
child and app RSS is separately measured by the acceptance suite. The 48 MiB
accounting ceiling is not added to independent sampled/lifetime peaks as if
they were a simultaneous measured total. SQLite separately caps its native
heap at 16 MiB; oversized streaming continuations share an 8 MiB retained-state
budget. None of these is a promise against every machine-wide OOM condition.

Scheduler priority: cancellation/control, bootstrap, live catch-up, user history,
then slow summaries; age queued work to prevent history starvation. Chunk long
scans into cancellable work slices. A proposed 250 ms / 16 MiB read slice yields
progress or continuation, not permission to loop unbounded before first paint.
Large native API frames have independent input caps and controlled failure;
a small outgoing page does not bound an App Server child's memory consumption.

Do not open one polling loop for each duplicate view. The helper shares reads
for identical threads across all attached clients and aggregates highest interest.
Preserve the requested
slow-mode polling contract in v1. Hidden threads have no transcript subscription;
existing attention/notification demand may retain a bounded summary subscription.

App behavior on both platforms:

- iPad/tablet: each actually visible detail pane has fast interest; visible list
  entries have slow interest. No fast subscription for merely cached navigation.
- iPhone/compact Android: list → detail → back changes interest, retains a
  bounded viewport cache, and cancels obsolete history requests. Loading/error
  controls must remain usable with the software keyboard and Dynamic Type.
- Anchor by stable record/tool identity plus viewport offset. Coalescing across
  a prepended page must not change the anchor. Incoming live content never
  forces a user reading older history to the bottom; show a new-content affordance.
- Release loading/cursor-request latches on error and cancellation so the same
  range can be retried. Deduplicate concurrent requests for the same cursor.
- Evict distant decoded content as users traverse history; virtualization alone
  does not bound model memory. Preserve reloadable anchors and pin the viewport.
  Target 8 MiB retained normalized content across the Agent Center client cache;
  measure native text/layout overhead separately and trim on memory pressure.
- Suspend/close releases that client's fast demand, not the shared service;
  resume reattaches and catches up or reboots the visible window. Ephemeral
  cursors/leases are not synced across
  devices; existing host/session/preference continuity remains unchanged.

Existing action proofs and receipt boundaries remain on their current safe
paths. New read cursors must never substitute for a send/interrupt proof.
Keep request paths allowlisted, inspect symlinks/file identity against approved
roots, and avoid raw transcript text, credentials, or paths in diagnostic reports.

## 8. Concrete code changes

Paths below exist unless marked new; names for new files are proposed.

| Area | Files / responsibility |
|---|---|
| Native helper (new) | `Tools/AgentHost/`: shared service, SSH stdio relay, socket/peer authentication, singleton lock, client leases, protocol, scheduler, bounded cache, JSONL reader, Codex/OpenCode/Pi adapters, build and parser tests |
| Shared contracts (new) | `Packages/TesseraCore/Sources/TesseraAgentCore/Ingestion/`: v2 envelopes, independent history/live state, capability and checkpoint validation |
| Existing shared domain | `Projection/AgentProjection.swift`, `Projection/AgentProjectionContinuation.swift`, `Reducer/AgentCenterRuntime.swift`: replace old cursor/reducer assumptions with independent ranges and revision-aware updates; preserve domain semantics |
| Shared presentation | `Presentation/AgentTranscriptGrouping.swift`: stable grouping/anchors across prepend and upsert |
| Host install | `Lifecycle/RemoteAgentLifecycleIntegrationInstaller.swift`: artifact selection, version negotiation, explicit update, rollback; keep existing lifecycle/action scripts |
| Apple duplex transport | `Tessera/AgentCenterV2/Platform/AppleCitadelAgentExec.swift`, `AppleAgentStreamingDataChannel.swift`: add bounded send/read/close session API; current code closes stdin and waits for exit |
| Apple orchestration | `Platform/AppleAgentSessionEndpoint.swift`, `AgentCenterV2Coordinator.swift`, `AgentCenterV2IntegrationCoordinator.swift`: host connection registry, route fencing, demand and range scheduling |
| Apple UI | `Views/AgentThreadDetailView.swift`, presentation model: viewport fill, stable prepend, retry/cancel and new-content affordance |
| Android transport | `android/agent-platform/.../AgentSessionEndpoint.kt`, `android/feature-session/.../SshAgentSessionEndpoint.kt`: allowlisted duplex operation, bounded channels and carrier lifetime |
| Android orchestration/UI | `android/feature-agent-center/.../AgentCenterPresenter.kt`, `AgentCenterScreen.kt`, `AgentTranscriptGrouping.kt`: same demand/history/live contracts through the shared bridge |
| Shared ABI | Existing TesseraCore C ABI/JNI bindings: expose v2 reducer state and capability values; retain wire-parity fixtures |
| Performance/tests | Extend `scripts/performance/agent_center_benchmark.py`, `scripts/performance/agent-center/`, `scripts/integration/run-agent-integration-script-tests.sh`; add native helper, multi-client security/protocol suites, and mandatory full-host-corpus compatibility runner |

Do not globally remove the existing Android five-second one-shot timeout.
Give v2 separate handshake, request-progress, lease, and idle policies. Keep
bounded per-request deadlines even though the connection is long-lived.

## 9. Acceptance and measurement

### 9.1 Mandatory full-host-corpus compatibility gate

The largest-file suite is only the performance sample. **Compatibility testing
must enumerate and exercise every Codex and Claude Code session/transcript on
the selected test host**, not just the largest three, hand-picked examples, or
synthetic fixtures. This full-corpus lane is mandatory before enabling either
refactored adapter and again before release. It is distinct from live-provider
E2E and from timing percentiles; all three gates are required.

Add a proposed `scripts/performance/agent-center/test_host_corpus.py` runner and
a checked-in, content-free schema/compatibility coverage report. Required work:

1. **Enumerate everything within the authorized provider roots.** Include all
   projects, historical/archived sessions, subagent/sidechain transcripts,
   legacy JSONL, and native paginated/session stores. Reconcile filesystem
   discovery against provider inventory when available. Do not deduplicate
   away a distinct file/schema variant simply because its session ID matches.
   No silent size/age/record-count filter. Report enumerated, readable, tested,
   unsupported, corrupt, incomplete-tail, permission-denied, and failed counts;
   every discovered candidate must have an explicit disposition. Missing roots,
   untested candidates, timeouts, and unexplained skips cannot yield a green run.
2. **Use finite private read-only snapshots.** Record capture time, opaque
   source ID, size, content digest, format and detected provider version. Freeze
   active JSONL at a complete-record boundary and report its excluded partial
   tail; test completion of that tail separately on a private copy. Capture
   native DB stores with a consistent snapshot including WAL state. Never
   resume a user thread or upgrade/migrate a user's live store for a test;
   use an isolated provider home/copy if startup could modify storage.
3. **Read the entire history, not just validate JSON syntax.** Exercise bootstrap,
   then exhaust older-range cursors and compare the chronological reconstructed
   conversation, roles, semantic blocks, identities, parent/tool relationships,
   compaction boundaries, attachments, ordering, title/preview seeds, and
   truncation flags. Verify that pagination/coalescing neither drops nor
   duplicates visible content. A parse-success exit code is not a coverage oracle.
4. **Use independent semantic references.** Compare new normalized output to
   the existing projector/shared reducer and, where available, official read-only
   provider interfaces. Existing code is not infallible: classify each mismatch
   against provider documentation and reviewed expected behavior. Generate one
   streaming reference pass per file instead of repeatedly rescanning it for
   every old page. For App Server vs raw JSONL, compare canonical semantics,
   accounting explicitly for different envelopes/metadata rather than requiring
   byte-identical representations. Retain private mismatch evidence for review.
5. **Exercise update boundaries across every corpus.** Replay records from each
   captured session into test-owned files/stores through the live path, with
   deterministic checkpoints and a sweep of observed record/block variants.
   Compare incremental results with the full canonical pass. Add split writes,
   tool input/output separated across pages, giant records, and branch/compaction
   transitions. Mutation/rotation/fuzz cases operate only on test-owned copies.
6. **Classify every observed type.** Maintain an explicit matrix of provider
   version/store format → envelope type/subtype/content block → normalized
   behavior → real-corpus counts → regression fixture/test. Classifications are
   rendered, retained as metadata, intentionally ignored with a documented
   reason, or unsupported. Unknown types cannot silently disappear. At runtime
   provide bounded safe fallback/diagnostics; in the compatibility gate,
   unexplained unknown or unsupported visible content fails. Never mistake
   deliberately hidden internal metadata for a missing human message.
   This must be independent of legacy-parser agreement: two generic unknown
   results are not semantic equivalence. Validate known-type field shapes,
   nested tool-result/metadata variants, null-vs-missing alias fallback, and
   unknown blocks outside bounded previews. Preserve diagnostics across the
   helper → shared model → native UI boundary. Diagnostic placeholders must
   not become authored prose or thread-title seeds. Report file-processing
   failures separately from unclassified/unsupported/malformed record counts.
7. **Keep the entire test corpus out of git.** Inputs, snapshots, provider homes,
   schema samples containing user content, paths/IDs, canonical transcripts,
   mismatch diffs, and recordings of real private sessions stay in explicitly
   user-private directories outside every worktree and are not uploaded. The
   runner must reject an in-repo raw-output destination, cap temporary disk use,
   support restartable runs, and clean up only its owned artifacts. Commit only
   reviewed content-free aggregate counts/digests and deliberately authored
   synthetic regression fixtures. Add a staging/content-leak check; gitignore
   alone is not the privacy guarantee. Do not run external AI review over raw
   private corpus artifacts; native visual reviews use synthetic/redacted data.

### 9.2 Official schemas and historical regression coverage

Implementation must be guided by authoritative provider contracts, not just
the current helper's recognized cases:

- **Codex App Server:** start from official documentation and generate version-
  matched JSON/TypeScript schemas with the installed CLI's schema-generation
  commands. Pin version/schema digest in the coverage manifest. Enumerate the
  entire `ThreadItem` union, nested input/content variants, relevant notifications,
  status/revision and experimental pagination contracts. The documentation's
  list of common types is not an exhaustive checklist. Map every relevant
  schema case to rendering, metadata, or an explicitly unsupported capability.
  [Official App Server schema and item documentation](https://learn.chatgpt.com/docs/app-server)
- **Codex rollout JSONL:** track its raw envelopes separately from App Server
  items; do not assume they share a schema. Consult official format material
  and version-matched provider type definitions where available, record their
  provenance, and supplement gaps with the full observed-corpus type inventory
  and existing regressions. An undocumented case must be labeled as such.
- **Claude Code:** the official session docs say raw transcript entries are
  internal and can change between versions. Use official session/SDK message
  and content definitions where documented; record raw-entry gaps explicitly.
  The documented `get_session_messages` interface offers `limit`/`offset` and
  user/assistant messages, not proof of an exhaustive raw-metadata schema or
  bounded physical I/O. Evaluate it as a reference/candidate, not a drop-in
  answer to tailing or completeness. [Session format caveat](https://code.claude.com/docs/en/sessions),
  [official SDK session messages](https://code.claude.com/docs/en/agent-sdk/python#get_session_messages)

Before changing normalization, audit **all relevant historical parsing fixes**
and create a fix → invariant → deterministic test → real-corpus coverage ledger.
At minimum preserve these verified commits and their existing tests:

| Historical fix | Required invariant |
|---|---|
| `e20f2263` — Claude compact summaries | Preserve summary content as a compaction boundary, never a human message or opening-prompt seed |
| `2012610a` — legacy Claude queue metadata | Oversized duplicated queued text cannot reject an otherwise valid bounded page |
| `45160a50` — Codex transcript artifacts | Preserve shared normalization/presentation of provider artifacts on both platforms |
| `46a46172` — Codex identity, metadata, live updates | Preserve source/thread identity, summary metadata, and update correctness |
| `afc8fb5d` — Codex image attachments | Keep attachment semantics and following prose; bounded redaction must not corrupt JSON or action evidence |
| `c429f2a9`, `f910d96e` — shared projection/history fixes | Carry forward applicable projector, pagination, delivery, and attention invariants |

This is a starting ledger, not permission to ignore earlier or newer fixes.
Inspect commit diffs and tests, including fixes on main after the worktree base;
do not blindly cherry-pick implementation into the refactor. Port tests before
replacing readers. Include existing reasoning summaries, internal/user metadata,
subagent attribution, content-array tool results, escaped images, opening prompts,
usage, exact append identity, and partial JSON record cases in the matrix.

Gate: all readable in-scope sessions exercised, every candidate accounted for,
zero unexplained semantic regressions or unknown visible message types, all
historical invariants passing on both platforms. Known damaged/inaccessible
sources need explicit disposition and approved exceptions; never count them as
successfully parsed. Synthetic coverage closes official-schema cases absent
from the corpus, while real corpus runs remain compulsory.

### 9.3 Performance, multi-client, and transport lanes

Record the full timeline: thread selected → discovery complete → helper ready
→ first committed page → shared snapshot → first native visible content →
two-viewport fill. An empty skeleton or progress frame is not a usable page.

Expand the suite with these lanes:

1. For repeated timing, exact existing six private corpus snapshots
   (hash-identified), plus current largest-by-size selection; this does not
   replace the full-corpus compatibility gate above. Legacy and paginated
   Codex stores are separate cases, not conversions silently substituted for
   the largest legacy file.
2. Cold full path from known host/session but unknown selected thread reference;
   helper/App Server/cache/index empty. Also retain the prior known-source
   model-ready lane for an apples-to-apples comparison. Measure artifact
   install/update separately from a normal already-installed cold open.
3. Steady unchanged, append bursts, mutable last item, older range near/far,
   coalesced tool-only pages, and live writes while repeatedly loading history.
4. Disconnect during bootstrap/page/live batch; process death; stale carrier;
   missed watcher events; rotation/truncation; source-generation reset; short
   writes and malformed/oversized input; replay eviction and retry same cursor.
5. Long/huge single lines and escaped embedded images, branch changes and deep
   parent chains, missing parents, unsupported schema/pagination, index overflow.
6. Capacity: 1 fast, then 4 fast + 50 slow threads, two app clients sharing one
   service (including simultaneous cold attach), sustained
   churn and at least a 30-minute idle/active soak. Track CPU, wakeups, I/O bytes,
   helper/owned-child process-tree RSS, client RSS delta, cache/queue watermarks,
   request fairness and leaked processes/descriptors. Never add independent
   lifetime RSS peaks and call the sum simultaneous memory use.
7. Multi-client lifetime/authentication: first client dies; one backgrounds;
   both expire; quick reconnect; stale lock/socket; different authorized keys
   for one remote user; different remote users; mixed app versions; cross-client
   lease/cancel/replay spoofing; last-client shutdown racing a new attach.
   Assert service/reader cardinality directly, not just equal UI output.
8. Jump-host matrix from section 3.3, including two clients using different
   routes to the same destination. Record chain setup, relay attach, and warmed
   ingestion separately; a multi-hop reconnect is not a new parser cold sample.

Proposed release gates, **targets pending review, not measured results**:

| Metric | Gate on the reference machine / controlled fixtures |
|---|---|
| Cold first usable model, including discovery and owned read-server startup | p95 ≤ 1 s per supported large-corpus adapter |
| First native visible conversation content | p95 ≤ 2 s on defined reference devices over controlled 50 ms RTT |
| Cached older page / uncached older page model readiness | p95 ≤ 100 ms / 500 ms |
| Persisted source update → client model, fast mode | p95 ≤ 1 s; report provider flush delay separately |
| Slow visible summary freshness | ≤ 7 s under the 4-fast/50-slow workload |
| Host memory | Shared service target ≤ 64 MiB; total service, provider children, and all client relays target ≤ 256 MiB under the capacity workload |
| Client Agent Center memory | Incremental RSS target ≤ 64 MiB on reference devices, bounded after prolonged scrolling |
| Idle host CPU | Mean ≤ 1% of one reference CPU core for 50 slow subscriptions; no transcript-size-dependent idle scan |
| Correctness | No silent gaps/duplicates, wrong-branch history, stale overwrites, scroll jumps, or action-routing regression |

Run at least 20 sequential trials for percentile comparisons, retain raw
distributions, and record hardware, build mode, provider version, storage
format, filesystem-cache state, and concurrent load. Do not label warm disk
cache as cold storage. Add cold-storage runs only in an isolated environment;
do not purge the user's system cache. For network-separated timestamps, report
clock uncertainty or use a test-owned round-trip/ack timing scheme.

Bound allocations and caches in code; use a process-tree watchdog as additional
test protection, not an OOM proof. Include App Server child RSS in the gate.
If its footprint dominates, disable/evict the owned child and test the fallback;
do not terminate user-owned provider processes. Report unsupported or slow
cases explicitly. Missing a gate requires fixing it or an explicit reviewed
scope/target change, not a silent performance exemption.

## 10. Delivery sequence and review gates

These are dependency-ordered implementation work packages. Internal packages
are not product handoffs; continue through each stated human-testable milestone.

### Phase 0 — settle capability and reader risks

Check in the read-only App Server probe, add largest legacy/paginated history
tests, test backward JSONL projection including giant records/branches, and
measure service plus child/relay memory. Establish the full-host-corpus manifest,
official-schema coverage matrix, historical-fix regression ledger, shared-service
singleton/lease design, and security/jump-host threat model before replacing
readers. Freeze provider capability matrix, native parser choice, host target
matrix, and consistency contract. Preserve private corpora outside git and
commit only content-free evidence. The exhaustive run may be checkpointed,
but must not be reduced to a size-selected sample to fit a time budget.

Review gate: evidence-backed go/no-go on the proposed native implementation;
no product behavior changed. If a bounded correct cold reader is impossible
for a store without indexing, state that cost before proceeding.

Completed probe work: real Claude headless synchronous/async/tool delivery and
interactive synchronous/async line streaming; native hook sender with bounded
private-socket delivery; synthetic launch/receipt/RSS measurements. These do
not satisfy the full-corpus, complete-reader, platform, or security gates.

### Phase 1 — end-to-end Codex/Claude vertical slice

Implement protocol/helper packaging, native Codex/Claude readers, shared v2
state, both duplex platform transports, and native bootstrap/history UI behind
an opt-in flag. Include basic fast/slow subscriptions and the bootstrap handoff,
not a one-shot prototype presented as a completed feature.
Minimum shared-service reuse, peer authentication, per-client lease cleanup,
destination/jump-route fencing, allocation/queue limits, and safe
failure/resync are mandatory in this first slice; Phase 2 hardens and exercises
them rather than introducing safety only after users can try the feature.

Human-testable milestone: on both platforms and all four transports, open a
large thread, read recent content, scroll up while new messages arrive, switch
threads, and return without duplicates or scroll displacement. Actions still
use their existing proofs. Pixel and iPad must demonstrably share one service;
backgrounding one must not interrupt the other. Pass full-corpus Codex/Claude
compatibility and the security gate before this real-data milestone. Commit
only after the affected integration gates, including destination jump routes.

### Phase 2 — lifecycle, capacity, and hardening

Harden per-client and last-client lease expiry, shared-service startup/shutdown
races, reconnect, carrier replacement, update/revision handling,
backpressure/resync, fair scheduling, bounded viewport/index caches, malformed
input defenses, and resource diagnostics. Run capacity and soak lanes.

Human-testable milestone: background/foreground, disconnect/reconnect, switch
tmux ownership, interrupt a history load by navigating back, and recover cleanly
on iPhone/iPad and Android phone/tablet. Verify another active device survives
one client's expiry and no owned service processes survive final idle expiry.

### Phase 3 — provider coverage

Add OpenCode native fast events plus bounded SQLite history; implement Pi
branch-aware reads and validated remaining-provider adapters. Keep individually
unsupported capabilities explicit; do not reintroduce the old Tessera protocol.
Run the same
protocol/semantic/visual tests against each advertised capability.

Human-testable milestone: all currently supported providers remain usable,
with matching ordering, grouping, paging, freshness, and fallback behavior.

### Phase 4 — release validation and controlled enablement

Run affected shared/native/platform targets under `scripts/integration/`,
including `run-agent-integration-script-tests.sh`, and the full relevant
`run-integration-tests.sh` lanes. Real-provider behavior needs the opt-in
`TESSERA_RUN_REAL_AGENT_E2E=1` lane; mocks are not sufficient evidence.
Repeat the full-host-corpus compatibility gate and its schema/regression ledger
against the release candidate. Enable `scripts/integration/jump/` fixtures and
run `run-jump-transport-tests.sh` / `app_jump_host_transports`; an aggregate pass
that skipped this opt-in lane is not complete evidence for jump-host support.

Use disposable VPS fixtures and uniquely named run-owned simulators/emulators,
never the user's local Mac as an integration test host. Local private-snapshot
performance and full-corpus runs remain private read-only corpus measurements.
Do not initiate user host connections through UI automation. Delete only tracked disposable
simulators after success or failure; never reset persistent user devices.

Capture landscape iPad plus compact phone behavior, Android parity, first-paint
recordings, history/live overlap, retry, and reconnect. Submit visual evidence
through the integration suite's single aggregate review while deterministic
lanes run. Apply the repository's adversarial-review workflow to protocol,
lifecycle, bounded parsing, and action-safety changes, verifying each finding.

Enable per provider after gates pass. No automatic dual reader on every live
thread: compare readers on test snapshots or explicit sampled diagnostic runs.
Incompatible helper/provider → explicit update-required/unsupported state;
do not fall back to a known long whole-file scan on every subscription tick.
Remove superseded ingestion paths once the replacement covers their semantics.
Preserve or port action/receipt proof consumers deliberately; their safety is
not waived by the lack of a shipped Agent Center. Rollback is a tested build
rollback, not a permanent dual-reader/protocol architecture.

Final handoff: commit/worktree, supported provider/host/route matrix, reproducible
commands and content-free full-corpus/performance results, historical-fix/schema
coverage, shared-server cardinality and security evidence, native visual
evidence, resource limits, known exceptions, rollback instructions, and all
unresolved gates.

## 11. Recorded direction and remaining validation

1. Use the corrected shared-service cardinality: one per active destination
   host-session scope across devices, independent client leases, and last-client
   idle shutdown; slow subscriptions remain host-side polling in v1.
2. Use C++17 + simdjson as the initial native candidate, conditional on
   complete-reader bounded-memory and correctness gates; no Omnigent platform
   dependency is proposed.
3. Implement the documented append-only-generation consistency contract;
   stronger arbitrary-prefix-edit detection would require an explicit change
   to the cost/consistency contract.
4. Treat the proposed performance/resource gates as acceptance targets, not
   measurements, with Codex/Claude-first
   rollout, with OpenCode/Pi/remaining-provider coverage tracked explicitly.
5. Use ephemeral bounded caches/indexes in the first implementation. A persistent disk index is
   a later, separately reviewed option if branch-history cold reads require it.
6. Implement and security-test the SSH + same-user Unix-socket model and its explicit
   same-UID/root limitation, including per-hop trust and final-destination-only
   service execution. No new network API or shared bearer credential is proposed.

Full-host-corpus testing, historical regression coverage, official-schema-guided
implementation, private test-data handling, and jump-host testing are required
scope, not optional performance samples or deferred polish.

Implementation is authorized. The shared native service, duplex relay,
canonical Codex/Claude readers, multiplexed scheduling, bounded history windows,
cross-platform app wiring and four-platform binary packaging are implemented.
Implementation and the scoped automated validation are complete on the worktree
branch. This does not convert proposed targets or incomplete oracle coverage
into passes: Android tablet Codex narrowly misses the 2 s candidate p95,
cold-app capture is a separate longer boundary, and strict corpus exceptions
remain recorded. See the [consolidated delivery report](research/agent-center-native-delivery-2026-09-13.md)
for current evidence and limits. No physical-device or blanket release
approval is implied.
