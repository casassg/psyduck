#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

echo "Building and running in debug mode..."
swift run --package-path "$ROOT" gh-prs
