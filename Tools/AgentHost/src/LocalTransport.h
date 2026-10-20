#pragma once
#include <string>

namespace tessera {
class VersionPin;
bool ownedDirectory(const std::string& path, bool create);
bool ownedSocket(const std::string& path);
bool sameUser(int descriptor);
bool nonblocking(int descriptor);
int connectLocal(const std::string& path, int timeoutMs);
int listenLocal(const std::string& path);
int runService(const std::string& runtime, int idleMs, int leaseMs, const VersionPin* version = nullptr);
int runRelay(const std::string& runtime, const char* executable, const std::string& initial = {}, int idleMs = 30000,
    bool attachOnly = false);
}
