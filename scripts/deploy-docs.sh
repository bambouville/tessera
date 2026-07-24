#!/bin/bash
# Builds the Tessera docs and deploys them through the sibling bambousite
# checkout. Manual equivalent of .github/workflows/docs.yml — handy for the
# first publish or when the Action is unavailable.
#
# Usage:  scripts/deploy-docs.sh
# Override the bambousite location with BAMBOUSITE_ROOT=/path/to/bambousite.
set -euo pipefail

TESSERA_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BAMBOUSITE_ROOT="${BAMBOUSITE_ROOT:-$TESSERA_ROOT/../bambousite}"

echo "==> building docs"
cd "$TESSERA_ROOT/docs/site"
npm ci --no-fund --no-audit
node build.mjs

echo "==> syncing into $BAMBOUSITE_ROOT/site/docs"
mkdir -p "$BAMBOUSITE_ROOT/site/docs"
rsync -a --delete "$TESSERA_ROOT/docs/site/dist/" "$BAMBOUSITE_ROOT/site/docs/"

echo "==> deploying bambousite to Cloudflare"
cd "$BAMBOUSITE_ROOT"
npx --yes wrangler@4 deploy

echo "==> done — https://bambouville.com/docs/"
