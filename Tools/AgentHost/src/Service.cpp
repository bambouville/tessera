#include "LocalTransport.h"
#include "ReadWorker.h"
#include "ReadStatus.h"
#include "Json.h"
#include "Scope.h"
#include "VersionPin.h"
#include <simdjson.h>
#include <arpa/inet.h>
#include <sys/file.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <unistd.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <algorithm>
#include <array>
#include <chrono>
#include <cstring>
#include <random>
#include <string>
#include <vector>
#include <map>

namespace tessera {
namespace {
using Clock = std::chrono::steady_clock;
constexpr size_t frameLimit = 65536;
constexpr size_t queueLimit = 2 * 1024 * 1024;
constexpr size_t globalQueueLimit = 8 * 1024 * 1024;
constexpr size_t clientLimit = 8;
constexpr size_t hookLimit = 32;
volatile sig_atomic_t stopping = 0;
void stop(int) { stopping = 1; }

std::string stringField(simdjson::dom::element value, const char* key) {
    std::string_view text;
    if (value[key].get_string().get(text)) return {};
    return std::string(text);
}

bool identifier(const std::string& value) {
    return !value.empty() && value.size() <= 128 && std::all_of(value.begin(), value.end(), [](unsigned char c) {
        return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
            (c >= '0' && c <= '9') || c == '_' || c == '-';
    });
}

std::string epoch() {
    std::random_device random;
    std::string result;
    for (int n = 0; n < 8; ++n) {
        auto value = random();
        for (int digit = 0; digit < 8; ++digit) {
            result += "0123456789abcdef"[value & 15];
            value >>= 4;
        }
    }
    return result;
}

struct Peer {
    struct Subscription {
        bool fast = false;
        bool readProgress = false;
        std::string cursor, pendingCursor, waiting, generation;
        std::string summaryRevision;
        bool pendingSummary = false;
        bool windowed = false;
        uint64_t windowVersion = 0;
        int64_t limit = 100;
        Clock::time_point next = Clock::now();
        Clock::time_point ackDeadline = Clock::time_point::max();
        Clock::time_point previewExpiry = Clock::time_point::max();
    };
    struct Pending { std::string thread, generation; bool automatic = false; };
    int fd;
    uint64_t token = 0;
    bool hook;
    bool hello = false;
    bool closed = false;
    bool readEnded = false;
    bool fast = false;
    bool dirty = false;
    std::string session;
    std::string input;
    std::string output;
    Clock::time_point expires;
    Clock::time_point drainDeadline = Clock::time_point::max();
    Clock::time_point nextSlow = Clock::now();
    uint64_t sequence = 0;
    std::map<std::string, Subscription> subscriptions;
    std::string lastScheduled;
    std::map<std::string, Pending> reads;
    struct WindowPending { std::string transaction; bool hasNewer; Clock::time_point deadline; };
    std::map<std::string, WindowPending> windows;
    void enqueue(const std::string& json) {
        if (json.size() > frameLimit || output.size() + json.size() + 4 > queueLimit) {
            closed = true; // Transport loss requires canonical resync, never silently drop events.
            return;
        }
        const auto length = htonl(static_cast<uint32_t>(json.size()));
        output.append(reinterpret_cast<const char*>(&length), 4);
        output += json;
    }
};

bool eventAllowed(const std::string& event) {
    static constexpr const char* events[] = {"SessionStart", "UserPromptSubmit", "MessageDisplay",
        "PreToolUse", "PostToolUse", "PostToolUseFailure", "PostToolBatch", "Stop", "StopFailure",
        "SessionEnd", "SubagentStart", "SubagentStop", "Notification", "PermissionRequest",
        "PreCompact", "PostCompact"};
    return std::any_of(std::begin(events), std::end(events), [&](const char* allowed) { return event == allowed; });
}

using Sources = std::map<std::string, std::pair<std::string, std::string>>;
void hookMessage(simdjson::dom::element object, std::vector<Peer>& peers, const std::string& serviceEpoch, const Sources& sources) {
    const auto event = stringField(object, "hook_event_name");
    const bool overflow = event == "TesseraHookOverflow";
    const auto session = stringField(object, "session_id");
    if (!overflow && (!identifier(session) || !eventAllowed(event))) return;
    // Preview transport only. Canonical history/reconciliation is a separate
    // reader contract. Never use the untrusted transcript_path to open a file.
    const auto raw = simdjson::minify(object);
    for (auto& peer : peers) {
        if (!peer.closed && !peer.hook && peer.hello) {
            for (auto& [thread, subscription] : peer.subscriptions) {
                const auto source = sources.find(thread);
                if (!subscription.fast || source == sources.end() || source->second.first != "claude" ||
                    (!overflow && source->second.second != session)) continue;
                subscription.next = Clock::now();
                if (event != "MessageDisplay" && !overflow) continue;
                json::Object display;
                display.string("hook_event_name", overflow ? "TesseraHookOverflow" : "MessageDisplay");
                display.string("session_id", source->second.second, 256);
                const auto delta = json::text(object, "delta");
                if (!overflow && delta.size() <= 32768) {
                    display.string("message_id", json::text(object, "message_id"), 256);
                    display.string("turn_id", json::text(object, "turn_id"), 256);
                    display.raw("index", simdjson::minify(json::get(object, "index")));
                    display.raw("final", simdjson::minify(json::get(object, "final")));
                    display.string("delta", delta, 32768);
                }
                json::Object value; value.string("kind", "hookPreview"); value.string("id", "hook_" + randomID());
                value.string("thread", thread); value.string("serviceEpoch", serviceEpoch); value.raw("event", display.finish());
                auto payload = value.finish();
                if (payload.size() > 65536) {
                    json::Object invalidation, envelope;
                    invalidation.string("hook_event_name", "TesseraHookOverflow");
                    invalidation.string("session_id", source->second.second, 256);
                    envelope.string("kind", "hookPreview"); envelope.string("id", "hook_" + randomID());
                    envelope.string("thread", thread); envelope.string("serviceEpoch", serviceEpoch);
                    envelope.raw("event", invalidation.finish()); payload = envelope.finish();
                }
                peer.enqueue(payload); subscription.previewExpiry = Clock::now() + std::chrono::seconds(10);
            }
        }
        if (peer.closed || peer.hook || !peer.hello || peer.session.empty() ||
            (!overflow && peer.session != session)) continue;
        if (!peer.fast) { peer.dirty = true; continue; }
        const auto prefix = "{\"kind\":\"" + std::string(overflow || raw.size() > 60000 ? "resyncRequired" : "hookPreview") +
            "\",\"serviceEpoch\":\"" + serviceEpoch + "\",\"sequence\":" + std::to_string(++peer.sequence);
        peer.enqueue(prefix + (overflow || raw.size() > 60000 ? ",\"reason\":\"hookOverflow\"}" : ",\"event\":" + raw + "}"));
    }
}

void request(simdjson::dom::element object, Peer& peer, const std::string& serviceEpoch, const std::string& contextScope, int leaseMs, ReadWorker& worker) {
    const auto kind = stringField(object, "kind");
    const auto id = stringField(object, "id");
    if (!identifier(id)) { peer.closed = true; return; }
    const std::string prefix = "{\"id\":\"" + id + "\",\"serviceEpoch\":\"" + serviceEpoch + "\",";
    if (!peer.hello) {
        int64_t version = 0;
        if (kind != "hello" || object["v"].get_int64().get(version) || version != 3) {
            peer.closed = true;
            return;
        }
        peer.hello = true;
        peer.expires = Clock::now() + std::chrono::milliseconds(leaseMs);
        peer.enqueue(prefix + "\"kind\":\"hello\",\"v\":3,\"experimental\":true,\"capabilities\":[\"claude.hookPreview\",\"jsonl.pages\",\"jsonl.subscriptions\",\"bounded.windows\",\"window.partitions\",\"pi.sessions.v1-v3\",\"opencode.sqlite.v1-v2\",\"kimi.wire.v1.4-v1.5\",\"read.progress.v1\",\"read.status.v1\",\"receipt.frontier.v1\",\"window.capacity.v1\"],"
            "\"maxFrameBytes\":65536,\"maxWindowSegments\":" + std::to_string(PageWindow::maximumViewportSegments) +
            ",\"maxRetainedBytes\":" + std::to_string(PageWindow::serviceGrowthLimit) +
            ",\"servicePID\":" + std::to_string(::getpid()) +
            ",\"contextScope\":\"" + contextScope + "\",\"leaseMs\":" + std::to_string(leaseMs) + "}");
    } else if (kind == "heartbeat") {
        peer.expires = Clock::now() + std::chrono::milliseconds(leaseMs);
        peer.enqueue(prefix + "\"kind\":\"ack\"}");
    } else if (kind == "subscribe") {
        const auto thread = stringField(object, "thread");
        if (!thread.empty()) {
            const auto interest = stringField(object, "interest");
            const auto cursor = stringField(object, "liveCursor");
            const bool windowed = !json::get(object, "windowVersion").is_null();
            int64_t windowVersion = 0;
            if (windowed && json::get(object, "windowVersion").get_int64().get(windowVersion)) {
                peer.enqueue(prefix + "\"kind\":\"error\",\"code\":\"invalidRequest\"}"); return;
            }
            int64_t limit = 100;
            if (!json::get(object, "limit").is_null() &&
                (json::get(object, "limit").get_int64().get(limit) || limit < 1 || limit > 100)) {
                peer.enqueue(prefix + "\"kind\":\"error\",\"code\":\"invalidRequest\"}"); return;
            }
            if (!identifier(thread) || (interest == "fast" ? !identifier(cursor) : (!cursor.empty() && !identifier(cursor))) || (interest != "fast" && interest != "slow") ||
                windowVersion < 0 ||
                (!peer.subscriptions.count(thread) && peer.subscriptions.size() >= 64)) {
                peer.enqueue(prefix + "\"kind\":\"error\",\"code\":\"invalidRequest\"}"); return;
            }
            auto existing = peer.subscriptions.find(thread);
            if (existing != peer.subscriptions.end()) {
                // Interest changes cannot rewind a committed cursor or cancel
                // an already emitted transaction while its ACK is in flight.
                existing->second.fast = interest == "fast";
                existing->second.readProgress = json::boolean(object, "readProgress");
                existing->second.windowed = windowed;
                existing->second.limit = limit;
                if (windowed && existing->second.waiting.empty()) {
                    existing->second.windowVersion = static_cast<uint64_t>(windowVersion);
                    if (!cursor.empty()) existing->second.cursor = cursor;
                }
                if (existing->second.cursor.empty()) existing->second.cursor = cursor;
                existing->second.next = Clock::now();
                peer.enqueue(prefix + "\"kind\":\"subscribed\",\"thread\":" + json::quote(thread) + "}"); return;
            }
            Peer::Subscription subscription;
            subscription.fast = interest == "fast"; subscription.cursor = cursor; subscription.generation = randomID();
            subscription.windowed = windowed; subscription.windowVersion = static_cast<uint64_t>(windowVersion);
            subscription.limit = limit;
            subscription.readProgress = json::boolean(object, "readProgress");
            peer.subscriptions[thread] = std::move(subscription);
            peer.enqueue(prefix + "\"kind\":\"subscribed\",\"thread\":" + json::quote(thread) + "}"); return;
        }
        const auto session = stringField(object, "session_id");
        const auto interest = stringField(object, "interest");
        if (!identifier(session) || (interest != "fast" && interest != "slow")) {
            peer.enqueue(prefix + "\"kind\":\"error\",\"code\":\"invalidRequest\"}");
            return;
        }
        peer.session = session;
        peer.fast = interest == "fast";
        peer.dirty = false;
        peer.enqueue(prefix + "\"kind\":\"subscribed\"}");
    } else if (kind == "unsubscribe") {
        const auto thread = stringField(object, "thread");
        if (thread.empty() && std::any_of(peer.subscriptions.begin(), peer.subscriptions.end(), [](const auto& entry) {
                return entry.second.windowed && !entry.second.waiting.empty();
            })) {
            // A successful response is a drain barrier. Do not claim one for
            // multiple worker lanes; callers must drain each exact thread.
            peer.enqueue(prefix + "\"kind\":\"error\",\"code\":\"threadRequired\"}"); return;
        }
        const auto subscription = peer.subscriptions.find(thread);
        if (subscription != peer.subscriptions.end() && subscription->second.windowed && !subscription->second.waiting.empty()) {
            // Drain/cancel the owned read on the same FIFO lane before the
            // unsubscribe response. A following manual page then starts from
            // the last ACK, never an invisible automatic staging transaction.
            json::Object cancel; cancel.string("kind", "window.cancel"); cancel.string("id", id);
            cancel.string("thread", thread); cancel.string("transaction", subscription->second.waiting);
            if (peer.reads.size() >= 4 || !worker.submit({peer.token, cancel.finish(), false, true})) {
                peer.enqueue(prefix + "\"kind\":\"error\",\"code\":\"busy\"}"); return;
            }
            peer.reads[id] = {};
            peer.subscriptions.erase(subscription);
            return;
        }
        if (!thread.empty()) peer.subscriptions.erase(thread);
        else peer.subscriptions.clear();
        peer.session.clear();
        peer.dirty = false;
        peer.enqueue(prefix + "\"kind\":\"ack\"}");
    } else if (kind == "ack") {
        const auto acknowledged = stringField(object, "requestID");
        for (auto& [thread, subscription] : peer.subscriptions) {
            if (subscription.waiting != acknowledged || acknowledged.empty() || subscription.pendingCursor.empty()) continue;
            if (subscription.windowed && !subscription.pendingSummary) continue;
            if (subscription.pendingSummary) subscription.summaryRevision = subscription.pendingCursor;
            else subscription.cursor = subscription.pendingCursor;
            subscription.pendingCursor.clear();
            subscription.waiting.clear(); subscription.ackDeadline = Clock::time_point::max();
        }
    } else if (kind == "resolve" || kind == "inventory" || kind == "bootstrap" || kind == "history" || kind == "updates" || kind == "summary" ||
               kind == "window.read" || kind == "window.ack" || kind == "window.cancel" || kind == "window.release" || kind == "receipt.frontier") {
        if (peer.reads.count(id)) { peer.closed = true; return; }
        const bool control = kind == "window.ack" || kind == "window.cancel" || kind == "window.release" || kind == "receipt.frontier";
        if (peer.reads.size() >= (control ? 4 : 2) || !worker.submit({peer.token, simdjson::minify(object), false, control,
            kind == "window.ack" || kind == "receipt.frontier"})) {
            peer.enqueue(prefix + "\"kind\":\"error\",\"code\":\"busy\"}"); return;
        }
        peer.reads[id] = {stringField(object, "thread"), "", false};
    } else if (kind == "bye") peer.closed = true;
    else peer.enqueue(prefix + "\"kind\":\"error\",\"code\":\"unsupported\"}");
}
}

int runService(const std::string& runtime, int idleMs, int leaseMs, const VersionPin* version) {
    const auto contextScope = providerScopeToken(runtime);
    ::umask(0077);
    if (!ownedDirectory(runtime, true)) return 77;
    const auto lockPath = runtime + "/service.lock";
    int lock = ::open(lockPath.c_str(), O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0600);
    struct stat lockInfo{};
    if (lock < 0) return 77;
    if (::fstat(lock, &lockInfo) || !S_ISREG(lockInfo.st_mode) || lockInfo.st_uid != ::geteuid() ||
        lockInfo.st_nlink != 1) { ::close(lock); return 77; }
    if (::flock(lock, LOCK_EX | LOCK_NB)) { ::close(lock); return 75; }
    const auto clientPath = runtime + "/client.sock";
    const auto hookPath = runtime + "/hooks.sock";
    int clients = listenLocal(clientPath);
    int hooks = clients < 0 ? -1 : listenLocal(hookPath);
    if (clients < 0 || hooks < 0) {
        if (clients >= 0) { ::close(clients); ::unlink(clientPath.c_str()); }
        ::close(lock);
        return 77;
    }
    (void)::signal(SIGPIPE, SIG_IGN);
    (void)::signal(SIGTERM, stop);
    (void)::signal(SIGINT, stop);
    stopping = 0;
    const auto serviceEpoch = epoch();
    ReadWorker worker(serviceEpoch);
    Sources sources;
    uint64_t nextPeer = 0;
    simdjson::dom::parser parser;
    std::vector<Peer> peers;
    peers.reserve(clientLimit + hookLimit);
    auto idleSince = Clock::now();
    bool activeBefore = false;
    size_t firstPeer = 0;
    auto nextPublicationCheck = Clock::now();
    while (!stopping) {
        std::vector<pollfd> descriptors{{clients, POLLIN, 0}, {hooks, POLLIN, 0}};
        bool bufferedWork = false;
        const auto beforePoll = Clock::now();
        if (version && beforePoll >= nextPublicationCheck) {
            if (version->superseded()) break;
            nextPublicationCheck = beforePoll + std::chrono::seconds(1);
        }
        auto wakeAt = beforePoll + std::chrono::seconds(1);
        auto due = [&](Clock::time_point deadline) { wakeAt = std::min(wakeAt, deadline); };
        if (version) due(nextPublicationCheck);
        if (!activeBefore) due(idleSince + std::chrono::milliseconds(idleMs));
        for (const auto& peer : peers)
        {
            due(peer.expires); due(peer.drainDeadline);
            if (peer.dirty) due(peer.nextSlow);
            for (const auto& [thread, waiting] : peer.windows) due(waiting.deadline);
            for (const auto& [thread, subscription] : peer.subscriptions) {
                due(subscription.ackDeadline); due(subscription.previewExpiry);
                if (peer.reads.size() < 2 && subscription.waiting.empty() && !peer.windows.count(thread)) due(subscription.next);
            }
            descriptors.push_back({peer.fd, static_cast<short>((peer.readEnded ? 0 : POLLIN) | (peer.output.empty() ? 0 : POLLOUT)), 0});
            if (peer.input.size() >= 4) {
                uint32_t length{};
                std::memcpy(&length, peer.input.data(), 4);
                bufferedWork |= peer.input.size() >= static_cast<size_t>(ntohl(length)) + 4;
            }
        }
        // Keep peer indexes stable; worker completion wakes this poll instead
        // of imposing a timer tick on every inventory/history page.
        descriptors.push_back({worker.notificationFD(), POLLIN, 0});
        // Socket readiness, worker completion and file-change notifications
        // wake us directly. Idle cards need their actual deadline, not fifty
        // full subscription-map sweeps per second. Retain a 20 ms retry when
        // already-due work was blocked by a bounded queue.
        const auto timeout = wakeAt <= beforePoll ? 20 :
            std::max<int64_t>(1, std::chrono::duration_cast<std::chrono::milliseconds>(wakeAt - beforePoll).count());
        if (::poll(descriptors.data(), descriptors.size(), bufferedWork ? 0 : static_cast<int>(timeout)) < 0 && errno != EINTR) break;
        worker.drainNotifications();
        const auto now = Clock::now();
        for (const auto& handle : worker.takeChanges()) {
            for (auto& peer : peers) {
                auto subscription = peer.subscriptions.find(handle);
                if (subscription != peer.subscriptions.end() && subscription->second.fast) subscription->second.next = now;
            }
        }
        for (auto& result : worker.take()) {
            if (!result.thread.empty() && !result.provider.empty() && !result.sessionID.empty() && sources.size() < 16384) {
                sources[result.thread] = {result.provider, result.sessionID};
            }
            auto found = std::find_if(peers.begin(), peers.end(), [&](const Peer& peer) { return peer.token == result.client && !peer.closed; });
            if (found == peers.end()) continue;
            auto& peer = *found;
            auto pending = peer.reads.find(result.id);
            if (pending == peer.reads.end()) continue;
            const auto ownership = pending->second;
            if (result.pending) {
                if (ownership.automatic) {
                    const auto subscription = peer.subscriptions.find(ownership.thread);
                    if (subscription == peer.subscriptions.end() || subscription->second.generation != ownership.generation) continue;
                }
                for (const auto& frame : result.frames) peer.enqueue(frame);
                continue;
            }
            peer.reads.erase(pending);
            if (result.kind == "window.ack") {
                const auto waiting = peer.windows.find(result.thread);
                const bool ownsPending = waiting == peer.windows.end() || waiting->second.transaction == result.acknowledgedTransaction;
                const bool catchUp = waiting != peer.windows.end() && waiting->second.hasNewer;
                if (ownsPending) peer.windows.erase(result.thread);
                auto subscription = peer.subscriptions.find(result.thread);
                if (ownsPending && subscription != peer.subscriptions.end()) {
                    if (result.failed) peer.subscriptions.erase(subscription);
                    else {
                        auto& state = subscription->second;
                        state.cursor = result.liveCursor; state.windowVersion = result.windowVersion;
                        if (state.waiting == result.acknowledgedTransaction) {
                            state.waiting.clear(); state.pendingCursor.clear(); state.ackDeadline = Clock::time_point::max();
                        }
                        if (catchUp) state.next = now;
                    }
                }
                if (ownsPending && result.failed) {
                    json::Object reset; reset.string("kind", "resyncRequired"); reset.string("thread", result.thread);
                    reset.string("serviceEpoch", serviceEpoch); reset.string("reason", result.code, 128);
                    reset.raw("status", ReadStatus::from(result.code).json()); peer.enqueue(reset.finish());
                }
            } else if (result.kind == "window.cancel" && !result.failed) {
                auto waiting = peer.windows.find(result.thread);
                if (waiting != peer.windows.end() && waiting->second.transaction == result.acknowledgedTransaction) peer.windows.erase(waiting);
                auto subscription = peer.subscriptions.find(result.thread);
                if (subscription != peer.subscriptions.end() && subscription->second.waiting == result.acknowledgedTransaction) {
                    subscription->second.waiting.clear(); subscription->second.pendingCursor.clear();
                    subscription->second.ackDeadline = Clock::time_point::max();
                }
            }
            if (ownership.automatic) {
                auto subscription = peer.subscriptions.find(ownership.thread);
                if (subscription == peer.subscriptions.end() || subscription->second.generation != ownership.generation) continue;
                auto& state = subscription->second;
                if (result.failed) {
                    if (result.code == "windowBusy") { state.waiting.clear(); state.next = now + std::chrono::milliseconds(100); continue; }
                    json::Object message; message.string("kind", "resyncRequired"); message.string("thread", ownership.thread);
                    const bool capacity = result.code == "windowCapacity" || result.code == "windowItemCapacity" ||
                        result.code == "claudeIndexCapacity" || result.code == "codexIndexCapacity" || result.code == "readBudgetExceeded" ||
                        result.code == "jsonlContinuationCapacity" || result.code == "readContinuationTimeout" ||
                        result.code == "codexMemoryBudgetExceeded" || result.code == "codexResponseBudgetExceeded" ||
                        result.code == "codexProcessBudgetExceeded" || result.code == "opencodeReadBudgetExceeded";
                    message.string("serviceEpoch", serviceEpoch); message.string("reason", capacity ? "capacityExceeded" : "canonicalReadFailed");
                    message.string("code", result.code, 128);
                    message.raw("status", ReadStatus::from(result.code).json());
                    peer.enqueue(message.finish()); peer.subscriptions.erase(subscription); continue;
                }
                if (result.empty) {
                    state.waiting.clear();
                    // Negotiated progress has a terminal event even when the
                    // canonical source has no new page to publish.
                    if (result.progressRequested) {
                        json::Object completed;
                        completed.string("kind", "read.complete"); completed.string("id", result.id);
                        completed.string("thread", result.thread); completed.string("serviceEpoch", serviceEpoch);
                        peer.enqueue(completed.finish());
                    }
                    continue;
                }
                state.pendingSummary = result.kind == "summary";
                state.pendingCursor = result.liveCursor; state.ackDeadline = now + std::chrono::seconds(30);
            }
            if (result.requiresWindowAck && !result.failed) {
                if (peer.windows.size() >= 16 && !peer.windows.count(result.thread)) { peer.closed = true; continue; }
                peer.windows[result.thread] = {result.id, result.hasNewer, now + std::chrono::seconds(30)};
            }
            for (const auto& frame : result.frames) peer.enqueue(frame);
        }
        for (size_t visited = 0; visited < peers.size(); ++visited) {
            const size_t i = (firstPeer + visited) % peers.size();
            auto& peer = peers[i];
            if (now >= peer.expires || now >= peer.drainDeadline) { peer.closed = true; continue; }
            for (auto waiting = peer.windows.begin(); waiting != peer.windows.end();) {
                if (now < waiting->second.deadline) { ++waiting; continue; }
                json::Object cancel; const auto id = "expire_" + randomID();
                cancel.string("kind", "window.cancel"); cancel.string("id", id);
                cancel.string("thread", waiting->first); cancel.string("transaction", waiting->second.transaction);
                if (peer.reads.size() >= 4 || !worker.submit({peer.token, cancel.finish(), false, true})) { ++waiting; continue; }
                peer.reads[id] = {}; peer.subscriptions.erase(waiting->first);
                json::Object reset; reset.string("kind", "resyncRequired"); reset.string("thread", waiting->first);
                reset.string("serviceEpoch", serviceEpoch); reset.string("reason", "windowAckExpired"); peer.enqueue(reset.finish());
                waiting = peer.windows.erase(waiting);
            }
            for (auto subscription = peer.subscriptions.begin(); subscription != peer.subscriptions.end();) {
                if (now < subscription->second.ackDeadline || peer.windows.count(subscription->first)) { ++subscription; continue; }
                json::Object reset; reset.string("kind", "resyncRequired"); reset.string("thread", subscription->first);
                reset.string("serviceEpoch", serviceEpoch); reset.string("reason", "subscriptionAckExpired"); peer.enqueue(reset.finish());
                subscription = peer.subscriptions.erase(subscription);
            }
            if (descriptors[i + 2].revents & (POLLERR | POLLNVAL)) peer.closed = true;
            if (!peer.readEnded && (descriptors[i + 2].revents & (POLLIN | POLLHUP))) {
                std::array<char, 8192> bytes;
                const auto count = ::read(peer.fd, bytes.data(), std::min(bytes.size(), frameLimit + 4 - peer.input.size()));
                if (count > 0) peer.input.append(bytes.data(), static_cast<size_t>(count));
                else if (!count) {
                    peer.readEnded = true;
                    peer.drainDeadline = now + std::chrono::seconds(2);
                } else if (errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR) peer.closed = true;
            }
            // Process buffered complete frames even without another socket
            // readiness edge. The per-turn budget is fairness, not a stall.
            if (!peer.closed) {
                for (int budget = 0; budget < 4 && peer.input.size() >= 4; ++budget) {
                    uint32_t length{};
                    std::memcpy(&length, peer.input.data(), 4);
                    length = ntohl(length);
                    if (!length || length > frameLimit) { peer.closed = true; break; }
                    if (peer.input.size() < length + 4) break;
                    simdjson::dom::element value;
                    if (parser.parse(peer.input.data() + 4, length).get(value) || !value.is_object()) peer.closed = true;
                    else if (peer.hook) hookMessage(value, peers, serviceEpoch, sources);
                    else request(value, peer, serviceEpoch, contextScope, leaseMs, worker);
                    peer.input.erase(0, length + 4);
                    if (peer.hook) peer.closed = true;
                    if (peer.closed) break;
                }
            }
            if (!peer.closed && (descriptors[i + 2].revents & POLLOUT) && !peer.output.empty()) {
                const auto count = ::write(peer.fd, peer.output.data(), peer.output.size());
                if (count > 0) peer.output.erase(0, static_cast<size_t>(count));
                else if (count < 0 && errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR) peer.closed = true;
            }
            if (!peer.closed && peer.dirty && now >= peer.nextSlow) {
                peer.enqueue("{\"kind\":\"summaryInvalidated\",\"serviceEpoch\":\"" + serviceEpoch + "\"}");
                peer.dirty = false;
                peer.nextSlow = now + std::chrono::seconds(5);
            }
            if (!peer.closed && peer.hello && !peer.hook && !peer.readEnded) {
                auto nextSubscription = peer.subscriptions.upper_bound(peer.lastScheduled);
                for (size_t visitedSubscription = 0; visitedSubscription < peer.subscriptions.size(); ++visitedSubscription) {
                    if (nextSubscription == peer.subscriptions.end()) nextSubscription = peer.subscriptions.begin();
                    auto& [thread, subscription] = *nextSubscription++;
                    if (now >= subscription.previewExpiry) {
                        subscription.previewExpiry = Clock::time_point::max();
                        const auto source = sources.find(thread);
                        if (source != sources.end()) {
                            json::Object event; event.string("hook_event_name", "TesseraHookExpired"); event.string("session_id", source->second.second, 256);
                            json::Object value; value.string("kind", "hookPreview"); value.string("id", "hook_" + randomID());
                            value.string("thread", thread); value.string("serviceEpoch", serviceEpoch); value.raw("event", event.finish());
                            peer.enqueue(value.finish());
                        }
                    }
                    // Timeout cleanup above is thread-scoped. If its control
                    // queue is full, suppress this thread and retry next tick.
                    if (now >= subscription.ackDeadline) continue;
                    if (peer.reads.size() >= 2 || now < subscription.next || !subscription.waiting.empty() || peer.windows.count(thread)) continue;
                    const auto id = "watch_" + randomID();
                    json::Object read; read.string("kind", subscription.fast ? (subscription.windowed ? "window.read" : "updates") : "summary"); read.string("id", id);
                    read.string("thread", thread);
                    read.boolean("readProgress", subscription.readProgress);
                    if (subscription.fast && subscription.windowed) { read.string("operation", "head"); read.number("windowVersion", subscription.windowVersion); read.number("limit", subscription.limit); }
                    if (subscription.fast) read.string("cursor", subscription.cursor);
                    else read.string("revision", subscription.summaryRevision);
                    if (!worker.submit({peer.token, read.finish(), true})) break;
                    peer.reads[id] = {thread, subscription.generation, true}; subscription.waiting = id;
                    peer.lastScheduled = thread;
                    subscription.next = now + std::chrono::milliseconds(subscription.fast ? 500 : 5000);
                }
            }
            if (peer.readEnded && peer.output.empty() && peer.reads.empty()) {
                bool complete = false;
                if (peer.input.size() >= 4) {
                    uint32_t length{};
                    std::memcpy(&length, peer.input.data(), 4);
                    complete = peer.input.size() >= static_cast<size_t>(ntohl(length)) + 4;
                }
                // A partial final frame can never commit. Complete buffered
                // requests and their replies drain before releasing the lease.
                if (!complete) peer.closed = true;
            }
        }
        if (!peers.empty()) firstPeer = (firstPeer + 1) % peers.size();
        size_t queued = 0;
        for (auto& peer : peers) {
            queued += peer.output.size();
            if (queued > globalQueueLimit) { queued -= peer.output.size(); peer.closed = true; }
        }
        peers.erase(std::remove_if(peers.begin(), peers.end(), [&](const Peer& peer) {
            if (!peer.closed) return false;
            // Only accepted client peers submit worker jobs. One-message hook
            // peers must not fill the bounded cancellation queue and crowd out
            // a client's release of its retained windows.
            if (!peer.hook && peer.hello) worker.cancel(peer.token);
            ::close(peer.fd); return true;
        }), peers.end());
        for (size_t listener = 0; listener < 2; ++listener) {
            if (!(descriptors[listener].revents & POLLIN)) continue;
            const bool isHook = listener == 1;
            // Bound accept work too: a hook flood cannot starve client timers.
            for (int budget = 0; budget < 8; ++budget) {
                int fd = ::accept(descriptors[listener].fd, nullptr, nullptr);
                if (fd < 0) break;
                auto count = std::count_if(peers.begin(), peers.end(), [isHook](const Peer& peer) { return peer.hook == isHook; });
                if (static_cast<size_t>(count) >= (isHook ? hookLimit : clientLimit) || !sameUser(fd) || !nonblocking(fd)) {
                    ::close(fd);
                    continue;
                }
                Peer peer{};
                peer.fd = fd;
                peer.token = ++nextPeer;
                peer.hook = isHook;
                peer.expires = now + std::chrono::milliseconds(isHook ? 200 : 2000);
                peers.push_back(std::move(peer));
            }
        }
        const bool active = std::any_of(peers.begin(), peers.end(), [](const Peer& peer) { return !peer.hook && peer.hello; });
        if (!active && activeBefore) idleSince = now;
        activeBefore = active;
        if (!active && now - idleSince >= std::chrono::milliseconds(idleMs)) break;
    }
    for (auto& peer : peers) ::close(peer.fd);
    // Singleton ownership includes all reader work and memory, not just the
    // socket loop. Never let a replacement overlap an in-flight old worker.
    worker.shutdown();
    ::close(hooks);
    ::close(clients);
    // Lock remains held until owned endpoint cleanup is complete.
    if (ownedSocket(hookPath)) ::unlink(hookPath.c_str());
    if (ownedSocket(clientPath)) ::unlink(clientPath.c_str());
    ::close(lock);
    return 0;
}
}
