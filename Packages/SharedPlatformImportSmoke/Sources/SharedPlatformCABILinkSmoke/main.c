#include "TesseraCoreABI.h"

#include <stddef.h>
#include <stdint.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

enum {
    RAW_TERMINAL_BATCH_BYTES = 720 * 1024,
    MAX_JSON_ENVELOPE_OVERHEAD_BYTES = 256,
};

typedef struct callback_context {
    const uint8_t *expected_terminal_payload;
    size_t expected_terminal_payload_count;
    size_t callback_count;
    size_t terminal_callback_count;
    size_t terminal_callback_bytes;
    int expected_step;
    atomic_flag callback_active;
    atomic_int error;
} callback_context;

static const uint8_t *find_bytes(
    const uint8_t *bytes,
    size_t count,
    const char *literal) {
    const size_t literal_count = strlen(literal);
    if (literal_count == 0 || literal_count > count) return NULL;
    for (size_t index = 0; index <= count - literal_count; ++index) {
        if (memcmp(bytes + index, literal, literal_count) == 0) {
            return bytes + index;
        }
    }
    return NULL;
}

static int contains_literal(
    const uint8_t *bytes,
    size_t count,
    const char *literal) {
    return find_bytes(bytes, count, literal) != NULL;
}

static int terminal_payload_matches(
    const callback_context *capture,
    const uint8_t *bytes,
    size_t count) {
    static const char marker[] = "\"payload\":\"";
    const uint8_t *payload = find_bytes(bytes, count, marker);
    if (payload == NULL) return 0;
    payload += sizeof(marker) - 1;
    const size_t prefix_count = (size_t)(payload - bytes);
    if (capture->expected_terminal_payload_count > count - prefix_count) return 0;
    if (memcmp(
            payload,
            capture->expected_terminal_payload,
            capture->expected_terminal_payload_count) != 0) return 0;
    const size_t suffix_offset = prefix_count + capture->expected_terminal_payload_count;
    return suffix_offset < count && bytes[suffix_offset] == '"';
}

static void encode_base64_triplets(
    const uint8_t *input,
    size_t input_count,
    uint8_t *output) {
    static const uint8_t alphabet[] =
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    size_t output_index = 0;
    for (size_t input_index = 0; input_index < input_count; input_index += 3) {
        const uint32_t value = ((uint32_t)input[input_index] << 16)
            | ((uint32_t)input[input_index + 1] << 8)
            | (uint32_t)input[input_index + 2];
        output[output_index++] = alphabet[(value >> 18) & 0x3fu];
        output[output_index++] = alphabet[(value >> 12) & 0x3fu];
        output[output_index++] = alphabet[(value >> 6) & 0x3fu];
        output[output_index++] = alphabet[value & 0x3fu];
    }
}

static void receive_event(
    const uint8_t *bytes,
    size_t count,
    void *context) {
    callback_context *capture = (callback_context *)context;
    if (capture == NULL) return;
    if (atomic_flag_test_and_set_explicit(
            &capture->callback_active,
            memory_order_acquire)) {
        atomic_store_explicit(&capture->error, 90, memory_order_release);
        return;
    }

    if (bytes == NULL || count == 0) {
        atomic_store_explicit(&capture->error, 91, memory_order_release);
        goto done;
    }

    capture->callback_count += 1;
    switch (capture->expected_step) {
        case 0:
            if (!contains_literal(bytes, count, "\"kind\":\"stateChanged\"")
                || !contains_literal(bytes, count, "\"code\":\"connecting\"")) {
                atomic_store_explicit(&capture->error, 10, memory_order_release);
                goto done;
            }
            break;
        case 1:
            if (!contains_literal(bytes, count, "\"kind\":\"backendCommandRequested\"")
                || !contains_literal(bytes, count, "\"code\":\"connect\"")) {
                atomic_store_explicit(&capture->error, 11, memory_order_release);
                goto done;
            }
            break;
        case 2:
            if (!contains_literal(bytes, count, "\"kind\":\"stateChanged\"")
                || !contains_literal(bytes, count, "\"code\":\"connected\"")) {
                atomic_store_explicit(&capture->error, 12, memory_order_release);
                goto done;
            }
            break;
        case 3:
            if (!contains_literal(bytes, count, "\"kind\":\"terminalBytes\"")
                || !terminal_payload_matches(capture, bytes, count)) {
                atomic_store_explicit(&capture->error, 13, memory_order_release);
                goto done;
            }
            capture->terminal_callback_count += 1;
            capture->terminal_callback_bytes = count;
            if (count < capture->expected_terminal_payload_count
                || count - capture->expected_terminal_payload_count
                    > MAX_JSON_ENVELOPE_OVERHEAD_BYTES) {
                atomic_store_explicit(&capture->error, 14, memory_order_release);
                goto done;
            }
            break;
        case 4:
            if (!contains_literal(bytes, count, "\"kind\":\"backendCommandRequested\"")
                || !contains_literal(bytes, count, "\"code\":\"destroy\"")) {
                atomic_store_explicit(&capture->error, 15, memory_order_release);
                goto done;
            }
            break;
        case 5:
            if (!contains_literal(bytes, count, "\"kind\":\"destroyed\"")) {
                atomic_store_explicit(&capture->error, 16, memory_order_release);
                goto done;
            }
            break;
        default:
            atomic_store_explicit(&capture->error, 17, memory_order_release);
            goto done;
    }
    capture->expected_step += 1;

done:
    atomic_flag_clear_explicit(&capture->callback_active, memory_order_release);
}

static void discard_cross_device_event(
    const uint8_t *bytes,
    size_t count,
    void *context) {
    (void)bytes;
    (void)count;
    (void)context;
}

static void discard_tmux_event(
    const uint8_t *bytes,
    size_t count,
    void *context) {
    (void)bytes;
    (void)count;
    (void)context;
}

int main(void) {
    if (tessera_core_abi_version() != TESSERA_CORE_ABI_VERSION) return 1;
    if (tessera_core_abi_max_payload_bytes()
        != TESSERA_CORE_ABI_MAX_PAYLOAD_BYTES) return 2;
    if (tessera_cross_device_abi_version()
        != TESSERA_CROSS_DEVICE_ABI_VERSION) return 18;
    if (tessera_cross_device_abi_max_payload_bytes()
        != TESSERA_CROSS_DEVICE_ABI_MAX_PAYLOAD_BYTES) return 19;
    tessera_cross_device_runtime_t cross_device =
        tessera_cross_device_runtime_create(discard_cross_device_event, NULL);
    if (cross_device == NULL) return 20;
    if (tessera_cross_device_runtime_send(cross_device, NULL, 0) != -1) return 21;
    tessera_cross_device_runtime_destroy(cross_device);

    // The stateful tmux render ABI has a separate, byte-ref copy-out path.
    // Call every entry point here so the native C link smoke proves both the
    // declarations and dynamic exports stay aligned on every target.
    void *tmux = tessera_tmux_runtime_create(discard_tmux_event, NULL);
    if (tmux == NULL) return 22;
    if (tessera_tmux_runtime_send_command(tmux, NULL, 0) != -1) return 23;
    if (tessera_tmux_runtime_queue_command(tmux, NULL, 0) != -1) return 23;
    if (tessera_tmux_runtime_submit_fact(tmux, NULL, 0) != -1) return 24;
    if (tessera_tmux_runtime_take_render_bytes(tmux, 1, NULL, 0) != -1) return 25;
    tessera_tmux_runtime_destroy(tmux);

    // 720 KiB is the largest round-number raw terminal batch whose base64 JSON
    // envelope stays comfortably below the public 1 MiB ABI payload ceiling.
    // It exercises 960 KiB of byte payload through one emit call and must
    // produce exactly one terminal callback, not per-byte/per-cell callbacks.
    if (RAW_TERMINAL_BATCH_BYTES % 3 != 0) return 3;
    static const uint8_t terminal_pattern[] =
        "\x1b[38;5;39muser@host:~$ printf 'shared-core batch'\r\n"
        "shared-core batch \xe2\x9c\x93\r\n\x1b[0m";
    uint8_t *terminal_bytes = (uint8_t *)malloc(RAW_TERMINAL_BATCH_BYTES);
    if (terminal_bytes == NULL) return 4;
    for (size_t index = 0; index < RAW_TERMINAL_BATCH_BYTES; ++index) {
        terminal_bytes[index] = terminal_pattern[index % (sizeof(terminal_pattern) - 1)];
    }

    const size_t terminal_payload_count = (RAW_TERMINAL_BATCH_BYTES / 3) * 4;
    uint8_t *terminal_payload = (uint8_t *)malloc(terminal_payload_count);
    if (terminal_payload == NULL) {
        free(terminal_bytes);
        return 5;
    }
    encode_base64_triplets(
        terminal_bytes,
        RAW_TERMINAL_BATCH_BYTES,
        terminal_payload);
    free(terminal_bytes);

    static const char terminal_prefix[] =
        "{\"generation\":1,\"kind\":\"terminalBytes\",\"payload\":\"";
    static const char terminal_suffix[] = "\",\"version\":1}";
    const size_t terminal_event_count =
        (sizeof(terminal_prefix) - 1)
        + terminal_payload_count
        + (sizeof(terminal_suffix) - 1);
    if (terminal_event_count > TESSERA_CORE_ABI_MAX_PAYLOAD_BYTES
        || terminal_event_count
            <= (TESSERA_CORE_ABI_MAX_PAYLOAD_BYTES * 9u) / 10u
        || terminal_event_count - terminal_payload_count
            > MAX_JSON_ENVELOPE_OVERHEAD_BYTES) {
        free(terminal_payload);
        return 6;
    }
    uint8_t *terminal_event = (uint8_t *)malloc(terminal_event_count);
    if (terminal_event == NULL) {
        free(terminal_payload);
        return 7;
    }
    size_t offset = 0;
    memcpy(terminal_event + offset, terminal_prefix, sizeof(terminal_prefix) - 1);
    offset += sizeof(terminal_prefix) - 1;
    memcpy(terminal_event + offset, terminal_payload, terminal_payload_count);
    offset += terminal_payload_count;
    memcpy(terminal_event + offset, terminal_suffix, sizeof(terminal_suffix) - 1);

    callback_context capture = {
        .expected_terminal_payload = terminal_payload,
        .expected_terminal_payload_count = terminal_payload_count,
        .callback_count = 0,
        .terminal_callback_count = 0,
        .terminal_callback_bytes = 0,
        .expected_step = 0,
        .callback_active = ATOMIC_FLAG_INIT,
        .error = ATOMIC_VAR_INIT(0),
    };

    tessera_core_runtime_t runtime = tessera_core_runtime_create(
        receive_event,
        &capture
    );
    if (runtime == NULL) {
        free(terminal_event);
        free(terminal_payload);
        return 8;
    }

    static const uint8_t connect_command[] =
        "{\"hostID\":\"11111111-1111-1111-1111-111111111111\","
        "\"kind\":\"connect\",\"policyGeneration\":7,"
        "\"requestID\":\"22222222-2222-2222-2222-222222222222\",\"v\":4}";
    static const uint8_t connected_event[] =
        "{\"attemptID\":\"22222222-2222-2222-2222-222222222222\","
        "\"kind\":\"transportConnected\",\"policyGeneration\":7,\"version\":1}";

    int result = 0;
    if (tessera_core_runtime_send(
            runtime,
            connect_command,
            sizeof(connect_command) - 1) != 0) {
        result = 9;
        goto destroy;
    }
    if (tessera_core_runtime_emit(
            runtime,
            connected_event,
            sizeof(connected_event) - 1) != 0) {
        result = 10;
        goto destroy;
    }
    if (tessera_core_runtime_emit(
            runtime,
            terminal_event,
            terminal_event_count) != 0) {
        result = 11;
    }

destroy:
    tessera_core_runtime_destroy(runtime);
    if (result == 0 && tessera_core_runtime_send(
            runtime,
            connect_command,
            sizeof(connect_command) - 1) != -2) result = 12;
    if (result == 0 && tessera_core_runtime_emit(
            runtime,
            connected_event,
            sizeof(connected_event) - 1) != -2) result = 13;
    // Idempotent destruction is part of the public handle contract.
    tessera_core_runtime_destroy(runtime);

    if (result == 0
        && atomic_load_explicit(&capture.error, memory_order_acquire) != 0) {
        result = 14;
    }
    if (result == 0
        && (capture.callback_count != 6
            || capture.expected_step != 6
            || capture.terminal_callback_count != 1
            || capture.terminal_callback_bytes < terminal_payload_count)) {
        result = 15;
    }

    free(terminal_event);
    free(terminal_payload);
    return result;
}
