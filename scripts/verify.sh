#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
export CLANG_MODULE_CACHE_PATH="$PWD/.cache/clang"
export SWIFT_MODULECACHE_PATH="$PWD/.cache/swift-modules"
export GOCACHE="$PWD/.cache/go"
export GOMODCACHE="$PWD/.cache/go-mod"
cargo fmt --all --check
cargo clippy --locked --all-targets -- -D warnings
cargo test --locked
[[ -d Vendor/ProximusCrypto.xcframework ]] || bash scripts/build-crypto.sh
xcrun swift test --scratch-path .build/tests --cache-path .cache/swift --disable-sandbox
(
    cd services
    go vet ./...
    go test -race ./...
)
python3 scripts/check-release.py
if [[ "${1:-}" == '--apple' ]]; then
    bash scripts/build.sh macos --unsigned
    bash scripts/build.sh ios --unsigned
fi
