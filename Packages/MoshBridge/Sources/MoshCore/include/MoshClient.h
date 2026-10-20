#ifndef MOSH_CLIENT_H
#define MOSH_CLIENT_H

#include <chrono>
#include <cstddef>
#include <cstdint>
#include <functional>
#include <memory>
#include <string>
#include <vector>

class MoshClient {
public:
    using OutputCallback = std::function<void(const uint8_t *, size_t)>;

    MoshClient(std::string host, int port, const std::string &base64_key);
    ~MoshClient();

    void start();
    std::chrono::milliseconds tick();
    void inject_user_bytes(const uint8_t *bytes, size_t length);
    void resize(int cols, int rows);
    uint64_t begin_full_repaint_fence();
    bool full_repaint_fence_ready(uint64_t token) const;
    void force_full_repaint();
    void shutdown();
    void set_output_callback(OutputCallback callback);
    int socket_fd() const;
    std::vector<int> socket_fds() const;
    bool connected() const;
    bool transport_reachable() const;
    uint64_t server_contact_age_ms() const;
    uint64_t reply_age_ms() const;
    bool shutdown_complete() const;
    bool application_mode_cursor_keys() const;
    bool retains_bootstrap_key_material() const;

private:
    class Impl;
    std::unique_ptr<Impl> impl_;
};

#endif
