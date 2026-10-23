#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
version="$(cat VERSION)"
app='build/macos/Build/Products/Release/Proximus.app'
[[ -d "$app" ]] || { echo 'Build the signed Mac release first: bash scripts/build.sh macos' >&2; exit 1; }
[[ "${PROXIMUS_RELEASE_TEAM_ID:-}" =~ ^[A-Z0-9]{10}$ ]] || { echo 'Set PROXIMUS_RELEASE_TEAM_ID to the expected Apple Developer team before packaging.' >&2; exit 1; }
codesign --verify --strict --deep "$app"
signature="$(codesign --display --verbose=4 "$app" 2>&1)"
[[ "$signature" == *"TeamIdentifier=$PROXIMUS_RELEASE_TEAM_ID"* && "$signature" == *'Authority=Developer ID Application:'* ]] || { echo 'The app does not have the expected Developer ID signature.' >&2; exit 1; }
xcrun stapler validate "$app"
spctl --assess --type execute "$app"
mkdir -p dist
archive="dist/Proximus-$version-macOS.zip"
ditto -c -k --sequesterRsrc --keepParent "$app" "$archive"
shasum -a 256 "$archive" > "$archive.sha256"
cargo metadata --locked --format-version 1 > "dist/Proximus-$version-dependencies.json"
python3 - "$archive" "$version" <<'PY'
import hashlib,json,sys
from pathlib import Path
archive=Path(sys.argv[1]);version=sys.argv[2]
manifest={'version':version,'filename':archive.name,'url':f'https://github.com/orithellama/proximus_password_and_keygen_storage/releases/download/v{version}/{archive.name}','sha256':hashlib.file_digest(archive.open('rb'),'sha256').hexdigest(),'bytes':archive.stat().st_size}
archive.with_suffix('.release.json').write_text(json.dumps(manifest,indent=2)+'\n')
PY
echo 'Verified Developer ID signature and notarization. Archive, checksum, and release manifest created in dist/.'
