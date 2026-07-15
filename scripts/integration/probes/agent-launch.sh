#!/bin/sh

# Disposable real-agent launcher probe. This mirrors the production v8 launch
# boundary: replace the launcher with the real provider without changing job
# control. Only a provider-owned lifecycle hook may publish availability.
set -u

provider="${1:-}"
shift || exit 64
case "$provider" in claude|codex) ;; *) exit 64 ;; esac
[ "$#" -gt 0 ] || exit 64

exec "$@"
