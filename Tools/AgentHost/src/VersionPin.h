#pragma once
#include <algorithm>
#include <cstdlib>
#include <fcntl.h>
#include <limits.h>
#include <stdexcept>
#include <string>
#include <sys/file.h>
#include <sys/stat.h>
#include <unistd.h>

namespace tessera {
// Services are launched by Relay using the resolved, immutable digest path.
// Keep that artifact pinned for the entire service lifetime; installer GC
// takes an exclusive nonblocking flock before removing an obsolete version.
class VersionPin {
public:
    explicit VersionPin(const char* executable) {
        char resolved[PATH_MAX];
        if (!::realpath(executable, resolved)) throw std::runtime_error("versionMissing");
        const std::string path(resolved);
        const auto slash = path.rfind('/');
        if (slash == std::string::npos) return;
        const auto parent = path.substr(0, slash);
        const auto directory = parent.substr(parent.rfind('/') + 1);
        if (directory != "agent-host-versions") return; // Unpackaged development binary.
        const auto digest = path.substr(slash + 1);
        if (digest.size() != 64 || !std::all_of(digest.begin(), digest.end(), [](char c) {
                return (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f');
            })) throw std::runtime_error("versionIdentity");
        descriptor_ = ::open(resolved, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK);
        struct stat info{}, named{};
        if (descriptor_ < 0 || ::flock(descriptor_, LOCK_SH | LOCK_NB) ||
            ::fstat(descriptor_, &info) || ::lstat(resolved, &named) ||
            info.st_dev != named.st_dev || info.st_ino != named.st_ino || !S_ISREG(info.st_mode) ||
            info.st_uid != ::geteuid() || info.st_nlink != 1 || !(info.st_mode & S_IXUSR)) {
            if (descriptor_ >= 0) ::close(descriptor_);
            descriptor_ = -1;
            throw std::runtime_error("versionUnavailable");
        }
        root_ = parent.substr(0, parent.rfind('/'));
        digest_ = digest;
    }
    ~VersionPin() { if (descriptor_ >= 0) ::close(descriptor_); }
    VersionPin(const VersionPin&) = delete;
    VersionPin& operator=(const VersionPin&) = delete;

    // Publication is an atomic symlink swap by the installer. Only a valid
    // owner-published executable target is a handover request; missing or
    // partial publications must not interrupt an otherwise healthy service.
    // Mode bits are never a criterion: the owner decides them.
    bool superseded() const {
        if (descriptor_ < 0) return false;
        for (const auto& directory : {root_, root_ + "/agent-host-versions"}) {
            struct stat info{};
            if (::lstat(directory.c_str(), &info) || !S_ISDIR(info.st_mode) || info.st_uid != ::geteuid()) return false;
        }
        const auto publication = root_ + "/tessera-agent-host";
        struct stat link{};
        if (::lstat(publication.c_str(), &link) || !S_ISLNK(link.st_mode) ||
            link.st_uid != ::geteuid()) return false;
        char bytes[128];
        const auto count = ::readlink(publication.c_str(), bytes, sizeof(bytes));
        if (count <= 0 || count >= static_cast<ssize_t>(sizeof(bytes))) return false;
        const std::string target(bytes, static_cast<size_t>(count));
        const std::string prefix = "agent-host-versions/";
        if (target.size() != prefix.size() + 64 || target.compare(0, prefix.size(), prefix) ||
            !std::all_of(target.begin() + prefix.size(), target.end(), [](char c) {
                return (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f');
            }) || target.substr(prefix.size()) == digest_) return false;
        struct stat artifact{};
        return !::lstat((root_ + "/" + target).c_str(), &artifact) && S_ISREG(artifact.st_mode) &&
            artifact.st_uid == ::geteuid() && artifact.st_nlink == 1 && (artifact.st_mode & S_IXUSR);
    }
private:
    int descriptor_ = -1;
    std::string root_, digest_;
};
}
