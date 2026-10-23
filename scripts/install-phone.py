#!/usr/bin/env python3
"""Build and install on one explicitly selected or sole connected Apple device."""
import argparse
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]


def run(arguments, **options):
    return subprocess.run(arguments, cwd=ROOT, check=True, **options)


def setting(path, key):
    if not path.exists():
        return None
    match = re.search(rf"^\s*{key}\s*=\s*([^/\n]+)", path.read_text(), re.MULTILINE)
    return match[1].strip() if match else None


def main():
    parser = argparse.ArgumentParser(description="Install Proximus on a trusted iPhone or iPad. Apple signing and Developer Mode are required.")
    parser.add_argument("--device", help="Device identifier or name from xcrun devicectl list devices")
    parser.add_argument("--team", help="Apple team ID, otherwise read Config/Local.xcconfig")
    parser.add_argument("--bundle-prefix", help="Bundle prefix owned by the signing team")
    parser.add_argument("--list", action="store_true", help="List available devices without installing")
    args = parser.parse_args()
    if sys.platform != "darwin":
        parser.error("A Mac with Xcode is required.")
    os.environ["PATH"] = f'{Path.home() / ".cargo/bin"}:/opt/homebrew/bin:/usr/local/bin:' + os.environ.get("PATH", "")
    run(["xcodebuild", "-version"], stdout=subprocess.DEVNULL)
    build = ROOT / "build"
    build.mkdir(exist_ok=True)
    devices_file = build / "connected-devices.json"
    run(["xcrun", "devicectl", "list", "devices", "--json-output", str(devices_file), "--timeout", "15"])
    if args.list:
        return
    device = args.device
    if not device:
        values = json.loads(devices_file.read_text()).get("result", {}).get("devices", [])
        devices = [d for d in values if d.get("hardwareProperties", {}).get("platform", "").lower() in ("ios", "ipados") and d.get("connectionProperties", {}).get("tunnelState") == "connected"]
        if not devices:
            parser.error("Connect and unlock your iPhone or iPad, approve Trust This Computer, and enable Developer Mode. Run ./install --phone again, or select a previously paired device with --device.")
        if len(devices) == 1:
            device = devices[0]["identifier"]
        elif sys.stdin.isatty():
            for i, value in enumerate(devices, 1):
                print(f'{i}. {value.get("deviceProperties", {}).get("name", "Apple device")}')
            try:
                selection = int(input("Install on device number: "))
            except ValueError:
                parser.error("Enter a device number.")
            if not 1 <= selection <= len(devices):
                parser.error("Select one of the listed devices.")
            device = devices[selection - 1]["identifier"]
        else:
            parser.error("Multiple devices are connected. Select one with --device.")
    local = ROOT / "Config/Local.xcconfig"
    team = args.team or setting(local, "DEVELOPMENT_TEAM")
    prefix = args.bundle_prefix or setting(local, "PROXIMUS_BUNDLE_PREFIX") or "org.proximus.passwords"
    if not team or not re.fullmatch(r"[A-Z0-9]{10}", team) or team == "YOURTEAMID":
        parser.error("Sign in to your Apple account in Xcode and configure Config/Local.xcconfig, or pass --team YOUR_TEAM_ID. The app and extension need App Groups and AutoFill provisioning.")
    if not re.fullmatch(r"[A-Za-z][A-Za-z0-9-]*(?:\.[A-Za-z0-9-]+)+", prefix):
        parser.error("Use a reverse-domain bundle prefix, such as org.yourname.passwords.")
    details_path = build / "install-device.json"
    run(["xcrun", "devicectl", "device", "info", "details", "--device", device, "--json-output", str(details_path), "--timeout", "15"])
    details = json.loads(details_path.read_text()).get("result", {})
    hardware = details.get("hardwareProperties", {})
    udid = hardware.get("udid")
    if hardware.get("platform", "").lower() not in ("ios", "ipados") or not udid or not re.fullmatch(r"[A-Fa-f0-9-]+", udid):
        parser.error("The selected device is not an available iPhone or iPad. Connect it and open it in Xcode first.")
    log_path = build / "install-phone.log"
    print(f"Building the phone app. Build log: {log_path}", flush=True)
    try:
        with log_path.open("w") as log:
            run(["bash", "scripts/bootstrap.sh"], stdout=log, stderr=subprocess.STDOUT)
            run(["xcodebuild", "-project", "ProximusPasswords.xcodeproj", "-scheme", "ProximusPasswords-iOS", "-configuration", "Release", "-destination", f"id={udid}", "-derivedDataPath", "build/phone", "-allowProvisioningUpdates", "-allowProvisioningDeviceRegistration", f"DEVELOPMENT_TEAM={team}", f"PROXIMUS_BUNDLE_PREFIX={prefix}", "build"], stdout=log, stderr=subprocess.STDOUT)
    except subprocess.CalledProcessError:
        print("\n".join(log_path.read_text(errors="replace").splitlines()[-25:]), file=sys.stderr)
        raise RuntimeError("Signing or compilation failed. Configure the app and AutoFill extension with the same team, App Group, and Keychain group in Xcode, then retry.")
    app = build / "phone/Build/Products/Release-iphoneos/Proximus Passwords.app"
    run(["codesign", "--verify", "--deep", "--strict", str(app)])
    if not (app / "embedded.mobileprovision").is_file():
        raise RuntimeError("The build has no provisioning profile. Installation stopped.")
    with (app / "Info.plist").open("rb") as info:
        bundle = plistlib.load(info)["CFBundleIdentifier"]
    run(["xcrun", "devicectl", "device", "install", "app", "--device", device, str(app), "--timeout", "120"])
    run(["xcrun", "devicectl", "device", "process", "launch", "--device", device, bundle, "--timeout", "30"])
    print("Installed and opened Proximus. Choose Pair with another device and scan the Mac's pairing QR code.")


if __name__ == "__main__":
    try:
        main()
    except (FileNotFoundError, RuntimeError, subprocess.CalledProcessError, json.JSONDecodeError, KeyError) as error:
        print(f"Installation stopped: {error}", file=sys.stderr)
        sys.exit(1)
