#include "MoshCABI.h"

#include <cstddef>
#include <cstdint>
#include <cstdio>

namespace {

struct OutputProbe {
    std::size_t callback_count = 0;
    std::size_t byte_count = 0;
    bool invalid_batch = false;
};

void collect_output(const std::uint8_t *bytes, std::size_t length, void *context) {
    auto *probe = static_cast<OutputProbe *>(context);
    if (probe == nullptr) return;
    if (bytes == nullptr || length == 0
        || length > TESSERA_MOSH_C_ABI_MAX_OUTPUT_BATCH_BYTES) {
        probe->invalid_batch = true;
        return;
    }
    probe->callback_count += 1;
    probe->byte_count += length;
}

int fail(int code, const char *message) {
    std::fprintf(stderr, "Mosh C ABI runtime smoke failed (%d): %s\n", code, message);
    return code;
}

} // namespace

int main() {
    if (tessera_mosh_abi_version() != TESSERA_MOSH_C_ABI_VERSION) {
        return fail(1, "ABI version mismatch");
    }
    if (tessera_mosh_max_output_batch_bytes()
        != TESSERA_MOSH_C_ABI_MAX_OUTPUT_BATCH_BYTES) {
        return fail(2, "output limit mismatch");
    }

    tessera_mosh_client *client = nullptr;
    const tessera_mosh_result result = tessera_mosh_client_create(nullptr, &client);
    if (result != TESSERA_MOSH_INVALID_ARGUMENT || client != nullptr) {
        return fail(3, "null configuration did not fail closed");
    }

    // A downstream consumer must link every public entry point, not merely
    // rely on object-file or whole-archive retention. Null handles are the
    // documented invalid-argument path and cannot start network activity.
    uint64_t wait_milliseconds = 0;
    int32_t integer_result = 0;
    size_t count = 0;
    char error_buffer[1] = {};
    if (tessera_mosh_client_start(nullptr) != TESSERA_MOSH_INVALID_ARGUMENT) {
        return fail(4, "null start did not fail closed");
    }
    if (tessera_mosh_client_tick(nullptr, &wait_milliseconds)
        != TESSERA_MOSH_INVALID_ARGUMENT) return fail(5, "null tick did not fail closed");
    if (tessera_mosh_client_inject_bytes(nullptr, nullptr, 0)
        != TESSERA_MOSH_INVALID_ARGUMENT) return fail(6, "null input did not fail closed");
    if (tessera_mosh_client_resize(nullptr, 80, 24)
        != TESSERA_MOSH_INVALID_ARGUMENT) return fail(7, "null resize did not fail closed");
    if (tessera_mosh_client_force_full_repaint(nullptr)
        != TESSERA_MOSH_INVALID_ARGUMENT) return fail(8, "null repaint did not fail closed");
    if (tessera_mosh_client_begin_full_repaint_fence(nullptr, &wait_milliseconds)
        != TESSERA_MOSH_INVALID_ARGUMENT) return fail(44, "null repaint fence did not fail closed");
    if (tessera_mosh_client_is_full_repaint_fence_ready(nullptr, 1, &integer_result)
        != TESSERA_MOSH_INVALID_ARGUMENT) return fail(45, "null repaint readiness did not fail closed");
    if (tessera_mosh_client_shutdown(nullptr)
        != TESSERA_MOSH_INVALID_ARGUMENT) return fail(9, "null shutdown did not fail closed");
    if (tessera_mosh_client_socket_fd(nullptr, &integer_result)
        != TESSERA_MOSH_INVALID_ARGUMENT) return fail(10, "null socket query did not fail closed");
    if (tessera_mosh_client_copy_socket_fds(nullptr, nullptr, 0, &count)
        != TESSERA_MOSH_INVALID_ARGUMENT) return fail(11, "null socket list did not fail closed");
    if (tessera_mosh_client_is_connected(nullptr, &integer_result)
        != TESSERA_MOSH_INVALID_ARGUMENT) return fail(12, "null connected query did not fail closed");
    if (tessera_mosh_client_is_transport_reachable(nullptr, &integer_result)
        != TESSERA_MOSH_INVALID_ARGUMENT) return fail(13, "null reachability query did not fail closed");
    if (tessera_mosh_client_server_contact_age_ms(nullptr, &wait_milliseconds)
        != TESSERA_MOSH_INVALID_ARGUMENT) return fail(47, "null contact age query did not fail closed");
    if (tessera_mosh_client_reply_age_ms(nullptr, &wait_milliseconds)
        != TESSERA_MOSH_INVALID_ARGUMENT) return fail(48, "null reply age query did not fail closed");
    if (tessera_mosh_client_is_shutdown_complete(nullptr, &integer_result)
        != TESSERA_MOSH_INVALID_ARGUMENT) return fail(14, "null shutdown query did not fail closed");
    if (tessera_mosh_client_application_mode_cursor_keys(nullptr, &integer_result)
        != TESSERA_MOSH_INVALID_ARGUMENT) return fail(15, "null cursor query did not fail closed");
    if (tessera_mosh_client_retains_bootstrap_key_material(nullptr, &integer_result)
        != TESSERA_MOSH_INVALID_ARGUMENT) return fail(16, "null key query did not fail closed");
    if (tessera_mosh_client_copy_last_error(
            nullptr,
            error_buffer,
            sizeof(error_buffer),
            &count) != TESSERA_MOSH_INVALID_ARGUMENT) {
        return fail(17, "null diagnostic query did not fail closed");
    }
    tessera_mosh_client_destroy(nullptr);

    OutputProbe output;
    tessera_mosh_client_config_v1 config{};
    config.abi_version = TESSERA_MOSH_C_ABI_VERSION;
    config.struct_size = sizeof(config);
    config.host = "127.0.0.1";
    config.port = 60001;
    config.base64_key = "qiXpjXIk6M8/nWtBn9s6rQ";
    config.output_callback = collect_output;
    config.output_context = &output;

    if (tessera_mosh_client_create(&config, &client) != TESSERA_MOSH_OK
        || client == nullptr) {
        return fail(18, "valid client creation failed");
    }
    tessera_mosh_client *retired_client = client;
    if (tessera_mosh_client_retains_bootstrap_key_material(client, &integer_result)
            != TESSERA_MOSH_OK
        || integer_result != 1) {
        return fail(19, "bootstrap key was not owned before start");
    }
    if (tessera_mosh_client_resize(client, 132, 43) != TESSERA_MOSH_OK) {
        return fail(20, "pre-start resize failed");
    }
    if (tessera_mosh_client_start(client) != TESSERA_MOSH_OK) {
        return fail(21, "start failed");
    }
    if (tessera_mosh_client_start(client) != TESSERA_MOSH_INVALID_STATE) {
        return fail(22, "repeated start did not fail closed");
    }
    if (output.invalid_batch || output.callback_count == 0 || output.byte_count == 0) {
        return fail(23, "start did not emit bounded terminal output");
    }
    if (tessera_mosh_client_retains_bootstrap_key_material(client, &integer_result)
            != TESSERA_MOSH_OK
        || integer_result != 0) {
        return fail(24, "bootstrap key remained after start");
    }
    if (tessera_mosh_client_tick(client, &wait_milliseconds) != TESSERA_MOSH_OK) {
        return fail(25, "tick failed");
    }
    const std::uint8_t input[] = {'p', 'w', 'd', '\r'};
    if (tessera_mosh_client_inject_bytes(client, input, sizeof(input))
        != TESSERA_MOSH_OK) {
        return fail(26, "input injection failed");
    }
    if (tessera_mosh_client_resize(client, 80, 24) != TESSERA_MOSH_OK) {
        return fail(27, "started resize failed");
    }
    if (tessera_mosh_client_force_full_repaint(client) != TESSERA_MOSH_OK) {
        return fail(28, "full repaint failed");
    }
    if (tessera_mosh_client_socket_fd(client, &integer_result) != TESSERA_MOSH_OK
        || integer_result < -1) {
        return fail(29, "socket descriptor query failed");
    }
    if (tessera_mosh_client_copy_socket_fds(client, nullptr, 0, &count)
            != TESSERA_MOSH_BUFFER_TOO_SMALL
        || count == 0) {
        return fail(30, "socket descriptor sizing failed");
    }
    if (tessera_mosh_client_is_connected(client, &integer_result) != TESSERA_MOSH_OK
        || (integer_result != 0 && integer_result != 1)) {
        return fail(31, "connected state query failed");
    }
    if (tessera_mosh_client_is_transport_reachable(client, &integer_result)
            != TESSERA_MOSH_OK
        || (integer_result != 0 && integer_result != 1)) {
        return fail(32, "reachability query failed");
    }
    if (tessera_mosh_client_server_contact_age_ms(client, nullptr)
        != TESSERA_MOSH_INVALID_ARGUMENT) return fail(49, "null contact age output did not fail closed");
    if (tessera_mosh_client_reply_age_ms(client, nullptr)
        != TESSERA_MOSH_INVALID_ARGUMENT) return fail(50, "null reply age output did not fail closed");
    if (tessera_mosh_client_server_contact_age_ms(client, &wait_milliseconds) != TESSERA_MOSH_OK
        || wait_milliseconds != 0) return fail(51, "unconnected contact age was not zero");
    if (tessera_mosh_client_reply_age_ms(client, &wait_milliseconds) != TESSERA_MOSH_OK
        || wait_milliseconds != 0) return fail(52, "unconnected reply age was not zero");
    if (tessera_mosh_client_application_mode_cursor_keys(client, &integer_result)
            != TESSERA_MOSH_OK
        || (integer_result != 0 && integer_result != 1)) {
        return fail(33, "cursor mode query failed");
    }
    if (tessera_mosh_client_shutdown(client) != TESSERA_MOSH_OK) {
        return fail(34, "shutdown failed");
    }
    if (tessera_mosh_client_is_shutdown_complete(client, &integer_result)
            != TESSERA_MOSH_OK
        || integer_result != 1) {
        return fail(35, "shutdown did not complete synchronously");
    }
    tessera_mosh_client_destroy(client);
    client = nullptr;
    if (tessera_mosh_client_is_connected(retired_client, &integer_result)
        != TESSERA_MOSH_INVALID_ARGUMENT) {
        return fail(36, "destroyed handle remained valid");
    }
    if (tessera_mosh_client_server_contact_age_ms(retired_client, &wait_milliseconds)
        != TESSERA_MOSH_INVALID_ARGUMENT) return fail(53, "destroyed contact age query remained valid");
    if (tessera_mosh_client_reply_age_ms(retired_client, &wait_milliseconds)
        != TESSERA_MOSH_INVALID_ARGUMENT) return fail(54, "destroyed reply age query remained valid");
    tessera_mosh_client_destroy(retired_client);

    std::printf(
        "TESSERA_MOSH_ANDROID_RUNTIME_OK callbacks=%zu bytes=%zu wait_ms=%llu\n",
        output.callback_count,
        output.byte_count,
        static_cast<unsigned long long>(wait_milliseconds)
    );
    return 0;
}
