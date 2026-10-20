#pragma once

namespace tessera {
// Observational hook: always returns success and never writes to stdout/stderr.
// No service start, retry spool, or change to provider output/decisions.
int sendHook(const char* socketPath);
}
