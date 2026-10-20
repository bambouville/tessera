#include "include/MoshCABI.h"

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cstdint>
#include <cstring>
#include <exception>
#include <memory>
#include <mutex>
#include <new>
#include <string>
#include <unordered_map>
#include <utility>
#include <vector>

#include "MoshClient.h"

namespace {

struct ClientState {
    std::mutex operation_mutex;
    std::unique_ptr<MoshClient> client;
    tessera_mosh_output_callback output_callback = nullptr;
    void *output_context = nullptr;
    std::string last_error;
    bool started = false;
    std::atomic<bool> destroy_requested{false};
    bool finalized = false;
    uintptr_t token = 0;
};

std::mutex client_registry_mutex;
std::unordered_map<uintptr_t, std::shared_ptr<ClientState>> client_registry;
uintptr_t next_client_token = 1;
bool client_token_space_exhausted = false;
thread_local ClientState *active_client_state = nullptr;

// Public handles are monotonically assigned, nonzero identity values. They are
// never dereferenced and, unlike allocator-backed pointer tokens, can never be
// recycled into a later client's identity after destruction.
uintptr_t token_for_handle(const tessera_mosh_client *handle) {
    return reinterpret_cast<uintptr_t>(handle);
}

uintptr_t allocate_client_token_locked() {
    if (client_token_space_exhausted) return 0;
    const uintptr_t token = next_client_token++;
    if (next_client_token == 0) client_token_space_exhausted = true;
    return token;
}

void secure_clear_string(std::string &value) {
    volatile char *bytes = value.empty() ? nullptr : value.data();
    for (size_t index = 0; index < value.size(); ++index) {
        bytes[index] = 0;
    }
    value.clear();
    value.shrink_to_fit();
}

class SensitiveStringScopeClear {
public:
    explicit SensitiveStringScopeClear(std::string &value) : value_(value) {}
    ~SensitiveStringScopeClear() { secure_clear_string(value_); }
private:
    std::string &value_;
};

class ActiveClientScope {
public:
    explicit ActiveClientScope(ClientState *state)
        : previous_(active_client_state) {
        active_client_state = state;
    }

    ~ActiveClientScope() { active_client_state = previous_; }

private:
    ClientState *previous_;
};

std::shared_ptr<ClientState> lookup_state(const tessera_mosh_client *handle) {
    if (handle == nullptr) return nullptr;
    std::lock_guard<std::mutex> lock(client_registry_mutex);
    const auto iterator = client_registry.find(token_for_handle(handle));
    return iterator == client_registry.end() ? nullptr : iterator->second;
}

bool is_bounded_nonempty_c_string(const char *value, size_t maximum_bytes) {
    if (value == nullptr || value[0] == '\0') return false;
    for (size_t index = 1; index <= maximum_bytes; ++index) {
        if (value[index] == '\0') return true;
    }
    return false;
}

void set_error(ClientState &state, const char *message) {
    if (message == nullptr || message[0] == '\0') {
        state.last_error = "Unknown mosh core failure.";
        return;
    }
    size_t count = 0;
    while (count < TESSERA_MOSH_C_ABI_MAX_ERROR_BYTES
        && message[count] != '\0') {
        ++count;
    }
    state.last_error.assign(message, count);
}

// Requires operation_mutex. Public token values are retired permanently; there
// is no allocation to free and therefore no stale-handle ABA reuse window.
void finalize_if_requested(ClientState &state) {
    if (!state.destroy_requested.load(std::memory_order_acquire)
        || state.finalized) {
        return;
    }
    state.client.reset();
    state.output_callback = nullptr;
    state.output_context = nullptr;
    state.finalized = true;
    {
        std::lock_guard<std::mutex> registry_lock(client_registry_mutex);
        const auto iterator = client_registry.find(state.token);
        if (iterator != client_registry.end()
            && iterator->second.get() == &state) {
            client_registry.erase(iterator);
        }
    }
    state.token = 0;
}

template <typename Function>
tessera_mosh_result perform(tessera_mosh_client *handle, Function &&function) {
    const std::shared_ptr<ClientState> state = lookup_state(handle);
    if (state == nullptr) return TESSERA_MOSH_INVALID_ARGUMENT;
    if (active_client_state == state.get()) return TESSERA_MOSH_INVALID_STATE;

    std::unique_lock<std::mutex> lock(state->operation_mutex);
    if (state->destroy_requested.load(std::memory_order_acquire)
        || state->client == nullptr) {
        return TESSERA_MOSH_INVALID_ARGUMENT;
    }

    tessera_mosh_result result = TESSERA_MOSH_OK;
    {
        ActiveClientScope active(state.get());
        try {
            function(*state);
            state->last_error.clear();
        } catch (const tessera_mosh_result &error) {
            result = error;
        } catch (const std::exception &error) {
            set_error(*state, error.what());
            result = TESSERA_MOSH_FAILURE;
        } catch (...) {
            set_error(*state, nullptr);
            result = TESSERA_MOSH_FAILURE;
        }
        finalize_if_requested(*state);
    }

    lock.unlock();
    return result;
}

template <typename Function>
tessera_mosh_result query_bool(
    const tessera_mosh_client *handle,
    int32_t *out_value,
    Function &&function) {
    if (out_value == nullptr) return TESSERA_MOSH_INVALID_ARGUMENT;
    return perform(const_cast<tessera_mosh_client *>(handle), [&](ClientState &state) {
        *out_value = function(state) ? 1 : 0;
    });
}

void deliver_bounded_output(
    const std::shared_ptr<ClientState> &state,
    const uint8_t *bytes,
    size_t length) {
    if (state->output_callback == nullptr || bytes == nullptr) return;
    const size_t maximum = TESSERA_MOSH_C_ABI_MAX_OUTPUT_BATCH_BYTES;
    size_t offset = 0;
    while (offset < length
        && !state->destroy_requested.load(std::memory_order_acquire)) {
        const size_t count = std::min(maximum, length - offset);
        state->output_callback(bytes + offset, count, state->output_context);
        offset += count;
    }
}

} // namespace

extern "C" uint32_t tessera_mosh_abi_version(void) {
    return TESSERA_MOSH_C_ABI_VERSION;
}

extern "C" size_t tessera_mosh_max_output_batch_bytes(void) {
    return TESSERA_MOSH_C_ABI_MAX_OUTPUT_BATCH_BYTES;
}

extern "C" tessera_mosh_result tessera_mosh_client_create(
    const tessera_mosh_client_config_v1 *config,
    tessera_mosh_client **out_client) {
    if (out_client == nullptr) return TESSERA_MOSH_INVALID_ARGUMENT;
    *out_client = nullptr;
    if (config == nullptr
        || config->abi_version != TESSERA_MOSH_C_ABI_VERSION
        || config->struct_size < sizeof(tessera_mosh_client_config_v1)
        || !is_bounded_nonempty_c_string(
            config->host,
            TESSERA_MOSH_C_ABI_MAX_HOST_BYTES)
        || config->port == 0
        || !is_bounded_nonempty_c_string(
            config->base64_key,
            TESSERA_MOSH_C_ABI_MAX_KEY_BYTES)) {
        return TESSERA_MOSH_INVALID_ARGUMENT;
    }

    try {
        auto state = std::make_shared<ClientState>();
        state->output_callback = config->output_callback;
        state->output_context = config->output_context;
        std::string bootstrap_key(config->base64_key);
        SensitiveStringScopeClear clear_key(bootstrap_key);
        state->client = std::make_unique<MoshClient>(
            std::string(config->host),
            static_cast<int>(config->port),
            bootstrap_key);
        const std::weak_ptr<ClientState> weak_state(state);
        state->client->set_output_callback(
            [weak_state](const uint8_t *bytes, size_t length) {
                if (const std::shared_ptr<ClientState> state = weak_state.lock()) {
                    deliver_bounded_output(state, bytes, length);
                }
            });

        {
            std::lock_guard<std::mutex> lock(client_registry_mutex);
            const uintptr_t token = allocate_client_token_locked();
            if (token == 0) return TESSERA_MOSH_FAILURE;
            state->token = token;
            client_registry.emplace(token, state);
            *out_client = reinterpret_cast<tessera_mosh_client *>(token);
        }
        return TESSERA_MOSH_OK;
    } catch (const std::bad_alloc &) {
        return TESSERA_MOSH_FAILURE;
    } catch (...) {
        return TESSERA_MOSH_FAILURE;
    }
}

extern "C" void tessera_mosh_client_destroy(tessera_mosh_client *client) {
    if (client == nullptr) return;

    const std::shared_ptr<ClientState> state = lookup_state(client);
    if (state == nullptr) return;
    state->destroy_requested.store(true, std::memory_order_release);

    // A synchronous output callback may destroy its own handle. The active
    // operation owns operation_mutex, so it performs finalization on return.
    if (active_client_state == state.get()) return;

    std::unique_lock<std::mutex> lock(state->operation_mutex);
    {
        ActiveClientScope active(state.get());
        finalize_if_requested(*state);
    }
}

extern "C" tessera_mosh_result tessera_mosh_client_start(tessera_mosh_client *client) {
    return perform(client, [](ClientState &state) {
        if (state.started) throw TESSERA_MOSH_INVALID_STATE;
        state.client->start();
        state.started = true;
    });
}

extern "C" tessera_mosh_result tessera_mosh_client_tick(
    tessera_mosh_client *client,
    uint64_t *out_wait_milliseconds) {
    if (out_wait_milliseconds == nullptr) return TESSERA_MOSH_INVALID_ARGUMENT;
    return perform(client, [&](ClientState &state) {
        if (!state.started) throw TESSERA_MOSH_INVALID_STATE;
        const auto wait = state.client->tick();
        *out_wait_milliseconds = wait == std::chrono::milliseconds::max()
            ? TESSERA_MOSH_C_ABI_NO_DEADLINE
            : static_cast<uint64_t>(std::max<int64_t>(0, wait.count()));
    });
}

extern "C" tessera_mosh_result tessera_mosh_client_inject_bytes(
    tessera_mosh_client *client,
    const uint8_t *bytes,
    size_t length) {
    if ((length != 0 && bytes == nullptr)
        || length > TESSERA_MOSH_C_ABI_MAX_INPUT_BATCH_BYTES) {
        return TESSERA_MOSH_INVALID_ARGUMENT;
    }
    return perform(client, [&](ClientState &state) {
        if (!state.started) throw TESSERA_MOSH_INVALID_STATE;
        state.client->inject_user_bytes(bytes, length);
    });
}

extern "C" tessera_mosh_result tessera_mosh_client_resize(
    tessera_mosh_client *client,
    int32_t columns,
    int32_t rows) {
    if (columns <= 0 || rows <= 0) return TESSERA_MOSH_INVALID_ARGUMENT;
    return perform(client, [&](ClientState &state) {
        state.client->resize(columns, rows);
    });
}

extern "C" tessera_mosh_result tessera_mosh_client_force_full_repaint(
    tessera_mosh_client *client) {
    return perform(client, [](ClientState &state) {
        if (!state.started) throw TESSERA_MOSH_INVALID_STATE;
        state.client->force_full_repaint();
    });
}

extern "C" tessera_mosh_result tessera_mosh_client_begin_full_repaint_fence(
    tessera_mosh_client *client,
    uint64_t *out_token) {
    if (out_token == nullptr) return TESSERA_MOSH_INVALID_ARGUMENT;
    return perform(client, [&](ClientState &state) {
        if (!state.started) throw TESSERA_MOSH_INVALID_STATE;
        *out_token = state.client->begin_full_repaint_fence();
    });
}

extern "C" tessera_mosh_result tessera_mosh_client_is_full_repaint_fence_ready(
    const tessera_mosh_client *client,
    uint64_t token,
    int32_t *out_ready) {
    if (out_ready == nullptr || token == 0) return TESSERA_MOSH_INVALID_ARGUMENT;
    return query_bool(client, out_ready, [&](ClientState &state) {
        if (!state.started) throw TESSERA_MOSH_INVALID_STATE;
        return state.client->full_repaint_fence_ready(token);
    });
}

extern "C" tessera_mosh_result tessera_mosh_client_shutdown(tessera_mosh_client *client) {
    return perform(client, [](ClientState &state) { state.client->shutdown(); });
}

extern "C" tessera_mosh_result tessera_mosh_client_socket_fd(
    const tessera_mosh_client *client,
    int32_t *out_fd) {
    if (out_fd == nullptr) return TESSERA_MOSH_INVALID_ARGUMENT;
    return perform(const_cast<tessera_mosh_client *>(client), [&](ClientState &state) {
        *out_fd = state.client->socket_fd();
    });
}

extern "C" tessera_mosh_result tessera_mosh_client_copy_socket_fds(
    const tessera_mosh_client *client,
    int32_t *buffer,
    size_t capacity,
    size_t *out_count) {
    if (out_count == nullptr) return TESSERA_MOSH_INVALID_ARGUMENT;
    return perform(const_cast<tessera_mosh_client *>(client), [&](ClientState &state) {
        const std::vector<int> fds = state.client->socket_fds();
        *out_count = fds.size();
        if (capacity < fds.size() || (fds.size() != 0 && buffer == nullptr)) {
            throw TESSERA_MOSH_BUFFER_TOO_SMALL;
        }
        for (size_t index = 0; index < fds.size(); ++index) {
            buffer[index] = static_cast<int32_t>(fds[index]);
        }
    });
}

extern "C" tessera_mosh_result tessera_mosh_client_is_connected(
    const tessera_mosh_client *client,
    int32_t *out_value) {
    return query_bool(client, out_value, [](ClientState &state) {
        return state.client->connected();
    });
}

extern "C" tessera_mosh_result tessera_mosh_client_is_transport_reachable(
    const tessera_mosh_client *client,
    int32_t *out_value) {
    return query_bool(client, out_value, [](ClientState &state) {
        return state.client->transport_reachable();
    });
}

extern "C" tessera_mosh_result tessera_mosh_client_server_contact_age_ms(
    const tessera_mosh_client *client,
    uint64_t *out_value) {
    if (out_value == nullptr) return TESSERA_MOSH_INVALID_ARGUMENT;
    return perform(const_cast<tessera_mosh_client *>(client), [&](ClientState &state) {
        *out_value = state.client->server_contact_age_ms();
    });
}

extern "C" tessera_mosh_result tessera_mosh_client_reply_age_ms(
    const tessera_mosh_client *client,
    uint64_t *out_value) {
    if (out_value == nullptr) return TESSERA_MOSH_INVALID_ARGUMENT;
    return perform(const_cast<tessera_mosh_client *>(client), [&](ClientState &state) {
        *out_value = state.client->reply_age_ms();
    });
}

extern "C" tessera_mosh_result tessera_mosh_client_is_shutdown_complete(
    const tessera_mosh_client *client,
    int32_t *out_value) {
    return query_bool(client, out_value, [](ClientState &state) {
        return state.client->shutdown_complete();
    });
}

extern "C" tessera_mosh_result tessera_mosh_client_application_mode_cursor_keys(
    const tessera_mosh_client *client,
    int32_t *out_value) {
    return query_bool(client, out_value, [](ClientState &state) {
        return state.client->application_mode_cursor_keys();
    });
}

extern "C" tessera_mosh_result tessera_mosh_client_retains_bootstrap_key_material(
    const tessera_mosh_client *client,
    int32_t *out_value) {
    return query_bool(client, out_value, [](ClientState &state) {
        return state.client->retains_bootstrap_key_material();
    });
}

extern "C" tessera_mosh_result tessera_mosh_client_copy_last_error(
    const tessera_mosh_client *client,
    char *buffer,
    size_t capacity,
    size_t *out_required_size) {
    if (out_required_size == nullptr) return TESSERA_MOSH_INVALID_ARGUMENT;
    return perform(const_cast<tessera_mosh_client *>(client), [&](ClientState &state) {
        const size_t required = state.last_error.size() + 1;
        *out_required_size = required;
        if (buffer == nullptr || capacity < required) {
            throw TESSERA_MOSH_BUFFER_TOO_SMALL;
        }
        std::memcpy(buffer, state.last_error.c_str(), required);
    });
}
