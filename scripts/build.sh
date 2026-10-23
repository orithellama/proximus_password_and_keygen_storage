#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
platform="${1:-macos}"
case "$platform" in
    macos) scheme=ProximusPasswords-macOS; destination='generic/platform=macOS' ;;
    local) scheme=ProximusPasswords-macOS; destination='generic/platform=macOS' ;;
    ios) scheme=ProximusPasswords-iOS; destination='generic/platform=iOS' ;;
    simulator) scheme=ProximusPasswords-iOS; destination='generic/platform=iOS Simulator' ;;
    *) echo 'Usage: bash scripts/build.sh [local|macos|ios|simulator] [--unsigned]' >&2; exit 1 ;;
esac
[[ -d Vendor/ProximusCrypto.xcframework ]] || bash scripts/build-crypto.sh
python3 scripts/generate-project.py
revision="$(git rev-parse HEAD)"
dirty=false
[[ -z "$(git status --porcelain --untracked-files=normal)" ]] || dirty=true
options=("PROXIMUS_SOURCE_REVISION=$revision" "PROXIMUS_SOURCE_DIRTY=$dirty")
if [[ "${2:-}" == '--unsigned' ]]; then options+=(CODE_SIGNING_ALLOWED=NO); fi
if [[ "$platform" == local ]]; then options+=(CODE_SIGNING_ALLOWED=NO DEVELOPMENT_TEAM=); fi
xcodebuild -project ProximusPasswords.xcodeproj -scheme "$scheme" \
    -configuration Release -destination "$destination" \
    -derivedDataPath "build/$platform" "${options[@]}" build
if [[ "$platform" == local ]]; then
    app="build/local/Build/Products/Release/Proximus.app"
    # Local builds do not register an unprovisioned credential-provider extension.
    if [[ -d "$app/Contents/PlugIns/ProximusAutoFill.appex" ]]; then
        mv "$app/Contents/PlugIns/ProximusAutoFill.appex" "build/local/ProximusAutoFill-unprovisioned-$(date +%s).appex"
    fi
    codesign --force --sign - --options runtime "$app"
    codesign --verify --strict "$app"
    echo "Local Mac application: $app"
fi
