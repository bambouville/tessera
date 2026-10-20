#ifndef TESSERA_CORE_ABI_H
#define TESSERA_CORE_ABI_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define TESSERA_CORE_ABI_VERSION 4u
#define TESSERA_CORE_ABI_MAX_PAYLOAD_BYTES 1048576u

/*
 * Callback executor contract:
 *
 * - callbacks from one runtime are serialized and never overlap;
 * - their order follows that runtime's accepted send/emit operation order;
 * - they have no fixed OS-thread, queue, main-thread, or UI-thread affinity
 *   (a runtime may invoke synchronously on its operation caller or from an
 *   ABI-owned executor); and
 * - `bytes` is borrowed only for the callback's duration. The callback must
 *   copy or consume it before returning.
 *
 * A callback returns before the next callback for that runtime begins.
 * Platform adapters are responsible for dispatching presentation work to their
 * UI executor rather than relying on the callback's current thread.
 */
typedef void (*tessera_core_event_callback)(
    const uint8_t * _Nullable bytes,
    size_t count,
    void * _Nullable context
);

typedef void *tessera_core_runtime_t;

/*
 * Agent Center has an independent ABI because its runtime evolves separately
 * from the already-shipped session ABI v1. Commands and callbacks are bounded,
 * canonical JSON. Callback bytes are borrowed only for the call duration; the
 * platform bridge must copy them before returning. Calls from one agent handle
 * are serialized in accepted-operation order and carry a runtime generation.
 */
#define TESSERA_AGENT_ABI_VERSION 1u
#define TESSERA_AGENT_ABI_MAX_PAYLOAD_BYTES 1048576u

typedef void (*tessera_agent_event_callback)(
    const uint8_t * _Nullable bytes,
    size_t count,
    void * _Nullable context
);

typedef void *tessera_agent_runtime_t;

uint32_t tessera_agent_abi_version(void);
size_t tessera_agent_abi_max_payload_bytes(void);

tessera_agent_runtime_t _Nonnull tessera_agent_runtime_create(
    tessera_agent_event_callback _Nonnull callback,
    void * _Nullable context
);

/* Returns 0 when accepted, -1 for invalid arguments, and -2 for a stale handle. */
int32_t tessera_agent_runtime_send(
    tessera_agent_runtime_t _Nullable runtime,
    const uint8_t * _Nullable bytes,
    size_t count
);

/*
 * Privileged host-bridge registration, deliberately separate from `send`.
 *
 * A trusted route-owner bridge first calls
 * `tessera_agent_runtime_register_platform_proof` with bounded canonical
 * AgentABIPlatformProofRegistration JSON after it has independently
 * authenticated the route and proved the exact process/binding. The runtime
 * returns an opaque, single-use AgentABIPlatformProofHandle. Raw Agent command
 * JSON has no proof or registration kind and therefore cannot mint or replace
 * either capability.
 *
 * Binding registration then receives AgentABIPlatformBindingRegistration JSON
 * containing that `proofHandle` and matching public identity facts, but no
 * process IDs. It returns an unguessable `bindingToken`; Android must retain
 * it privately and include it on bind/lifecycle/projection/action/launch and
 * action-result/launch-receipt commands. The runtime rejects a mismatched or
 * reused proof. Observe-only proofs require exactly observe capability, no
 * PID/process IDs/directories, and can never authorize action or launch.
 *
 * Returns 0 on success, -1 for malformed arguments/rejected authority or
 * insufficient output space, and -2 for a stale handle.  No partial response
 * is written on failure.
 */
int32_t tessera_agent_runtime_register_platform_proof(
    tessera_agent_runtime_t _Nullable runtime,
    const uint8_t * _Nullable proof_bytes,
    size_t proof_count,
    uint8_t * _Nullable response_bytes,
    size_t response_capacity,
    size_t * _Nullable response_count
);

/* Exchanges a single-use proof handle for an opaque binding token. */
int32_t tessera_agent_runtime_register_platform_binding(
    tessera_agent_runtime_t _Nullable runtime,
    const uint8_t * _Nullable registration_bytes,
    size_t registration_count,
    uint8_t * _Nullable response_bytes,
    size_t response_capacity,
    size_t * _Nullable response_count
);

/*
 * Registers only a bounded list of Tier-C provider IDs that a trusted
 * platform route has already live-validated. The implementation selects the
 * matching adapter IDs and fixture digests from compiled attestations; callers
 * cannot provide either value. Returns 0 on success, -1 malformed/rejected,
 * and -2 for a stale handle.
 */
int32_t tessera_agent_runtime_register_platform_conformances(
    tessera_agent_runtime_t _Nullable runtime,
    const uint8_t * _Nullable registration_bytes,
    size_t registration_count
);

/* Privileged Tier-A candidate bridge; never available through send JSON. */
int32_t tessera_agent_runtime_register_platform_candidate(
    tessera_agent_runtime_t _Nullable runtime,
    const uint8_t * _Nullable registration_bytes, size_t registration_count
);
int32_t tessera_agent_runtime_remove_platform_candidate(
    tessera_agent_runtime_t _Nullable runtime,
    const uint8_t * _Nullable registration_bytes, size_t registration_count
);

/* Idempotent; stale handles are rejected by subsequent sends. */
void tessera_agent_runtime_destroy(tessera_agent_runtime_t _Nullable runtime);

/*
 * Remote Agent Center integration has its own stateless command-builder ABI.
 * It is deliberately separate from both terminal-core and Agent-runtime v1:
 * Android runs the returned command only over its authenticated shell route.
 * The three snapshot `present` flags distinguish an absent file from a
 * present-but-empty file so the generated install command retains its atomic
 * compare-and-swap guard. Inputs are UTF-8 and bounded by the published limit.
 */
#define TESSERA_AGENT_INTEGRATION_ABI_VERSION 2u
#define TESSERA_AGENT_INTEGRATION_ABI_MAX_CONFIG_BYTES 1048576u

uint32_t tessera_agent_integration_abi_version(void);
size_t tessera_agent_integration_abi_max_config_bytes(void);
size_t tessera_agent_integration_abi_max_install_attempts(void);
// Shared observation intervals in milliseconds as bounded JSON. As with command
// exports, a null output buffer returns the required byte count.
int32_t tessera_agent_integration_check_policy(
    uint32_t consecutive_failures, uint8_t *output_bytes, size_t output_capacity);

int32_t tessera_agent_host_deployment_command(const uint8_t *input_bytes, size_t input_count,
                                            uint8_t *output_bytes, size_t output_capacity);
int32_t tessera_agent_integration_status_command(
    uint8_t * _Nullable output_bytes, size_t output_capacity
);
int32_t tessera_agent_integration_codex_hooks_read_command(
    uint8_t * _Nullable output_bytes, size_t output_capacity
);
int32_t tessera_agent_integration_claude_settings_read_command(
    uint8_t * _Nullable output_bytes, size_t output_capacity
);
int32_t tessera_agent_integration_kimi_config_read_command(
    uint8_t * _Nullable output_bytes, size_t output_capacity
);
int32_t tessera_agent_integration_shell_status_command(
    const uint8_t * _Nullable process_ids_bytes, size_t process_ids_count,
    uint8_t * _Nullable output_bytes, size_t output_capacity
);

/* Scoped process discovery and raw probe parsers. All input/output is
 * bounded UTF-8/canonical JSON. ABI v2 is unreleased and intentionally keeps
 * policy with TesseraAgentCore rather than the platform adapters. */
int32_t tessera_agent_integration_process_discovery_command(
    const uint8_t * _Nullable scope_bytes, size_t scope_count,
    uint8_t * _Nullable output_bytes, size_t output_capacity
);
int32_t tessera_agent_integration_parse_status(
    const uint8_t * _Nullable input_bytes, size_t input_count,
    uint8_t * _Nullable output_bytes, size_t output_capacity
);
int32_t tessera_agent_integration_classify_install_output(
    const uint8_t * _Nullable input_bytes, size_t input_count,
    uint8_t * _Nullable output_bytes, size_t output_capacity
);
int32_t tessera_agent_integration_parse_shell_status(
    const uint8_t * _Nullable input_bytes, size_t input_count,
    uint8_t * _Nullable output_bytes, size_t output_capacity
);
int32_t tessera_agent_integration_parse_lifecycle_event(
    const uint8_t * _Nullable input_bytes, size_t input_count,
    uint8_t * _Nullable output_bytes, size_t output_capacity
);
int32_t tessera_agent_integration_parse_configs(
    const uint8_t * _Nullable input_bytes, size_t input_count,
    uint8_t * _Nullable output_bytes, size_t output_capacity
);
int32_t tessera_agent_integration_parse_process_discovery(
    const uint8_t * _Nullable scope_bytes, size_t scope_count,
    const uint8_t * _Nullable input_bytes, size_t input_count,
    uint8_t * _Nullable output_bytes, size_t output_capacity
);
int32_t tessera_agent_integration_apply_current_shell_command(
    uint8_t * _Nullable output_bytes, size_t output_capacity
);
int32_t tessera_agent_integration_persist_apply_current_shell_command(
    uint8_t * _Nullable output_bytes, size_t output_capacity
);
int32_t tessera_agent_integration_install_command(
    int32_t codex_present, const uint8_t * _Nullable codex_bytes, size_t codex_count,
    int32_t claude_present, const uint8_t * _Nullable claude_bytes, size_t claude_count,
    int32_t kimi_present, const uint8_t * _Nullable kimi_bytes, size_t kimi_count,
    uint8_t * _Nullable output_bytes, size_t output_capacity
);
int32_t tessera_agent_integration_resolve(
    const uint8_t * _Nullable request_bytes, size_t request_count,
    uint8_t * _Nullable output_bytes, size_t output_capacity
);

/* Existing Agent Center exports: bounded JSON composer evidence, base64
 * insertion bytes, and content-free projector error fields. Copy-out calls
 * support a null output size query; -1 means unavailable/invalid input. */
int32_t tessera_agent_composer_assess(
    const uint8_t * _Nullable input_bytes, size_t input_count
);
/* Boolean match (0 or 1); invalid evidence is not a match. */
int32_t tessera_agent_composer_matches(
    const uint8_t * _Nullable input_bytes, size_t input_count
);
int32_t tessera_agent_composer_insertion(
    const uint8_t * _Nullable input_bytes, size_t input_count,
    uint8_t * _Nullable output_bytes, size_t output_capacity
);
int32_t tessera_agent_projector_diagnostics(
    const uint8_t * _Nullable input_bytes, size_t input_count,
    uint8_t * _Nullable output_bytes, size_t output_capacity
);

/*
 * Shared, display-only Agent Markdown parsing. Input must be valid UTF-8 and
 * no larger than 128 KiB; a null input is permitted only with count zero.
 * Output is canonical JSON no larger than 2 MiB. A null output queries the
 * required size. An insufficient non-null output buffer returns -1 and writes
 * no bytes.
 */
int32_t tessera_agent_markdown_parse(
    const uint8_t * _Nullable input_bytes, size_t input_count,
    uint8_t * _Nullable output_bytes, size_t output_capacity
);

/* Bounded framed canonical page and query -> display-only search matches. */
int32_t tessera_agent_page_search(
    const uint8_t * _Nullable input_bytes, size_t input_count,
    uint8_t * _Nullable output_bytes, size_t output_capacity
);

/* Bounded JSON array of process descriptors -> JSON array of provider IDs. */
int32_t tessera_agent_provider_classify(
    const uint8_t * _Nullable descriptor_bytes, size_t descriptor_count,
    uint8_t * _Nullable output_bytes, size_t output_capacity
);

/*
 * Portable compact-pane geometry shared by Apple and Android. The layout is
 * tmux's cell grammar without the checksum ("WxH,X,Y{...}"); with it and the
 * focused pane id (-1 for none) the size is solved against tmux's own window
 * resize. Without a layout, or with one the core's parser refuses (malformed,
 * or longer than it accepts), the window/focus rectangles (0,0 for absent)
 * are scaled by ratio. The size helper packs columns in the high 32 bits and
 * rows in the low 32 bits; zero denotes invalid input. The reprojection
 * helper reads and replaces the caller's two opaque memo words (both 0 for a
 * fresh tmux client) and returns 0 hold, 1 reproject, 2 hold a stopped resize
 * cycle, 3 for the call that stopped it, or -1 for invalid input (memo
 * untouched).
 */
uint64_t tessera_tmux_compact_layout_client_size(
    int32_t viewport_columns,
    int32_t viewport_rows,
    const uint8_t * _Nullable layout_bytes,
    size_t layout_count,
    int32_t focus_pane_id,
    int32_t window_columns,
    int32_t window_rows,
    int32_t focus_columns,
    int32_t focus_rows
);

int32_t tessera_tmux_compact_layout_reprojection(
    int32_t viewport_columns,
    int32_t viewport_rows,
    int32_t last_columns,
    int32_t last_rows,
    const uint8_t * _Nullable layout_bytes,
    size_t layout_count,
    int32_t focus_pane_id,
    int32_t window_columns,
    int32_t window_rows,
    int32_t focus_columns,
    int32_t focus_rows,
    uint64_t * _Nullable memo
);

/*
 * Side-channel window sizing reconciliation: 0 fitting, 1 waiting, 2 replay,
 * or -1 for invalid geometry. Dimensions are 1...65535; absent observed or
 * last-attempt geometry is exactly 0,0. Fitting never clears an outstanding
 * attempt: only its fresh post-command confirmation may do that.
 */
int32_t tessera_tmux_window_size_replay_decision(
    int32_t requested_columns, int32_t requested_rows,
    int32_t observed_columns, int32_t observed_rows,
    int32_t last_attempt_columns, int32_t last_attempt_rows
);

/*
 * Three newline-separated fixed commands: resize, unset window-size, and a
 * tagged exact-window geometry query. Send the first two mutations and wait
 * for both successful acknowledgements before transmitting the third command
 * separately: a batched query can read the temporary manual grid before tmux
 * applies the unset policy. Window IDs are nonnegative. Returns the
 * required/copied UTF-8 byte count, or -1 for invalid arguments/short buffer.
 * A nil or zero-capacity output queries the required count; no NUL is written.
 */
int32_t tessera_tmux_window_size_replay_commands(
    int32_t window_id, int32_t columns, int32_t rows,
    uint8_t * _Nullable output_bytes, size_t output_capacity
);

/*
 * Confirm the final command's reply: tessera-window-size TAB @window TAB cols
 * TAB rows, optionally followed by one LF/CRLF. Returns 1 for an exact match,
 * 0 for a malformed/mismatched reply, or -1 for invalid arguments. The reply
 * is bounded to 256 bytes. The adapter must also match its unique attempt
 * token and transport generation before clearing an outstanding attempt.
 */
int32_t tessera_tmux_window_size_replay_confirm(
    int32_t window_id, int32_t columns, int32_t rows,
    const uint8_t * _Nullable reply_bytes, size_t reply_count
);

/*
 * The tagged exact-window size read alone (the third replay command), which
 * a take-back claim also writes as its settle probe after its fence was
 * acknowledged. Same output contract as tessera_tmux_window_size_replay_commands.
 */
int32_t tessera_tmux_window_size_replay_size_query(
    int32_t window_id,
    uint8_t * _Nullable output_bytes, size_t output_capacity
);

/*
 * The grid a size read's reply reports for window_id: columns << 32 | rows,
 * 0 for a malformed reply or one naming another window, or -1 for invalid
 * arguments. Same reply grammar and 256-byte bound as
 * tessera_tmux_window_size_replay_confirm.
 */
int64_t tessera_tmux_window_size_replay_reported_geometry(
    int32_t window_id,
    const uint8_t * _Nullable reply_bytes, size_t reply_count
);

/*
 * Prove that a physical window's complete client inventory contains exactly
 * the two distinct supplied name|pid|created identities. Every inventory row
 * has four actual TAB-separated fields: @window_id, name, pid, created.
 * All records and positive decimal identity numbers must be canonical;
 * duplicate client identities or records fail closed, including other windows.
 * LF/CRLF records and one terminal line ending are accepted. Identity inputs
 * are bounded to 256 UTF-8 bytes each; inventory is bounded to 65536 bytes.
 * Returns 1 for exclusive ownership, 0 for malformed UTF-8/content or lack of
 * ownership, and -1 for negative window ID or invalid pointers/counts.
 */
int32_t tessera_tmux_window_size_replay_proves_exclusive_ownership(
    int32_t window_id,
    const uint8_t * _Nullable control_identity_bytes, size_t control_identity_count,
    const uint8_t * _Nullable visible_identity_bytes, size_t visible_identity_count,
    const uint8_t * _Nullable inventory_bytes, size_t inventory_count
);

/*
 * Derive the portable automatic-tmux target from a UTF-8 user@host:port key.
 * Returns the number of UTF-8 bytes copied, or -1 for invalid arguments.
 */
int32_t tessera_tmux_default_session_name(
    const uint8_t * _Nullable host_key_bytes,
    size_t host_key_count,
    uint8_t * _Nullable output_bytes,
    size_t output_capacity
);

/* Shared capture-pane repaint parser and terminal-state restoration. */
int32_t tessera_tmux_assemble_repaint(
    const uint8_t * _Nullable metadata_bytes,
    size_t metadata_count,
    const uint8_t * _Nullable capture_bytes,
    size_t capture_count,
    int32_t terminal_is_in_alt_screen,
    int32_t client_rows,
    uint8_t * _Nullable output_bytes,
    size_t output_capacity
);

/*
 * Shared remote-command builders. Every one follows the same string contract:
 * a NULL or zero-capacity output buffer queries the required byte count,
 * otherwise the UTF-8 bytes are copied and their count returned. -1 means the
 * arguments were invalid or the command did not fit.
 */
/* A zero-length device id publishes no grid-authority ownership option. */
int32_t tessera_tmux_mosh_visible_client_command(
    const uint8_t * _Nullable session_target_bytes,
    size_t session_target_count,
    const uint8_t * _Nullable grid_authority_device_id_bytes,
    size_t grid_authority_device_id_count,
    int32_t ignores_size,
    uint8_t * _Nullable output_bytes,
    size_t output_capacity
);

/* Tessera's private view of a user tmux session, sharing its windows. */
int32_t tessera_tmux_mosh_view_session_name(
    const uint8_t * _Nullable session_target_bytes,
    size_t session_target_count,
    uint8_t * _Nullable output_bytes,
    size_t output_capacity
);

/* Joins Tessera's private view session, as the visible mosh client does. */
int32_t tessera_tmux_mosh_control_channel_command(
    const uint8_t * _Nullable session_target_bytes,
    size_t session_target_count,
    int32_t preserve_initial_geometry,
    uint8_t * _Nullable output_bytes,
    size_t output_capacity
);

int32_t tessera_tmux_control_mode_session_command(
    const uint8_t * _Nullable session_target_bytes,
    size_t session_target_count,
    int32_t preserve_initial_geometry,
    uint8_t * _Nullable output_bytes,
    size_t output_capacity
);

/*
 * Frame one tmux window so its focused pane fills a compact viewport. Writes
 * content_width, content_height, scale, offset_x, offset_y. Returns 1 when a
 * projection was written, 0 when the inputs are degenerate and the caller
 * should render at natural size, -1 when output_values is NULL.
 */
int32_t tessera_tmux_compact_canvas_projection(
    int32_t window_columns,
    int32_t window_rows,
    int32_t window_x,
    int32_t window_y,
    int32_t focus_columns,
    int32_t focus_rows,
    int32_t focus_x,
    int32_t focus_y,
    double cell_width,
    double cell_height,
    double viewport_width,
    double viewport_height,
    double * _Nullable output_values
);

/*
 * The fixed hydration queries, newline-separated in send order. The runtime
 * parses their tagged replies, so a client keeping its own copy of these format
 * strings drifts out of step with the parser. Same string contract as above.
 */
int32_t tessera_tmux_hydration_commands(
    uint8_t * _Nullable output_bytes,
    size_t output_capacity
);

/*
 * Shared tmux window command builders. JSON requests and structured responses
 * are canonical UTF-8; all four functions use the ordinary two-pass output
 * contract. A negative result rejects malformed, overlong, or unsupported
 * input without writing a partial result. A `selectWindow` request may carry
 * `sessionId` (`"$N"`, the issuing client's own session) to build the
 * session-qualified tab switch `select-window -t '$N:@W'`; no other op
 * accepts it.
 */
int32_t tessera_tmux_window_command(
    const uint8_t * _Nullable request_bytes,
    size_t request_count,
    uint8_t * _Nullable output_bytes,
    size_t output_capacity
);

int32_t tessera_tmux_window_reorder_plan(
    const uint8_t * _Nullable request_bytes,
    size_t request_count,
    uint8_t * _Nullable output_bytes,
    size_t output_capacity
);

int32_t tessera_tmux_window_capabilities(
    const uint8_t * _Nullable request_bytes,
    size_t request_count,
    uint8_t * _Nullable output_bytes,
    size_t output_capacity
);

int32_t tessera_tmux_session_group_members(
    const uint8_t * _Nullable request_bytes,
    size_t request_count,
    uint8_t * _Nullable output_bytes,
    size_t output_capacity
);

int32_t tessera_tmux_session_group_renumber_commands(
    const uint8_t * _Nullable request_bytes,
    size_t request_count,
    uint8_t * _Nullable output_bytes,
    size_t output_capacity
);

/*
 * The fixed tagged active-pane query for a validated numeric tmux window id.
 * The runtime parses its correlated result before the platform completion is
 * delivered. Same two-pass string contract; negative for invalid input.
 */
int32_t tessera_tmux_active_pane_command(
    int32_t window_id,
    uint8_t * _Nullable output_bytes,
    size_t output_capacity
);

/*
 * The one session-qualified window target: `'$S:@W'`, or `'$S:@W.%P'` when
 * `pane_id` is non-negative (negative means no pane). A bare `@W` target
 * resolves to the most recently active session holding the window, which in
 * a session group can be a sibling (the mosh view session, a user's
 * `tmux new -t`), so a tab switch or a visible-client `switch-client` must
 * name its own session. Single-quoted so tmux's lexer never treats the `$`
 * as an environment expansion. Same two-pass string contract; negative for a
 * negative session or window id.
 */
int32_t tessera_tmux_session_window_target(
    int32_t session_id,
    int32_t window_id,
    int32_t pane_id,
    uint8_t * _Nullable output_bytes,
    size_t output_capacity
);

/**
 * The shared client-size replay (`TmuxClientSizeReplay`): `refresh-client -C
 * columns,rows` and, on the inline path, a targetless no-op `select-window`
 * fence — tmux resolves it to the current window when it executes, right
 * after the refresh, and the command is what makes this client the window's
 * `latest` client. Without that fence tmux ignores the size whenever another
 * client holds `latest` (an `ignore-size` attach, a keystroke on a laptop
 * client) and the window freezes at its old grid while this device renders
 * the new one. `side_channel` != 0 selects the mosh side-channel path, which
 * forces windows directly instead and gets the refresh alone. Each command
 * is its own control-mode reply. `belongs_to_claim` != 0 marks the replay a
 * take-back claim issues: the claim acks and fences it itself, so the
 * refresh goes out alone. Newline-separated in send order; same string
 * contract as above; negative for a grid tmux would reject.
 */
int32_t tessera_tmux_client_size_replay_commands(
    int32_t columns,
    int32_t rows,
    int32_t side_channel,
    int32_t belongs_to_claim,
    uint8_t * _Nullable output_bytes,
    size_t output_capacity
);

/* Canonical JSON {op, ownerSessionID?, stamp?, name?}; JSON command array.
 * op: query | write | ownerResolution. Send each separately;
 * only the first write reply acknowledges the authority commit. */
int32_t tessera_tmux_authority_commands(
    const uint8_t * _Nullable request_bytes, size_t request_count,
    uint8_t * _Nullable output_bytes, size_t output_capacity);
/* Canonical JSON {ownerSessionID?, reply: [string]}; the reply's stamp lines
 * as a JSON array, or JSON null when an owner read found no owner. */
int32_t tessera_tmux_authority_query_reply(
    const uint8_t * _Nullable request_bytes, size_t request_count,
    uint8_t * _Nullable output_bytes, size_t output_capacity);
/* Canonical JSON {ownerReply?: [string], ownReply?: [string]}; id or -1. */
int64_t tessera_tmux_authority_resolve_owner(const uint8_t * _Nullable request_bytes, size_t request_count);
/* 1 when an Agent Center tmux command only reads, 0 otherwise, -1 for a
 * missing command. Reads may run while another device holds the grid. */
int32_t tessera_tmux_agent_command_is_read_only(const uint8_t * _Nullable command_bytes, size_t command_count);
/* 1 when an Agent Center tmux command only reads or sends to a proved pane
 * without moving grid authority, 0 when it waits on the authority gate,
 * -1 for a missing command. */
int32_t tessera_tmux_agent_command_is_authority_neutral(const uint8_t * _Nullable command_bytes, size_t command_count);

/*
 * The inline replay's latest fence alone: the targetless select-window
 * above, for the writes an adapter makes itself (a take-back's own fence).
 * Same string contract as above.
 */
int32_t tessera_tmux_client_size_latest_fence_command(
    uint8_t * _Nullable output_bytes,
    size_t output_capacity
);

int32_t tessera_tmux_classify_launch_failure(int32_t exit_status,
                                            int32_t has_exit_status,
                                            const uint8_t * _Nullable output_bytes,
                                            size_t output_count);

/*
 * Name whoever holds the shared grid. known_device_names is a tab-separated
 * list of the device classes the calling platform stamps; a peer name outside
 * that set resolves to the shared stamp-less wording rather than rendering
 * another platform's stamp verbatim. Same string contract as above.
 */
int32_t tessera_tmux_peer_label(
    const uint8_t * _Nullable peer_display_name_bytes,
    size_t peer_display_name_count,
    const uint8_t * _Nullable self_display_name_bytes,
    size_t self_display_name_count,
    const uint8_t * _Nullable known_device_names_bytes,
    size_t known_device_names_count,
    uint8_t * _Nullable output_bytes,
    size_t output_capacity
);

/*
 * Whether a window resize this device did not initiate proves a stamp-less
 * peer took the grid. A negative seconds_since_local_size_replay means this
 * device has never replayed a size on this connection.
 */
int32_t tessera_tmux_stampless_peer_should_raise(
    int32_t participates_in_authority,
    int32_t window_size_policy_known,
    int32_t window_size_policy_is_latest,
    int32_t rederive_in_flight,
    int32_t already_peer,
    int32_t reclaim_in_flight,
    int32_t layout_is_for_rendered_window,
    int32_t layout_columns,
    int32_t layout_rows,
    int32_t local_columns,
    int32_t local_rows,
    double seconds_since_local_size_replay
);

/*
 * The stateful tmux parser/topology runtime. It owns the control-mode parse,
 * the pane/window snapshot, and grid-authority arbitration; a client feeds it
 * bytes and receives snapshot events on the callback. Callback bytes are
 * borrowed for the call duration only.
 *
 * Event version 3 carries `snapshot` only when it changed since the last one
 * the handle queued (and on the handle's first event), and every envelope
 * names its snapshot by `snapshotKey` {epoch, revision}. On a state event (one
 * without platformWireCommands) an absent snapshot means "the one decoded
 * under this same key". A wire-only event is the exception: it carries no
 * snapshot after the handle's first event and its key may be ahead of the
 * last carried one, so its key is not compared and any snapshot a platform
 * pairs with it may lag the engine. The platform must therefore decode every
 * callback, in order, with one decoder per handle, even while no listener is
 * attached. A state event whose key differs from the held snapshot's key
 * means a carrying event was lost or failed to decode: call
 * tessera_tmux_runtime_resync_snapshot.
 *
 * These five prototypes were absent from this header while the JNI shim
 * dlsym'd them anyway, which is precisely the failure `scripts/check-abi-header.sh`
 * now prevents: a missing declaration is invisible until the symbol is missing
 * at runtime, on a device.
 *
 * The runtime reports changed raw authorityStamps as one-shot edges; the
 * shared authority session classifies them. One operation may emit bounded
 * callbacks when its ordered effect list does not fit one envelope. `feed`
 * returns 0 accepted, -1 for invalid input or bounded-delivery backpressure,
 * and -2 for a stale handle.
 */
void * _Nonnull tessera_tmux_runtime_create(
    tessera_core_event_callback _Nonnull callback,
    void * _Nullable context
);

int32_t tessera_tmux_runtime_feed(
    void * _Nullable handle,
    const uint8_t * _Nullable bytes,
    size_t count
);

/*
 * tessera_tmux_runtime_feed at now_millis on the attached authority session's
 * clock (never negative). With a session attached, the session reduces a read
 * that carries stamp edges or moves the topology in wire order, as iOS reduces
 * each message: a control-session change at its step (a switch between known
 * sessions also reports the new session's window facts and attaches again),
 * and the window facts at each step that changes them (past 32 changes in one
 * read, only those in force before each stamp edge and at the read's end).
 * Each verdict is projected before the later messages reach the render
 * ledger, which releases the work it owed the verdict there. The event then
 * carries no authorityStamps but `authorityReducedInFeed` and
 * `authoritySession`, the session's response to the read in the shape
 * tessera_tmux_authority_lifecycle_reduce returns, absent when the read changed
 * nothing; apply it as that call's result, and report none of those facts
 * again. A split event carries both in its first callback. The adapter
 * reduces the read itself (its edges arrive as authorityStamps) for a read
 * fed from inside a callback, a read with more than 32 edges and a read with
 * more than four session changes; then the edges before the read's last
 * session switch are dropped, as that switch reset the session they spoke
 * for. `controlSessionSwitched` marks a read that switched between known
 * sessions either way. An event outside a feed (a resync answer, a fact's)
 * carries `authorityReducedInFeed` when the session already holds its
 * snapshot, so an adapter that lost the read's event does not take the
 * snapshot's session for a switch it must reduce.
 *
 * Returns 0, or 1 when the event carried `authoritySession`; -1 rejects the
 * read (or a negative clock) and -2 identifies a stale handle. The session
 * has moved on either way: an adapter whose session did not adopt that
 * result during the call lost its event, and asks for it again with
 * tessera_tmux_runtime_redeliver_authority_result.
 */
int32_t tessera_tmux_runtime_feed_at(
    void * _Nullable handle,
    const uint8_t * _Nullable bytes,
    size_t count,
    int64_t now_millis
);

/*
 * Deliver the last tessera_tmux_runtime_feed_at's `authoritySession` again,
 * in a state event carrying the current snapshot: the session's state at
 * now_millis with the lost result's effects and trace, each of which the
 * adapter judges against that state. Only right after that feed, outside a
 * callback; a later feed or attach forgets the result. Returns 0, -1 when
 * there is nothing to deliver (or the call is out of place), and -2 for a
 * stale handle.
 */
int32_t tessera_tmux_runtime_redeliver_authority_result(
    void * _Nullable handle,
    int64_t now_millis
);

/*
 * Attach the authority session (a tessera_tmux_authority_lifecycle handle)
 * that tessera_tmux_runtime_feed_at reduces stamps into; NULL detaches. The
 * runtime holds it across transports until detached, and stops reducing it
 * once the session handle is destroyed. Call it under the transport-order lock
 * that serializes every reduction of that session. Returns 0, -1 for a session
 * handle that is not live, and -2 for a stale runtime handle.
 */
int32_t tessera_tmux_runtime_attach_authority_session(
    void * _Nullable handle,
    void * _Nullable session
);

/*
 * Put one platform-originated tmux command into the same FIFO that owns
 * render-ledger capture commands. A positive return is the 63-bit reply tag;
 * -1 rejects invalid command bytes and -2 identifies a stale handle. The
 * adapter must atomically admit this call and its physical wire enqueue
 * under the same transport-order lock used by every feed/submit_fact call that
 * can emit sendCommand. It receives the matching reply as a render effect on
 * the ordinary callback.
 */
int64_t tessera_tmux_runtime_send_command(
    void * _Nullable handle,
    const uint8_t * _Nullable text,
    size_t count
);

/*
 * Reserve one platform command and deliver its physical write through the
 * same ordered callback queue as render-ledger commands. The callback has
 * platformWireCommands: [{tag, command}] and no render effects, authority
 * edges or snapshot (unless it is the handle's first event, whose snapshot
 * must still be decoded). It publishes no state of its own: transport its
 * commands, and never separately write the command supplied to this
 * function. Deliver them even when no snapshot is known yet, since each one
 * already holds a reply slot. This avoids
 * wire/FIFO inversion when a reentrant fact has queued an earlier command.
 *
 * A positive return is the reply tag; -1 rejects invalid bytes or bounded
 * callback backpressure and -2 identifies a stale handle. A rejected command
 * leaves no reply slot. Delivery may occur before this call returns, so admit
 * the call and install the tag's reply purpose under the transport-order lock
 * used by feed/submit_fact. Cancellation of an unwritten tag also suppresses
 * its pending wire callback. The legacy send_command contract is unchanged.
 */
int64_t tessera_tmux_runtime_queue_command(
    void * _Nullable handle,
    const uint8_t * _Nullable text,
    size_t count
);

/*
 * JSON array variants of send_command and queue_command. The nonempty array
 * contains nonempty command strings without semicolon, LF, CR or NUL. Callers
 * supply one concrete command per element; tmux syntax is not parsed. The
 * wire text is joined with " ; ", reserving one reply tag for the whole line.
 * The reply closes after every command frame or the first error, and includes
 * parts: [{success, lines}] for lists of more than one command. Single-element
 * lists preserve the single-command reply JSON. Return values, locking and
 * ordered callback rollback follow the corresponding single-command API.
 */
int64_t tessera_tmux_runtime_send_command_list(
    void * _Nullable handle,
    const uint8_t * _Nullable json,
    size_t count
);

int64_t tessera_tmux_runtime_queue_command_list(
    void * _Nullable handle,
    const uint8_t * _Nullable json,
    size_t count
);

/*
 * Submit one bounded, canonical, versioned RenderFact JSON document. Returns
 * 0 accepted, -1 for invalid input, an unsupported fact version, or bounded
 * callback-delivery backpressure, and -2 for a stale handle. Resulting render
 * effects are delivered synchronously through the normal runtime callback;
 * the callback may re-enter this function within that bounded queue.
 */
int32_t tessera_tmux_runtime_submit_fact(
    void * _Nullable handle,
    const uint8_t * _Nullable json,
    size_t count
);

/*
 * Ceiling on one render payload exposed by
 * tessera_tmux_runtime_take_render_bytes. It is deliberately larger than
 * TESSERA_CORE_ABI_MAX_PAYLOAD_BYTES, which bounds arguments a platform
 * composes: a render payload is a tmux capture-pane reply whose size the host
 * decides, and a full-depth inline history capture of a wide pane runs to
 * several hundred kilobytes.
 */
#define TESSERA_TMUX_ABI_MAX_RENDER_BYTES 8388608u

/*
 * Copy the raw payload named by a previously delivered RenderEffect.feed.
 * Pass NULL output_bytes to query the byte count without consuming the ref,
 * then call again with sufficient capacity to copy and consume it. Every
 * exposed payload is at most TESSERA_TMUX_ABI_MAX_RENDER_BYTES. Unclaimed
 * refs expire only when taken, superseded by an authoritative generation, or
 * the handle is destroyed. A bounded byte/reference backlog rejects new
 * effects rather than evicting promised refs. Returns a non-negative byte
 * count, -1 for a bad/expired ref or insufficient capacity, and -2 for a stale
 * handle.
 */
int32_t tessera_tmux_runtime_take_render_bytes(
    void * _Nullable handle,
    uint64_t bytes_ref,
    uint8_t * _Nullable output_bytes,
    size_t output_capacity
);

/* Inline (SSH+tmux) history deepen gate. The shared rule for when a
 * platform should submit the `scrollbackRequested` render fact for a
 * surface so the ledger fetches older tmux history than the first deep
 * capture. `can_deepen` and `request_in_flight` come from the platform's
 * record of the last `inlineHistorySettled` render effect; the row counts
 * are local view geometry (rows still hidden above the viewport top, and
 * visible rows). Flags are 0/1; any other flag value returns -1. Returns 1
 * to request, 0 to stay quiet. */
int32_t tessera_tmux_inline_history_should_request(
    int32_t can_deepen,
    int32_t request_in_flight,
    int32_t rows_above_oldest,
    int32_t viewport_rows,
    int32_t crossed_oldest_row
);

/*
 * Project the shared authority session's verdict (TmuxGridAuthoritySnapshot's
 * Codable JSON) and release the render work deferred while a peer held the
 * grid: relayout repaints and take-back history. An unchanged projection
 * returns {"renderEffects":[]} and leaves the ledger alone.
 *
 * output_bytes must be non-NULL with output_capacity at least
 * TESSERA_CORE_ABI_MAX_PAYLOAD_BYTES. Capacity and JSON are checked before
 * mutation. Success returns the byte count of {"renderEffects":[...]}, using
 * the same RenderEffect objects as the ordinary runtime event.
 *
 * Outside a callback the work is returned: write every sendCommand in order
 * under this call's transport-order lock and before any later command, since
 * each already owns a FIFO reply slot. Inside a callback it is queued behind
 * the earlier events and the result is {"renderEffects":[]}. The projection
 * emits no snapshot event of its own; the next state event carries it.
 * Returns -1 for malformed JSON, missing/short output or bounded-delivery
 * backpressure (fence as for submit_fact), and -2 for a stale handle.
 */
int32_t tessera_tmux_runtime_project_authority_releasing(
    void * _Nullable handle,
    const uint8_t * _Nullable authority_json,
    size_t authority_count,
    uint8_t * _Nullable output_bytes,
    size_t output_capacity
);

/*
 * Adapter-owned render-ledger switches, as bits for
 * tessera_tmux_runtime_set_render_ledger_options. A new handle has none set.
 *
 * SUPPRESSES_UNCHANGED_CLIENT_SIZE_REPLAY (P6): a clientSize fact for the grid
 * this connection already advertised sends no refresh-client -C; the inline
 * path still sends its latest fence alone. The memory belongs to one
 * connection: a failed -C reply, transportAttached, transportLost, a command
 * FIFO reset and %session-changed clear it, so a rejected or lost
 * advertisement is sent again. Set it only once every -C the adapter sends
 * goes through the clientSize fact.
 *
 * INLINE_CLIENT_SIZE_REPLAY_BELONGS_TO_CLAIM: an inline clientSize replay
 * sends its refresh alone, without the latest fence: set it while a take-back
 * claim is pending (the claim fences itself) and while the session's
 * authority read found no stamp, and clear it otherwise. Update it before
 * submitting the clientSize fact it should govern.
 *
 * PIPELINES_VISIBLE_CAPTURE (P8): a take-back's visible-rows refresh, and any
 * refresh while a peer holds the grid, sends its capture in the same burst as
 * its metadata query, and a correlated refresh queues behind the commands its
 * adapter already sent instead of waiting for the FIFO to drain.
 */
#define TESSERA_TMUX_RENDER_LEDGER_SUPPRESSES_UNCHANGED_CLIENT_SIZE_REPLAY 1u
#define TESSERA_TMUX_RENDER_LEDGER_INLINE_CLIENT_SIZE_REPLAY_BELONGS_TO_CLAIM 2u
#define TESSERA_TMUX_RENDER_LEDGER_PIPELINES_VISIBLE_CAPTURE 4u

/*
 * Replace the adapter-owned switches above with exactly the bits in options
 * (every other ledger setting is the core's). Takes effect for the next
 * decision; work already queued keeps the decision it was made under. Emits
 * no callback and may be called from inside one. Returns 0, -1 for an
 * undefined bit, and -2 for a stale handle.
 */
int32_t tessera_tmux_runtime_set_render_ledger_options(
    void * _Nullable handle,
    uint32_t options
);

/*
 * OSC 7501 program status for the attached session's panes, initially disabled.
 * Disabling discards every record. Emits no callback; may be called from one.
 * Every runtime envelope (including wire-only events and split shards) carries
 * programStatusRevision, the monitor's revision at emit time. Version stays 3.
 * Returns 0, or -2 for a stale handle.
 */
int32_t tessera_tmux_runtime_set_program_status_enabled(
    void * _Nullable handle,
    int32_t enabled
);

/*
 * The live refresh-client -B feeds the runtime keeps registered for this
 * control client. feeds is a bitmask: 1 bell, 2 pane metadata, 4 window order
 * (registered only once the server reports tmux 3.2 or later), 8 grid
 * authority. authority_owner_session_id names the authority scope when bit 8
 * is set: -1 the client's own session, otherwise the owner session $N.
 *
 * Every feed is registered against one pane or one window, never %*, @* or
 * the session: tmux 3.2-3.6a crash the server when a control client holding
 * one of those outlives its session. Pane feeds are registered for each pane
 * once this connection's window list has been ingested, and dropped as panes
 * close; the session feeds (authority, window order) ride one anchor window.
 * The commands this call produces arrive in callback events'
 * subscriptionCommands, as later ones do in feed events, a large change split
 * across several events; the adapter sends each, in order, and ignores the
 * reply. Requests survive a reset.
 * Returns 0, -1 for an invalid argument or a refused event, -2 for a stale
 * handle.
 */
int32_t tessera_tmux_runtime_set_subscriptions(
    void * _Nullable handle,
    uint32_t feeds,
    int64_t authority_owner_session_id
);

/*
 * Two-pass copy of the version 1 program status JSON document. A NULL output
 * returns its byte count. Optional keys are omitted, never null. Returns the
 * byte count copied, -1 for short capacity (without writing), -2 for a stale
 * handle. May be called from inside a callback.
 */
int32_t tessera_tmux_runtime_copy_program_status(
    void * _Nullable handle,
    uint8_t * _Nullable output_bytes,
    size_t output_capacity
);

/*
 * Mark pane pane_id's unread results through result token through as checked.
 * Blocked records are never acknowledged. Returns 1 when the visible status
 * changed (revision moved), 0 when unchanged, -1 for pane_id < 0, -2 stale.
 */
int32_t tessera_tmux_runtime_acknowledge_program_status(
    void * _Nullable handle,
    int64_t pane_id,
    uint64_t through
);

/* Raw (plain SSH) OSC 7501 monitor; initially disabled, answers queries. */
#define TESSERA_PROGRAM_STATUS_MAX_REPLY_BYTES 4096u

void * _Nonnull tessera_program_status_monitor_create(void);
void tessera_program_status_monitor_destroy(void * _Nullable handle);

/* Returns 0, -2 stale. Disabling discards every record. */
int32_t tessera_program_status_monitor_set_enabled(
    void * _Nullable handle,
    int32_t enabled
);

/*
 * Scan output before handing it to the terminal emulator. Write query replies
 * to the remote first. Writes only whole ProgramStatusReply.query replies, up
 * to reply_capacity; drops replies that do not fit. Writes the revision after
 * scanning to revision_out if non-NULL.
 * Returns the reply byte count, -1 for bytes == NULL with count > 0, count >
 * TESSERA_CORE_ABI_MAX_PAYLOAD_BYTES, or reply == NULL with reply_capacity > 0;
 * -2 for a stale handle.
 */
int32_t tessera_program_status_monitor_feed(
    void * _Nullable handle,
    const uint8_t * _Nullable bytes,
    size_t count,
    uint8_t * _Nullable reply,
    size_t reply_capacity,
    uint64_t * _Nullable revision_out
);

/* Same two-pass JSON copy contract as tessera_tmux_runtime_copy_program_status. */
int32_t tessera_program_status_monitor_copy_snapshot(
    void * _Nullable handle,
    uint8_t * _Nullable output_bytes,
    size_t output_capacity
);

/* Acknowledge raw results through token through. 1 changed, 0 unchanged, -2 stale. */
int32_t tessera_program_status_monitor_acknowledge(
    void * _Nullable handle,
    uint64_t through
);

/* Mark all records historical on transport loss. Returns 0, -2 stale. */
int32_t tessera_program_status_monitor_note_transport_lost(void * _Nullable handle);

/*
 * Idempotent; later calls with the handle are rejected. When called outside a
 * callback, return is a callback-lifetime barrier. Re-entrant destruction from
 * a callback suppresses all later queued callbacks; the current callback must
 * return before its context is released.
 */
void tessera_tmux_runtime_destroy(void * _Nullable handle);

/*
 * Answer a platform whose held snapshot no longer matches a state event's
 * snapshotKey with a state event that carries the current snapshot under a
 * new epoch, so no later key can match one from before the request. The
 * answer has no render effects and no one-shot edges. Called from a callback
 * it is queued behind the callbacks already queued. Returns 0 accepted, -1
 * for bounded-delivery backpressure and -2 for a stale handle.
 */
int32_t tessera_tmux_runtime_resync_snapshot(void * _Nullable handle);

int32_t tessera_tmux_authority_visible_client_option(
    const uint8_t * _Nullable device_id_bytes,
    size_t device_id_count,
    uint8_t * _Nullable output_bytes,
    size_t output_capacity
);

int32_t tessera_tmux_authority_stamp_value(
    const uint8_t * _Nullable device_id_bytes,
    size_t device_id_count,
    const uint8_t * _Nullable display_name_bytes,
    size_t display_name_count,
    uint64_t generation,
    uint8_t * _Nullable output_bytes,
    size_t output_capacity
);

/*
 * Stateful, platform-neutral tmux authority session. The reduce
 * request and response share the exact maximum returned below. An accepted call
 * mutates exactly once and therefore requires a caller-provided output buffer
 * rather than the two-pass string-builder contract used by pure command
 * helpers. Callers must provide at least that many output bytes. A response
 * that exceeds the maximum is rejected before mutation. Only version 2 requests
 * are accepted; they drive the whole show-rule session. Other versions are
 * rejected without changing session state.
 */
void * _Nullable tessera_tmux_authority_lifecycle_create(void);
/* Explicit generation seed for deterministic host tests. Negative is rejected. */
void * _Nullable tessera_tmux_authority_lifecycle_create_seeded(int64_t initial_generation);

size_t tessera_tmux_authority_lifecycle_max_payload_bytes(void);

int32_t tessera_tmux_authority_lifecycle_reduce(
    void * _Nullable handle,
    const uint8_t * _Nullable request_bytes,
    size_t request_count,
    uint8_t * _Nullable output_bytes,
    size_t output_capacity
);

void tessera_tmux_authority_lifecycle_destroy(void * _Nullable handle);

/*
 * Stateful show/hide edge detector for one presentation slot, with the same
 * bounded JSON contract as the lifecycle reducer above: request and response
 * share the maximum returned below, callers provide at least that many output
 * bytes, and a response that exceeds it is rejected before mutation.
 */
void * _Nullable tessera_tmux_show_edges_create(void);

size_t tessera_tmux_show_edges_max_payload_bytes(void);

int32_t tessera_tmux_show_edges_reduce(
    void * _Nullable handle,
    const uint8_t * _Nullable request_bytes,
    size_t request_count,
    uint8_t * _Nullable output_bytes,
    size_t output_capacity
);

void tessera_tmux_show_edges_destroy(void * _Nullable handle);


/*
 * ---------------------------------------------------------------------------
 * Stateless shared-policy calls.
 *
 * Everything below is a pure function: no handle, no runtime, no callback. All
 * of it follows the same two contracts.
 *
 * The STRING/BYTES contract: a NULL or zero-capacity output buffer queries the
 * exact byte count, so a caller with no fixed ceiling can size its buffer
 * precisely; a buffer that is present but too small returns -1 rather than
 * truncating. The same call is answered identically in both phases.
 *
 * The JSON contract: structured arguments and results are canonical UTF-8 JSON
 * with sorted keys and unescaped slashes. An absent optional field is OMITTED
 * from a result rather than written as null; an argument may spell it either
 * way. Seconds are `double`; a platform carrying milliseconds converts at its
 * wrapper edge. UUIDs are uppercase canonical strings. Raw byte fields inside
 * JSON are base64.
 *
 * Unless a function says otherwise, -1 means "invalid arguments". A rejected
 * *input* — a malformed known_hosts line, a non-canonical QR payload, an
 * invalid forwarding rule — is a successful call whose JSON reports it, not
 * -1: the classification is the answer the caller needs.
 * ---------------------------------------------------------------------------
 */

/*
 * Terminal input. `modifier_bits` is this bit vector, deliberately NOT xterm's
 * `1 + shift + 2*alt + 4*ctrl` parameter (a wire encoding, with no bit for
 * Command). An undefined bit is rejected, so a newer platform flag cannot be
 * silently ignored by an older core.
 */
#define TESSERA_INPUT_MODIFIER_CONTROL 1
#define TESSERA_INPUT_MODIFIER_ALTERNATE 2
#define TESSERA_INPUT_MODIFIER_SHIFT 4
#define TESSERA_INPUT_MODIFIER_COMMAND 8

/*
 * Bytes for one accessory catalog entry, addressed by canonical catalog ID
 * (`pgup`, `ctrlC`, …) — never a legacy Android spelling and never a label.
 * Command is stripped before encoding because no terminal sequence carries it.
 * Returns -1 for an unknown ID or a modifier chip, which sends nothing.
 */
int32_t tessera_input_encode_accessory_key(
    const uint8_t * _Nullable id_bytes, size_t id_count,
    int32_t modifier_bits,
    int32_t application_cursor_mode,
    uint8_t * _Nullable output_bytes, size_t output_capacity
);

/*
 * Applies armed software modifiers to an ordinary typed key event: Ctrl+Space
 * to NUL, Ctrl+? to DEL, Alt to an ESC prefix, Shift to the US-layout shifted
 * byte. Multi-byte payloads — pastes and composed Unicode commits — pass
 * through unchanged.
 */
int32_t tessera_input_apply_software_modifiers(
    const uint8_t * _Nullable input_bytes, size_t input_count,
    int32_t modifier_bits,
    uint8_t * _Nullable output_bytes, size_t output_capacity
);

/* TerminalMouseEventABIRequest JSON in, raw xterm sequence out. An encoding of
 * "none" legitimately produces zero bytes: mouse reporting is off. */
int32_t tessera_input_encode_mouse_event(
    const uint8_t * _Nullable request_bytes, size_t request_count,
    uint8_t * _Nullable output_bytes, size_t output_capacity
);

/*
 * Where one scroll gesture goes — the rule every platform and transport share:
 * primary screen → the local scrollback; alternate screen with mouse reporting
 * → wheel reports; alternate screen without → arrow keys. The screen decides,
 * never mouse tracking alone: mosh never relays the alternate screen, so a
 * mosh+tmux visible client sits on the primary screen with the server's
 * `mouse on` in force, and a wheel report there enters copy-mode instead of
 * moving the overlay the side channel painted. `mouse_reporting_implies_alt_
 * screen` is the session's one input — 1 only while it has no local scrollback
 * to offer (plain mosh, mosh+tmux before its pane grid), so a remote program
 * that asked for the mouse still gets the wheel. Flags are 0/1; any other
 * value returns -1.
 */
#define TESSERA_INPUT_SCROLL_ROUTE_LOCAL_SCROLLBACK 0
#define TESSERA_INPUT_SCROLL_ROUTE_MOUSE_WHEEL 1
#define TESSERA_INPUT_SCROLL_ROUTE_ARROW_KEYS 2
int32_t tessera_input_scroll_route(
    int32_t buffer_is_alternate, int32_t mouse_reporting,
    int32_t mouse_reporting_implies_alt_screen
);

/* The canonical catalog: IDs, both default bar orders, the `custom:<uuid>`
 * prefix, and the legacy-Android migration table. A platform reads this rather
 * than keeping a second hand-written list. */
int32_t tessera_input_accessory_catalog(
    uint8_t * _Nullable output_bytes, size_t output_capacity
);

/*
 * Resolves a stored bar order into canonical slot IDs, migrating legacy
 * Android spellings in the same pass. Absent storage yields the platform
 * default; a stored EMPTY array is a deliberately empty row and stays empty.
 * Unknown IDs are dropped individually, so one bad entry does not cost the bar.
 */
int32_t tessera_input_accessory_bar_order(
    const uint8_t * _Nullable request_bytes, size_t request_count,
    uint8_t * _Nullable output_bytes, size_t output_capacity
);

/* Chord label rendering. Display only: nothing this returns reaches the wire. */
int32_t tessera_input_render_chord(
    const uint8_t * _Nullable request_bytes, size_t request_count,
    uint8_t * _Nullable output_bytes, size_t output_capacity
);

/*
 * One modifier-arming transition (tap / consume / cancel), state in and state
 * out, so a platform can drive it from an observable of its own without a
 * handle. One-shot consumes on the first key; sticky stays armed until cancel.
 */
int32_t tessera_input_modifier_arming_transition(
    const uint8_t * _Nullable request_bytes, size_t request_count,
    uint8_t * _Nullable output_bytes, size_t output_capacity
);

/*
 * Foreground session restore. The window's hard-won rules: a session that only
 * "looks connected" is not evidence of life until the alive floor has passed
 * (two SSH transports died 4 ms apart and the summary a millisecond later
 * still reported both as connected), and mosh reports reachability separately
 * from its `connected` state.
 */
int32_t tessera_session_restore_verdict(
    const uint8_t * _Nullable request_bytes, size_t request_count,
    uint8_t * _Nullable output_bytes, size_t output_capacity
);
int32_t tessera_session_restore_evaluate(
    const uint8_t * _Nullable request_bytes, size_t request_count,
    uint8_t * _Nullable output_bytes, size_t output_capacity
);

/* "settled" | "backstop" | "open". The backstop outranks settling, except
 * under an unanswered restore prompt: a sheet on screen is a verdict in
 * progress, and closing the window under it strips the snapshots it offers. */
int32_t tessera_session_restore_window_closure(
    int32_t remaining_cohort_count,
    double elapsed_since_window_opened_seconds,
    double max_window_seconds,
    int32_t has_unanswered_prompt,
    uint8_t * _Nullable output_bytes, size_t output_capacity
);

/* Seconds the window's clock advances on one pass. has_last_charge_at == 0
 * charges nothing. A single step is capped: a larger gap means the process was
 * suspended, not that time was spent waiting. */
double tessera_session_restore_charge_delta(
    double now_seconds,
    double last_charge_at_seconds,
    int32_t has_last_charge_at,
    int32_t is_prompting,
    double max_tick_seconds
);

/* "liveOnly" | "keepCohort" | "mergeWithStored". A write that mirrors the live
 * list deletes everything it cannot see — and the sessions worth restoring are
 * exactly the ones no longer there. */
int32_t tessera_session_restore_persist_mode(
    int32_t is_active,
    int32_t has_preserved_snapshots,
    int32_t is_window_open,
    int32_t has_cohort_entries,
    uint8_t * _Nullable output_bytes, size_t output_capacity
);

/* Restore-document validation: schema version, snapshot cap, uniqueness, and
 * the selection rule (a dangling selection is repaired, not rejected). */
int32_t tessera_session_restore_document_rules(
    const uint8_t * _Nullable request_bytes, size_t request_count,
    uint8_t * _Nullable output_bytes, size_t output_capacity
);

/* What a cold start should do: {"action":"wait"|"skip"|"restore"|"offer", …}.
 * "hosts loaded" and "the host list is empty" are separate facts here, and a
 * caller that treats `wait` as `skip` spends its one cold-start pass on a
 * question it could not yet answer — which is how a launch racing the host
 * store cleared the document and restored nothing. */
int32_t tessera_session_restore_startup_action(
    const uint8_t * _Nullable request_bytes, size_t request_count,
    uint8_t * _Nullable output_bytes, size_t output_capacity
);

/* "ask" | "always" | "never", coerced for the shell being presented: compact
 * navigation has no multi-session chooser, so `ask` behaves as `always` there
 * without disturbing the stored cross-device preference. */
int32_t tessera_session_restore_effective_policy(
    const uint8_t * _Nullable stored_policy_bytes, size_t stored_policy_count,
    int32_t uses_compact_shell,
    uint8_t * _Nullable output_bytes, size_t output_capacity
);

/* What one snapshot write contains and what it selects, given the mode
 * tessera_session_restore_persist_mode chose. Each entry names the collection
 * its record comes from; the core never sees the records themselves. */
int32_t tessera_session_restore_persist_plan(
    const uint8_t * _Nullable request_bytes, size_t request_count,
    uint8_t * _Nullable output_bytes, size_t output_capacity
);

/*
 * Terminal resize coalescing, state in and state out. Presenting a modal makes
 * a terminal shrink and come back — 976 -> 944 -> 976pt in 28 ms — which cost
 * two client resizes, two `refresh-client -C` round trips, two grid-authority
 * generations, and two full repaints for a size that never changed.
 *
 * The first size SENDs; a platform that schedules it instead has drifted.
 */
int32_t tessera_session_resize_note(
    const uint8_t * _Nullable request_bytes, size_t request_count,
    uint8_t * _Nullable output_bytes, size_t output_capacity
);
int32_t tessera_session_resize_settle(
    const uint8_t * _Nullable request_bytes, size_t request_count,
    uint8_t * _Nullable output_bytes, size_t output_capacity
);
double tessera_session_resize_settle_seconds(void);

/*
 * End-of-session classification. A socket at EOF proves only that the socket
 * is gone; a remote EXIT STATUS is authenticated evidence that the shell
 * itself finished, and only that retires a restore record. has_exit_status ==
 * 0 is EOF-without-status. Returns 1, 0, or -1.
 */
int32_t tessera_session_remote_process_ended(int32_t exit_status, int32_t has_exit_status);
int32_t tessera_session_retains_restore_record(int32_t exit_status, int32_t has_exit_status);

/* Native mosh's two end events, which one integer cannot tell apart: a
 * transport stop is recoverable (the far-side mosh-server is still there to
 * re-attach), a shutdown completion is a genuine remote exit. */
int32_t tessera_session_mosh_remote_process_ended(int32_t is_shutdown_completion);

/*
 * Reconnect policy. In order: an explicit disconnect never retries; a
 * transport that never connected never retries unless a recovery is already in
 * flight; `transport_disconnected` always retries; otherwise the failure
 * detail must name one of the eleven shared transient markers. Returns 1, 0,
 * or -1.
 */
int32_t tessera_session_should_retry(
    const uint8_t * _Nullable request_bytes, size_t request_count
);

/* One-based attempt. Past the ladder's end the delay holds at its last rung
 * rather than growing without bound. */
double tessera_session_retry_delay_seconds(int32_t attempt);
int32_t tessera_session_retry_max_attempts(void);

/*
 * Mosh bootstrap grammar. The parse is strict — a literal "MOSH CONNECT "
 * prefix and exactly four fields — because every extra accepted shape widens
 * what a garbled or hostile transcript can talk the client into dialling.
 * Nothing here ever returns a transcript: a malformed line may still carry
 * live key material.
 */
int32_t tessera_mosh_parse_connect_response(
    const uint8_t * _Nullable stdout_bytes, size_t stdout_count,
    const uint8_t * _Nullable stderr_bytes, size_t stderr_count,
    uint8_t * _Nullable output_bytes, size_t output_capacity
);

/* `mosh-server new` with the optional trailing `-- <argv>`. A zero-length
 * argument means no launch command. */
int32_t tessera_mosh_server_new_command(
    const uint8_t * _Nullable launch_command_bytes, size_t launch_command_count,
    uint8_t * _Nullable output_bytes, size_t output_capacity
);

/*
 * PID-reuse-fenced termination script. The PID comes from mosh-server's
 * detached banner and may be arbitrarily stale, so the script re-checks
 * `ps -o comm=` for *mosh-server* before signalling, treats an already-exited
 * server as success, and never escalates past TERM. Script exit codes: 0 gone,
 * 64 the PID is alive but is not a mosh-server.
 */
int32_t tessera_mosh_server_termination_script(
    int32_t pid,
    uint8_t * _Nullable output_bytes, size_t output_capacity
);

/**
 * Read-only liveness probe for a session's detached mosh-server. Prints
 * TESSERA_MOSH_SERVER=alive, =gone or =unknown and never signals the
 * process: a PID that cannot be signalled or now runs something else is
 * gone, a host whose ps cannot name it is unknown. Returns the byte count
 * under the string contract, or -1 for a non-positive PID.
 */
int32_t tessera_mosh_server_liveness_script(
    int32_t pid,
    uint8_t * _Nullable output_bytes, size_t output_capacity
);

/**
 * Liveness probe output -> 1 alive, 2 gone, 0 unknown (no exact marker line;
 * never evidence of loss), -1 invalid arguments.
 */
int32_t tessera_mosh_server_liveness_verdict(
    const uint8_t * _Nullable output_input_bytes, size_t output_input_count
);

/** Foreground unreachability before the first liveness probe, in ms. */
uint64_t tessera_mosh_server_liveness_grace_milliseconds(void);

/**
 * When the next liveness probe runs, in ms: -1 when none follows (server gone,
 * or invalid arguments), -2 when it waits for a wake only (network path
 * change, return to the foreground, unlock), else the delay. outcome: 0
 * unknown, 1 alive, 2 gone, 3 host unreachable (SSH failed).
 * consecutive_host_failures counts the current run of host-unreachable
 * outcomes, this one included. asked_owner is nonzero when this probe put an
 * owner-authentication prompt in front of the user.
 */
int64_t tessera_mosh_server_liveness_next_probe_milliseconds(
    int32_t outcome,
    int32_t consecutive_host_failures,
    int32_t asked_owner
);

/* Both markers must be present: an ordinary transcript mentioning mosh-server
 * is not a diagnosis, and neither is a bare "command not found". 1, 0, or -1. */
int32_t tessera_mosh_transcript_suggests_missing_server(
    const uint8_t * _Nullable stdout_bytes, size_t stdout_count,
    const uint8_t * _Nullable stderr_bytes, size_t stderr_count
);

/* The PID from the detached banner, or 0 when it is absent or unparseable — a
 * caller must then treat the server as un-signallable. -1 invalid arguments. */
int32_t tessera_mosh_detached_server_pid(
    const uint8_t * _Nullable output_input_bytes, size_t output_input_count
);

int32_t tessera_mosh_normalized_connect_key(
    const uint8_t * _Nullable key_bytes, size_t key_count,
    uint8_t * _Nullable output_bytes, size_t output_capacity
);

/* Byte counts and whether the credential marker was present — never the
 * transcript. Safe to log in full. */
int32_t tessera_mosh_bootstrap_transcript_summary(
    const uint8_t * _Nullable stdout_bytes, size_t stdout_count,
    const uint8_t * _Nullable stderr_bytes, size_t stderr_count,
    uint8_t * _Nullable output_bytes, size_t output_capacity
);

/*
 * The app-wide diagnostic redaction authority. `patterns_bytes` is an optional
 * JSON array of pattern names selecting a subset; omit it for the full list.
 * The APPLIED order is always the core's, never the caller's: the MOSH CONNECT
 * line scrub runs before the bare-key scrub so a well-formed line keeps its
 * validated port for diagnosis, and the key scrub then catches split or
 * exception-bridged key material the line scrub could not see.
 */
int32_t tessera_redact_sensitive(
    const uint8_t * _Nullable text_bytes, size_t text_count,
    const uint8_t * _Nullable patterns_bytes, size_t patterns_count,
    uint8_t * _Nullable output_bytes, size_t output_capacity
);

/*
 * Remote-OS detection. Run the probe NON-interactively (an SSH ExecRequest,
 * i.e. `$SHELL -c`): a common "auto tmux" dotfile would hijack an interactive
 * probe shell, and with no PTY tmux exits before `uname` ever runs. The
 * command's trailing `exit 0` is equally load-bearing — a missing release file
 * makes the last `cat` exit non-zero, which a client turns into a command
 * failure and discards the accumulated stdout with.
 */
int32_t tessera_os_detection_probe_command(
    uint8_t * _Nullable output_bytes, size_t output_capacity
);
int32_t tessera_os_detection_parse(
    const uint8_t * _Nullable probe_output_bytes, size_t probe_output_count,
    uint8_t * _Nullable output_bytes, size_t output_capacity
);
/* -1 when the output identifies no family, which is the ordinary "no badge
 * update" outcome rather than something to report to the user. */
int32_t tessera_os_detection_parse_family(
    const uint8_t * _Nullable probe_output_bytes, size_t probe_output_count,
    uint8_t * _Nullable output_bytes, size_t output_capacity
);

/*
 * Host-key trust. The verdict grows a fourth case: revertedToPrevious, when
 * the presented key is the one this endpoint was pinned to before the last
 * rotation. It still blocks, but it is a materially different story to tell
 * the user than an unrecognised key, and collapsing the two throws away the
 * evidence separating a botched server rollback from an attacker. Omit
 * `previous` and the result is identical to the pre-rotation-history behavior.
 */
int32_t tessera_trust_check(
    const uint8_t * _Nullable request_bytes, size_t request_count,
    uint8_t * _Nullable output_bytes, size_t output_capacity
);

/* Trim, strip one trailing dot and one matched bracket pair, lowercase, reject
 * empty/whitespace hosts, require port 1..65535. Only ONE trailing dot: a name
 * with two roots is malformed input, and repairing it would collapse two
 * spellings onto one pin. */
int32_t tessera_trust_normalize_endpoint(
    const uint8_t * _Nullable host_bytes, size_t host_count,
    int32_t port,
    uint8_t * _Nullable output_bytes, size_t output_capacity
);

/*
 * "SHA256:" + base64(SHA-256(blob)). padded == 0 is the canonical
 * cross-platform form. padded == 1 exists for one caller: iOS has persisted
 * padded fingerprints since its store shipped and compares stored against
 * freshly computed, so switching it silently would report a key MISMATCH on
 * every already-pinned host.
 */
int32_t tessera_trust_sha256_fingerprint(
    const uint8_t * _Nullable blob_bytes, size_t blob_count,
    int32_t padded,
    uint8_t * _Nullable output_bytes, size_t output_capacity
);

/*
 * Builds — and only builds — the known_hosts import plan. Nothing here touches
 * a pin store: a file with one malformed line still yields a full plan
 * describing the good lines and naming the bad one. A parser that mutated as
 * it went is what left a half-imported store behind on the first bad line.
 *
 * Apply-time must re-check each candidate's expected_prior_fingerprint: a
 * reviewed plan is a proposal about a PAST state, and the store can have moved
 * underneath it.
 *
 * The request JSON carries "endpointNormalization": "verbatim" (the default
 * when absent) or "normalized". It selects the ONE key space the plan is
 * computed in — candidate keys, the existingFingerprints lookup, ambiguity
 * detection and duplicate warnings all use it — and it must match how the
 * calling store keys itself, with existingFingerprints supplied in that same
 * space. Android's Room table is keyed normalized (trimmed, one trailing dot
 * and one bracket pair stripped, lowercased) and passes "normalized"; a store
 * keyed by the address as the user typed it passes "verbatim". Mix the two and
 * an already-pinned host is planned as an add the store then refuses, and two
 * spellings of one host stop looking like one endpoint.
 */
int32_t tessera_trust_known_hosts_import_plan(
    const uint8_t * _Nullable request_bytes, size_t request_count,
    uint8_t * _Nullable output_bytes, size_t output_capacity
);

/* Renders stored pins as known_hosts text, lines sorted so the output is
 * stable and diffable. A pin at the default port writes a bare host, because
 * that is what ssh(1) writes. An empty record list yields 0 bytes. */
int32_t tessera_trust_known_hosts_export(
    const uint8_t * _Nullable records_bytes, size_t records_count,
    uint8_t * _Nullable output_bytes, size_t output_capacity
);

/*
 * Port forwarding. Local and dynamic listeners are loopback-only; only a
 * remote bind may use port 0 (the server allocates it); a dynamic rule must
 * have no target; and a bind collision is checked only among ENABLED
 * non-remote rules — a disabled rule no longer reserves its port.
 */
int32_t tessera_forwarding_validate_rule(
    const uint8_t * _Nullable request_bytes, size_t request_count,
    uint8_t * _Nullable output_bytes, size_t output_capacity
);

/* transport: 0 = ssh, 1 = mosh (which can forward only while its
 * authenticated SSH side channel exists). The unavailable reason is an enum,
 * not prose: the platforms localize. */
int32_t tessera_forwarding_capabilities(
    int32_t transport,
    int32_t ssh_side_channel_available,
    uint8_t * _Nullable output_bytes, size_t output_capacity
);

/* Whether swapping one rule for another must tear the listener down. Label,
 * enabled, and autoStart changes never disturb live traffic. 1, 0, or -1. */
int32_t tessera_forwarding_requires_restart(
    const uint8_t * _Nullable request_bytes, size_t request_count
);

/* The subset the cross-device bootstrap manifest can carry: loopback local
 * forwards with a target. Dynamic and remote rules are dropped rather than
 * flattened into a wrong local rule. */
int32_t tessera_forwarding_portable_local_subset(
    const uint8_t * _Nullable rules_bytes, size_t rules_count,
    uint8_t * _Nullable output_bytes, size_t output_capacity
);

/* Whether a rule can be opened in the in-app browser, and at what URL.
 * Addressability only — a local loopback bind whose service port is not a
 * known non-web protocol; whether the listener is up right now stays with the
 * caller, because live forwarder state never crosses this ABI. */
int32_t tessera_forwarding_web_target(
    const uint8_t * _Nullable rule_bytes, size_t rule_count,
    uint8_t * _Nullable output_bytes, size_t output_capacity
);

/*
 * tmux name and target validation, so no platform keeps its own charset
 * literal — three copies of that literal on Android had already drifted apart.
 * The session-name grammar is deliberately conservative (ASCII alphanumerics
 * plus - _ .) because these names are interpolated into fixed remote commands
 * without shell quoting.
 *
 * Session name: 0 ok, 1 empty, 2 too long, 3 unsafe character, and -1 only
 * for a genuinely malformed argument (negative count, or bytes that are not
 * UTF-8). A name of any length past the ceiling is answered as too long, not
 * refused, so a wrapper that treats -1 as a programming error cannot be
 * crashed by a pathologically long paste. Target id: kind 0 = session ($123),
 * 1 = window (@7), 2 = pane (%9); returns 1 valid, 0 invalid, -1 invalid
 * arguments.
 */
int32_t tessera_tmux_session_name_validate(
    const uint8_t * _Nullable name_bytes, size_t name_count
);
int32_t tessera_tmux_target_id_validate(
    const uint8_t * _Nullable value_bytes, size_t value_count,
    int32_t kind
);

/* The one git-branch grammar behind agent launches: ASCII-only and bounded in
 * UTF-8 bytes. A platform-side isLetterOrDigit-style Unicode acceptance has
 * already diverged from it once. 1 valid, 0 invalid, -1 invalid arguments. */
int32_t tessera_agent_validate_branch(
    const uint8_t * _Nullable branch_bytes, size_t branch_count
);

/*
 * Pairing QR text codec. The grammar is a small closed one, parsed directly
 * rather than through URL normalization: no percent escapes, no alternate
 * query layouts, no optional URL components. Decoding also enforces a strict
 * canonical round trip — a re-spelled offer is rejected as nonCanonical rather
 * than normalized — and returns the CANONICAL offer bytes, which is what a
 * caller forwards to the pairing runtime.
 */
int32_t tessera_pairing_qr_decode_offer(
    const uint8_t * _Nullable text_bytes, size_t text_count,
    uint8_t * _Nullable output_bytes, size_t output_capacity
);
int32_t tessera_pairing_qr_encode_offer(
    const uint8_t * _Nullable offer_bytes, size_t offer_count,
    uint8_t * _Nullable output_bytes, size_t output_capacity
);

/*
 * Re-encodes a cross-device command into the exact bytes
 * tessera_cross_device_runtime_send will accept. That entry point applies a
 * strict byte-equality gate so an adapter cannot smuggle ignored fields or
 * alternate JSON spellings past the boundary — which also means a non-Swift
 * builder would otherwise have to reproduce Swift's encoder exactly. Submit
 * what you built here, and send what this returns.
 */
int32_t tessera_cross_device_canonicalize_command(
    const uint8_t * _Nullable command_bytes, size_t command_count,
    uint8_t * _Nullable output_bytes, size_t output_capacity
);

/* Pure setup presentation v1 JSON projection. No side effects or authority.
 * Standard bytes-to-text contract; -1 for invalid/oversized input. */
int32_t tessera_setup_flow_project_v1(
    const uint8_t * _Nullable input_bytes, size_t input_count,
    uint8_t * _Nullable output_bytes, size_t output_capacity
);

/*
 * Continuation route identity: `connectionKey#fingerprint` for a route, so a
 * recovery store can recognise it across process death without persisting a
 * second plaintext copy of the route. The canonical rendering length-prefixes
 * each field in UTF-8 BYTES; the first Android implementation counted UTF-16
 * code units, and byte counting is the deliberate portable choice.
 *
 * The descriptor form must agree byte for byte with the endpoint form for the
 * same route — that agreement is the point of routing both through one
 * implementation.
 */
int32_t tessera_continuation_route_identity(
    const uint8_t * _Nullable request_bytes, size_t request_count,
    uint8_t * _Nullable output_bytes, size_t output_capacity
);
int32_t tessera_continuation_descriptor_route_identity(
    const uint8_t * _Nullable descriptor_bytes, size_t descriptor_count,
    uint8_t * _Nullable output_bytes, size_t output_capacity
);


/*
 * Cross-device Pairing v1 uses a separate handle namespace from the terminal
 * core ABI. Commands and callbacks are bounded canonical JSON envelopes; the
 * runtime itself owns the pairing/transaction ordering.  In particular, this
 * ABI deliberately does not accept owner-authorization capabilities.
 */
#define TESSERA_CROSS_DEVICE_ABI_VERSION 1u
#define TESSERA_CROSS_DEVICE_ABI_MAX_PAYLOAD_BYTES 1048576u
#define TESSERA_CROSS_DEVICE_ABI_MAX_SOCKET_CHUNK_BYTES 786000u

typedef void (*tessera_cross_device_event_callback)(
    const uint8_t * _Nullable bytes,
    size_t count,
    void * _Nullable context
);

typedef void *tessera_cross_device_runtime_t;

uint32_t tessera_cross_device_abi_version(void);
size_t tessera_cross_device_abi_max_payload_bytes(void);

tessera_cross_device_runtime_t _Nonnull tessera_cross_device_runtime_create(
    tessera_cross_device_event_callback _Nonnull callback,
    void * _Nullable context
);

/* Returns 0 when accepted, -1 for invalid arguments, and -2 for a stale handle. */
int32_t tessera_cross_device_runtime_send(
    tessera_cross_device_runtime_t _Nullable runtime,
    const uint8_t * _Nullable bytes,
    size_t count
);

/*
 * Idempotent with the same completion-barrier and reentrant-callback rules as
 * tessera_core_runtime_destroy.  The callback bytes are borrowed only for the
 * callback duration, callbacks are serialized, and a destroyed handle returns
 * -2 from send.
 */
void tessera_cross_device_runtime_destroy(
    tessera_cross_device_runtime_t _Nullable runtime
);

uint32_t tessera_core_abi_version(void);
size_t tessera_core_abi_max_payload_bytes(void);

/* S5′: a JSON object from each backend operation kind code to its
 * grid-authority gate ("typing", "mutation" or "ungated"). */
int32_t tessera_session_authority_gates(
    uint8_t * _Nullable output_bytes, size_t output_capacity);

tessera_core_runtime_t _Nonnull tessera_core_runtime_create(
    tessera_core_event_callback _Nonnull callback,
    void * _Nullable context
);

/* Returns 0 when accepted, -1 for invalid arguments, and -2 for a stale handle. */
int32_t tessera_core_runtime_send(
    tessera_core_runtime_t _Nullable runtime,
    const uint8_t * _Nullable bytes,
    size_t count
);

/* Delivers a versioned platform-backend event to the shared session engine. */
int32_t tessera_core_runtime_emit(
    tessera_core_runtime_t _Nullable runtime,
    const uint8_t * _Nullable bytes,
    size_t count
);

/*
 * Idempotent. Calls made with a destroyed handle fail with -2.
 *
 * For ordinary calls this is a completion barrier: all callbacks finish before
 * it returns, after which the caller may release `context`. If called from the
 * runtime's own callback, it returns without deadlocking and suppresses every
 * later callback; the current callback remains responsible for its own stack.
 */
void tessera_core_runtime_destroy(tessera_core_runtime_t _Nullable runtime);

/* Initial detail read budget and demand gates, shared across native clients. */
int32_t tessera_agent_ingestion_read_status(
    const uint8_t * _Nullable request_bytes, size_t request_count,
    uint8_t * _Nullable output_bytes, size_t output_capacity
);
int32_t tessera_agent_initial_load_page_count(void);
uint64_t tessera_agent_process_proof_timeout_milliseconds(void);
uint64_t tessera_agent_read_retry_delay_milliseconds(int32_t consecutive_failures);
int32_t tessera_agent_initial_load_should_prefetch(int32_t completed_pages, uint32_t flags);

#ifdef __cplusplus
}
#endif

#endif /* TESSERA_CORE_ABI_H */
