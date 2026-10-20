#include "FileWakeups.h"
#include <algorithm>
#include <array>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>
#ifdef __APPLE__
#include <sys/event.h>
#else
#include <sys/inotify.h>
#endif

namespace tessera {
FileWakeups::FileWakeups() {
#ifdef __APPLE__
    queue_ = ::kqueue();
    if (queue_ >= 0) ::fcntl(queue_, F_SETFD, FD_CLOEXEC);
#else
    queue_ = ::inotify_init1(IN_NONBLOCK | IN_CLOEXEC);
#endif
}
FileWakeups::~FileWakeups() {
    while (!watches_.empty()) remove(watches_.begin()->first);
    if (queue_ >= 0) ::close(queue_);
}
void FileWakeups::remove(const std::string& handle) {
    const auto found = watches_.find(handle);
    if (found == watches_.end()) return;
#ifndef __APPLE__
    const int key = found->second.key;
    const auto aliases = std::count_if(watches_.begin(), watches_.end(),
        [key](const auto& entry) { return entry.second.key == key; });
    if (aliases == 1) ::inotify_rm_watch(queue_, key);
#endif
    ::close(found->second.descriptor); watches_.erase(found);
}
void FileWakeups::watch(const std::string& handle, int fd) {
    if (fd < 0) return;
    if (queue_ < 0) { ::close(fd); return; }
    const auto found = watches_.find(handle);
    if (found != watches_.end()) {
        struct stat before{}, after{};
        if (!::fstat(found->second.descriptor, &before) && !::fstat(fd, &after) &&
            before.st_dev == after.st_dev && before.st_ino == after.st_ino) { ::close(fd); return; }
        remove(handle);
        order_.erase(std::remove(order_.begin(), order_.end(), handle), order_.end());
    }
    while (order_.size() >= 128) { remove(order_.front()); order_.pop_front(); }
    int key = -1;
#ifdef __APPLE__
    struct kevent event;
    EV_SET(&event, fd, EVFILT_VNODE, EV_ADD | EV_CLEAR,
        NOTE_WRITE | NOTE_EXTEND | NOTE_ATTRIB | NOTE_RENAME | NOTE_DELETE | NOTE_REVOKE, 0, nullptr);
    if (!::kevent(queue_, &event, 1, nullptr, 0, nullptr)) key = fd;
#else
    // Watch the already-authorized open inode, not a second path traversal.
    const auto path = "/proc/self/fd/" + std::to_string(fd);
    key = ::inotify_add_watch(queue_, path.c_str(), IN_MODIFY | IN_ATTRIB | IN_MOVE_SELF | IN_DELETE_SELF);
#endif
    if (key < 0) { ::close(fd); return; }
    watches_[handle] = {fd, key}; order_.push_back(handle);
}
std::vector<std::string> FileWakeups::take() {
    std::vector<std::string> result;
    if (queue_ < 0) return result;
    auto note = [&](int key) {
        for (const auto& [handle, watch] : watches_) if (key < 0 || watch.key == key) {
            if (std::find(result.begin(), result.end(), handle) == result.end()) result.push_back(handle);
        }
    };
#ifdef __APPLE__
    std::array<struct kevent, 128> events{};
    struct timespec timeout{};
    const int count = ::kevent(queue_, nullptr, 0, events.data(), events.size(), &timeout);
    for (int index = 0; index < count; ++index) note(static_cast<int>(events[index].ident));
#else
    alignas(struct inotify_event) std::array<char, 32768> bytes{};
    const auto count = ::read(queue_, bytes.data(), bytes.size());
    for (ssize_t offset = 0; offset + static_cast<ssize_t>(sizeof(struct inotify_event)) <= count;) {
        const auto* event = reinterpret_cast<const struct inotify_event*>(bytes.data() + offset);
        note((event->mask & IN_Q_OVERFLOW) ? -1 : event->wd);
        offset += sizeof(struct inotify_event) + event->len;
    }
#endif
    return result;
}
}
