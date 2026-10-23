#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
version="$(cat VERSION)"
app='build/macos/Build/Products/Release/Proximus Passwords.app'
[[ -d "$app" ]] || { echo 'Build the signed Mac release first: bash scripts/build.sh macos' >&2; exit 1; }
codesign --verify --strict --deep "$app"
mkdir -p dist
ditto -c -k --sequesterRsrc --keepParent "$app" "dist/Proximus-Passwords-$version-macOS.zip"
shasum -a 256 "dist/Proximus-Passwords-$version-macOS.zip" > "dist/Proximus-Passwords-$version-macOS.zip.sha256"
cargo metadata --locked --format-version 1 > "dist/Proximus-Passwords-$version-dependencies.json"
echo 'Archive and SHA-256 checksum created in dist/. Submit the signed archive for Apple notarization before public distribution.'
