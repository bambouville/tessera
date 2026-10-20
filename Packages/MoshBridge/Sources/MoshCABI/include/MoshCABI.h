#ifndef TESSERA_MOSH_C_ABI_H
#define TESSERA_MOSH_C_ABI_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define TESSERA_MOSH_C_ABI_VERSION 1u
#define TESSERA_MOSH_C_ABI_MAX_HOST_BYTES 1024u
#define TESSERA_MOSH_C_ABI_MAX_KEY_BYTES 128u
#define TESSERA_MOSH_C_ABI_MAX_INPUT_BATCH_BYTES 65536u
#define TESSERA_MOSH_C_ABI_MAX_OUTPUT_BATCH_BYTES 65536u
#define TESSERA_MOSH_C_ABI_MAX_ERROR_BYTES 4096u
#define TESSERA_MOSH_C_ABI_NO_DEADLINE UINT64_MAX

typedef struct tessera_mosh_client tessera_mosh_client;

typedef enum tessera_mosh_result {
    TESSERA_MOSH_OK = 0,
    TESSERA_MOSH_INVALID_ARGUMENT = 1,
    TESSERA_MOSH_INVALID_STATE = 2,
    TESSERA_MOSH_FAILURE = 3,
    TESSERA_MOSH_BUFFER_TOO_SMALL = 4
} tessera_mosh_result;

/// Output is delivered synchronously on the thread invoking start/tick/repaint.
/// `length` is always 1...TESSERA_MOSH_C_ABI_MAX_OUTPUT_BATCH_BYTES.
///
/// Calls for one client may originate on different threads; the ABI serializes
/// them. A callback must not reenter that same client except to destroy it.
/// Other same-client reentrant calls fail with TESSERA_MOSH_INVALID_STATE.
/// Callback-time destruction is deferred until the invoking call returns.
typedef void (*tessera_mosh_output_callback)(
    const uint8_t *bytes,
    size_t length,
    void *context);

typedef struct tessera_mosh_client_config_v1 {
    uint32_t abi_version;
    uint32_t struct_size;
    const char *host;
    uint16_t port;
    uint16_t reserved;
    const char *base64_key;
    tessera_mosh_output_callback output_callback;
    void *output_context;
} tessera_mosh_client_config_v1;

uint32_t tessera_mosh_abi_version(void);
size_t tessera_mosh_max_output_batch_bytes(void);

tessera_mosh_result tessera_mosh_client_create(
    const tessera_mosh_client_config_v1 *config,
    tessera_mosh_client **out_client);

/// Invalidates the public handle immediately and waits for any call already in
/// progress, except when invoked from that handle's output callback. Repeated
/// destruction is a no-op, and a destroyed handle's identity is never assigned
/// to a later client. The callback context must remain valid until this function
/// returns, or until the enclosing ABI call returns for callback-time destruction.
void tessera_mosh_client_destroy(tessera_mosh_client *client);

tessera_mosh_result tessera_mosh_client_start(tessera_mosh_client *client);
tessera_mosh_result tessera_mosh_client_tick(
    tessera_mosh_client *client,
    uint64_t *out_wait_milliseconds);
tessera_mosh_result tessera_mosh_client_inject_bytes(
    tessera_mosh_client *client,
    const uint8_t *bytes,
    size_t length);
tessera_mosh_result tessera_mosh_client_resize(
    tessera_mosh_client *client,
    int32_t columns,
    int32_t rows);
tessera_mosh_result tessera_mosh_client_force_full_repaint(
    tessera_mosh_client *client);
/// Queue this device's current resize after the last sent SSP input state.
/// Zero means the client cannot start a fence in its current lifecycle state.
tessera_mosh_result tessera_mosh_client_begin_full_repaint_fence(
    tessera_mosh_client *client,
    uint64_t *out_token);
/// A fresh input state has been sent, the server's post-input echo ack
/// covers it, and the received framebuffer matches this device's current grid.
/// This query never ticks the client or emits terminal output.
tessera_mosh_result tessera_mosh_client_is_full_repaint_fence_ready(
    const tessera_mosh_client *client,
    uint64_t token,
    int32_t *out_ready);
tessera_mosh_result tessera_mosh_client_shutdown(tessera_mosh_client *client);

tessera_mosh_result tessera_mosh_client_socket_fd(
    const tessera_mosh_client *client,
    int32_t *out_fd);
tessera_mosh_result tessera_mosh_client_copy_socket_fds(
    const tessera_mosh_client *client,
    int32_t *buffer,
    size_t capacity,
    size_t *out_count);
tessera_mosh_result tessera_mosh_client_is_connected(
    const tessera_mosh_client *client,
    int32_t *out_value);
tessera_mosh_result tessera_mosh_client_is_transport_reachable(
    const tessera_mosh_client *client,
    int32_t *out_value);
tessera_mosh_result tessera_mosh_client_server_contact_age_ms(
    const tessera_mosh_client *client,
    uint64_t *out_value);
tessera_mosh_result tessera_mosh_client_reply_age_ms(
    const tessera_mosh_client *client,
    uint64_t *out_value);
tessera_mosh_result tessera_mosh_client_is_shutdown_complete(
    const tessera_mosh_client *client,
    int32_t *out_value);
tessera_mosh_result tessera_mosh_client_application_mode_cursor_keys(
    const tessera_mosh_client *client,
    int32_t *out_value);
tessera_mosh_result tessera_mosh_client_retains_bootstrap_key_material(
    const tessera_mosh_client *client,
    int32_t *out_value);

/// Copies a NUL-terminated, non-secret diagnostic from the most recent failed
/// call. `out_required_size` includes the NUL. Pass NULL/0 to size the buffer.
tessera_mosh_result tessera_mosh_client_copy_last_error(
    const tessera_mosh_client *client,
    char *buffer,
    size_t capacity,
    size_t *out_required_size);

#ifdef __cplusplus
}
#endif

#endif
