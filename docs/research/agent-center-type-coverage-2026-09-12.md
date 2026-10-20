# Agent Center message-type coverage audit

Status: **not a compatibility pass**. File-processing success is separate from
understanding the records in those files. This supplements the implementation
plan; it does not replace the remaining semantic, live-replay or native UI gates.

## Latest full physical pass: run m

The subsequent native implementation recognizes completed CoreTurnItem envelopes
and typed Codex lifecycle, settings, goal, token-usage and resume-state records.
Unknown fields, malformed numeric/identity fields and unknown variants remain
diagnostic; arbitrary world-state data is not recursively treated as messages.
Run m processed all 1,243 files with zero processing failures and **2,447
unclassified records in 15 files**: 2,287 legacy Codex user/assistant events in
11 histories, plus the previously identified 160 non-session Claude workflow
records in four files. These are overlapping unknown/unclassified counters,
not additive losses. This remains a failed coverage gate.

The legacy-projector differential reports 406,118 exact payloads, 29,725 bounded
prefixes, 8,674 block-count differences, 3,759 block-field differences, 30
block-content differences and 148,550 classification differences. Newly
supported completed events explain many legacy-parser disagreements, but no
blanket exemption makes those mismatches pass. The separate selected canonical
run c finds 132,924 exact projections, 22 other content differences, 678 equal
projections with different envelope budget flags, 183 missing native references
and 11 legacy histories requiring their own canonical reference. It too fails.

Run l was invalidated by sandbox-denied process-RSS inspection, not by parsing;
its fail-closed guard rejected every file. Run m reran with inspection allowed.
Run k's one read-budget failure is now covered by a real 40 MiB canonical-index
regression: admitted page prefixes survive exhaustion and obtain an independent,
bounded cursor witness before continuing. A single over-budget record still
reports explicit capacity; this is not yet resumable giant-record ingestion.

Private evidence: `/private/tmp/tessera-normalization-coverage-20260912-m` and
`/private/tmp/tessera-codex-selected-projection-20260912-c`. The earlier audit
below is retained as the before-fix baseline, not the current unknown count.

## Complete private JSONL audit

Run `normalization-coverage-20260912-h` processed the finite private snapshot:

| Provider | Files | Records | File-processing failures | Files with unclassified records |
| --- | ---: | ---: | ---: | ---: |
| Codex | 973 | 706,945 | 0 | 972 |
| Claude Code | 270 | 122,441 | 0 | 116 |
| Total | 1,243 | 829,386 | 0 | 1,088 |

There are **199,121 unclassified records**, not 199,121 proven lost messages.
The independent output-vocabulary check flags those same records. Another
185,700-record counter flags the subset emitted as literal `unknown` records;
these counters overlap and must not be added together.

No unknown content-block, malformed known-field, or nested-content-flattening
issues were detected by this run after the fixes below. This statement is
bounded by the implemented schema checks and the captured corpus, not a claim
that all future provider types are supported. The legacy-parser differential
still has classification/block mismatches requiring reconciliation; agreement
with the legacy parser is never sufficient to pass type coverage.

Sampled peak worker RSS: native 16,302,080 bytes; independent Python reference
198,082,560 bytes. These are audit-worker measurements, not app/helper-tree or
cold-render latency measurements. The audit scripts, schema, normalizer binary
and reference are pinned in the private evidence directory with digests.
All transcript content, paths, IDs and mismatch samples remain outside Git.

### Unresolved observed envelopes

The original physical-file audit below remains **unsupported/unclassified**,
pending semantic review. A subsequent discovery audit identifies the `started`,
`result`, and `failed` rows as non-session workflow logs, not Claude transcript
message types; their160 records remain accounted for separately below.
No broad ignore rule was added to turn the test green. In particular, duplicate
event representations require evidence of their canonical counterpart, not
just a plausible name.

| Provider | Envelope / subtype | Records |
| --- | --- | ---: |
| Codex | event_msg/item_completed | 145,451 |
| Codex | token_usage_record | 18,654 |
| Codex | event_msg/task_started | 7,049 |
| Codex | event_msg/thread_settings_applied | 5,507 |
| Codex | inter_agent_communication_metadata | 3,879 |
| Codex | world_state | 2,679 |
| Codex | event_msg/user_message | 1,144 |
| Codex | event_msg/agent_message | 1,143 |
| Codex | event_msg/turn_aborted | 188 |
| Codex | event_msg/thread_goal_updated | 6 |
| Claude Code | last-prompt | 5,250 |
| Claude Code | atis-latch | 3,622 |
| Claude Code | bridge-session | 3,138 |
| Claude Code | file-history-delta | 558 |
| Claude Code | file-history-snapshot | 473 |
| Claude Code | relocated | 105 |
| Claude Code | worktree-state | 104 |
| Claude Code | started | 80 |
| Claude Code | result | 79 |
| Claude Code | pr-link | 10 |
| Claude Code | failed | 1 |
| Claude Code | fork-context-ref | 1 |

A corrected relationship probe finds exact source-text counterparts for all
1,144 legacy user events as well as1,143 assistant events. The earlier zero
user-match result was an oracle error: Codex input_text fragments concatenate
without inserted newlines. That investigation reproduced a real display bug:
the64-block cap could evict the start of a fragmented input. The native reader
now coalesces adjacent input_text before block admission, without crossing
attachments or injected-context boundaries. All39 reader tests pass, including
8KiB/16KiB, UTF-8 and explicit truncation boundaries.

The independent `codex_event_text_corpus.py` oracle checks the11 affected
private snapshots against original event text:222 exact native text results,
922 explicitly flagged bounded prefixes, zero mismatches or worker failures
(`/private/tmp/tessera-codex-event-text-20260912-a/content-free-results.json`).
This is a scoped text-preservation result, not event-only fallback or a
completed-item reconciliation. Completed-item IDs also often lack identical
raw response-item IDs; different identity domains must not be conflated.
No blanket ignore policy was added. The field-shape inventory shows completed
items include user/agent messages, reasoning, commands, edits, tools, plans,
compaction and extension variants, not just harmless lifecycle markers.

### Provider discovery versus arbitrary JSONL files

`source_layout_corpus.py` run c executes the pinned SDK's actual
`_read_sessions_from_dir` and `_collect_agent_files` on a private, content-free
copy of the source directory layout. Only title/content visibility helpers are
stubbed; the file collectors, UUID and leaf-name predicates are unchanged.
Native discovery matches all270 original file paths and8 synthetic edge cases:
112 main sessions,154 subagent transcripts,4 non-session workflow result logs.
There are no orphan subagent roots in this corpus. This is file-collection
grammar parity, not SDK title filtering or message-content equivalence.

The four sidecar logs contain80 `started`,79 `result`, and1 `failed` record.
They remain in the physical-file evidence; discovery no longer surfaces them
as conversations. Other unresolved types still occur in genuine sessions.
Evidence: `/private/tmp/tessera-source-layout-20260912-c/content-free-results.json`.
The earlier run a checked two handwritten path predicates plus SDK UUID
validation; it was not an independent SDK collector oracle and is superseded.

Fixture relocation now carries an explicit original provider root (saved in
new manifests), preserves nested subagent/workflow paths including directories
named `projects`, and chooses the largest recognized conversation rather than
the largest arbitrary JSONL sidecar. All source files remain in cold discovery
fixtures, including excluded sidecars.

Malformed Codex positional content annotations and non-object annotation
containers now produce a typed diagnostic without exposing injected fragments
as user prose. The independent source-shape audit rejects both failures too.
Synthetic regressions cover both; the real source inventory contains2,767
well-shaped annotations and5,026 absent annotations, with no malformed cases.

## Claude bookkeeping classification and hardened ignore audit

Strict rerun j covers1,243 physical files /829,386 records. All266 genuine
Claude transcripts have zero unknown/malformed input/output type-coverage
findings. This is not full content, relationship, branch or live-replay proof.

The13,261 non-message bookkeeping records are explicitly classified by both
known type and required/allowed field shapes: `file-history-snapshot`,
`file-history-delta`, `last-prompt`, `atis-latch`, `bridge-session`, `relocated`,
`worktree-state`, `pr-link`, and `fork-context-ref`. Their private cached/resume
payloads are omitted with a specific `claude-sdk-non-message/<type>` reason.
Malformed fields, extra unknown root fields and duplicate root keys do not
qualify. The independent audit rejects non-string/unknown reasons, mismatched
provider/type/visibility, and disagreement with the decoded source envelope.
Synthetic regressions reproduce the reviewed first-key/last-key decoder
ambiguity; native rejection prevents it from silently hiding future types.

All1,243 files finished with zero processing errors, but overall status remains
`failed_coverage`:185,700 Codex records and160 records in four non-session
workflow logs are still unclassified. No records were removed from physical
audit accounting. Evidence:
`/private/tmp/tessera-normalization-coverage-20260912-j/content-free-results.json`.
Reader44 / audit34 tests,13/13 native groups and disposable Linux reader/service/
hook/Codex/deployment lanes pass. Full canonical equivalence remains required.

## Structured Codex audit is a separate result

Run `native-window-coverage-20260912-c` traversed all **612 populated native
histories / 133,624 items**, in both directions, with zero file errors and zero
unknown normalized-item coverage failures. It checks identity/order,
dispositions, output vocabulary and revision/ACK behavior, not full canonical
payload equivalence or append/live replay. Tree peak: 151,912,448 bytes.
It includes malformed-reasoning/required-field and diagnostic-placeholder
hardening, but predates the final dynamic image/audio URL-alias validation.

A separate `native-source-schema-20260912-c` run validates all **133,624 items**
against the pinned generated official `ThreadItem` schema: zero invalid source
records. Schema SHA-256:
`24df528acec2952e6b96c1c2b061f98e60177d059e12c90cf318621380c9de9e`.
The corpus contains14 of19 declared item variants; the other5 now have
schema-validated synthetic fixtures with native block-type assertions:
`dynamicToolCall`, `functionCallOutput`, `hookPrompt`, `enteredReviewMode`, and
`exitedReviewMode`. All19 top-level variants have examples; this is not proof
that every possible nested-field combination is covered.
This uses `jsonschema/4.25.1`, a test-only pinned dependency,
with local schema references only. It does not treat a valid source item as
proof that every semantic field survived normalization.

The [official App Server item documentation](https://learn.chatgpt.com/docs/app-server)
and the locally pinned Codex 0.154 generated schema guide structured mappings.
They do not establish a complete contract for historical rollout JSONL
envelopes; the unresolved table above must not be represented as documented
internal metadata without further evidence.

## Regressions fixed during the audit

- Claude server/advisor calls, advisor result variants and model fallback
  boundaries now have typed mappings. Opaque encrypted output is labelled,
  never treated as plaintext.
- Mixed tool results retain text, images and tool references in source order.
  Codex tool-search/web-search items are recognized. `call_id` takes precedence
  over a distinct item `id` when associating calls and results.
- Unknown blocks remain counted even when a bounded preview evicts them.
  Independent input/output shape checks reject malformed known blocks and
  recursive wrappers instead of accepting an empty or flattened result.
- Shared-model unknown blocks are typed diagnostics, not user/assistant prose
  or thread-title seeds. Subsequent direct tests reproduced and fixed the same
  ordinary-prose fallback in the native App Server normalizer.
- Subsequent direct native tests cover malformed all-text tool-result arrays,
  primitive tool outputs, missing thinking text and invalid advisor text.
  Unknown-count diagnostics also survive system/injected-content filtering.

Tests: `Tools/AgentHost/tests/test_normalization_corpus.py`,
`test_jsonl_reader.py`, `normalize_tests.cpp`, the service wire-disposition case,
and shared `AgentConversationNormalizationTests`. Synthetic inputs only are
checked in. The full private corpus remains a required non-optional gate.

Audit h includes the JSONL direct-test fixes above. It predates the later
headline-status reporting change, which is separately unit tested: zero
file-processing errors with unresolved types reports `failed_coverage`.
Incomplete and empty corpora cannot pass. All28 audit tests pass.
# Latest continuation: legacy messages and independent conversion

Full physical run n processed all 1,243 files without processing failures.
All 1,239 conversation-layout files have zero unknown/unclassified records or
content-coverage issues. The remaining 160 unknown records are confined to four
non-session Claude workflow logs. Those failures remain in the strict report;
layout classification is not a claim that the logs were decoded as messages.
Old-projector payload differences still require semantic reconciliation, not
blanket equivalence because tags are recognized.

Actual-upstream Core audit c: 133,172 exact bounded projections plus 633 exact
same-revision native-store projections for installed-schema additions. Two
completed-subagent rows lack native references. Its 11 legacy-reference flags
are addressed separately for authored messages, not erased from the report.

The actual-upstream legacy authored audit passes all 11 historical files:
2,287 authored messages have exact block content and order. The selector pairs
2,287 exact event/response copies within turn boundaries, preserves standalone
events and distinct same-preview messages, and retains typed reasoning/tools.
Filtered positional annotations cannot prove pairing; a red/green regression
and reviewer recheck verify that distinct authored messages survive.

Evidence: `/private/tmp/tessera-normalization-coverage-20260912-n`,
`/private/tmp/tessera-upstream-core-corpus-20260912-c`, and
`/private/tmp/tessera-legacy-authored-corpus-20260912-a`.
Full replay, relationships, receipts, inherited-history traversal and remaining
native performance/lifecycle gates are still separate requirements.
