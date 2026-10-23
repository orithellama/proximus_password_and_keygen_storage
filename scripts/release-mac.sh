#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
# Builds, Developer ID exports, notarizes, and packages. Publication is a separate command.
python3 scripts/archive-apple.py macos
python3 scripts/package-mac.py --app build/distribution/macos/Proximus.app
python3 scripts/prepare-release-notes.py
