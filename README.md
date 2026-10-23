# Proximus Passwords

Free, open-source password manager and passkey provider for Mac, iPhone, and iPad. Local encrypted storage, QR device enrollment, and optional self-hosted sync. All features are included, with no subscription or purchase required.

**Version 0.1.0 - Apache-2.0 - PROXIMUS Research Labs Foundation**

## Features

- Passwords, secure notes, search, favorites, and collections
- On-device password generator with saved settings
- Password AutoFill with exact HTTPS origin matching
- Secure Enclave passkeys and device unlock
- Encrypted backups, recovery, and CSV import
- QR enrollment and self-hosted encrypted sync

The sidebar links to [Proximus sign-up](https://www.proximus.sh/sign-up). A Proximus account is optional and is not required to use the password manager.

The interface uses the original Proximus wings, Sora headings, Space Grotesk body text, and the dashboard’s light and dark palettes.

## Requirements

| Component | Requirement |
| --- | --- |
| Mac | Apple silicon, macOS 14 or later |
| iPhone and iPad | iOS 17 or iPadOS 17 or later |
| Passkeys and paired-device unlock | Secure Enclave and a configured device passcode or password |
| Apple build tools | Xcode 16.1 or later, with an SDK compatible with the target device |
| Cryptography build | Rust, Cargo, and Apple ARM64 targets |
| Project generation | Python 3 |
| Sync relay | Go 1.27.3 or later, or Docker |
| Physical-device installation | Apple signing team, provisioning profiles, App Groups, and AutoFill capability |

The app uses SwiftUI, AuthenticationServices, CryptoKit, Keychain, LocalAuthentication, and Network.framework. A Rust library supplies Argon2id, AES-GCM, and unbiased password generation. The sync relay uses Go’s standard library.

## Installation from source

### Mac double-click installation

Install Xcode 16.1 or later and [Rust](https://rustup.rs), then open Xcode once to complete its setup. Clone this repository, open its folder in Finder, and double-click **[Install Proximus.command](Install%20Proximus.command)**.

The installer builds the app, verifies its local code signature, installs it at `~/Applications/Proximus Passwords.app`, and opens it. The first build downloads dependencies. No Apple Developer account or Proximus account is required for this local Mac installation. Existing vault data is preserved on updates, and the previous app bundle is retained for rollback. Build output is recorded in `build/install-mac.log`.

The same installation is available from Terminal:

```sh
bash scripts/install-mac.sh
```

Browser AutoFill and passkey-provider integration require the signed setup below. iPhone and iPad use Xcode installation.

### Apple signing and manual builds

From the repository root:

```sh
bash scripts/bootstrap.sh
cp Config/Local.example.xcconfig Config/Local.xcconfig
open ProximusPasswords.xcodeproj
```

The bootstrap script builds the Rust XCFramework and generates the Xcode project. Icons, logo assets, and fonts are included in the repository.

Configure a signing team and a bundle prefix owned by that team in `Config/Local.xcconfig`:

```xcconfig
DEVELOPMENT_TEAM = YOURTEAMID
PROXIMUS_BUNDLE_PREFIX = org.yourname.proximuspasswords
```

| Target | Identifier |
| --- | --- |
| Mac app | `$(PROXIMUS_BUNDLE_PREFIX).mac` |
| Mac AutoFill | `$(PROXIMUS_BUNDLE_PREFIX).mac.autofill` |
| iPhone and iPad app | `$(PROXIMUS_BUNDLE_PREFIX).ios` |
| iPhone and iPad AutoFill | `$(PROXIMUS_BUNDLE_PREFIX).ios.autofill` |
| Shared App Group | `group.$(PROXIMUS_BUNDLE_PREFIX)` |
| Shared Keychain group | `$(AppIdentifierPrefix)$(PROXIMUS_BUNDLE_PREFIX).shared` |

Register the identifiers with the signing team. Enable the same App Group and Keychain group for each app and its extension. Apple provisioning supplies `AppIdentifierPrefix`. Local signing configuration is excluded from Git.

### Mac

Build a local Mac application without an Apple Developer account:

```sh
bash scripts/build.sh local
open 'build/local/Build/Products/Release/Proximus Passwords.app'
```

Local Mac builds use an isolated Application Support vault and the macOS login Keychain. The build script applies an ad-hoc signature and excludes the unprovisioned AutoFill extension. Password storage, generation, import, backup, device unlock, pairing, and encrypted sync remain available. Browser AutoFill and passkey-provider integration use the Apple-team-signed build.

For shared AutoFill, configure `Config/Local.xcconfig`, select the `ProximusPasswords-macOS` scheme, and run it on **My Mac**, or build from the terminal:

```sh
bash scripts/build.sh macos
```

Copy `build/macos/Build/Products/Release/Proximus Passwords.app` to `/Applications` or `~/Applications`. Keep the embedded AutoFill extension inside the application bundle.

### iPhone and iPad without the App Store

1. Connect the device to the Mac and trust the Mac on the device.
2. Enable **Developer Mode** in the device’s Privacy & Security settings.
3. Open the Xcode project and select `ProximusPasswords-iOS`.
4. Select the connected iPhone or iPad as the run destination.
5. Use the same signing team for the app and its AutoFill extension.
6. Run the app from Xcode.
7. Enable Proximus in the device’s **AutoFill & Passwords** settings.

QR enrollment connects an installed app. It does not install an IPA or replace Apple provisioning. Personal Team provisioning expires after seven days. Capability availability depends on the signing team. Registered-device distribution uses Apple Developer Program provisioning. [Apple membership comparison](https://developer.apple.com/support/compare-memberships/), [Developer Mode](https://developer.apple.com/documentation/xcode/enabling-developer-mode-on-a-device)

### Compile without signing

```sh
bash scripts/build.sh macos --unsigned
bash scripts/build.sh ios --unsigned
bash scripts/build.sh simulator --unsigned
```

Unsigned builds verify compilation. Physical-device installation uses the signed procedure above.

## Vault setup and recovery

Creating a vault creates a local vault identifier and encryption keys. It does not create a Proximus website account or require an email address. The optional sidebar sign-up opens the Proximus website in the browser and is separate from vault access.

**Create a vault** generates a random 256-bit vault key and a separate 256-bit recovery key. The master passphrase has a minimum length of 12 UTF-8 bytes. The recovery key and master passphrase together unlock an encrypted backup.

The recovery key can be remembered in the device’s local Keychain. **Settings → Enable device unlock** adds a Secure Enclave protected unlock path. Subsequent unlocks can use Face ID or Touch ID on supported hardware. Device owner authentication can also accept the device passcode or password. Biometric data is handled by the operating system and is not sent to Proximus. Device unlock does not replace the recovery kit for restoring a backup on a new device.

**Settings → Import passwords from CSV** accepts UTF-8 exports with `name` or `title`, `url` or `website`, `username`, `password`, and optional `notes` columns. Chrome, Safari, and password-only Bitwarden aliases are supported. Imports add validated records without replacing existing items. OTP secrets are rejected rather than discarded.

**Settings → Export encrypted backup** writes a `.proximusvault` file. **Restore an encrypted backup** restores that file on a device without an existing vault, using the master passphrase and recovery key. Hardware-bound passkey private keys are excluded from backups.

## Pair a device

1. Install Proximus on both devices.
2. Unlock the source vault and choose **Pair a device**.
3. On the new device, choose **Pair with another device**.
4. Scan the QR code or paste the pairing link.
5. Compare the six-digit code on both screens.
6. Approve the matching code on both devices.

Pairing works over a local network without internet access. Invitations expire after two minutes and accept one connection. The QR contains a temporary public key, session identifier, and expiry. The encrypted transfer contains the password vault, its authenticated checkpoint, and optional relay configuration. Passkey private keys remain on their original device.

Ongoing remote synchronization uses the optional relay. Each device continues to read, edit, and generate passwords while offline.

## Password AutoFill and passkeys

Enable Proximus as an AutoFill provider in system settings. **Enable AutoFill suggestions** publishes usernames and website names to the system credential index. Passwords and private keys are excluded from that index.

Password selection uses exact normalized HTTPS origins. Subdomains and non-default ports are separate destinations. AutoFill identifies the destination and requires **Use password** confirmation before releasing a password.

Passkeys are created through the website’s registration or account-security flow. Proximus generates an ES256 key in Secure Enclave and returns a WebAuthn registration response. Signing requires device owner authentication. A canceled or failed passkey request does not fall back to a password.

Each hardware-bound passkey belongs to one device. Other devices can hold its metadata but cannot sign with it. Separate device registrations, a website-supported cross-device flow, or the website’s recovery method provide access from another device.

## Self-hosted sync

The relay stores content-addressed encrypted snapshots and a current-head pointer. It receives no vault key, master passphrase, recovery key, or plaintext record. Snapshot ancestry detects divergent changes. Conflicts require an explicit keep-both merge.

```sh
python3 -c 'import secrets; print("PROXIMUS_ENROLLMENT_KEY=" + secrets.token_urlsafe(32))' > .env
chmod 600 .env
docker compose up --build -d
```

The container listens on `127.0.0.1:8088`. Place an HTTPS reverse proxy in front of it using [Config/Caddyfile.example](Config/Caddyfile.example). In **Settings → Encrypted sync**, enter the HTTPS endpoint and enrollment key, then select **Connect relay**.

To run a native Go process:

```sh
cd services
go build -trimpath -o ../build/proximus-relay ./relay
PROXIMUS_DATA=./data/relay \
PROXIMUS_ENROLLMENT_KEY='GENERATED_ENROLLMENT_KEY' \
PROXIMUS_LISTEN=127.0.0.1:8088 \
../build/proximus-relay
```

| Setting | Default | Purpose |
| --- | --- | --- |
| `PROXIMUS_LISTEN` | `127.0.0.1:8088` | Relay listener |
| `PROXIMUS_DATA` | `./data/relay` | Ciphertext and authentication data |
| `PROXIMUS_ENROLLMENT_KEY` | Unset | Authorizes new vault namespaces |

Per-vault limits are 256 MiB of history, 10,000 objects, and 12 MiB per uploaded object. A process lock prevents concurrent service writers. Head updates use compare-and-swap. The relay retains old snapshots.

Public endpoints use HTTPS. Plain HTTP is accepted only for localhost development. The relay runs independently of Proximus browser sandboxes and security scanners. Hosted service URLs are release configuration, not hardcoded endpoints.

## Cryptography and storage

| Boundary | Implementation |
| --- | --- |
| Vault records | AES-256-GCM with a random 96-bit nonce per encryption |
| Recovery envelope | Argon2id v19, 64 MiB, 3 iterations, 1 lane, 16-byte salt, separate 32-byte secret |
| Authenticated context | Format, vault identifier, revision, parent snapshot hashes |
| Device unlock | Secure Enclave P-256 agreement, HKDF-SHA-256, authenticated wrapping |
| Passkeys | Secure Enclave P-256 signing, ES256, user verification, `none` attestation |
| Pairing | Ephemeral P-256 agreement, pinned QR public key, HKDF-SHA-256, AES-GCM |
| Local secrets | Non-synchronizing `WhenUnlockedThisDeviceOnly` entries in provisioned builds, login Keychain in standalone Mac builds |
| Local writes | Atomic replacement and interprocess locking |
| Network requests | HTTPS, no redirects, no cookies, bounded responses |

Titles, usernames, websites, passwords, notes, collections, and device names are encrypted inside snapshots. The unencrypted header contains format and recovery-envelope data. Locking drops session data and clears the dedicated key buffer. SwiftUI and operating-system APIs can retain temporary plaintext copies while an item is in use.

Storage encryption protects locked vault data. A website receives a password when it is filled. A compromised operating system can capture passwords in use or misuse a signed-in session. Secure Enclave protects private-key extraction, while session security and account recovery remain separate controls.

Disconnecting sync does not revoke keys already held by a paired device. Lost-device response includes account session revocation, password rotation, and migration to a fresh vault and relay namespace.

## Password generation

The generator uses operating-system cryptographic randomness and rejection sampling. Default length is 24 characters. Supported lengths are 12 to 128 characters, with or without symbols.

| Uniform random selection | Approximate search-space entropy |
| --- | --- |
| 20 characters from 62 letters and digits | 119 bits |
| 24 characters from 62 letters and digits | 143 bits |
| 6 words from a 7,776-word list | 77.5 bits |
| 7 words from a 7,776-word list | 90.5 bits |

Long, independently random passwords resist guessing. Unique passwords prevent one leak from opening other accounts. Predictable substitutions, quotations, birthdays, and reused base passwords do not provide equivalent randomness. Six or seven independently selected dice words provide a practical master passphrase. [EFF passphrase generation](https://www.eff.org/dice)

Replace weak, reused, or exposed passwords. Investigate account sessions, recovery methods, and connected apps when compromise is suspected. Strong, unique passwords do not require arbitrary periodic replacement. [NIST password guidance](https://pages.nist.gov/800-63-4/sp800-63b.html#passwordver)

## Verification

```sh
bash scripts/verify.sh
bash scripts/verify.sh --apple
cargo audit
cd services
go run golang.org/x/vuln/cmd/govulncheck@latest ./...
```

Tests cover known-answer encryption vectors, corrupted snapshots, recovery factors, concurrent edits, backup restoration, exact-origin matching, pairing transcripts, WebAuthn encoding, CSV imports, and relay compare-and-swap. Physical-device verification covers provisioning, biometric prompts, browser registration and assertions, password AutoFill, and local-network pairing.

Go 1.27.3 includes the October 2026 X.509 security update. [Go release history](https://go.dev/doc/devel/release)

## Version control and releases

`VERSION` matches `MARKETING_VERSION` in `Config/Base.xcconfig` and the Rust crate version. Vault format version `1` is independent of the application version. Unsupported formats are rejected.

```sh
git status
git log --oneline
git switch -c feature/short-description
```

Release tags use `vMAJOR.MINOR.PATCH`. After updating the version files:

```sh
bash scripts/verify.sh --apple
bash scripts/build.sh macos
bash scripts/package-mac.sh
```

The package script writes a ZIP, SHA-256 checksum, and dependency manifest under `dist/`. Public Mac distribution uses Developer ID signing and Apple notarization. iPhone and iPad archives use the selected development or registered-device distribution profile. [Apple notarization](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)

Build output, vault files, local signing configuration, environment files, and private keys are excluded from Git. CI compiles Apple targets and runs Rust, Swift, and Go checks.

## Repository layout

```text
apps/Shared/             Native Mac, iPhone, and iPad views
apps/AutoFill/           Password and passkey provider extension
apps/Brand/              Original Proximus logo assets
apps/Fonts/              Dashboard fonts and OFL licenses
Sources/ProximusKit/     Vault, hardware keys, pairing, sync
crates/proximus-crypto/  Rust cryptography and C interface
services/relay/         Ciphertext relay
Tests/                  Swift protocol and integration tests
Config/                 Signing, privacy, capabilities, release settings
scripts/                Build, verification, branding, packaging
```

## Announcement

```text
Introducing Proximus Passwords for Mac, iPhone and iPad. 100% free, with local storage and self-hosted encrypted sync.

After all the DMs:
1. Check your accounts.
2. Replace weak, reused or exposed passwords.
3. Enable passkeys or strong MFA.

```

## License

[Apache License 2.0](LICENSE). Copyright 2026 PROXIMUS Research Labs Foundation. Source use, modification, redistribution, and commercial use follow that license. Proximus names and marks remain separate from the software license. Sora and Space Grotesk use the SIL Open Font License included in `apps/Fonts/`. [NOTICE](NOTICE)
