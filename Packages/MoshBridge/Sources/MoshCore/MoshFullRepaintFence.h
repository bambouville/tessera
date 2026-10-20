#ifndef MOSH_FULL_REPAINT_FENCE_H
#define MOSH_FULL_REPAINT_FENCE_H

#include <cstdint>
#include <limits>

namespace tessera_mosh {

// A queued resize changes UserStream, so the next sender state includes it.
// Keep this minimum state fixed while later user states continue advancing.
inline uint64_t full_repaint_fence_token(uint64_t last_sent_state) {
    const uint64_t shutdown_state = std::numeric_limits<uint64_t>::max();
    return last_sent_state >= shutdown_state - 1 ? 0 : last_sent_state + 1;
}

inline bool full_repaint_fence_ready(
    uint64_t token,
    uint64_t last_sent_state,
    uint64_t remote_echo_ack,
    int framebuffer_columns,
    int framebuffer_rows,
    int current_columns,
    int current_rows) {
    return token != 0
        && token != std::numeric_limits<uint64_t>::max()
        && last_sent_state >= token
        && remote_echo_ack >= token
        && framebuffer_columns == current_columns
        && framebuffer_rows == current_rows;
}

} // namespace tessera_mosh

#endif
