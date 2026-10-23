#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
command -v rustup >/dev/null || { echo 'Install Rust with rustup from https://rustup.rs first.' >&2; exit 1; }
command -v python3 >/dev/null || { echo 'Python 3 is required.' >&2; exit 1; }
xcrun --find swift >/dev/null
rustup target add aarch64-apple-darwin aarch64-apple-ios aarch64-apple-ios-sim
bash scripts/build-crypto.sh
python3 scripts/generate-project.py
echo 'Ready. Configure Config/Local.xcconfig and open ProximusPasswords.xcodeproj.'
