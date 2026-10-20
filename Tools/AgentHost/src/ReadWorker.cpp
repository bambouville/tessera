#include "ReadWorker.h"
#include "OpenCodeStore.h"
#include "Json.h"
#include "JsonlReader.h"
#include "ReadStatus.h"
#include <algorithm>
#include <cctype>
#include <limits>
#include <stdexcept>
#include <set>
#include <fcntl.h>
#include <cerrno>
#include <sys/resource.h>
#include <sys/stat.h>
#include <unistd.h>

namespace tessera {
namespace {
std::string codexMetadataReason(const std::string& reason) {
    const bool code = !reason.empty() && reason.size() <= 80 &&
        std::all_of(reason.begin(), reason.end(), [](unsigned char c) { return std::isalnum(c); });
    return code ? reason : "unclassified";
}
std::string codexMetadataReason(const std::exception& error) { return codexMetadataReason(std::string(error.what())); }
}
ReadWorker::ReadWorker(std::string epoch) : epoch_(std::move(epoch)), codex_([this] { return cancelled_.load(); }) {
    catalog_.cancelled = [this] { return cancelled_.load(); };
    if (::pipe(notifications_)) throw std::runtime_error("workerNotificationUnavailable");
    for (int fd : notifications_) {
        if (::fcntl(fd, F_SETFL, O_NONBLOCK) < 0 || ::fcntl(fd, F_SETFD, FD_CLOEXEC) < 0) {
            ::close(notifications_[0]); ::close(notifications_[1]);
            throw std::runtime_error("workerNotificationUnavailable");
        }
    }
    try { thread_ = std::thread([this] { run(); }); }
    catch (...) { ::close(notifications_[0]); ::close(notifications_[1]); throw; }
}
ReadWorker::~ReadWorker() { shutdown(); ::close(notifications_[0]); ::close(notifications_[1]); }
void ReadWorker::notify() {
    // A full nonblocking pipe already represents pending work. Never block the
    // I/O lane on the socket loop, and never consume the notification there.
    const char byte = 1;
    while (::write(notifications_[1], &byte, 1) < 0 && errno == EINTR) {}
}
void ReadWorker::drainNotifications() {
    char bytes[256];
    while (true) {
        auto count = ::read(notifications_[0], bytes, sizeof(bytes));
        if (count > 0 || (count < 0 && errno == EINTR)) continue;
        break;
    }
}
void ReadWorker::shutdown() {
    { std::lock_guard<std::mutex> lock(mutex_); stopped_ = true; cancelled_ = true; jobs_.clear(); }
    changed_.notify_one(); if (thread_.joinable()) thread_.join();
    // The owned native child is part of this singleton's lifetime, including
    // its bounded TERM/KILL grace. Never release the host lock before reaping.
    codex_.shutdown();
}
bool ReadWorker::submit(ReadJob job) {
    std::lock_guard<std::mutex> lock(mutex_);
    // Reserve control admission so a full ordinary-read queue cannot prevent
    // clients from acknowledging/freeing the pages already delivered to them.
    if (outstanding_ >= (job.control ? 16 : 12) || job.request.size() > 65536 || stopped_) return false;
    // One finite observation survives every yielded slice of this job. New
    // jobs receive a fresh token and can observe appends made in the meantime.
    job.observationToken = ++nextObservationToken_;
    if (job.observationToken == 0) job.observationToken = ++nextObservationToken_;
    ++outstanding_;
    // ACKs free retained staging immediately. Cancellation retains FIFO with
    // reads: it must not run before the queued transaction it abandons.
    if (job.urgent) jobs_.insert(std::find_if(jobs_.begin(), jobs_.end(), [](const ReadJob& pending) { return !pending.urgent; }), std::move(job));
    else jobs_.push_back(std::move(job));
    changed_.notify_one(); return true;
}
std::vector<ReadResult> ReadWorker::take() {
    std::lock_guard<std::mutex> lock(mutex_);
    std::vector<ReadResult> result; result.swap(results_);
    outstanding_ -= std::count_if(result.begin(), result.end(), [](const auto& value) { return !value.pending; });
    return result;
}
std::vector<std::string> ReadWorker::takeChanges() {
    std::lock_guard<std::mutex> lock(mutex_);
    std::vector<std::string> result; result.swap(changes_); return result;
}
void ReadWorker::cancel(uint64_t client) {
    std::lock_guard<std::mutex> lock(mutex_);
    if (activeClient_ == client) cancelled_ = true;
    for (auto it = jobs_.begin(); it != jobs_.end();) {
        if (it->client == client) { it = jobs_.erase(it); --outstanding_; } else ++it;
    }
    // At most the bounded peer count can disconnect between worker turns.
    if (cancellations_.size() < 128) cancellations_.push_back(client);
    changed_.notify_one();
}
void ReadWorker::run() {
    JsonlContinuation continuation;
    JsonlContinuation::Scope continuationScope(continuation);
    while (true) {
        ReadJob job;
        {
            std::unique_lock<std::mutex> lock(mutex_);
            changed_.wait_for(lock, std::chrono::milliseconds(100), [&] { return stopped_ || !jobs_.empty() || !cancellations_.empty(); });
            if (stopped_) return;
            for (const auto& handle : wakeups_.take()) {
                if (changes_.size() < 128 && std::find(changes_.begin(), changes_.end(), handle) == changes_.end()) changes_.push_back(handle);
            }
            if (!changes_.empty()) notify();
            for (auto client : cancellations_) {
                inventories_.erase(client);
                for (auto it = native_.begin(); it != native_.end();)
                    if (it->first.first == client) it = native_.erase(it); else ++it;
                for (auto it = windows_.begin(); it != windows_.end();)
                    if (it->first.first == client) it = windows_.erase(it); else ++it;
                for (auto it = nativeReplay_.begin(); it != nativeReplay_.end();)
                    if (it->second.client == client) { nativeReplayBytes_ -= it->second.bytes; it = nativeReplay_.erase(it); }
                    else ++it;
                for (auto it = cursors_.begin(); it != cursors_.end();)
                    if (it->second.client == client) it = cursors_.erase(it); else ++it;
            }
            cancellations_.clear();
            if (jobs_.empty()) {
                cancelled_ = false;
                lock.unlock(); codex_.supervise();
                continue;
            }
            job = std::move(jobs_.front()); jobs_.pop_front();
            activeClient_ = job.client; cancelled_ = false;
            auto pending = job.historyPins;
            for (const auto& queued : jobs_) pending.insert(queued.historyPins.begin(), queued.historyPins.end());
            claudeChains_.pending(pending);
            kimiHistories_.pending(pending);
            codexHistories_.pending(std::move(pending));
        }
        continuation.beginSlice(job.observationToken);
        claudeChains_.beginRead();
        kimiHistories_.beginRead();
        codexHistories_.beginRead();
        if (job.continuationDeadline == std::chrono::steady_clock::time_point{})
            job.continuationDeadline = std::chrono::steady_clock::now() + std::chrono::seconds(30);
        auto result = execute(job);
        std::lock_guard<std::mutex> lock(mutex_);
        activeClient_ = 0;
        if (result.failed && result.code == "readPending" && !cancelled_ && !stopped_ &&
            (continuation.consumed() > 0 || std::chrono::steady_clock::now() < job.continuationDeadline)) {
            // Retain the original request/lease admission and let queued ACKs
            // and other clients run between bounded physical I/O slices.
            job.resumedBytes += continuation.consumed();
            // Advancing work renews the idle budget, not an absolute limit on
            // transcript length. A stuck zero-work continuation still expires.
            const auto now = std::chrono::steady_clock::now();
            if (continuation.consumed() > 0) job.continuationDeadline = now + std::chrono::seconds(30);
            if (result.progressRequested && continuation.consumed() > 0 &&
                (job.progressSequence == 0 || now - job.lastProgress >= std::chrono::milliseconds(250))) {
                ++job.progressSequence; job.lastProgress = now;
                result.pending = true; result.failed = false; result.frames.clear();
                json::Object progress; progress.string("kind", "read.progress"); progress.string("id", result.id);
                progress.string("thread", result.thread); progress.string("serviceEpoch", epoch_);
                progress.string("sequence", std::to_string(job.progressSequence));
                progress.string("bytesRead", std::to_string(job.resumedBytes));
                progress.raw("status", ReadStatus::from("readPending").json());
                result.frames.push_back(progress.finish()); results_.push_back(std::move(result)); notify();
            }
            for (const auto* paths : {&claudeChains_.readPaths(), &kimiHistories_.readPaths(), &codexHistories_.readPaths()})
                job.historyPins.insert(paths->begin(), paths->end());
            // A queued same-client cancel/release is a drain barrier. Yield
            // to ordinary reads and urgent ACKs, but do not move the original
            // transaction behind its cancellation and resurrect it afterward.
            auto barrier = std::find_if(jobs_.begin(), jobs_.end(), [&](const ReadJob& queued) {
                return queued.client == job.client && queued.control && !queued.urgent;
            });
            // Move that client's barrier and its following requests together;
            // a barrier at the front must not starve another client's reads
            // behind it for the entire large-record continuation.
            std::deque<ReadJob> afterBarrier;
            for (auto it = barrier; it != jobs_.end();) {
                if (it->client == job.client && !it->urgent) {
                    afterBarrier.push_back(std::move(*it)); it = jobs_.erase(it);
                } else ++it;
            }
            jobs_.push_back(std::move(job));
            for (auto& queued : afterBarrier) jobs_.push_back(std::move(queued));
            continue;
        }
        results_.push_back(std::move(result));
        notify();
    }
}
std::string ReadWorker::cursor(uint64_t client, const std::string& thread, const std::string& identity,
                               uint64_t position, uint64_t anchor, const std::string& direction,
                               const std::string& providerCursor) {
    while (cursorOrder_.size() >= 4096) { cursors_.erase(cursorOrder_.front()); cursorOrder_.pop_front(); }
    auto token = randomID();
    cursors_[token] = {client, position, anchor, thread, identity, direction, providerCursor};
    cursorOrder_.push_back(token); return token;
}
std::vector<Source> ReadWorker::inventory() {
    const auto now = std::chrono::steady_clock::now();
    if (inventoryRefresh_ > now) return sharedInventory_;
    // The walk keeps no partial state, so it runs outside the read slice.
    // Inside it, a walk longer than a slice reran from the start for every
    // Pi/Kimi header it had not cached yet (88 s on a real host). Headers
    // are bounded reads, and each is cached by its file witness.
    auto sources = [&] { JsonlContinuation::Suspend unsliced; return catalog_.inventory(); }();
    inventoryFallback_.clear();
    // Explicitly include every documented source kind. An empty sourceKinds
    // list means interactive-only in 0.154.0, not all historical sessions.
    // Codex's budget starts after the walk: a walk longer than it skipped
    // Codex's own list on every refresh.
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::milliseconds(1500);
    const auto initialNativeBytes = codex_.bytesRead();
    try {
        for (bool archived : {false, true}) {
            std::string next; std::set<std::string> seen;
            for (size_t page = 0; page < 656; ++page) {
                // Stored first-prompt previews can be very large. Twenty-five
                // rows keep their bounded string projections below the DOM
                // budget without hydrating turns or aggregating a whole store.
                json::Object params; params.number("limit", 25); params.boolean("useStateDbOnly", true);
                params.boolean("archived", archived); params.string("sortKey", "updated_at");
                params.raw("modelProviders", "[]");
                params.raw("sourceKinds", "[\"cli\",\"vscode\",\"exec\",\"appServer\",\"subAgent\",\"subAgentReview\",\"subAgentCompact\",\"subAgentThreadSpawn\",\"subAgentOther\",\"unknown\"]");
                params.optional("cursor", next, 2048);
                const auto consumed = codex_.bytesRead() - initialNativeBytes;
                if (consumed >= 64 * 1024 * 1024) throw std::runtime_error("codexInventoryBudgetExceeded");
                auto raw = codex_.call("thread/list", params.finish(), deadline,
                    static_cast<size_t>(std::min<uint64_t>(16 * 1024 * 1024, 64 * 1024 * 1024 - consumed)));
                simdjson::dom::parser parser; simdjson::dom::element response;
                // Truncated preview text is not used for identity or paths.
                // Their bounded fields are validated separately by Catalog.
                if (parser.parse(raw).get(response) || !json::get(response, "data").is_array())
                    throw std::runtime_error("codexInventoryMalformed");
                for (const auto row : simdjson::dom::array(json::get(response, "data").get_array().value())) {
                    const auto path = json::text(row, "path");
                    const auto modified = json::integer(row, "updatedAt");
                    auto source = catalog_.identifyCodex(json::text(row, "id"), path, static_cast<uint64_t>(std::max<int64_t>(0, modified)));
                    const auto found = std::find_if(sources.begin(), sources.end(), [&](const Source& item) {
                        return item.handle == source.handle || (item.provider == "codex" && item.sessionID == source.sessionID);
                    });
                    if (found != sources.end()) *found = source;
                    else if (sources.size() < 16384) sources.push_back(std::move(source));
                    else throw std::runtime_error("catalogBudgetExceeded");
                }
                next = json::text(response, "nextCursor");
                if (next.empty()) break;
                // The streaming projection retains 16 KiB of raw string.
                // Six-byte Unicode escapes must never turn a clipped opaque
                // cursor into an apparently valid token below this bound.
                if (next.size() > 2048 || !seen.insert(next).second || page == 655) throw std::runtime_error("codexInventoryBudgetExceeded");
            }
        }
    } catch (const std::exception& error) {
        if (cancelled_.load()) throw;
        inventoryFallback_ = error.what();
    }
    std::sort(sources.begin(), sources.end(), [](const Source& left, const Source& right) {
        return left.modified != right.modified ? left.modified > right.modified : left.handle < right.handle;
    });
    sharedInventory_ = sources; inventoryRefresh_ = std::chrono::steady_clock::now() + std::chrono::seconds(5);
    return sources;
}
ReadResult ReadWorker::execute(const ReadJob& job) {
    ReadResult result; result.client = job.client;
    auto envelope = [&](const std::string& kind) {
        json::Object value;
        value.string("id", result.id, 128); value.string("serviceEpoch", epoch_, 128);
        value.string("kind", kind, 64); value.optional("thread", result.thread, 128);
        return value;
    };
    try {
        simdjson::dom::parser parser; simdjson::dom::element request;
        if (parser.parse(job.request).get(request) || !request.is_object()) throw std::runtime_error("invalidRequest");
        result.id = json::text(request, "id"); result.kind = json::text(request, "kind");
        result.thread = json::text(request, "thread");
        result.progressRequested = json::boolean(request, "readProgress") &&
            (result.kind == "window.read" || result.kind == "summary" || result.kind == "bootstrap" ||
             result.kind == "history" || result.kind == "updates");
        const auto token = json::text(request, "cursor");
        if (result.kind == "resolve") {
            const auto nativeID = json::text(request, "nativeSessionID");
            Source source;
            if (!nativeID.empty() && json::text(request, "provider") == "opencode") {
                if (!json::text(request, "transcriptRef").empty()) throw std::runtime_error("sourceNotAuthorized");
                source = catalog_.resolveOpenCode(nativeID);
            } else if (!nativeID.empty()) {
                if (json::text(request, "provider") != "codex" || !json::text(request, "transcriptRef").empty())
                    throw std::runtime_error("sourceNotAuthorized");
                if (nativeID.size() != 36 || nativeID.find_first_not_of("0123456789abcdef-") != std::string::npos)
                    throw std::runtime_error("sourceNotAuthorized");
                try { source = catalog_.resolveCodex(nativeID); }
                catch (const std::runtime_error& error) {
                    if (std::string(error.what()) != "sourceNotAuthorized") throw;
                    // thread/list in 0.154.0 omits empty-preview histories,
                    // including populated subagents. A known lifecycle ID is
                    // only a hint: the authenticated read server must confirm
                    // its exact identity without hydrating history first.
                    json::Object params; params.string("threadId", nativeID); params.boolean("includeTurns", false);
                    auto raw = codex_.call("thread/read", params.finish(),
                        std::chrono::steady_clock::now() + std::chrono::milliseconds(1500), 16 * 1024 * 1024);
                    simdjson::dom::parser nativeParser; simdjson::dom::element response;
                    if (nativeParser.parse(raw).get(response)) throw std::runtime_error("codexMetadataMalformed");
                    const auto thread = json::get(response, "thread"), turns = json::get(thread, "turns");
                    if (json::text(thread, "id") != nativeID || !turns.is_array() || turns.get_array().value().size())
                        throw std::runtime_error("sourceNotAuthorized");
                    source = catalog_.identifyCodex(nativeID, json::text(thread, "path"),
                        static_cast<uint64_t>(std::max<int64_t>(0, json::integer(thread, "updatedAt"))));
                }
            } else if (json::text(request, "provider") == "opencode")
                source = catalog_.resolveOpenCode(json::openCodeSessionLocator(json::text(request, "transcriptRef")));
            else source = catalog_.resolve(json::text(request, "provider"), json::transcriptPath(json::text(request, "transcriptRef")));
            result.thread = source.handle;
            result.provider = source.provider; result.sessionID = source.sessionID;
            auto reply = envelope("resolved"); reply.string("provider", source.provider);
            reply.string("sessionID", source.sessionID, 256); result.frames.push_back(reply.finish());
            return result;
        }
        if (result.kind == "inventory") {
            int64_t requestedLimit = 100;
            if (!json::get(request, "limit").is_null() &&
                (json::get(request, "limit").get_int64().get(requestedLimit) || requestedLimit < 1 || requestedLimit > 500))
                throw std::runtime_error("invalidRequest");
            size_t offset = 0;
            if (token.empty()) {
                if (inventories_.size() >= 8 && !inventories_.count(job.client)) throw std::runtime_error("busy");
                inventories_[job.client] = {inventory(), randomID()};
            }
            auto snapshot = inventories_.find(job.client);
            if (snapshot == inventories_.end()) throw std::runtime_error("cursorExpired");
            auto& inventory = snapshot->second.sources;
            const auto& generation = snapshot->second.generation;
            if (!token.empty()) {
                auto found = cursors_.find(token);
                if (found == cursors_.end() || found->second.client != job.client || found->second.direction != "inventory" ||
                    found->second.identity != generation) throw std::runtime_error("cursorExpired");
                offset = found->second.position;
            }
            if (offset > inventory.size()) throw std::runtime_error("invalidCursor");
            result.frames.push_back(envelope("inventory.begin").finish());
            size_t wireBytes = result.frames.back().size() + 4;
            // Amortize round trips without enlarging either client's receive
            // byte budget. Long/escaped paths shorten a page independently of
            // its row limit; leave room for the cursor/end envelope.
            constexpr size_t inventoryWireLimit = 192 * 1024, endReserve = 4096;
            const auto end = std::min(offset + static_cast<size_t>(requestedLimit), inventory.size());
            for (; offset < end; ++offset) {
                const auto& source = inventory[offset];
                auto reply = envelope("inventory.thread"); reply.string("thread", source.handle);
                reply.string("provider", source.provider); reply.string("sessionID", source.sessionID, 256);
                reply.string("transcriptRef", source.provider == "opencode" ? "" : source.path, 2048);
                if ((source.provider == "codex" && source.path.empty()) || source.provider == "opencode") reply.string("nativeSessionID", source.sessionID, 256);
                reply.number("bytes", source.bytes);
                reply.number("modified", source.modified);
                auto encoded = reply.finish();
                if (wireBytes + encoded.size() + 4 + endReserve > inventoryWireLimit) {
                    if (result.frames.size() == 1) throw std::runtime_error("capacityExceeded");
                    break;
                }
                wireBytes += encoded.size() + 4;
                result.frames.push_back(std::move(encoded));
            }
            auto reply = envelope("inventory.end"); reply.boolean("hasMore", offset < inventory.size());
            reply.optional("fallbackReason", inventoryFallback_, 128);
            if (offset < inventory.size()) reply.string("cursor", cursor(job.client, "", generation, offset, 0, "inventory"));
            result.frames.push_back(reply.finish()); return result;
        }
        auto source = catalog_.source(result.thread);
        result.provider = source.provider; result.sessionID = source.sessionID;
        if (result.kind == "receipt.frontier") {
            const auto action = json::text(request, "actionID");
            if (action.empty() || action.size() > 128 || action.find_first_not_of(
                "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-") != std::string::npos)
                throw std::runtime_error("invalidRequest");
            json::Object frontier; frontier.number("version", 1); frontier.string("actionID", action);
            frontier.string("serviceEpoch", epoch_); frontier.string("provider", source.provider);
            frontier.string("providerSessionID", source.sessionID, 256);
            bool observed = false;
            // This read never enters history indexing, changes a window cursor,
            // or starts an App Server. The current authorized raw EOF includes
            // an unfinished tail, which cannot later count as new submission.
            if (!source.path.empty() && source.provider != "opencode") {
                int descriptor = -1;
                try {
                    descriptor = catalog_.open(source);
                    struct stat info{};
                    if (!::fstat(descriptor, &info) && S_ISREG(info.st_mode) && info.st_size >= 0) {
                        frontier.string("sourceIdentity", "jsonl:" + std::to_string(info.st_dev) + ":" + std::to_string(info.st_ino));
                        frontier.string("sourceEnd", std::to_string(static_cast<uint64_t>(info.st_size)));
                        observed = true;
                    }
                } catch (...) { /* Missing receipt authority must not block terminal delivery. */ }
                if (descriptor >= 0) ::close(descriptor);
            }
            frontier.string("consistency", observed ? "observedPrefix" : "unavailable");
            auto reply = envelope("receipt.frontier"); reply.raw("frontier", frontier.finish());
            result.frames.push_back(reply.finish()); return result;
        }
        if (result.kind == "window.release") {
            const auto key = std::make_pair(job.client, result.thread);
            auto found = windows_.find(key);
            if (found != windows_.end()) {
                found->second.expire();
                if (found->second.pending()) throw std::runtime_error("windowBusy");
                windows_.erase(found);
            }
            result.frames.push_back(envelope("window.released").finish()); return result;
        }
        if (result.kind != "window.ack" && result.kind != "window.cancel" && !source.path.empty()) {
            try { wakeups_.watch(source.handle, source.provider == "opencode" ?
                OpenCodeStore::wakeupDescriptor(source.path) : catalog_.open(source)); }
            catch (...) { if (source.provider != "codex") throw; }
        }
        if (result.kind == "window.read" || result.kind == "summary" || result.kind == "bootstrap" ||
            result.kind == "history" || result.kind == "updates") {
            std::set<std::string> pinnedChains;
            for (const auto& entry : windows_) if (!entry.second.sourcePath().empty()) pinnedChains.insert(entry.second.sourcePath());
            claudeChains_.pin(pinnedChains); kimiHistories_.pin(pinnedChains); codexHistories_.pin(std::move(pinnedChains));
        }
        if (result.kind == "window.read" || result.kind == "window.ack" || result.kind == "window.cancel") {
            const auto key = std::make_pair(job.client, result.thread);
            int64_t version = 0;
            if (result.kind != "window.cancel" &&
                (json::get(request, "windowVersion").get_int64().get(version) || version < 0))
                throw std::runtime_error("invalidWindowVersion");
            auto found = windows_.find(key);
            if (result.kind == "window.cancel" && found == windows_.end()) {
                result.acknowledgedTransaction = json::text(request, "transaction");
                auto ack = envelope("window.cancelled"); ack.string("transaction", result.acknowledgedTransaction);
                result.frames.push_back(ack.finish()); return result;
            }
            if (found == windows_.end()) {
                if (result.kind != "window.read" || json::text(request, "operation") != "bootstrap") throw std::runtime_error("windowMissing");
                const auto owned = std::count_if(windows_.begin(), windows_.end(), [&](const auto& entry) { return entry.first.first == job.client; });
                if (windows_.size() >= PageWindow::maximumServiceWindows || static_cast<size_t>(owned) >= PageWindow::maximumClientWindows)
                    throw std::runtime_error("windowCapacity");
                found = windows_.try_emplace(key).first;
            }
            auto& window = found->second;
            if (result.kind == "window.cancel") {
                result.acknowledgedTransaction = json::text(request, "transaction");
                window.cancel(result.acknowledgedTransaction);
                auto ack = envelope("window.cancelled"); ack.string("transaction", json::text(request, "transaction"));
                result.frames.push_back(ack.finish()); return result;
            }
            if (result.kind == "window.ack") {
                result.acknowledgedTransaction = json::text(request, "transaction");
                const auto values = json::get(request, "viewport");
                if (!values.is_array()) throw std::runtime_error("invalidWindowAck");
                if (values.get_array().value().size() > PageWindow::maximumViewportSegments) throw std::runtime_error("windowCapacity");
                std::vector<std::string> retained;
                for (const auto value : simdjson::dom::array(values.get_array().value())) {
                    std::string_view id;
                    if (value.get_string().get(id) || id.empty() || id.size() > 128) throw std::runtime_error("invalidWindowAck");
                    retained.emplace_back(id);
                }
                window.acknowledge(result.acknowledgedTransaction, static_cast<uint64_t>(version), retained, json::text(request, "head"));
                result.liveCursor = window.liveCursor(); result.windowVersion = window.version();
                auto ack = envelope("window.acked"); ack.string("liveCursor", result.liveCursor); ack.number("windowVersion", result.windowVersion);
                result.frames.push_back(ack.finish()); return result;
            }
            const auto requestedLimit = json::get(request, "limit").is_null() ? 100 : json::integer(request, "limit");
            if (requestedLimit <= 0 || requestedLimit > 100) throw std::runtime_error("invalidRequest");
            WindowPageReader reader(catalog_, codex_, [this] { return cancelled_.load(); }, &claudeChains_, job.automatic, &codexHistories_, &kimiHistories_);
            // The service-wide retained budget: committed plus staged pages of
            // every client's windows. This lane is the only writer, so the
            // total already includes every earlier unacknowledged read. A
            // staging past its ACK deadline can no longer commit: drop it here
            // even if its client's late ACK already cleared the service timer.
            size_t serviceBytes = 0;
            for (auto& entry : windows_) { entry.second.expire(); serviceBytes += entry.second.footprint(); }
            WindowReply page;
            try {
                page = window.read(reader, codex_, source, result.id, json::text(request, "operation"), token,
                    static_cast<uint64_t>(version), static_cast<size_t>(requestedLimit), job.automatic, serviceBytes);
            } catch (...) {
                if (!window.version() && !window.pending()) windows_.erase(key);
                throw;
            }
            result.empty = page.unchanged; result.liveCursor = page.liveCursor; result.windowVersion = page.version;
            result.requiresWindowAck = !page.unchanged; result.hasNewer = page.hasNewer;
            if (page.unchanged) return result;
            try {
                const auto operation = page.lane == "bootstrap" ? "bootstrap" :
                    (page.lane == "before" || page.lane == "after") ? "history" : "updates";
                auto begin = envelope("page.begin"); begin.string("sourceIdentity", page.source); begin.optional("from", token);
                begin.string("operation", operation); result.frames.push_back(begin.finish());
                std::sort(page.records.begin(), page.records.end(), [](const auto& left, const auto& right) { return left.start < right.start; });
                for (const auto& record : page.records) {
                    auto value = envelope("page.record"); value.string("recordID", page.native ? record.value.providerID : page.source + ":" + std::to_string(record.start), 256);
                    value.number("order", record.start); value.number("revision", record.revision); value.raw("record", record.value.json);
                    value.string("sourceType", record.value.sourceType, 256);
                    value.string("disposition", record.value.disposition, 32);
                    value.boolean("visible", record.value.visible);
                    if (record.sourceByteOffset != UINT64_MAX) value.number("sourceOffset", record.sourceByteOffset);
                    if (!record.receiptSourceIdentity.empty() && record.receiptSourceOffset != UINT64_MAX) {
                        value.string("receiptSourceIdentity", record.receiptSourceIdentity, 256);
                        value.string("receiptSourceOffset", std::to_string(record.receiptSourceOffset));
                    }
                    result.frames.push_back(value.finish());
                }
                auto end = envelope("page.end"); end.string("backend", source.provider == "opencode" ? "opencode-sqlite" : page.native ? "codex-appserver" : "jsonl"); end.optional("fallbackReason", page.fallback, 128);
                OpenCodeStore::CodexMetadata pageMetadata;
                std::string pageMetadataIssue, pageMetadataReason;
                if (page.canonicalCodex && !page.native && page.lane != "before") {
                    auto cached = codexPageMetadata_.find(source.handle);
                    const auto now = std::chrono::steady_clock::now();
                    if (page.lane == "bootstrap" || cached == codexPageMetadata_.end() ||
                        now - cached->second.refreshed >= std::chrono::seconds(5)) {
                        CodexPageMetadata fresh;
                        try {
                            fresh.value = catalog_.codexMetadata(source);
                            // The name still stands when only the opening
                            // prompt could not be read.
                            if (!fresh.value.promptReason.empty()) {
                                fresh.issue = "codexOpeningPromptUnavailable";
                                fresh.reason = codexMetadataReason(fresh.value.promptReason);
                            }
                        }
                        catch (const std::exception& error) {
                            if (cancelled_.load() || std::string(error.what()) == "cancelled") throw;
                            fresh.issue = "codexTitleUnavailable";
                            fresh.reason = codexMetadataReason(error);
                        }
                        fresh.refreshed = std::chrono::steady_clock::now();
                        if (cached == codexPageMetadata_.end()) {
                            while (codexPageMetadataOrder_.size() >= 128) {
                                codexPageMetadata_.erase(codexPageMetadataOrder_.front());
                                codexPageMetadataOrder_.pop_front();
                            }
                            codexPageMetadataOrder_.push_back(source.handle);
                        }
                        codexPageMetadata_[source.handle] = std::move(fresh);
                        cached = codexPageMetadata_.find(source.handle);
                    }
                    pageMetadata = cached->second.value;
                    pageMetadataIssue = cached->second.issue;
                    pageMetadataReason = cached->second.reason;
                }
                json::Object descriptor; descriptor.string("lane", page.lane); descriptor.number("version", page.version);
                if (!page.partitions.empty()) {
                    std::vector<std::string> partitions;
                    for (const auto& part : page.partitions) {
                        json::Object value; value.string("original", part.original); value.string("id", part.id);
                        value.string("before", part.before); value.string("after", part.after);
                        value.number("offset", part.offset); value.number("count", part.count);
                        value.boolean("hasOlder", part.hasOlder); value.boolean("hasNewer", part.hasNewer);
                        partitions.push_back(value.finish());
                    }
                    descriptor.raw("partitions", json::array(partitions));
                }
                if (page.segment) {
                    descriptor.string("segmentID", page.segment->id); descriptor.string("before", page.segment->before); descriptor.string("after", page.segment->after);
                    descriptor.boolean("hasOlder", page.segment->hasOlder); descriptor.boolean("hasNewer", page.segment->hasNewer);
                }
                end.raw("window", descriptor.finish());
                if (std::string(operation) != "updates") {
                    end.boolean("hasOlder", page.segment && page.segment->hasOlder);
                    if (page.segment && page.segment->hasOlder) end.string("historyCursor", page.segment->before);
                }
                if (std::string(operation) != "history") {
                    end.string("liveCursor", page.liveCursor); end.boolean("hasNewer", page.hasNewer);
                    if (!page.native) end.number("sourceEnd", page.sourceEnd);
                }
                end.number("records", page.records.size()); end.number("bytesRead", page.bytesRead + job.resumedBytes);
                rusage usage{}; ::getrusage(RUSAGE_SELF, &usage);
#ifdef __APPLE__
                end.number("hostPeakRSSBytes", usage.ru_maxrss);
#else
                end.number("hostPeakRSSBytes", usage.ru_maxrss * 1024);
#endif
                end.number("codexSampledPeakRSSBytes", codex_.peakResidentBytes());
                size_t bytes = 0;
                for (const auto& frame : result.frames) { if (frame.size() > 65536) throw std::runtime_error("windowWireCapacity"); bytes += frame.size(); }
                auto encoded = end.finish();
                const auto fits = [&](const std::string& candidate) {
                    return candidate.size() <= 65536 && bytes + candidate.size() <= 262144;
                };
                const auto withFields = [&](const std::string& base, const std::string& fields) {
                    return base.substr(0, base.size() - 1) + "," + fields.substr(1);
                };
                if (!pageMetadataIssue.empty()) {
                    json::Object fields;
                    fields.string("metadataIssue", pageMetadataIssue, 128);
                    fields.string("metadataReason", pageMetadataReason, 128);
                    const auto candidate = withFields(encoded, fields.finish());
                    if (fits(candidate)) encoded = candidate;
                }
                if (!pageMetadata.name.empty() || !pageMetadata.openingPrompt.empty()) {
                    auto name = pageMetadata.name, prompt = pageMetadata.openingPrompt;
                    // JSON escaping can multiply the wire size of a bounded
                    // UTF-8 value. Keep canonical records/ACKs intact and
                    // shorten this optional field to the remaining envelope.
                    for (;;) {
                        json::Object fields, metadata;
                        metadata.optional("nativeTitle", name, 512);
                        metadata.optional("openingPrompt", prompt, 4096);
                        fields.raw("metadata", metadata.finish());
                        const auto candidate = withFields(encoded, fields.finish());
                        if (fits(candidate)) { encoded = candidate; break; }
                        auto& value = !prompt.empty() ? prompt : name;
                        if (value.empty()) break;
                        size_t limit = value.size() / 2;
                        while (limit && (static_cast<unsigned char>(value[limit]) & 0xc0) == 0x80) --limit;
                        value.resize(limit);
                        if (name.empty() && prompt.empty()) break;
                    }
                }
                if (!fits(encoded)) throw std::runtime_error("windowWireCapacity");
                result.frames.push_back(std::move(encoded));
            } catch (...) { window.cancel(result.id); throw; }
            return result;
        }
        if (result.kind == "summary") {
            WindowPageReader sourceReader(catalog_, codex_, [this] { return cancelled_.load(); },
                &claudeChains_, job.automatic, &codexHistories_, &kimiHistories_);
            if (source.provider == "opencode") {
                auto found = summaries_.find(source.handle);
                const auto now = std::chrono::steady_clock::now();
                if (found == summaries_.end() || found->second.expires <= now) {
                    uint64_t revision = 0;
                    const auto page = sourceReader.read(source, "", std::nullopt, false, 16, revision);
                    OpenCodeStore database(source.path, [this] { return cancelled_.load(); });
                    const auto metadata = database.metadata(source.sessionID);
                    if (database.identity(source.sessionID) != page.segment.source) throw std::runtime_error("sourceChanged");
                    json::Object title; title.string("type", "session-title"); title.string("title", metadata.title, 2048);
                    std::vector<std::string> records{title.finish()}; size_t bytes = records.front().size();
                    for (auto it = page.segment.records.rbegin(); it != page.segment.records.rend(); ++it) {
                        if (bytes + it->value.json.size() > 56 * 1024) break;
                        records.insert(records.begin(), it->value.json); bytes += it->value.json.size();
                    }
                    const auto encoded = json::array(records);
                    const auto version = found != summaries_.end() && found->second.records == encoded && found->second.witness == page.segment.source ? found->second.revision : randomID();
                    if (found == summaries_.end()) {
                        while (summaryOrder_.size() >= 128) { summaries_.erase(summaryOrder_.front()); summaryOrder_.pop_front(); }
                        summaryOrder_.push_back(source.handle);
                    }
                    summaries_[source.handle] = {page.segment.source, version, encoded, metadata.modified, now + std::chrono::milliseconds(500)};
                    found = summaries_.find(source.handle);
                }
                const auto& summary = found->second;
                result.empty = json::text(request, "revision") == summary.revision; result.liveCursor = summary.revision;
                auto value = envelope("summary"); value.string("revision", summary.revision); value.number("modified", summary.modified);
                value.raw("records", summary.records); result.frames.push_back(value.finish()); return result;
            }
            uint64_t headerBytes = 0;
            const bool canonical = sourceReader.canonicalCodexAvailable(source, headerBytes);
            if (source.provider == "codex" && !canonical) {
                try {
                    auto found = summaries_.find(source.handle);
                    const auto now = std::chrono::steady_clock::now();
                    if (found == summaries_.end() || found->second.expires <= now) {
                        json::Object params; params.string("threadId", source.sessionID, 256); params.boolean("includeTurns", false);
                        auto raw = codex_.call("thread/read", params.finish(), now + std::chrono::milliseconds(1500), 16 * 1024 * 1024);
                        simdjson::dom::parser parser; simdjson::dom::element response;
                        if (parser.parse(raw).get(response)) throw std::runtime_error("codexSummaryMalformed");
                        const auto thread = json::get(response, "thread");
                        if (json::text(thread, "id") != source.sessionID || !json::get(thread, "turns").is_array() ||
                            json::get(thread, "turns").get_array().value().size()) throw std::runtime_error("codexSummaryMalformed");
                        json::Object title; title.string("type", "session-title"); title.optional("title", json::text(thread, "name"), 512);
                        json::Object metadata; metadata.string("type", "session_meta");
                        const auto cwd = json::text(thread, "cwd");
                        metadata.optional("project", cwd.substr(cwd.find_last_of('/') == std::string::npos ? 0 : cwd.find_last_of('/') + 1), 256);
                        metadata.optional("branch", json::text(json::get(thread, "gitInfo"), "branch"), 512);
                        // Thread.preview is usually the FIRST user prompt,
                        // not the latest message. Do not overwrite a card's
                        // canonical recent preview or infer runtime status.
                        auto records = "[" + title.finish() + "," + metadata.finish() + "]";
                        const auto modified = static_cast<uint64_t>(std::max<int64_t>(0, json::integer(thread, "updatedAt")));
                        const auto revision = found != summaries_.end() && found->second.records == records && found->second.modified == modified
                            ? found->second.revision : randomID();
                        if (found == summaries_.end()) {
                            while (summaryOrder_.size() >= 128) { summaries_.erase(summaryOrder_.front()); summaryOrder_.pop_front(); }
                            summaryOrder_.push_back(source.handle);
                        }
                        // This is coalescing, not another polling interval.
                        // A five-second cache can just miss a five-second
                        // subscription tick and postpone an update to ten.
                        summaries_[source.handle] = {"native", revision, std::move(records), modified, now + std::chrono::milliseconds(500)};
                        found = summaries_.find(source.handle);
                    }
                    const auto& summary = found->second;
                    result.empty = json::text(request, "revision") == summary.revision; result.liveCursor = summary.revision;
                    auto value = envelope("summary"); value.string("revision", summary.revision); value.number("modified", summary.modified);
                    value.raw("records", summary.records); result.frames.push_back(value.finish()); return result;
                } catch (...) { if (source.path.empty() || cancelled_.load()) throw; }
            }
            const int fd = catalog_.open(source);
            struct stat info{};
            if (::fstat(fd, &info)) { ::close(fd); throw std::runtime_error("sourceMissing"); }
#ifdef __APPLE__
            const auto modified = info.st_mtimespec; const auto changed = info.st_ctimespec;
#else
            const auto modified = info.st_mtim; const auto changed = info.st_ctim;
#endif
            const auto witness = std::to_string(info.st_dev) + ":" + std::to_string(info.st_ino) + ":" +
                std::to_string(info.st_size) + ":" + std::to_string(modified.tv_sec) + ":" + std::to_string(modified.tv_nsec) + ":" +
                std::to_string(changed.tv_sec) + ":" + std::to_string(changed.tv_nsec);
            auto found = summaries_.find(source.handle);
            JsonlReader reader(source.path, source.provider, fd, [this] { return cancelled_.load(); });
            uint64_t summaryReadBytes = headerBytes + job.resumedBytes;
            std::string metadataIssue, metadataReason;
            if (canonical || found == summaries_.end() || found->second.witness != witness) {
                std::vector<PositionedRecord> selected;
                if (canonical || source.provider == "pi" || source.provider == "kimi") {
                    // Preview selection must share history's ownership,
                    // lineage and replay rules. Raw tail prose can belong to
                    // an ancestor or excluded model context. The shared capped
                    // metadata index reuses bootstrap/append work; worker I/O
                    // continuations still bound cold summary scheduling.
                    uint64_t revision = 0;
                    auto page = sourceReader.read(source, "", std::nullopt, false, canonical ? 15 : 16, revision);
                    summaryReadBytes += page.bytesRead;
                    selected = std::move(page.segment.records);
                } else selected = reader.page(std::numeric_limits<uint64_t>::max(), false, 16).records;
                reader.validateSnapshot();
                std::string records;
                // Keep newest metadata/prose. Summary bytes never become
                // canonical messages, page cursors, or submission receipts.
                for (auto it = selected.rbegin(); it != selected.rend(); ++it) {
                    if (records.size() + it->value.json.size() + 1 > 56 * 1024) break;
                    records = it->value.json + (records.empty() ? "" : ",") + records;
                }
                if (canonical) {
                    // Codex names live in its metadata store, not JSONL. This
                    // optional card metadata cannot invalidate canonical text.
                    try {
                        const auto name = catalog_.codexTitle(source);
                        if (!name.empty()) {
                            json::Object title; title.string("type", "session-title"); title.string("title", name, 2048);
                            records = title.finish() + (records.empty() ? "" : ",") + records;
                        }
                    } catch (const std::exception& error) {
                        if (cancelled_.load()) throw;
                        metadataIssue = "codexTitleUnavailable";
                        // The store's own code (opencodeDatabaseUnavailable,
                        // sourceNotAuthorized, ...) is what makes a silent
                        // generated title diagnosable; never free text.
                        metadataReason = codexMetadataReason(error);
                    }
                }
                if (found == summaries_.end()) {
                    while (summaryOrder_.size() >= 128) { summaries_.erase(summaryOrder_.front()); summaryOrder_.pop_front(); }
                    summaryOrder_.push_back(source.handle);
                }
                const auto encoded = "[" + records + "]";
                const auto revision = found != summaries_.end() && found->second.witness == witness &&
                    found->second.records == encoded ? found->second.revision : randomID();
                summaries_[source.handle] = {witness, revision, encoded, static_cast<uint64_t>(std::max<time_t>(0, modified.tv_sec))};
                found = summaries_.find(source.handle);
            } else reader.validateSnapshot();
            const auto& summary = found->second;
            result.empty = json::text(request, "revision") == summary.revision;
            result.liveCursor = summary.revision; // ACK-owned summary witness, not a canonical cursor.
            auto value = envelope("summary"); value.string("revision", summary.revision);
            value.optional("metadataIssue", metadataIssue, 128);
            value.optional("metadataReason", metadataReason, 128);
            value.number("bytesRead", summaryReadBytes + reader.bytesRead());
            value.number("modified", summary.modified); value.raw("records", summary.records);
            result.frames.push_back(value.finish()); return result;
        }
        uint64_t position = std::numeric_limits<uint64_t>::max();
        const bool forward = result.kind == "updates";
        if (result.kind != "bootstrap" && result.kind != "history" && !forward) throw std::runtime_error("unsupported");
        if (result.kind == "bootstrap" && !token.empty()) throw std::runtime_error("invalidCursor");
        const Cursor* witness = nullptr;
        if (result.kind != "bootstrap") {
            auto found = cursors_.find(token);
            if (found == cursors_.end() || found->second.client != job.client || found->second.thread != result.thread ||
                found->second.direction != (forward ? "live" : "history")) throw std::runtime_error("cursorExpired");
            witness = &found->second;
            position = witness->position;
        }
        const auto requestedLimit = json::get(request, "limit").is_null() ? 100 : json::integer(request, "limit");
        if (requestedLimit <= 0 || requestedLimit > 100) throw std::runtime_error("invalidRequest");
        JsonlPage page;
        std::string olderProviderCursor, liveProviderCursor;
        std::string fallbackReason;
        uint64_t olderAnchor = 0, liveAnchor = 0;
        uint64_t sourceEnd = 0;
        bool native = source.provider == "codex" && (!witness || witness->identity.rfind("codex-appserver:", 0) == 0);
        uint64_t headerBytes = 0;
        WindowPageReader canonicalReader(catalog_, codex_, [this] { return cancelled_.load(); }, &claudeChains_, false, &codexHistories_, &kimiHistories_);
        if (canonicalReader.canonicalCodexAvailable(source, headerBytes)) {
            if (witness && native) throw std::runtime_error("sourceChanged");
            // Canonical revisions need the ACK-owned window revision sweep.
            // An ordinal-only stateless live cursor cannot prove no changes.
            if (forward) throw std::runtime_error("windowSubscriptionRequired");
            native = false;
        }
        const auto nativeKey = std::make_pair(job.client, result.thread);
        if (native) {
            try {
                auto found = native_.find(nativeKey);
                if (result.kind == "bootstrap") {
                    if (found == native_.end() && native_.size() >= 16) throw std::runtime_error("busy");
                    NativeState next;
                    next.identity = "codex-appserver:" + randomID();
                    native_[nativeKey] = std::move(next); found = native_.find(nativeKey);
                }
                if (found == native_.end() || (witness && witness->identity != found->second.identity)) throw std::runtime_error("cursorExpired");
                CodexPage value;
                const auto replay = nativeReplay_.find(token);
                if (replay != nativeReplay_.end()) value = replay->second.page;
                else {
                    value = found->second.reader.read(codex_, source.sessionID, result.kind,
                        witness ? witness->providerCursor : "", position, static_cast<size_t>(requestedLimit));
                    if (!token.empty() && !value.page.records.empty()) {
                        const auto bytes = value.page.json().size() + value.before.size() + value.after.size() + 1024;
                        while (!nativeReplayOrder_.empty() && (nativeReplayOrder_.size() >= 16 || nativeReplayBytes_ + bytes > 2 * 1024 * 1024)) {
                            const auto old = nativeReplayOrder_.front(); nativeReplayOrder_.pop_front();
                            const auto expired = nativeReplay_.find(old);
                            if (expired != nativeReplay_.end()) { nativeReplayBytes_ -= expired->second.bytes; nativeReplay_.erase(expired); }
                            // Without the original delta, this input cursor
                            // cannot safely reconstruct already-read revisions.
                            cursors_.erase(old);
                        }
                        nativeReplay_[token] = {job.client, value, bytes};
                        nativeReplayOrder_.push_back(token); nativeReplayBytes_ += bytes;
                    }
                }
                page = std::move(value.page); page.sourceIdentity = found->second.identity;
                olderProviderCursor = std::move(value.before); liveProviderCursor = std::move(value.after);
            } catch (const std::exception& error) {
                // Backend changes are allowed only at bootstrap. A cursor may
                // never silently change from native item order to byte offsets.
                if (result.kind != "bootstrap" || cancelled_.load()) throw;
                fallbackReason = error.what();
                native_.erase(nativeKey); native = false;
            }
        }
        if (!native) {
            // Search borrows stateless pages from the same branch reader as
            // display. It must not allocate, move or acknowledge a UI window.
            WindowPageReader reader(catalog_, codex_, [this] { return cancelled_.load(); }, &claudeChains_, false, &codexHistories_, &kimiHistories_);
            std::optional<WindowAnchor> anchor;
            if (witness) anchor = WindowAnchor{witness->identity, witness->providerCursor, "", witness->position, witness->anchor, forward, false};
            uint64_t revision = 0;
            auto selected = reader.read(source, witness ? witness->identity : "", anchor, forward,
                static_cast<size_t>(requestedLimit), revision);
            page.sourceIdentity = selected.segment.source;
            page.records = std::move(selected.segment.records);
            page.older = selected.before.position; page.live = selected.after.position;
            page.hasOlder = selected.segment.hasOlder; page.hasNewer = selected.segment.hasNewer;
            page.bytesRead = selected.bytesRead; sourceEnd = selected.sourceEnd;
            olderAnchor = selected.before.fileWitness; liveAnchor = selected.after.fileWitness;
            if (source.provider == "opencode") {
                olderProviderCursor = selected.before.providerCursor; liveProviderCursor = selected.after.providerCursor; native = true;
            }
        }
        result.empty = page.records.empty();
        auto begin = envelope("page.begin"); begin.string("sourceIdentity", page.sourceIdentity, 256);
        begin.optional("from", token, 128);
        begin.string("operation", result.kind); result.frames.push_back(begin.finish());
        for (const auto& record : page.records) {
            auto value = envelope("page.record");
            value.string("recordID", native ? record.value.providerID : page.sourceIdentity + ":" + std::to_string(record.start), 256);
            value.number("order", record.start); value.number("revision", record.revision);
            value.optional("providerRecordID", record.value.providerID, 256); value.optional("parentID", record.value.parentID, 256);
            if (record.sourceByteOffset != UINT64_MAX) value.number("sourceOffset", record.sourceByteOffset);
            if (!record.receiptSourceIdentity.empty() && record.receiptSourceOffset != UINT64_MAX) {
                value.string("receiptSourceIdentity", record.receiptSourceIdentity, 256);
                value.string("receiptSourceOffset", std::to_string(record.receiptSourceOffset));
            }
            value.raw("record", record.value.json); result.frames.push_back(value.finish());
        }
        auto end = envelope("page.end");
        end.string("backend", source.provider == "opencode" ? "opencode-sqlite" : native ? "codex-appserver" : "jsonl");
        end.optional("fallbackReason", fallbackReason, 128);
        // A history response cannot move the live checkpoint; live responses
        // cannot overwrite the independently-owned scroll-back anchor.
        if (!forward) {
            end.boolean("hasOlder", page.hasOlder);
            if (page.hasOlder) end.string("historyCursor", cursor(job.client, result.thread, page.sourceIdentity,
                page.older, olderAnchor, "history", olderProviderCursor));
        }
        if (result.kind != "history") {
            result.liveCursor = forward && page.records.empty() ? token : cursor(job.client, result.thread, page.sourceIdentity,
                page.live, liveAnchor, "live", liveProviderCursor);
            end.string("liveCursor", result.liveCursor); end.boolean("hasNewer", page.hasNewer);
            if (!native) end.number("sourceEnd", sourceEnd);
        }
        end.number("records", page.records.size()); end.number("bytesRead", page.bytesRead + headerBytes + job.resumedBytes);
        rusage usage{}; ::getrusage(RUSAGE_SELF, &usage);
#ifdef __APPLE__
        end.number("hostPeakRSSBytes", usage.ru_maxrss);
#else
        end.number("hostPeakRSSBytes", usage.ru_maxrss * 1024);
#endif
        end.number("codexSampledPeakRSSBytes", codex_.peakResidentBytes());
        result.frames.push_back(end.finish());
    } catch (const std::exception& error) {
        result.failed = true; result.frames.clear();
        result.code = error.what();
        if (result.code == "readPending" && std::chrono::steady_clock::now() >= job.continuationDeadline &&
            (!JsonlContinuation::active() || JsonlContinuation::active()->consumed() == 0))
            result.code = "readContinuationTimeout";
        auto reply = envelope("error"); reply.string("code", result.code, 128);
        reply.raw("status", ReadStatus::from(result.code).json()); result.frames.push_back(reply.finish());
    }
    return result;
}
}
