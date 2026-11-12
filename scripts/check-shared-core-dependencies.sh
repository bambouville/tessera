#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
core_resolved="$repo_root/Packages/TesseraCore/Package.resolved"
smoke_resolved="$repo_root/Packages/SharedPlatformImportSmoke/Package.resolved"
sbom="$repo_root/docs/refactor/shared-platform-sbom.spdx.json"

check_resolved() {
  jq -e '
    .version == 3
    and (.pins | length) == 4
    and ([.pins[].identity] | sort) == ["swift-asn1", "swift-cmark", "swift-crypto", "swift-markdown"]
    and any(.pins[];
      .identity == "swift-crypto"
      and .kind == "remoteSourceControl"
      and .location == "https://github.com/apple/swift-crypto.git"
      and .state.version == "3.15.1"
      and .state.revision == "95ba0316a9b733e92bb6b071255ff46263bbe7dc")
    and any(.pins[];
      .identity == "swift-asn1"
      and .kind == "remoteSourceControl"
      and .location == "https://github.com/apple/swift-asn1.git"
      and .state.version == "1.7.1"
      and .state.revision == "a9a5efd40eaf558a2bcd48d64b1d1646be686008")
    and any(.pins[];
      .identity == "swift-cmark"
      and .kind == "remoteSourceControl"
      and .location == "https://github.com/swiftlang/swift-cmark.git"
      and .state.version == "0.8.0"
      and .state.revision == "924936d0427cb25a61169739a7660230bffa6ea6")
    and any(.pins[];
      .identity == "swift-markdown"
      and .kind == "remoteSourceControl"
      and .location == "https://github.com/swiftlang/swift-markdown.git"
      and .state.version == "0.8.0"
      and .state.revision == "3c6f9523da3a1ec2fd829673e472d95b8097a3b8")
  ' "$1" >/dev/null
}

check_resolved "$core_resolved"
check_resolved "$smoke_resolved"

check_git_checkout() {
  local path="$1"
  local expected_revision="$2"
  local relative_path="${path#"$repo_root/"}"
  local index_entry
  index_entry="$(git -C "$repo_root" ls-files -s -- "$relative_path")"
  [[ "$index_entry" == "160000 $expected_revision 0"$'\t'"$relative_path" ]]
  [[ "$(git -C "$path" rev-parse HEAD)" == "$expected_revision" ]]
  [[ -z "$(git -C "$path" status --porcelain --untracked-files=all)" ]]
}

check_dependency_checkout() {
  local path="$1"
  local expected_revision="$2"
  local license_file="$3"
  local expected_license_sha256="$4"
  [[ -d "$path/.git" || -f "$path/.git" ]]
  [[ "$(git -C "$path" rev-parse HEAD)" == "$expected_revision" ]]
  [[ -z "$(git -C "$path" status --porcelain --untracked-files=all)" ]]
  [[ "$(shasum -a 256 "$path/$license_file" | awk '{print $1}')" \
    == "$expected_license_sha256" ]]
}

check_license_sha256() {
  local path="$1"
  local expected="$2"
  [[ "$(shasum -a 256 "$path" | awk '{print $1}')" == "$expected" ]]
}

check_git_checkout \
  "$repo_root/Packages/MoshBridge/Vendor/mosh" \
  "64bea12b2ec55fc0a5f995ab2fe42ce219549806"
check_git_checkout \
  "$repo_root/Packages/MoshBridge/Vendor/protobuf" \
  "f0dc78d7e6e331b8c6bb2d5283e06aa26883ca7c"

# The release command runs package tests before this gate, so SwiftPM's exact
# resolved checkouts must be present. Verify the consumed trees and license
# texts, not only the literals copied into Package.resolved and the SBOM.
check_dependency_checkout \
  "$repo_root/Packages/TesseraCore/.build/checkouts/swift-crypto" \
  "95ba0316a9b733e92bb6b071255ff46263bbe7dc" \
  LICENSE.txt \
  "cfc7749b96f63bd31c3c42b5c471bf756814053e847c10f3eb003417bc523d30"
check_dependency_checkout \
  "$repo_root/Packages/TesseraCore/.build/checkouts/swift-asn1" \
  "a9a5efd40eaf558a2bcd48d64b1d1646be686008" \
  LICENSE.txt \
  "8c6db340475136df3c1201d458fa5755698eace76e510471ecc9d857d6083dac"
check_dependency_checkout \
  "$repo_root/Packages/TesseraCore/.build/checkouts/swift-cmark" \
  "924936d0427cb25a61169739a7660230bffa6ea6" \
  COPYING \
  "c22e885f33b821bddb24cf007145e5540655b6c0f403e49e6c76a93c28e6d9a9"
check_dependency_checkout \
  "$repo_root/Packages/TesseraCore/.build/checkouts/swift-markdown" \
  "3c6f9523da3a1ec2fd829673e472d95b8097a3b8" \
  LICENSE.txt \
  "167beb36f181bd163c93c6feb45c68e5f9462fe1af55b278f7bfd1df20e673a3"

test -f "$repo_root/LICENSE"
test -f "$repo_root/COPYING.iOS"
test -f "$repo_root/Packages/MoshBridge/Vendor/mosh/COPYING"
test -f "$repo_root/Packages/MoshBridge/Vendor/mosh/COPYING.iOS"
test -f "$repo_root/Packages/MoshBridge/Vendor/protobuf/LICENSE"

check_license_sha256 "$repo_root/LICENSE" \
  "8ceb4b9ee5adedde47b31e975c1d90c73ad27b6b165a1dcd80c7c545eb65b903"
check_license_sha256 "$repo_root/COPYING.iOS" \
  "42da7d1f612a72b68a76f3185291cf1246aeef8da2a1a6914731ab9932df8637"
check_license_sha256 "$repo_root/Packages/MoshBridge/Vendor/mosh/COPYING" \
  "8ceb4b9ee5adedde47b31e975c1d90c73ad27b6b165a1dcd80c7c545eb65b903"
check_license_sha256 "$repo_root/Packages/MoshBridge/Vendor/mosh/COPYING.iOS" \
  "8042495ddc8d99b883335d53552554eccf825fc1f0ba487d0f8e6656baaa8199"
check_license_sha256 "$repo_root/Packages/MoshBridge/Vendor/protobuf/LICENSE" \
  "6e5e117324afd944dcf67f36cf329843bc1a92229a8cd9bb573d7a83130fea7d"

jq -e '
  .spdxVersion == "SPDX-2.3"
  and ([.packages[].SPDXID] | unique | length) == (.packages | length)
  and ([.packages[].name] | sort) == ([
    "OpenSSL",
    "Tessera shared platform core",
    "mosh",
    "protobuf",
    "swift-asn1",
    "swift-cmark",
    "swift-crypto",
    "swift-markdown"
  ] | sort)
  and any(.packages[];
    .name == "swift-crypto"
    and .versionInfo == "3.15.1"
    and .licenseDeclared == "Apache-2.0"
    and .checksums == [{"algorithm":"SHA1","checksumValue":"95ba0316a9b733e92bb6b071255ff46263bbe7dc"}])
  and any(.packages[];
    .name == "swift-asn1"
    and .versionInfo == "1.7.1"
    and .licenseDeclared == "Apache-2.0"
    and .checksums == [{"algorithm":"SHA1","checksumValue":"a9a5efd40eaf558a2bcd48d64b1d1646be686008"}])
  and any(.packages[];
    .name == "swift-cmark"
    and .versionInfo == "0.8.0"
    and .licenseDeclared == "BSD-2-Clause AND MIT"
    and .checksums == [{"algorithm":"SHA1","checksumValue":"924936d0427cb25a61169739a7660230bffa6ea6"}])
  and any(.packages[];
    .name == "swift-markdown"
    and .versionInfo == "0.8.0"
    and .licenseDeclared == "Apache-2.0 WITH Swift-exception"
    and .checksums == [{"algorithm":"SHA1","checksumValue":"3c6f9523da3a1ec2fd829673e472d95b8097a3b8"}])
  and any(.packages[];
    .name == "mosh"
    and .versionInfo == "1.4.0-5-g64bea12"
    and .licenseDeclared == "GPL-3.0-or-later WITH cryptsetup-OpenSSL-exception"
    and .checksums == [{"algorithm":"SHA1","checksumValue":"64bea12b2ec55fc0a5f995ab2fe42ce219549806"}])
  and any(.packages[];
    .name == "protobuf"
    and .versionInfo == "21.12"
    and .licenseDeclared == "BSD-3-Clause"
    and .checksums == [{"algorithm":"SHA1","checksumValue":"f0dc78d7e6e331b8c6bb2d5283e06aa26883ca7c"}])
  and any(.packages[];
    .name == "OpenSSL"
    and .versionInfo == "3.5.7"
    and .licenseDeclared == "Apache-2.0"
    and .primaryPackagePurpose == "LIBRARY"
    and .checksums == [{"algorithm":"SHA256","checksumValue":"a8c0d28a529ca480f9f36cf5792e2cd21984552a3c8e4aa11a24aa31aeac98e8"}])
  and ([.relationships[] | [.spdxElementId, .relationshipType, .relatedSpdxElement]] | sort) == ([
    ["SPDXRef-Package-TesseraSharedCore", "DEPENDS_ON", "SPDXRef-Package-SwiftCrypto"],
    ["SPDXRef-Package-SwiftCrypto", "DEPENDS_ON", "SPDXRef-Package-SwiftASN1"],
    ["SPDXRef-Package-TesseraSharedCore", "DEPENDS_ON", "SPDXRef-Package-SwiftMarkdown"],
    ["SPDXRef-Package-SwiftMarkdown", "DEPENDS_ON", "SPDXRef-Package-SwiftCmark"],
    ["SPDXRef-Package-TesseraSharedCore", "DEPENDS_ON", "SPDXRef-Package-Mosh"],
    ["SPDXRef-Package-Mosh", "DEPENDS_ON", "SPDXRef-Package-Protobuf"],
    ["SPDXRef-Package-Mosh", "DEPENDS_ON", "SPDXRef-Package-OpenSSL"]
  ] | sort)
' "$sbom" >/dev/null

echo "shared-core dependency, license, and SBOM checks passed"
