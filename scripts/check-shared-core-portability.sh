#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

swift_roots=(
  "$repo_root/Packages/TesseraCore/Sources/TesseraDomainCore"
  "$repo_root/Packages/TesseraCore/Sources/TesseraProtocolCore"
  "$repo_root/Packages/TesseraCore/Sources/TesseraTrustCore"
  "$repo_root/Packages/TesseraCore/Sources/TesseraInputCore"
  "$repo_root/Packages/TesseraCore/Sources/TesseraSessionCore"
  "$repo_root/Packages/TesseraCore/Sources/TesseraPairingCore"
  "$repo_root/Packages/TesseraCore/Sources/TesseraBootstrapCore"
  "$repo_root/Packages/TesseraCore/Sources/TesseraEnrollmentCore"
  "$repo_root/Packages/TesseraCore/Sources/TesseraContinuityCore"
  "$repo_root/Packages/TesseraCore/Sources/TesseraCoreABI"
  "$repo_root/Packages/TesseraCore/Sources/TesseraCore"
  "$repo_root/Packages/TmuxControl/Sources/TmuxControlCore"
)

for root in "${swift_roots[@]}"; do
  if [[ ! -d "$root" ]]; then
    echo "missing portable source root: ${root#"$repo_root/"}" >&2
    exit 1
  fi
done

input_core_root="$repo_root/Packages/TesseraCore/Sources/TesseraInputCore"
if [[ ! -d "$input_core_root" ]]; then
  echo "missing portable input target: ${input_core_root#"$repo_root/"}" >&2
  exit 1
fi
if ! rg -q 'library\(name: "TesseraInputCore"' "$repo_root/Packages/TesseraCore/Package.swift"; then
  echo "TesseraInputCore is not exported as a package product" >&2
  exit 1
fi

apple_continuity_root="$repo_root/Packages/TesseraCore/Sources/TesseraAppleContinuity"
if [[ ! -d "$apple_continuity_root" ]]; then
  echo "missing shared Apple Continuity target: ${apple_continuity_root#"$repo_root/"}" >&2
  exit 1
fi
if ! rg -q 'library\(name: "TesseraAppleContinuity"' \
    "$repo_root/Packages/TesseraCore/Package.swift"; then
  echo "TesseraAppleContinuity is not exported as a package product" >&2
  exit 1
fi
swift_import_prefix='^[[:space:]]*(?:(?:@[[:alnum:]_]+(?:\([^)]*\))?|public|internal|package|private|fileprivate)[[:space:]]+)*import[[:space:]]+'
forbidden_modules='(SwiftUI|UIKit|AppKit|SwiftData|StoreKit|Security|LocalAuthentication|Network|UserNotifications|GameController)'
if rg -n --pcre2 --glob '*.swift' \
    "${swift_import_prefix}${forbidden_modules}(?:[[:space:]]|$)" \
    "$apple_continuity_root"; then
  echo "shared Apple Continuity target exceeds its Foundation-only adapter boundary" >&2
  exit 1
fi
if rg -n 'TesseraAppleContinuity' \
    "$repo_root/Packages/TesseraCore/Sources/TesseraCore/TesseraCore.swift"; then
  echo "portable TesseraCore umbrella must not export TesseraAppleContinuity" >&2
  exit 1
fi
if rg -n 'TesseraAppleContinuity' \
    "$repo_root/Packages/SharedPlatformImportSmoke/Sources/SharedPlatformImportSmoke"; then
  echo "Android-cross-compiled import smoke must not import TesseraAppleContinuity" >&2
  exit 1
fi

forbidden_imports="${swift_import_prefix}${forbidden_modules}(?:[[:space:]]|$)"
if rg -n --pcre2 --glob '*.swift' "$forbidden_imports" "${swift_roots[@]}"; then
  echo "portable Swift targets contain forbidden platform imports" >&2
  exit 1
fi

if rg -n --pcre2 --glob '*.swift' \
    'String[[:space:]]*\([[:space:]]*localized:|NSLocalizedString[[:space:]]*\(|LocalizedStringResource|LocalizedError|var[[:space:]]+errorDescription[[:space:]]*:' \
    "${swift_roots[@]}"; then
  echo "portable Swift targets contain platform-localized error text" >&2
  exit 1
fi

abi_root="$repo_root/Packages/TesseraCore/Sources/TesseraCoreABI"
if rg -n --glob '*.swift' '(@Observable|ObservableObject|AsyncStream|(^|[[:space:]])actor[[:space:]])' "$abi_root"; then
  echo "the language-neutral ABI exposes a Swift runtime/presentation primitive" >&2
  exit 1
fi

mosh_abi_root="$repo_root/Packages/MoshBridge/Sources/MoshCABI"
if [[ ! -d "$mosh_abi_root" ]]; then
  echo "missing portable Mosh C ABI source root" >&2
  exit 1
fi
if rg -n '#[[:space:]]*(import|include)[[:space:]]*[<\"](Foundation|UIKit|AppKit|Security)' "$mosh_abi_root"; then
  echo "Mosh C ABI contains an Apple framework dependency" >&2
  exit 1
fi

echo "shared-core portability checks passed"
