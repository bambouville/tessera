#include "LocalTransport.h"
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <unistd.h>
#include <fcntl.h>
#include <poll.h>
#include <cerrno>
#include <cstdlib>
#include <cstring>
#include <limits.h>

namespace tessera {
bool ownedDirectory(const std::string& path, bool create) {
    if (path.empty() || path.front() != '/' || path.size() > 2048) return false;
    if (create && ::mkdir(path.c_str(), 0700) && errno != EEXIST) return false;
    char canonical[PATH_MAX];
    struct stat info{};
    // Ownership and type, never mode bits: the owner decides how their own
    // directories are shared, and a umask 0002 host must still work.
    return ::realpath(path.c_str(), canonical) && path == canonical &&
        ::lstat(path.c_str(), &info) == 0 && S_ISDIR(info.st_mode) &&
        info.st_uid == ::geteuid();
}

bool ownedSocket(const std::string& path) {
    if (path.empty() || path.front() != '/' || path.size() >= sizeof(sockaddr_un::sun_path)) return false;
    const auto slash = path.find_last_of('/');
    struct stat info{};
    return slash != 0 && slash != std::string::npos && ownedDirectory(path.substr(0, slash), false) &&
        ::lstat(path.c_str(), &info) == 0 && S_ISSOCK(info.st_mode) &&
        info.st_uid == ::geteuid();
}

bool sameUser(int fd) {
#ifdef __APPLE__
    uid_t uid{};
    gid_t gid{};
    return ::getpeereid(fd, &uid, &gid) == 0 && uid == ::geteuid();
#elif defined(__linux__)
    ucred credentials{};
    socklen_t size = sizeof(credentials);
    return ::getsockopt(fd, SOL_SOCKET, SO_PEERCRED, &credentials, &size) == 0 &&
        size == sizeof(credentials) && credentials.uid == ::geteuid();
#else
    (void)fd;
    return false;
#endif
}

bool nonblocking(int fd) {
    const int flags = ::fcntl(fd, F_GETFL);
    return flags >= 0 && ::fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 &&
        ::fcntl(fd, F_SETFD, FD_CLOEXEC) == 0;
}

int connectLocal(const std::string& path, int timeoutMs) {
    if (!ownedSocket(path)) return -1;
    int fd = ::socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    sockaddr_un address{};
    address.sun_family = AF_UNIX;
    std::memcpy(address.sun_path, path.c_str(), path.size() + 1);
    bool valid = nonblocking(fd);
    if (valid && ::connect(fd, reinterpret_cast<sockaddr*>(&address), sizeof(address))) {
        if (errno != EINPROGRESS) valid = false;
        else {
            pollfd pollItem{fd, POLLOUT, 0};
            int error{};
            socklen_t size = sizeof(error);
            valid = ::poll(&pollItem, 1, timeoutMs) > 0 &&
                ::getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &size) == 0 && error == 0;
        }
    }
    if (valid && sameUser(fd)) return fd;
    ::close(fd);
    return -1;
}

// Caller holds the singleton lock. Never remove a foreign or non-socket object.
int listenLocal(const std::string& path) {
    if (path.size() >= sizeof(sockaddr_un::sun_path)) return -1;
    struct stat existing{};
    if (::lstat(path.c_str(), &existing) == 0) {
        if (!ownedSocket(path) || ::unlink(path.c_str())) return -1;
    } else if (errno != ENOENT) return -1;
    int fd = ::socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    sockaddr_un address{};
    address.sun_family = AF_UNIX;
    std::memcpy(address.sun_path, path.c_str(), path.size() + 1);
    if (nonblocking(fd) && !::bind(fd, reinterpret_cast<sockaddr*>(&address), sizeof(address)) &&
        !::chmod(path.c_str(), 0600) && !::listen(fd, 32)) return fd;
    ::close(fd);
    return -1;
}
}
