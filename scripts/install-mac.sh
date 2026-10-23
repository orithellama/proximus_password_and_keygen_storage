#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export PATH="$HOME/.cargo/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"

fail() { echo "Installation stopped: $*" >&2; exit 1; }
[[ "$(uname -s)" == Darwin && "$(uname -m)" == arm64 ]] || fail 'An Apple silicon Mac is required.'
command -v rustup >/dev/null || fail 'Install Rust from https://rustup.rs, then run this installer again.'
command -v python3 >/dev/null || fail 'Python 3 is required.'
xcodebuild -version >/dev/null 2>&1 || fail 'Install and open Xcode, complete its first-run setup, then run this installer again.'
xcrun --find swift >/dev/null 2>&1 || fail 'The selected Xcode installation does not include Swift.'

install_dir="${PROXIMUS_INSTALL_DIR:-$HOME/Applications}"
mkdir -p "$install_dir"
install_dir="$(cd "$install_dir" && pwd -P)"
installed_app="$install_dir/Proximus.app"
[[ ! -L "$installed_app" ]] || fail 'The installation path is a symbolic link. Choose a different installation directory.'
[[ ! -e "$installed_app" || -d "$installed_app" ]] || fail 'The installation path is occupied by a file.'
lock_dir="$install_dir/.proximus-install.lock"
mkdir "$lock_dir" 2>/dev/null || fail "Another installation is active. If it was interrupted, remove the empty $lock_dir directory."
staging=''
cleanup() {
    if [[ -n "$staging" && -d "$staging" ]]; then rm -rf "$staging"; fi
    rmdir "$lock_dir" 2>/dev/null || true
}
trap cleanup EXIT

mkdir -p build
log="$PWD/build/install-mac.log"
echo 'Building Proximus. The first build downloads dependencies and can take several minutes.'
echo "Build log: $log"
if ! bash scripts/bootstrap.sh > "$log" 2>&1; then
    tail -30 "$log" >&2
    fail 'Build preparation failed. See the build log for details.'
fi
if ! bash scripts/build.sh local >> "$log" 2>&1; then
    tail -30 "$log" >&2
    fail 'The application could not be built. See the build log for details.'
fi

staging="$(mktemp -d "$install_dir/.proximus-install.XXXXXX")"
ditto 'build/local/Build/Products/Release/Proximus.app' "$staging/Proximus.app"
codesign --verify --strict "$staging/Proximus.app"
previous=''
if [[ -d "$installed_app" ]]; then
    previous="$install_dir/.Proximus.previous-$(date +%Y%m%d-%H%M%S)-$$.app"
    mv "$installed_app" "$previous"
fi
if ! mv "$staging/Proximus.app" "$installed_app"; then
    if [[ -n "$previous" ]]; then mv "$previous" "$installed_app"; fi
    fail 'Could not install the application. The previous application was restored.'
fi
echo "Installed: $installed_app"
# Retire the old display name only when it is this app's bundle. Data locations
# and bundle identifiers are unchanged by the rename.
legacy_app="$install_dir/Proximus Passwords.app"
if [[ -d "$legacy_app" && ! -L "$legacy_app" ]]; then
    legacy_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$legacy_app/Contents/Info.plist" 2>/dev/null || true)
    installed_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$installed_app/Contents/Info.plist")
    if [[ -n "$legacy_id" && "$legacy_id" == "$installed_id" ]]; then
        mv "$legacy_app" "$install_dir/.Proximus.renamed-$(date +%Y%m%d-%H%M%S)-$$.app"
    fi
fi
if [[ -n "$previous" ]]; then echo "Previous application: $previous"; fi
echo 'Vault data is stored separately and is preserved when the app is updated.'
open -n "$installed_app"
