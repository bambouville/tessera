# Agent Center ingestion: performance evidence and existing solutions

Date: 2026-09-11. Worktree: `.worktrees/agent-center-performance`.
Branch: `codex/agent-center-performance`; baseline: `94d65a0cc562fd6e7048bb1fa4e1e12cb233e591`.
Scope: benchmark and research only. No production helper, native app, user
configuration, connection, or provider session was changed. Recommendations
below are candidates for a subsequent implementation decision.

## What the current code actually does

The expensive unit is a complete **projection**, not one `json.load` of an
entire JSON document. Provider files are JSONL. The shared installer embeds a
Python program that streams 8 KiB chunks, retains a 48 KiB prefix per source
record, strips Codex image URLs with `ImageLine`, normalizes every record, and
retains a bounded deque. Output is bounded to 100 records / 256 KiB.

Nevertheless, `project()` scans from offset zero through the complete captured
file even when the request asks only for the newest page or an older page.
An unchanged refresh repeats this work. After an append, `cursor_decode()` also
SHA-256 hashes the entire previous prefix to verify continuity, before
`project()` scans and normalizes the whole new snapshot. One small update
therefore reads roughly twice the history size. A source mutation during the
projection can trigger an additional verification pass. The bounded receipt
path is different and is measured separately.

Apple opens a new `withExec` channel/process for each request on the existing
authenticated SSH client. It does not perform a new SSH authentication for
every page. The channel carries streaming bytes, but Python state does not
survive requests and the client decodes complete pages. Mosh uses the SSH side
channel too. A persistent *projector/session protocol* is the relevant missing
piece; merely retaining the authenticated connection is already implemented.

Source: `RemoteAgentLifecycleIntegrationInstaller.swift` (`ImageLine`, `lines`,
`cursor_decode`, `project`), `AppleCitadelAgentExec.swift`,
`AppleAgentStreamingDataChannel.swift`, and Android's
`AgentCenterPresenter.kt` (5,000 ms projector stream timeout).

## Reproduction and measurement boundaries

See [suite instructions](../../scripts/performance/agent-center/README.md).
The runner selects the three largest local Codex and Claude Code JSONL files
by bytes across their configured roots. It measures private finite snapshots
and appends a contiguous real-record suffix of at most 32 KiB to private copies.
Raw conversations, titles, absolute source paths and attachments are never
written to the evidence report or committed. Corpus hashes identify snapshots.

Environment: Apple M2 Pro, 16 GiB RAM, macOS 26.6.2, ARM64; Homebrew CPython
3.14.3; locally installed simdjson 4.6.4, compiled `clang++ -O3 -std=c++17`
against its static library. File cache is warm. Concurrent compiler activity
(user builds and brief harness preparation) was observed; timings are
development-machine measurements, not an idle-host
capacity guarantee. Each benchmark case is sequential, with no parallel
benchmark workers. No SSH/network/UI time is included.

The fresh lane executes the actual generated shell and dispatch. The resident
lane loads exactly the same Python functions once. Only source roots and
external Codex title database lookup are substituted. Swift-dumped shell bytes
are checked against the benchmark's extraction. The installed Mac helper also
matches these bytes exactly (SHA-256 `85e849a53fece526f044811c0098deee82bd420fab998c9c87548b6bfaec9fbc`).
The local standard JSON decoder uses CPython's `_json` C accelerator; it is not
an entirely interpreted JSON parser. RSS is the process high-water
resident size, not Python heap or total system RAM. A 512 MiB sampled
process-tree watchdog and a 600-second per-scenario timeout protect the host;
neither is a proof against every short allocation spike.

An initial five-repetition pilot exceeded its 300-second scenario budget on
the largest Codex file. The subsequent suite retains completed samples on
timeouts, uses three repetitions for measured updates and one pass per read
diagnostic, and has a 600-second scenario budget. Pilot numbers are excluded
from the final tables. The temporary pilot snapshots were cleaned up.

## Measured results

Follow-up: [cold start to first renderable conversation model](agent-center-cold-first-page-2026-09-11.md)
adds independent first-open trials through the real Apple decoder and shared
reducer/snapshot endpoint. The original measurements below are retained unchanged.

The selection covered **962 Codex files (5.43 GB)** and **278 Claude Code
files (0.53 GB)** with **zero scan errors**. The selected six files total
912.2 MB; no selected snapshot had an incomplete trailing record. Labels below
are rank-by-size, with full content fingerprints in the evidence JSON.

Current helper: initial newest page is one first-request sample; unchanged and
append columns are medians of three sequential samples. File sizes use decimal
MB; memory uses MiB. Peak is the maximum helper RSS across that file's fresh
process requests. These are observed local costs, not network/device timings.

| Corpus | File MB | JSONL records | Initial page s | Unchanged s | Append refresh s | Peak helper MiB |
|---|---:|---:|---:|---:|---:|---:|
| codex-1 | 376.9 | 42,605 | 29.528 | 23.584 | 30.674 | 38.8 |
| codex-2 | 263.8 | 37,259 | 19.131 | 15.935 | 16.116 | 39.1 |
| codex-3 | 180.7 | 11,287 | 5.128 | 5.404 | 5.744 | 38.3 |
| claude-1 | 46.5 | 1,901 | 0.252 | 0.248 | 0.273 | 36.5 |
| claude-2 | 23.5 | 9,688 | 0.771 | 0.787 | 0.779 | 37.6 |
| claude-3 | 20.9 | 2,927 | 0.349 | 0.376 | 0.364 | 38.3 |

All 24 fresh-process Codex history projections (initial, unchanged, append and
older-page requests) exceeded five seconds. All corresponding Claude requests
were below one second. The largest Claude file is faster than the second-largest:
record count and record contents matter, not just file size. Largest individual
records ranged from 0.25 MB to 10.91 MB across the six sources.

### Why persistence must include incremental work

Keeping the same Python interpreter alive does not remove history scans.
The following controls use the same bounded lexer and normalizer. The offset
control retains only 100 normalized records and checks its final newest records
and offsets against production; it intentionally omits metadata/page encoding,
full-prefix verification, persistence, watching and network delivery. Its
millisecond figures are **incremental normalization costs**, not a promised
replacement's end-to-end latency. Initial processing still costs a full scan.

| Corpus | Replayed append KB | Current append read MB | Resident full refresh ms | Offset control update ms |
|---|---:|---:|---:|---:|
| codex-1 | 17.86 | 753.74 | 23272.02 | 1.91 |
| codex-2 | 31.11 | 527.61 | 17120.03 | 4.07 |
| codex-3 | 16.26 | 361.38 | 5092.32 | 3.05 |
| claude-1 | 26.82 | 92.93 | 182.05 | 0.89 |
| claude-2 | 31.17 | 47.12 | 996.36 | 1.05 |
| claude-3 | 31.34 | 41.77 | 345.93 | 1.17 |

For `codex-1`, an unchanged query reads 376,861,178 bytes. Appending
17,861 bytes causes 753,740,217 bytes to be read: exactly the old size plus
new size. The offset control reads only the new bytes; unchanged checks read
zero transcript bytes. Fresh bounded receipt requests cost roughly 85–131 ms
(medians across the two runs), versus sub-millisecond resident receipt work.
Process startup is real overhead, but it does not explain a 20–30 second scan.

The largest Codex cProfile run attributes about 64% of cumulative projection
time to `ImageLine.feed` and 33% to `bounded_string`. `json.loads` accounts
for about 7%, **overlapping** those callers, with 1,367,173 calls for 42,605
source records because the lexer also decodes short JSON string tokens. These
are directional profile shares, not additive components or an exact speedup
forecast: profiling inflated that request to 79.8 seconds. The unprofiled
parser-only experiment below independently checks the JSON-decoder hypothesis.

### Native parser control

A second sequential run used the exact same six corpus hashes. It compares
full per-line DOM decoding, discarding each document, with no Tessera
normalization or image redaction. Native input uses 64 KiB `fread` chunks plus
`memchr`; both engines process all input bytes and agree on valid/invalid
record counts. Medians are three samples; RSS is the maximum of those samples.

| Corpus | Python JSON ms | simdjson ms | Python peak MiB | simdjson peak MiB |
|---|---:|---:|---:|---:|
| codex-1 | 892.15 | 179.54 | 117.7 | 37.3 |
| codex-2 | 647.40 | 125.23 | 89.7 | 22.7 |
| codex-3 | 346.79 | 63.84 | 140.6 | 58.5 |
| claude-1 | 75.69 | 14.07 | 45.1 | 10.8 |
| claude-2 | 87.07 | 13.38 | 38.2 | 2.7 |
| claude-3 | 46.75 | 7.80 | 45.3 | 9.6 |

The chunked native baseline is about 5–6.5 times faster here. The original
`std::getline` native control took 1.36 seconds on `codex-1`, versus 0.18
seconds with chunked input using the **same** simdjson DOM engine. Both readers'
results remain in the evidence: precompiling a program is not enough if framing
or normalization dominates. Neither native control is a complete projector.

Current production projection stayed at roughly 35–41 MiB across the cases.
The uncapped-per-line Python DOM baseline peaked at 142.8 MiB in the main run;
the chunked native DOM control peaked at 58.5 MiB. These are single-worker
measurements, not a proof against OOM across many simultaneous sessions or
larger/more adversarial records. Giant-record limits, byte-bounded queues and
cache eviction remain necessary even with a compiled parser.

### Evidence and exact commands

- [Primary measurements](agent-center-ingestion-2026-09-11-results.json): 72 completed scenario/trial blocks, 228 operation samples, zero failed trials.
- [Parser/framing controls](agent-center-ingestion-2026-09-11-parser-controls.json): 42 completed trial blocks, 54 operation samples, zero failed trials.
- Full medians, observed ranges, memory peaks and five-second exceedances are reproducible with `scripts/performance/agent-center/summarize.py` on either JSON file.

```sh
python3 scripts/performance/agent_center_benchmark.py \
  --output /tmp/tessera-agent-perf-primary-new --top 3 --repeats 3 \
  --timeout 600 --native /tmp/tessera-simdjson-baseline
python3 scripts/performance/agent_center_benchmark.py \
  --output /tmp/tessera-agent-perf-controls-new --top 3 --repeats 3 \
  --timeout 120 --modes raw --native /tmp/tessera-simdjson-chunked
```

Binary build commands and prerequisites are in the suite README. The checked-in
JSON contains all timing samples, read counts, profiles and content hashes,
without the original transcript contents.

## Omnigent: source-level assessment

Inspected [omnigent-ai/omnigent](https://github.com/omnigent-ai/omnigent) at
`d94e288e579606f2f2567f10d5cb8f238b105f5f` (2026-09-11). Public source was
downloaded for inspection; the application was not installed or started and
was not given access to the real conversation corpus.

**Codex:** its native bridge maintains a WebSocket connection over a Unix socket
or TCP to Codex App Server, with a dedicated reader task and request/notification
routing. Its forwarder subscribes using `thread/resume`; healthy reconnects pass
`excludeTurns` to avoid loading old turns, while interrupted delivery can replay
the active turn. This is an implemented example of persistent event ingestion,
not a faster JSONL decoder. Sources:
[connection](https://github.com/omnigent-ai/omnigent/blob/d94e288e579606f2f2567f10d5cb8f238b105f5f/omnigent/harnesses/codex_native/app_server.py#L606),
[subscription/recovery](https://github.com/omnigent-ai/omnigent/blob/d94e288e579606f2f2567f10d5cb8f238b105f5f/omnigent/harnesses/codex_native/forwarder.py#L2419).

**Claude Code:** its persistent Python forwarder polls at a default 250 ms,
persists byte/line cursors and deduplication state, and seeks directly to unread
bytes. It defers incomplete trailing records. The normalizer still calls
standard `json.loads`. This is evidence that Python and fast incremental
updates are compatible. It uses a local cursor fingerprint rather than hashing
every historical byte on each poll (specifically, a 256-byte cursor-adjacent
sample plus the offset). Sources:
[forwarder/cursor state](https://github.com/omnigent-ai/omnigent/blob/d94e288e579606f2f2567f10d5cb8f238b105f5f/omnigent/harnesses/claude_native/forwarder.py#L612),
[incremental reader](https://github.com/omnigent-ai/omnigent/blob/d94e288e579606f2f2567f10d5cb8f238b105f5f/omnigent/harnesses/claude_native/bridge.py#L2898).

**History and live delivery:** conversation items have database indexes on
conversation and position. The items API supports before/after cursors with a
default page of 100. Its SSE broadcaster uses per-subscriber queues of 1,024
events and disconnects overflowing consumers, which recover through a snapshot
and live-tail protocol. A live event queue is not an unbounded history cache.
Sources:
[indexes](https://github.com/omnigent-ai/omnigent/blob/d94e288e579606f2f2567f10d5cb8f238b105f5f/omnigent/db/db_models.py#L982),
[pagination](https://github.com/omnigent-ai/omnigent/blob/d94e288e579606f2f2567f10d5cb8f238b105f5f/omnigent/server/routes/sessions/routes_items.py#L58),
[SSE and overflow](https://github.com/omnigent-ai/omnigent/blob/d94e288e579606f2f2567f10d5cb8f238b105f5f/omnigent/runtime/session_stream.py#L1).

**Limits for Tessera:** this is a Python/server/database orchestration platform
that launches or wraps provider sessions, with a web/desktop UI, accounts,
policies and collaboration. It is not a small standalone transcript-parser
binary. Its Codex approach assumes access to the corresponding App Server;
it does not establish safe passive attachment to every pre-existing unrelated
terminal session. The [project FAQ](https://omnigent.ai/faq) explicitly calls it
alpha. Its docs list Claude and Codex as fully supported harnesses, with direct
and native-TUI modes. [Supported harnesses](https://omnigent.ai/docs/build/harnesses/supported).

There are memory tradeoffs to investigate before reusing code. The Claude
`_read_complete_jsonl_records()` implementation uses uncapped `readline()` and
collects all unread decoded records into a list. A cold import or large backlog
can therefore retain much more than one page. Codex's connection allows a
128 MiB message, and the 1,024-event SSE limit is a count bound, not a byte
bound. These are source-level observations, not measured Omnigent RSS results.
Sources:
[reader](https://github.com/omnigent-ai/omnigent/blob/d94e288e579606f2f2567f10d5cb8f238b105f5f/omnigent/harnesses/claude_native/bridge.py#L3497),
[message bound](https://github.com/omnigent-ai/omnigent/blob/d94e288e579606f2f2567f10d5cb8f238b105f5f/omnigent/harnesses/codex_native/app_server.py#L90).

Assessment: a strong architectural reference for event delivery, durable
cursors, deduplication and paged history. Adopting the full platform would change
Tessera's deployment model substantially. Reusing selected mechanisms or
supporting Omnigent as an optional provider is a separate decision from fixing
the existing passive transcript adapter.

## Other existing solutions

| Candidate | Existing mechanism | Fit and remaining work |
|---|---|---|
| [Codex App Server](https://learn.chatgpt.com/docs/app-server) | Bidirectional JSON-RPC with event notifications; stored-thread read APIs; experimental turn/item pagination | Prefer the owning server's events when available. `thread/read` does not subscribe. `thread/resume` is not a passive read. Current docs label WebSocket/app-server support experimental; capability/version checks are necessary. |
| [Claude Agent SDK](https://code.claude.com/docs/en/agent-sdk/streaming-output) | Streaming output from SDK-managed runs | Good for sessions Tessera explicitly launches/manages; not evidence of passive observation of arbitrary running CLI processes. The [session browser API](https://platform.claude.com/cookbook/claude-agent-sdk-05-building-a-session-browser) reads stored history and provides limit/offset, but that API shape alone does not guarantee incremental parsing or bounded RSS. |
| [claude-watch](https://github.com/satabd/claude-watch#pipelines) | Python/FastAPI; file watcher, per-file byte offsets, SSE; persistent asyncssh/SFTP append fetching | Close reference for observing existing remote files. Claude-specific and includes a server/UI; no local large-corpus performance verification in this investigation. |
| [cc-viewer](https://github.com/jhhuh/cc-viewer#architecture) | Native Rust viewer, `notify` file watching and incremental JSONL tailing | Demonstrates the native tailer pattern; a small Claude-specific GUI project, not a shared transport/normalization service. |
| [Harnss](https://github.com/OpenSource03/harnss#engines--agents) | Claude SDK, Codex App Server, ACP engines behind a desktop client | Useful provider abstraction and live UI reference. It runs/manages agent sessions; replacing Tessera's native UI or importing the client is a larger product change. |
| [agent-session](https://docs.rs/agent-session/0.5.14/agent_session/) | Rust session IR, Codex/Claude/Gemini parsers, discovery and process matching | Candidate parser/schema library to evaluate. Documentation explicitly leaves UI, persistence and export to consumers; no bounded incremental contract or measured latency established here. |
| [cass](https://github.com/Dicklesworthstone/coding_agent_session_search) | Rust cross-provider search/indexing CLI with watch mode | Archive/search reference. Its [documented incremental safety](https://github.com/Dicklesworthstone/coding_agent_session_search/blob/main/README.md#incremental-safety) still rescans a changed file in full, so “incremental” does not automatically solve this hot path. Its [license](https://github.com/Dicklesworthstone/coding_agent_session_search/blob/main/LICENSE) includes an OpenAI/Anthropic rider; do not assume ordinary MIT reuse. No code was copied or executed. |
| [Vector file source](https://vector.dev/docs/reference/configuration/sources/file/) | Persistent file checkpoints, fingerprints, rotation handling, bounded reads | Mature log-ingestion patterns worth reusing conceptually. Defaults limit line size; large image records require deliberate handling. It does not implement coding-agent semantics, stable tool IDs, receipts, or paged conversation history. |
| [simdjson](https://github.com/simdjson/simdjson), [orjson](https://github.com/ijl/orjson) | Existing native JSON engines; simdjson also has [On-Demand multi-document iteration](https://github.com/simdjson/simdjson/blob/master/doc/iterate_many.md) | Reuse a parser rather than invent one. A parser does not supply durable offsets, bounded normalization, rewrite handling or subscriptions. `orjson` preserves a Python runtime/deployment dependency and does not provide JSONL file streaming itself. Only the local simdjson DOM lane was benchmarked here. |

These are primary-source checks of mechanisms and fit, not a market-share
ranking or a claim that every candidate is production-ready. Project popularity
and vendor benchmark throughput are not used as performance evidence.

## Direction to evaluate next

The main design question is how to make steady-state work proportional to new
content, with strict memory and correctness bounds. A compiled helper is a
reasonable candidate, but its language is secondary to avoiding repeated
history scans and returning indexed pages.

For passive observation, evaluate one persistent host-side service/channel
using durable offsets and an on-disk normalized index, with bounded in-memory
pages, output queues and per-source budgets. For provider-managed sessions,
evaluate supported event APIs through the same normalized protocol. Retain a
compatibility fallback for hosts without the service or compatible provider
API. A new service should use the already-authenticated SSH carrier, including
mosh's side channel, rather than requiring a separately exposed network port.

The hard unresolved invariant is rewrite detection: Tessera currently proves
the entire earlier prefix. Replacing that proof with a local fingerprint,
mtime or watcher notification weakens what is detected. Any proposed
incremental design must specify its trusted-writer assumption, source
generation/rotation handling, compaction recovery, watch-overflow rescan,
restart recovery and durable acknowledgement boundary. A stream should have
sequence IDs, backpressure, reconnect catch-up and byte-bounded queues. Image
redaction must preserve following prose, UTF-8 validation and source hashes.

The protocol should be shared across SSH, SSH+tmux, mosh and mosh+tmux, and across
Apple/Android adapters. iPhone keeps the same paged conversation semantics with
its compact UI; no keyboard requirement or large in-memory transcript should
be introduced. Host-side state belongs to the source, with per-client cursors
so iPad and iPhone can reconnect independently. Transcript events must continue
to be separate from the fresh terminal-ownership proof used to authorize
actions.

Before selecting a replacement, require the same real-corpus suite plus
semantic parity, cold start, long-running growth, many simultaneous threads,
slow-reader backpressure, malformed/giant records, compaction/rotation, SSH
disconnect/reconnect and Linux/Windows host measurements. Native UI and live
four-transport regression gates belong to that implementation, not to this
host-only benchmark/report change. No architecture migration is approved or
implemented by this report.

## Validation and handoff

The affected host integration target passed:

```sh
bash scripts/integration/run-agent-integration-script-tests.sh \
  /tmp/tessera-agent-perf-integration-20260911
```

This includes 47 existing projector tests, all 10 new benchmark validity tests
(including exact Swift-dumper extraction), 15 recovery tests, and the script's
install/lifecycle/process-proof/launch/bootstrap assertions. The first sandboxed
attempt passed the Python tests but failed the existing process-proof assertion
because `/bin/ps` was denied. Rerunning with process-inspection permission passed
the complete target; no product change was needed.

Both native input readers passed 30 fixture subcases, covering empty files,
missing trailing newlines, invalid JSON, Unicode, embedded NUL, 64 KiB chunk
boundaries and a 2 MiB record. Both evidence summaries passed canonical-record
and parser-count checks; every raw/native sample agrees on record/byte counts.
The two runs used identical corpus hashes. `git diff --check` passed.

The complete host gate log is retained locally at
`/private/tmp/tessera-agent-perf-integration-20260911/gate-unrestricted.log`.
The content-free results linked above are durable checked-in evidence; the
private benchmark transcript copies were automatically removed. No simulator
was created, and no provider or user host was connected. Native app, live
transport and Windows/Linux execution remain untested by this host-only change.
