#!/usr/bin/env python3
"""Connect a locally installed Proximus app to Chrome's native messaging."""
import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parent
HOST = "org.proximus.browser"
BROWSERS = {"chrome": "Google/Chrome", "chromium": "Chromium"}


def extension_id():
    manifest = json.loads((ROOT / "manifest.json").read_text())
    digest = hashlib.sha256(base64.b64decode(manifest["key"], validate=True)).hexdigest()[:32]
    return "".join(chr(ord("a") + int(c, 16)) for c in digest)


def install(app, directory):
    if app.is_symlink():
        raise ValueError("Choose an application folder, not a symbolic link.")
    app = app.resolve(strict=True)
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    if info.get("ProximusBrowserProtocol") != 1 or info.get("ProximusBrowserExtensionID") != extension_id():
        raise ValueError("Update the Proximus Mac app first: run ./install from the source folder.")
    if info.get("CFBundleExecutable") != "Proximus":
        raise ValueError("This application is not a supported Proximus app.")
    executable = app / "Contents/MacOS/Proximus"
    if not executable.is_file() or not os.access(executable, os.X_OK):
        raise ValueError("The installed app is incomplete. Run ./install again.")
    subprocess.run(["/usr/bin/codesign", "--verify", "--strict", str(app)], check=True, capture_output=True)
    if directory.is_symlink():
        raise ValueError("The browser host directory must not be a symbolic link.")
    directory.mkdir(parents=True, exist_ok=True, mode=0o700)
    destination = directory / (HOST + ".json")
    if destination.is_symlink():
        raise ValueError("The browser host registration must not be a symbolic link.")
    manifest = {"name": HOST, "description": "Proximus local vault approval", "path": str(executable),
                "type": "stdio", "allowed_origins": ["chrome-extension://" + extension_id() + "/"]}
    fd, temporary = tempfile.mkstemp(prefix=".proximus-", suffix=".json", dir=directory)
    try:
        with os.fdopen(fd, "w") as file:
            json.dump(manifest, file, indent=2)
            file.write("\n")
        os.replace(temporary, destination)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)
    return destination


def main():
    parser = argparse.ArgumentParser(description="Connect Proximus to Chrome on this Mac.")
    parser.add_argument("--app", type=Path, help="Installed Proximus.app path")
    parser.add_argument("--browser", choices=BROWSERS, default="chrome")
    parser.add_argument("--uninstall", action="store_true", help="Remove the browser connection, keeping your vault")
    args = parser.parse_args()
    if sys.platform != "darwin":
        parser.error("The browser connection requires the Proximus Mac app.")
    directory = Path.home() / "Library/Application Support" / BROWSERS[args.browser] / "NativeMessagingHosts"
    try:
        if args.uninstall:
            path = directory / (HOST + ".json")
            if path.is_symlink() or directory.is_symlink():
                raise ValueError("The browser registration must not be a symbolic link.")
            if path.exists():
                current = json.loads(path.read_text())
                if current.get("name") != HOST:
                    raise ValueError("The registration belongs to another host. It was left unchanged.")
                path.unlink()
            print("Browser connection removed. Your vault is unchanged.")
            return
        app = args.app or next((path for path in [Path.home() / "Applications/Proximus.app", Path("/Applications/Proximus.app")] if path.is_dir()), None)
        if app is None:
            raise ValueError("Install the Mac app first: run ./install from the source folder.")
        print("Browser connection installed:", install(app, directory))
        print("In Chrome, open chrome://extensions, enable Developer mode, and choose Load unpacked.")
        print("Select this folder:", ROOT)
        print("Pin Proximus to the toolbar. Open an HTTPS sign-in page to fill or save a login.")
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        parser.exit(1, "Could not install the browser connection: " + str(error) + "\n")


if __name__ == "__main__":
    main()
