#include "MoshClient.h"

#include <algorithm>
#include <array>
#include <cctype>
#include <cerrno>
#include <climits>
#include <clocale>
#include <cwchar>
#include <limits>
#include <mutex>
#include <stdexcept>
#include <string>
#include <utility>

#include "completeterminal.h"
#include "fatal_assert.h"
#include "network.h"
#include "networktransport-impl.h"
#include "parseraction.h"
#include "shared.h"
#include "terminaldisplay.h"
#include "terminalframebuffer.h"
#include "terminaloverlay.h"
#include "timestamp.h"
#include "user.h"

namespace {

constexpr int kDefaultColumns = 80;
constexpr int kDefaultRows = 24;
constexpr size_t kMaxPacketsPerTick = 32;
constexpr uint64_t kServerLateThresholdMilliseconds = 6500;
constexpr uint64_t kReplyLateThresholdMilliseconds = 10000;

using NetworkType = Network::Transport<Network::UserStream, Terminal::Complete>;
using NetworkPointer = shared::shared_ptr<NetworkType>;

/// Volatile writes keep the compiler from eliding this erase before the
/// string's storage is released. The printable bootstrap key is no longer
/// needed after Network::Transport has decoded it into Crypto::Session.
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

bool is_no_packet_exception(const Network::NetworkException &error) {
    return error.function == "No packet received"
        || error.the_errno == EAGAIN
        || error.the_errno == EWOULDBLOCK;
}

std::wstring make_notification_string(const std::string &message) {
    return std::wstring(message.begin(), message.end());
}

std::wstring make_connecting_notification(const std::string &port) {
    wchar_t buffer[128];
    swprintf(buffer, 128, L"Nothing received from server on UDP port %s.",
             port.c_str());
    return std::wstring(buffer);
}

std::chrono::milliseconds no_deadline() {
    return std::chrono::milliseconds::max();
}

bool locale_name_contains_utf8(const char *name) {
    if (name == nullptr) {
        return false;
    }

    std::string lower(name);
    std::transform(
        lower.begin(),
        lower.end(),
        lower.begin(),
        [](const unsigned char ch) {
            return static_cast<char>(std::tolower(ch));
        });
    return lower.find("utf-8") != std::string::npos
        || lower.find("utf8") != std::string::npos;
}

void ensure_utf8_ctype_locale() {
    static std::once_flag once;
    std::call_once(once, [] {
        const char *locale_name = setlocale(LC_CTYPE, "");
        if (locale_name_contains_utf8(locale_name)) {
            return;
        }

        const std::array<const char *, 4> fallbacks = {
            "en_US.UTF-8",
            "en_US.utf8",
            "C.UTF-8",
            "UTF-8",
        };

        for (const char *candidate : fallbacks) {
            locale_name = setlocale(LC_CTYPE, candidate);
            if (locale_name_contains_utf8(locale_name)) {
                return;
            }
        }
    });
}

} // namespace

class MoshClient::Impl {
public:
    Impl(std::string host, int port, const std::string &base64_key)
        : host_(std::move(host)),
          port_string_(std::to_string(port)),
          key_(base64_key),
          cols_(kDefaultColumns),
          rows_(kDefaultRows),
          local_framebuffer_(1, 1),
          next_framebuffer_(1, 1),
          display_(true),
          connecting_notification_(make_connecting_notification(port_string_)) {
        overlays_.get_prediction_engine().set_display_preference(
            Overlay::PredictionEngine::Never);
    }

    ~Impl() {
        // Reset first so the transport's Crypto::Session destructor clears
        // its AES context before the surrounding client storage is released.
        network_.reset();
        secure_clear_string(key_);
    }

    void set_output_callback(OutputCallback callback) {
        output_callback_ = std::move(callback);
    }

    void start() {
        if (started_) {
            return;
        }

        SensitiveStringScopeClear clear_key_on_return(key_);
        ensure_utf8_ctype_locale();
        freeze_timestamp();

        local_framebuffer_ = Terminal::Framebuffer(cols_, rows_);
        next_framebuffer_ = Terminal::Framebuffer(1, 1);
        clean_shutdown_ = false;
        terminated_ = false;
        emitted_close_sequence_ = false;

        emit_bytes(display_.new_frame(false, local_framebuffer_, local_framebuffer_));

        Network::UserStream initial_user_stream;
        Terminal::Complete initial_terminal(cols_, rows_);
        network_ = NetworkPointer(new NetworkType(initial_user_stream,
                                                  initial_terminal,
                                                  key_.c_str(),
                                                  host_.c_str(),
                                                  port_string_.c_str()));
        network_->set_send_delay(1);
        network_->get_current_state().push_back(Parser::Resize(cols_, rows_));
        started_ = true;
    }

    std::chrono::milliseconds tick() {
        if (!started_) {
            throw std::runtime_error("MoshClient.tick() called before start()");
        }

        freeze_timestamp();

        if (terminated_ || !network_) {
            return no_deadline();
        }

        bool hit_packet_limit = false;

        try {
            size_t packets_processed = 0;
            while (network_) {
                try {
                    network_->recv();
                    process_network_input();
                    packets_processed++;
                    if (packets_processed >= kMaxPacketsPerTick) {
                        hit_packet_limit = true;
                        break;
                    }
                } catch (const Network::NetworkException &error) {
                    if (is_no_packet_exception(error)) {
                        break;
                    }
                    process_network_exception(error);
                    break;
                }
            }

            update_connection_notifications();
            network_->tick();
            process_send_error();
        } catch (const Network::NetworkException &error) {
            process_network_exception(error);
        } catch (const Crypto::CryptoException &error) {
            if (error.fatal) {
                throw;
            }
            overlays_.get_notification_engine().set_notification_string(
                make_notification_string(
                    std::string("Crypto exception: ") + error.what()));
        }

        if (should_finish_shutdown()) {
            finalize_shutdown();
            return no_deadline();
        }

        render_current_frame();

        if (hit_packet_limit) {
            return std::chrono::milliseconds(0);
        }

        return next_deadline();
    }

    void inject_user_bytes(const uint8_t *bytes, size_t length) {
        if (!started_ || terminated_ || !network_ || length == 0
            || network_->shutdown_in_progress()) {
            return;
        }

        freeze_timestamp();

        NetworkType &network = *network_;
        overlays_.get_prediction_engine().set_local_frame_sent(
            network.get_sent_state_last());

        const bool paste = length > 100;
        if (paste) {
            overlays_.get_prediction_engine().reset();
        }

        for (size_t i = 0; i < length; i++) {
            const char byte = static_cast<char>(bytes[i]);
            if (!paste) {
                overlays_.get_prediction_engine().new_user_byte(
                    byte, local_framebuffer_);
            }
            network.get_current_state().push_back(Parser::UserByte(byte));
        }
    }

    void resize(int cols, int rows) {
        if (cols <= 0 || rows <= 0) {
            return;
        }

        freeze_timestamp();

        cols_ = cols;
        rows_ = rows;
        overlays_.get_prediction_engine().reset();

        if (!started_ || terminated_ || !network_ || network_->shutdown_in_progress()) {
            return;
        }

        network_->get_current_state().push_back(Parser::Resize(cols, rows));
    }

    /// Repaint the whole screen from the client's authoritative framebuffer.
    ///
    /// The SSP diff stream assumes the local terminal shows exactly what
    /// `local_framebuffer_` holds. Anything that paints the terminal outside
    /// this client (a tmux window redraw replayed through a buffered attach,
    /// a restored continuity snapshot) breaks that assumption, and because
    /// the diff engine believes those cells are already correct it will never
    /// repaint them. Emitting one uninitialized frame — a clear plus every
    /// cell of the current state — resynchronizes the terminal with the
    /// model; subsequent diffs stay consistent from there.
    void force_full_repaint() {
        freeze_timestamp();

        if (!started_ || terminated_ || !network_
            || network_->shutdown_in_progress() || still_connecting()) {
            return;
        }

        next_framebuffer_ = network_->get_latest_remote_state().state.get_fb();
        overlays_.apply(next_framebuffer_);
        emit_bytes(display_.new_frame(false, next_framebuffer_, next_framebuffer_));
        local_framebuffer_ = next_framebuffer_;
    }

    void shutdown() {
        freeze_timestamp();

        if (!started_ || terminated_) {
            return;
        }

        if (network_ && network_->has_remote_addr() && !network_->shutdown_in_progress()) {
            network_->start_shutdown();
            try {
                network_->tick();
            } catch (...) {
                // Best-effort send of the shutdown frame. Teardown continues below.
            }
        }

        finalize_shutdown();
    }

    int socket_fd() const {
        if (!network_ || terminated_) {
            return -1;
        }

        const std::vector<int> fds = network_->fds();
        if (fds.empty()) {
            return -1;
        }

        return fds.back();
    }

    std::vector<int> socket_fds() const {
        if (!network_ || terminated_) {
            return {};
        }

        return network_->fds();
    }

    bool connected() const {
        return network_ && !terminated_ && network_->get_remote_state_num() != 0;
    }

    bool transport_reachable() const {
        if (!connected()) {
            return false;
        }

        const uint64_t now = Network::timestamp();
        const uint64_t last_word_from_server =
            network_->get_latest_remote_state().timestamp;
        const uint64_t last_acked_state =
            network_->get_sent_state_acked_timestamp();

        return now - last_word_from_server <= kServerLateThresholdMilliseconds
            && now - last_acked_state <= kReplyLateThresholdMilliseconds;
    }

    bool shutdown_complete() const {
        return terminated_;
    }

    bool application_mode_cursor_keys() const {
        if (!started_ || terminated_) {
            return false;
        }
        return local_framebuffer_.ds.application_mode_cursor_keys;
    }

    bool retains_bootstrap_key_material() const {
        return !key_.empty()
            || (network_ && network_->retains_raw_key_material());
    }

private:
    std::string host_;
    std::string port_string_;
    std::string key_;
    int cols_;
    int rows_;
    Terminal::Framebuffer local_framebuffer_;
    Terminal::Framebuffer next_framebuffer_;
    Overlay::OverlayManager overlays_;
    NetworkPointer network_;
    Terminal::Display display_;
    std::wstring connecting_notification_;
    bool started_ = false;
    bool clean_shutdown_ = false;
    bool terminated_ = false;
    bool emitted_close_sequence_ = false;
    OutputCallback output_callback_;

    bool still_connecting() const {
        return network_ && network_->get_remote_state_num() == 0;
    }

    void emit_bytes(const std::string &bytes) const {
        if (bytes.empty() || !output_callback_) {
            return;
        }

        output_callback_(
            reinterpret_cast<const uint8_t *>(bytes.data()),
            bytes.size());
    }

    void render_current_frame() {
        if (!network_) {
            return;
        }

        next_framebuffer_ = network_->get_latest_remote_state().state.get_fb();
        overlays_.apply(next_framebuffer_);

        const std::string diff = display_.new_frame(true,
                                                    local_framebuffer_,
                                                    next_framebuffer_);
        emit_bytes(diff);
        local_framebuffer_ = next_framebuffer_;
    }

    void process_network_input() {
        overlays_.get_notification_engine().server_heard(
            network_->get_latest_remote_state().timestamp);
        overlays_.get_notification_engine().server_acked(
            network_->get_sent_state_acked_timestamp());

        overlays_.get_prediction_engine().set_local_frame_acked(
            network_->get_sent_state_acked());
        overlays_.get_prediction_engine().set_send_interval(
            network_->send_interval());
        overlays_.get_prediction_engine().set_local_frame_late_acked(
            network_->get_latest_remote_state().state.get_echo_ack());
    }

    void process_network_exception(const Network::NetworkException &error) {
        if (!network_ || is_no_packet_exception(error)) {
            return;
        }

        if (!network_->shutdown_in_progress()) {
            overlays_.get_notification_engine().set_network_error(error.what());
        }
    }

    void process_send_error() {
        if (!network_) {
            return;
        }

        std::string &send_error = network_->get_send_error();
        if (!send_error.empty()) {
            overlays_.get_notification_engine().set_network_error(send_error);
            send_error.clear();
        } else {
            overlays_.get_notification_engine().clear_network_error();
        }
    }

    void update_connection_notifications() {
        if (!network_) {
            return;
        }

        if (still_connecting()
            && !network_->shutdown_in_progress()
            && (Network::timestamp() - network_->get_latest_remote_state().timestamp > 250)) {
            if (Network::timestamp() - network_->get_latest_remote_state().timestamp > 15000) {
                overlays_.get_notification_engine().set_notification_string(
                    L"Timed out waiting for server...", true);
                network_->start_shutdown();
            } else {
                overlays_.get_notification_engine().set_notification_string(
                    connecting_notification_);
            }
        } else if (network_->get_remote_state_num() != 0
                   && overlays_.get_notification_engine().get_notification_string()
                       == connecting_notification_) {
            overlays_.get_notification_engine().set_notification_string(L"");
        }
    }

    bool should_finish_shutdown() {
        if (!network_ || !network_->shutdown_in_progress()) {
            return false;
        }

        if (network_->shutdown_acknowledged()) {
            clean_shutdown_ = true;
            return true;
        }

        if (network_->counterparty_shutdown_ack_sent()) {
            clean_shutdown_ = true;
            return true;
        }

        return network_->shutdown_ack_timed_out();
    }

    void finalize_shutdown() {
        if (terminated_) {
            return;
        }

        if (network_) {
            overlays_.get_notification_engine().set_notification_string(L"");
            overlays_.get_notification_engine().server_heard(Network::timestamp());
            render_current_frame();
            network_.reset();
        }

        if (!emitted_close_sequence_) {
            emit_bytes(display_.close());
            emitted_close_sequence_ = true;
        }

        terminated_ = true;
    }

    std::chrono::milliseconds next_deadline() const {
        if (!network_ || terminated_) {
            return no_deadline();
        }

        int wait_time = std::min(network_->wait_time(), overlays_.wait_time());
        if (still_connecting()) {
            wait_time = std::min(250, wait_time);
        }

        if (wait_time == INT_MAX) {
            return no_deadline();
        }

        return std::chrono::milliseconds(std::max(wait_time, 0));
    }
};

MoshClient::MoshClient(std::string host, int port, const std::string &base64_key)
    : impl_(std::make_unique<Impl>(std::move(host), port, base64_key)) {}

MoshClient::~MoshClient() = default;

void MoshClient::start() {
    impl_->start();
}

std::chrono::milliseconds MoshClient::tick() {
    return impl_->tick();
}

void MoshClient::inject_user_bytes(const uint8_t *bytes, size_t length) {
    impl_->inject_user_bytes(bytes, length);
}

void MoshClient::resize(int cols, int rows) {
    impl_->resize(cols, rows);
}

void MoshClient::force_full_repaint() {
    impl_->force_full_repaint();
}

void MoshClient::shutdown() {
    impl_->shutdown();
}

void MoshClient::set_output_callback(OutputCallback callback) {
    impl_->set_output_callback(std::move(callback));
}

int MoshClient::socket_fd() const {
    return impl_->socket_fd();
}

std::vector<int> MoshClient::socket_fds() const {
    return impl_->socket_fds();
}

bool MoshClient::connected() const {
    return impl_->connected();
}

bool MoshClient::transport_reachable() const {
    return impl_->transport_reachable();
}

bool MoshClient::shutdown_complete() const {
    return impl_->shutdown_complete();
}

bool MoshClient::application_mode_cursor_keys() const {
    return impl_->application_mode_cursor_keys();
}

bool MoshClient::retains_bootstrap_key_material() const {
    return impl_->retains_bootstrap_key_material();
}
