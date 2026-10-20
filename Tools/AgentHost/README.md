# Tessera native agent host

This is the new native host-tool implementation, not a released service.
Bounded canonical Codex/Claude/Pi/OpenCode/Kimi readers, read-only Codex App Server pagination,
hook reconciliation, multiplexed transactions, client leases, both app
connection paths and four-target precompiled packaging are implemented.
Functional gates include all four SSH-side-channel transports through a jump
host and native phone/tablet history/live overlap on both platforms. These are
not a blanket release or performance-target pass. Completed full-corpus,
credentialed provider, resource and native-render tests, together with measured
exceptions and reproducible evidence, are consolidated in the
[delivery report](../../docs/research/agent-center-native-delivery-2026-09-13.md).
The [plan](../../docs/agent-center-ingestion-implementation-plan.md) records the
design and proposed targets.

## Build and test

C++17, CMake 3.20+, locally installed **simdjson 4.6.4**, and the verified
**SQLite 3.53.4** amalgamation are required on the build machine. No
dependency is downloaded and no compiler is required on a user host:
`SharedAssets/agent-host` contains the precompiled artifacts. The current CMake
target statically links the installed simdjson library.

```sh
python3 Tools/AgentHost/fetch_sqlite.py /tmp/tessera-sqlite-3530400
cmake -S Tools/AgentHost -B /tmp/tessera-agent-host-build -G Ninja -DCMAKE_BUILD_TYPE=Release \
  -DTESSERA_SQLITE_AMALGAMATION=/tmp/tessera-sqlite-3530400
cmake --build /tmp/tessera-agent-host-build
ctest --test-dir /tmp/tessera-agent-host-build --output-on-failure
```

Tests use only private synthetic Unix sockets, files, and owned processes.
The sandbox must permit Unix socket creation. No user host connection or
existing coding session is used. The full native suite runs on macOS arm64;
the packaged Linux x86_64 helper passes service, hooks, JSONL, Codex and
deployment tests on disposable VPS fixtures. The packaged Intel macOS helper
passes hook, service, JSONL and Codex protocol suites under Rosetta; this is not
a physical Intel machine run. The packaged Linux aarch64 helper also passes
the service, hooks, JSONL, all provider readers and deployment suites on a
run-owned Debian ARM VM, including privileged namespace/cross-UID rejection.
The VM has no host mounts or provider credentials and is deleted on exit.
Validate all four binaries against their source,
architecture, digests and license matrix with
`python3 Tools/AgentHost/validate_artifacts.py SharedAssets/agent-host`.

### Reproducing the bundled artifacts

`SharedAssets/agent-host` (Git LFS) holds the four helpers the apps ship,
their `manifest.json` (per-target size, SHA-256 and the `sourceSHA256` of
`src/`) and `THIRD-PARTY-NOTICES.txt`. `build_artifacts.py` rebuilds them on
macOS: the Darwin targets with Xcode clang (macOS 12 minimum), the Linux targets
statically against musl with Zig 0.15.2 (the script checks the version). Its
pinned inputs, each verified by SHA-256 in the script:

- simdjson 4.6.4 single-header `simdjson.h` and `simdjson.cpp`, and
  `LICENSE-MIT`, from the `singleheader/` directory and root of the upstream
  `v4.6.4` tag (https://github.com/simdjson/simdjson).
- SQLite 3.53.4 amalgamation `sqlite3.c` and `sqlite3.h`, fetched and verified by
  `fetch_sqlite.py`.

```sh
python3 Tools/AgentHost/fetch_sqlite.py /tmp/tessera-sqlite-3530400
python3 Tools/AgentHost/build_artifacts.py --zig /path/to/zig-0.15.2/zig \
  --simdjson-source simdjson/singleheader/simdjson.cpp \
  --simdjson-header simdjson/singleheader/simdjson.h \
  --simdjson-license simdjson/LICENSE-MIT \
  --sqlite-source /tmp/tessera-sqlite-3530400/sqlite3.c \
  --sqlite-header /tmp/tessera-sqlite-3530400/sqlite3.h \
  --output SharedAssets/agent-host
python3 Tools/AgentHost/validate_artifacts.py SharedAssets/agent-host
```

The Linux binaries are reproducible from these inputs. The Darwin binaries
depend on the installed Xcode toolchain, so a rebuild matches the manifest's
`sourceSHA256` but not necessarily its per-binary digests. The iOS app bundles
the helpers LZFSE-compressed (`scripts/package-agent-host.sh`) and
verifies the decompressed bytes against the manifest before uploading one to a
host.

### OpenCode native SQLite gate

`opencode.sqlite.v1-v2` admits the native adapter in both apps. One bounded
read transaction uses the real WAL, not a copied main database. Once the
provider has closed its WAL-mode store (no `-wal` sidecar, which this helper
never creates), the checkpointed main file is read as an immutable snapshot:
the snapshot is taken only once the file's mtime is old enough for a later
rewrite to stamp differently, and the read is discarded as `sourceChanged`
if the sidecar reappeared or the file's identity, size or mtime moved. A
rollback-journal store keeps SQLite's own locking. The same path serves Codex
thread names from its `state_N.sqlite`. A provider that restarts commits to
its WAL first, which the main-file wakeup does not see; the 500 ms fast and
5 s slow reconciliation polls bound that staleness. Legacy history
walks OpenCode's actual message `(session_id,time_created,id)` and part
`(message_id,id)` indexes; current `session_message` history uses sequence order.
Opaque cursors retain this source-specific position. Message-level errors,
agent mentions, attachments and mixed tool outputs remain visible; unknown
and malformed content are explicit diagnostics.

Fast subscriptions use kernel WAL dirty notifications plus bounded polling
reconciliation. They do not start another provider process or assume that an
existing TUI exposes an authenticated HTTP endpoint. Slow subscriptions remain
server-side polling. SQLite consumes at most 16 MiB heap, with bounded cache,
VM steps, decoded blob bytes and read deadlines; reported `bytesRead` measures
decoded blobs, not total SQLite/WAL filesystem I/O. Filesystem checks include
ancestors and sidecars; writes to main/WAL/journal and destructive cleanup are
forbidden. Existing same-user SHM coordination remains allowed.

```sh
TESSERA_AGENT_CORE_LIBRARY=/absolute/path/to/libTesseraCoreAndroid.dylib \
  python3 Tools/AgentHost/tests/test_opencode_reader.py /absolute/path/to/tessera-agent-host
```

The database suite includes the upstream indexes on a 100,000-part synthetic
session, revision/history isolation, WAL reads, rowid-shadow rejection and
preservation of WAL files after rejected reads. Real two-client provider
evidence is recorded separately in the implementation ledger.

### Pi native-to-Core gate

Pi v1/v2/v3 reads follow persisted parent links, retaining display history
across compaction rather than copying Pi's current model context. The explicit
`pi.sessions.v1-v3` handshake enables this adapter in both apps; an old RPC
probe cannot enable it. Bootstrap, backward history and append updates share
the bounded metadata index. Visible extension messages remain typed system
content; unknown payloads remain explicit diagnostics.

Stateless bootstrap/history pages also serve on-demand search without changing
the acknowledged display window. Search matches bounded retained display text
using shared Core normalization and Unicode matching; it is not a raw-transcript
full-text index. Both clients cap work at 512 pages, 25 matches and a cancellable
30-second deadline, reporting unavailable on exhaustion instead of an empty
successful search. No copied Pi/RPC process is started for these reads.

Run the actual native wire through the shared decoder/search, in addition to
the standalone C++ tests (the dynamic product name is historical; this build
is for the local host):

```sh
swift build --package-path Packages/TesseraCore --product TesseraCoreAndroid
TESSERA_AGENT_CORE_LIBRARY=/absolute/path/to/libTesseraCoreAndroid.dylib \
  python3 Tools/AgentHost/tests/test_pi_reader.py /absolute/path/to/tessera-agent-host
```

This lane checks the `pi-chain` source domain, required physical offsets,
canonical record IDs, stateless search and independent live window state.

### Claude compaction ancestry

Claude selection follows the official SDK's `parentUuid`-only leaf choice, but
display ancestry continues through a `compact_boundary` root instead of ending at it.
Its effective parent is the current revision of `logicalParentUuid` when that
starts before the boundary. Otherwise it is the nearest earlier current
non-sidechain node, or none. That advisory link can name a later record or
nothing. Compact, lazy and linear-proof indexes apply the same rule. An
effective parent always starts earlier. After a boundary, every step must reach
a node earlier than the whole path so far, or the path stops there, so a forward
`parentUuid` cannot turn the boundary into a cycle. On compacted files the
selection therefore deliberately extends beyond the SDK's
`_build_conversation_chain`. The leaf is unchanged.

```sh
python3 Tools/AgentHost/tests/test_claude_compaction.py /absolute/path/to/agent-claude-chain-driver
```

### Kimi native wire gate

`kimi.wire.v1.4-v1.5` enables the pinned Kimi 0.41.0 adapter in both apps.
The fixed provider-root session index authorizes exact per-agent wire files;
tombstones revoke existing handles, and child agents retain distinct identities.
Replay follows the official display reducer, including deferred messages,
interrupted tools, same-step late content, undo and compaction boundaries.
Headers, control keys and nested content are validated; unsupported records
remain explicit unknown/unparsed diagnostics, including otherwise hidden rows.

The metadata index is bounded, reused across reads and invalidated on changed
history. Bootstrap/history/search share canonical pages; live append wakeups
use the common file subscription path. It does not start or resume Kimi.
The 60-type public fixture is schema-only. Private semantic testing runs the
pinned official reducer on finite snapshots, compares selected content/order,
and separately requires complete physical-record normalization coverage.
Private transcripts and results must remain outside Git.

```sh
TESSERA_AGENT_CORE_LIBRARY=/absolute/path/to/libTesseraCoreAndroid.dylib \
  python3 Tools/AgentHost/tests/test_kimi_reader.py /absolute/path/to/tessera-agent-host
```

## Process roles

- `connect --stdio --runtime ABSOLUTE_PRIVATE_DIRECTORY`: duplex framed relay;
  discovers/starts the singleton service and reuses it for subsequent clients.
  Add `--attach-only` for externally supervised fixtures: it never creates the
  runtime or starts a replacement service. Missing runtime exits 77; an absent
  service in an existing private runtime exits 69.
- `serve --runtime ABSOLUTE_PRIVATE_DIRECTORY`: service holding the singleton
  lock, with separate `client.sock` and `hooks.sock` endpoints. Default client
  lease and final idle grace are each 30 seconds. Test-only explicit timing
  knobs are `--lease-ms` and `--idle-ms` (100–30000).
  Packaged services check the installer's private immutable publication once
  per second. A different valid target retires the old service even while
  clients hold leases. Reader shutdown and socket cleanup finish before the
  singleton lock is released; reconnecting relays start/share the published
  build. Provider processes and terminal sessions are never signalled.
  Already-running older builds without this check still need their original
  lease/idle expiry once; publication cannot retrofit running executable code.
- `hook --socket ABSOLUTE_PRIVATE_SOCKET`: observational native sender, max
  64 KiB input and 100 ms native work deadline; always silent/successful.
  Missing service is a no-op. Oversize is an explicit reconciliation hint.

No TCP listener, network token, permanent service registration, disk transcript
spool, shell-command forwarding, or provider control API is implemented.
Same-UID kernel peer credentials are verified on both socket ends. Runtime
directory must be canonical, user-owned, and private; socket ownership/type/
permissions and lock-file type/link count are checked. Same-UID/root adversaries
are outside this isolation boundary, as described in the plan.

Metadata accounting is bounded separately for Codex, shared Claude/Pi, and
Kimi caches: 16 MiB and 24 entries per family, 48 MiB aggregate plus bounded
container overhead. Per-index maxima are 8 MiB for Codex and 4 MiB for the
others. Active/pending windows pin indexes; exhausted capacity reports an
explicit error instead of discarding another client's retained history. This
is not a 16 MiB helper-wide RSS bound. Native SQLite heap and streaming
continuations have separate 16 MiB and 8 MiB limits; resource measurements
include the real process footprints rather than summing these budgets.

## Experimental ingestion protocol

Codex fallback follows `history_base` only through ID-matched,
catalog-authorized files. Each ancestor contributes its newline-terminated
byte prefix, verified against the exclusive ordinal; the child contributes its
current snapshot. Cycles, ambiguous/missing/mismatched sources and inconsistent
cutoffs fail explicitly. Maximum eight physical segments and 20,000 selected
items share the existing 16 MiB metadata cache; active children pin their
dependency indexes. Known parent hints are reopened/revalidated, without an
all-provider discovery scan on every poll.

For this indexed history, `sourceOffset` and `sourceEnd` refer to the virtual
concatenation of frozen ancestor prefixes followed by the child—not raw offsets
in the child file. The opaque composite source generation scopes all offsets
and receipts. Parent appends beyond the fork cutoff do not shift this domain.
Archiving a parent invalidates its missing cached path and rediscovers it only
within authorized Codex roots. Existing cursors reset explicitly if the index
generation changes; fresh bootstrap then resumes normal updates. A substituted
symlink, non-directory, or inaccessible cached path still fails closed.

Known upstream-path distinction: at inspected Codex revision `bb1af235ea`,
native DB paging filters parent items by their creation ordinal but returns
their current stored body. A later parent revision can therefore appear through
native paging after the fork cutoff. Tessera's JSONL fallback preserves the
referenced physical prefix, including the earlier parent body. This deliberate
fork-snapshot policy is tested; do not call it exact native-DB equivalence for
post-fork parent revisions. Ordinary nonforked canonical selection is unchanged.

Linux child RSS supervision reads the bounded `/proc/PID/stat` fields for
process group and resident pages in one pass, following the kernel's
[proc field documentation](https://docs.kernel.org/filesystems/proc.html).
The 50 ms active/1 Hz idle sampling cadence and 192 MiB/64-process guards
remain unchanged. Kernel RSS accounting is approximate; this is not an OS
allocation limit or proof against a transient unsampled memory spike.

The persistent worker slices JSONL physical I/O at 64 MiB and resumes oversized
records without retaining their full JSON. Its worker-owned continuation cache
holds at most four streaming projections, with an 8 MiB aggregate retained
capacity guard, and sixteen bounded newline-scan checkpoints. The current
64 KiB input block and allocation growth during one feed are additional bounded
working memory. Every skipped string byte is still syntax/UTF-8 validated;
malformed tails never become successful clipped messages. Standalone `jsonl`
CLI reads retain their explicit per-operation work limit.

Continuations reopen authorized sources and require exact size/mtime snapshot
matches before cache reuse. Even growth invalidates a cached decoder: rewrite
plus append is not proof of append-only content. A continuously mutating giant
record can therefore restart until the 30-second request deadline, then reports
`readContinuationTimeout`; it is never skipped or silently accepted. The original
request/lease remains admitted while slices yield to other clients and ACKs.
Same-client cancel/release drain barriers retain their order without blocking
independent clients behind them. Reported page I/O includes all resumed slices.

Four-byte big-endian length followed by UTF-8 JSON, maximum 65536 bytes. Request
IDs are bounded ASCII identifiers. Send `{"kind":"hello","v":3,"id":"hello"}`
before other requests. The response advertises `claude.hookPreview`,
`jsonl.pages`, `jsonl.subscriptions`, `bounded.windows`, `window.partitions` and
`window.capacity.v1` with integer `maxWindowSegments` (64), and includes a
service epoch. Version 3 requires atomic retained-page revision
partitioning. Incompatible versions are disconnected before lease admission;
they cannot replace the shared service or silently consume different paging
semantics. Both native apps require version 3 and the partition capability.
Heartbeats renew only the accepted connection's lease. `resolve` accepts a
provider/path locator but authorizes it only under fixed provider roots;
it returns an opaque thread handle. `inventory`, `bootstrap`, `history`, and
`updates` run on a bounded worker lane. History/live cursors are opaque,
client-scoped, and independent. Pages commit only at `page.end`.

Inventory requests accept an integer `limit` from 1 through 500 (default 100).
Inventory pages stop at that row count **or 192 KiB of framed wire data**, with
reserved space for the end/cursor envelope. Long or escaped paths therefore
produce shorter pages, not oversized client transactions. Native clients request
500 rows, retaining their existing receive-byte limits; Apple reduces summaries
in at most 100-row Core batches. History/message limits are unchanged.

`subscribe` accepts a thread handle, `liveCursor`, and `interest` (`fast`/`slow`).
Automatic page transactions require an ACK after the app's shared reducer
commits them. Changing interest preserves an in-flight transaction/cursor.
Slow subscriptions poll bounded summaries and deliver changed card state.
Codex native items use stable provider IDs and monotonic revisions; native
capability/resource failure can select JSONL only at bootstrap, never silently
mid-cursor. A read-only App Server child is stopped/reaped before singleton
ownership is released. RSS supervision is sampled, not a kernel OOM guarantee.

Hook delivery is `hookPreview` with the original bounded hook JSON. It is
**provisional**, not a canonical normalized message. Canonical fast delivery
uses the independent window transaction and retention ACK lane.
`unsubscribe` affects only its connection. `bye`/disconnect releases that client.
Overflow produces `resyncRequired`; a slow consumer exceeding its queue budget
is disconnected so it must reconcile.

`window.read` operations are `bootstrap`, `before`, `after`, and `head`.
`page.end.window` identifies the committed lane and proposed version; only a
valid `window.ack` commits retained coverage. A `revisions` lane may include
at most twenty `partitions`: each names its `original` retained segment,
replacement `id`, `offset`/`count`, opaque `before`/`after` boundaries, and
`hasOlder`/`hasNewer`. Parts cover the whole original exactly and in order.
They reference retained records plus this transaction's patches, not duplicate
message bodies. Both native cursor storage and client encoding count toward
partition sizing. Patches and descriptors share the existing 256 KiB transaction
budget. A single over-budget item remains an explicit capacity error.

The client substitutes those parts and retains a contiguous interval of at
most `maxWindowSegments` viewport segments around its pinned record (four
against a host without `window.capacity.v1`). The host admits at most that many
segments and 100 records per segment, plus a detached head; a larger ACK fails
with `windowCapacity`. Per-page, frame and partition bounds are unchanged; a
revision slice patches at most four distinct retained segments. It ACKs the replacement
IDs; only a split of the retained head changes the head ID, to its final part.
The live cursor, source generation and record identities do not change.
Cancelled/invalid/lost ACKs leave old coverage and boundaries intact; replayed
ACKs must match the already committed IDs and version. Evicted edge parts are
recoverable by normal ranged history, never by jumping to the latest page.

All windows of one service, across every client and thread, share a 64 MiB
retained budget, advertised as hello `maxRetainedBytes`. It counts committed
pages plus staged, unacknowledged pages and revision patches, including the
most a revision ACK can add by rewriting duplicate record copies or splitting
pages. The single worker lane checks it before any I/O, so concurrent reads
from several clients cannot overshoot. A `bootstrap`, `before` or `after` read
fails with the retryable `windowCapacity` unless one more full 256 KiB page
fits under 64 MiB. A re-bootstrap of an existing window (the apps' Retry
button) replaces that window's pages: its result must fit under 64 MiB, and
its staging needs one page of the refresh headroom. Live `head` reads and their
`revisions` lanes may use 12 MiB more than 64 MiB, so they keep committing
after history growth is refused. That headroom fits a detached head plus one
in-flight refresh page for each of the 24 window slots. Near that ceiling a
revision slice defers its newest patches to the next slice. Accumulated refresh
growth, such as a head replacing a smaller page or growing revisions, can
still use up the headroom. Refreshes and re-bootstraps then also fail with
`windowCapacity` until other windows shrink, are released or disconnect.

ACKs, cancels and releases are never budget-checked: an ACK only keeps or
drops what its read staged. Staging past its ACK deadline stops counting at the
next read or release. Disconnect and `window.release` free a client's windows.
For `windowCapacity`, the apps keep the window, show a read status with Retry
and retry the failed read or subscription with 1–15 s backoff. Only the Retry
button re-bootstraps.

Without this budget, 24 windows of 64 viewport pages plus a detached head
could retain 24 × 65 × 256 KiB ≈ 390 MiB per service (65 MiB per client).
The worst case is now 76 MiB of window pages per service, 64 MiB plus the
refresh headroom. These are accounting bytes: serialized record, anchor and
cursor sizes plus fixed per-record and per-page overhead. They are not
allocator RSS, and an ACK briefly holds old and revised copies. This is
separate from the metadata, SQLite and continuation limits above. Apps
normally retain less, because each caps a window at its per-thread byte budget.

This experimental surface must not be exposed as completed Agent Center.
Installation, environment-scope identity, branch semantics, revision-aware
overlays, shared-reader scheduling, and native UI acceptance remain required
work. Existing Tessera wire compatibility
is not a requirement; historical provider-format correctness still is.
