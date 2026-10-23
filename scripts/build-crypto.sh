#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p Vendor build/crypto
# Apply the app deployment targets to C dependencies such as libsecp256k1.
export MACOSX_DEPLOYMENT_TARGET=14.0
export IPHONEOS_DEPLOYMENT_TARGET=17.0
targets=(aarch64-apple-darwin)
if [[ "${1:-}" != "--mac-only" ]]; then
  targets+=(aarch64-apple-ios aarch64-apple-ios-sim)
fi
for target in "${targets[@]}"; do
  cargo build --locked --release --target "$target" -p proximus-crypto
done
args=(-create-xcframework)
for target in "${targets[@]}"; do
  args+=(-library "target/$target/release/libproximus_crypto.a" -headers crates/proximus-crypto/include)
done
if [[ -d Vendor/ProximusCrypto.xcframework ]]; then
  mv Vendor/ProximusCrypto.xcframework "build/crypto/previous-$(date +%s)-$$.xcframework"
fi
xcodebuild "${args[@]}" -output Vendor/ProximusCrypto.xcframework
