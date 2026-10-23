#!/usr/bin/env python3
from pathlib import Path
import json
import plistlib
import re
from urllib.parse import unquote

root = Path(__file__).resolve().parents[1]
version = (root / "VERSION").read_text().strip()
assert re.fullmatch(r"\d+\.\d+\.\d+", version), "Invalid semantic version"
assert f'MARKETING_VERSION = {version}' in (root / "Config/Base.xcconfig").read_text()
assert f'version = "{version}"' in (root / "crates/proximus-crypto/Cargo.toml").read_text()
assert version in (root / "README.md").read_text()
for path in (root / "Config").glob("*.plist"):
    value = plistlib.loads(path.read_bytes())
    assert value["ProximusAppGroup"] == "$(PROXIMUS_APP_GROUP)"
    assert value["ProximusKeychainGroup"] == "$(PROXIMUS_KEYCHAIN_GROUP)"
    assert value["ASCredentialProviderExtensionCapabilities"]["ProvidesPasskeys"]
for path in (root / "Config").glob("*.entitlements"):
    value = plistlib.loads(path.read_bytes())
    assert value["com.apple.security.application-groups"] == ["$(PROXIMUS_APP_GROUP)"]
    assert value["keychain-access-groups"] == ["$(PROXIMUS_KEYCHAIN_GROUP)"]
    assert value["com.apple.developer.authentication-services.autofill-credential-provider"]
for path in (root / "apps/Assets.xcassets").rglob("Contents.json"):
    json.loads(path.read_text())
for link in re.findall(r"\]\(([^)#]+)(?:#[^)]*)?\)", (root / "README.md").read_text()):
    if not link.startswith(("https://", "http://", "mailto:")):
        assert (root / unquote(link)).exists(), f"Missing README link: {link}"
assert (root / "LICENSE").read_text().lstrip().startswith("Apache License")
print(f"Version {version}, entitlements, asset catalogs, license, and README links verified")
