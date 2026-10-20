#pragma once
#include <string>
namespace tessera {
// A collision-resistant authorization decision never relies on the compact
// directory hash: the full scope witness must match byte-for-byte under lock.
std::string scopedRuntime(const std::string& base, bool create, int lockWaitMs = -1);
// Opaque reconnect lookup, not a credential. SSH + private witness ownership
// supply authority; never accepts a provider path from the client.
void restoreProviderScope(const std::string& base, const std::string& token);
std::string providerScopeToken(const std::string& runtime);
}
