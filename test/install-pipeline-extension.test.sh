#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

HOME="$TEST_ROOT/home" "$REPO_ROOT/install.sh" "$REPO_ROOT" --extension-only >/dev/null

PIPELINE_DIR="$TEST_ROOT/home/.copilot/extensions/ralph-pipeline"

node -e "import('${PIPELINE_DIR}/lib/promote-ready.mjs')"

if ! grep -q '>Promote to ready</button>' "$PIPELINE_DIR/renderer.mjs"; then
  echo "FAIL: installed pipeline renderer does not expose the one-tap control"
  exit 1
fi

echo "PASS: installed pipeline extension loads with one-tap promotion"
