#include <sys/file.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/stat.h>
#include <cassert>
#include <cstdlib>
#include <filesystem>
#include <string>

static std::string versionPath;
static bool replaceDuringLock = false;
static bool collectDuringLock = false;
static int pinTestFlock(int descriptor, int operation) {
    if (collectDuringLock && (operation & LOCK_SH)) {
        const int collector = ::open(versionPath.c_str(), O_RDONLY);
        assert(collector >= 0);
        assert(::flock(collector, LOCK_EX | LOCK_NB) == 0);
        assert(::unlink(versionPath.c_str()) == 0);
        if (replaceDuringLock) {
            const int replacement = ::open(versionPath.c_str(), O_WRONLY | O_CREAT | O_EXCL, 0700);
            assert(replacement >= 0); ::close(replacement);
        }
        ::close(collector);
    }
    return ::flock(descriptor, operation);
}
#define flock pinTestFlock
#include "VersionPin.h"
#undef flock

int main() {
    char pattern[] = "/tmp/tessera-version-pin-XXXXXX";
    const auto root = ::mkdtemp(pattern); assert(root);
    const auto versions = std::filesystem::path(root) / "agent-host-versions";
    std::filesystem::create_directory(versions);
    versionPath = (versions / std::string(64, 'a')).string();
    for (const bool replacement : {false, true}) {
        const int file = ::open(versionPath.c_str(), O_WRONLY | O_CREAT | O_EXCL, 0700);
        assert(file >= 0); ::close(file);
        collectDuringLock = true; replaceDuringLock = replacement;
        bool rejected = false;
        try { tessera::VersionPin pin(versionPath.c_str()); }
        catch (const std::runtime_error&) { rejected = true; }
        assert(rejected);
        if (replacement) assert(::unlink(versionPath.c_str()) == 0);
    }
    collectDuringLock = false;
    const int file = ::open(versionPath.c_str(), O_RDWR | O_CREAT | O_EXCL, 0700);
    assert(file >= 0);
    { tessera::VersionPin pin(versionPath.c_str()); assert(::flock(file, LOCK_EX | LOCK_NB) != 0); }
    assert(::flock(file, LOCK_EX | LOCK_NB) == 0); ::close(file);
    assert(::chmod(versions.c_str(), 0700) == 0);
    const auto publication = std::filesystem::path(root) / "tessera-agent-host";
    const auto candidate = versions / std::string(64, 'b');
    const auto safeTarget = "agent-host-versions/" + std::string(64, 'b');
    {
        tessera::VersionPin pin(versionPath.c_str());
        assert(!pin.superseded()); // No published install, e.g. a developer build.
        assert(::symlink(("agent-host-versions/" + std::string(64, 'a')).c_str(), publication.c_str()) == 0);
        assert(!pin.superseded()); // Same artifact is not an upgrade.
        assert(::unlink(publication.c_str()) == 0);
        assert(::symlink(safeTarget.c_str(), publication.c_str()) == 0);
        assert(!pin.superseded()); // A missing target must not interrupt clients.
        const int replacement = ::open(candidate.c_str(), O_CREAT | O_EXCL | O_RDWR, 0700);
        assert(replacement >= 0); ::close(replacement);
        assert(pin.superseded());
        // The owner decides the modes of the parent, the versions directory
        // and the artifact (a umask 0002 host writes them group-writable);
        // none of them withholds a handover.
        assert(::chmod(root, 0755) == 0);
        assert(pin.superseded());
        assert(::chmod(root, 0775) == 0);
        assert(pin.superseded());
        assert(::chmod(root, 0700) == 0);
        assert(::chmod(candidate.c_str(), 0775) == 0);
        assert(pin.superseded());
        assert(::chmod(candidate.c_str(), 0700) == 0);
        assert(::chmod(versions.c_str(), 0775) == 0);
        assert(pin.superseded());
        assert(::chmod(versions.c_str(), 0700) == 0);
        assert(::unlink(candidate.c_str()) == 0);
        assert(::symlink(versionPath.c_str(), candidate.c_str()) == 0);
        assert(!pin.superseded()); // The immutable artifact must not be a symlink.
        assert(::unlink(publication.c_str()) == 0);
        assert(::symlink(("agent-host-versions/../" + std::string(64, 'b')).c_str(), publication.c_str()) == 0);
        assert(!pin.superseded()); // No traversal or arbitrary executable.
    }
    std::filesystem::remove_all(root);
}
