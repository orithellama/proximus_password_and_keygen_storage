# Proximus

Free, open-source app for passwords, passkeys, and wallet keys for Mac, iPhone, and iPad. Local encrypted storage, QR device enrollment, and optional self-hosted sync. All features are included, with no subscription or purchase required.

**Version 0.4.0 - Apache-2.0 - PROXIMUS Research Labs Foundation**

## Features

- Passwords, secure notes, search, favorites, and collections
- On-device password generator with saved settings
- BIP-39 master passphrase generation
- Solana, Ethereum/EVM, Bitcoin, and Monero wallet keys, addresses, and recovery
- Chain labels, native-coin balances, reviewed transfers, and optional paired-device approval
- Local Monero wallet companion support on Mac
- Password AutoFill with exact HTTPS origin matching
- Secure Enclave passkeys and device unlock
- Local profile creation with Face ID / Touch ID unlock
- Optional encrypted iCloud recovery kits including local wallet phrases
- Custom Solana, EVM, Bitcoin Core, and Monero RPC connection settings
- Encrypted vault exports and CSV import
- QR enrollment, nearby sync over direct peer-to-peer Wi-Fi, and self-hosted encrypted sync

The sidebar links to [Proximus sign-up](https://www.proximus.sh/sign-up). A Proximus account is optional and is not required to use the password manager.

The interface uses the original Proximus wings, Sora headings, Space Grotesk body text, and the dashboard’s light and dark palettes.

Screenshots on the product page are captured from the native Mac app with sample data.

## Install Proximus

Official downloads are listed at [proximus.sh/proximus-app](https://www.proximus.sh/proximus-app). The Mac download becomes available after a Developer ID signed, notarized release is published and its exact SHA-256 checksum is pinned on the website. Local test packages are not offered through that download.

### Mac disk image

1. Download `Proximus-0.4.0-macOS.dmg` from the official download page.
2. Open the disk image.
3. Drag **Proximus** onto **Applications**.
4. Eject the disk image and open Proximus from Applications.

The packaged app includes its compiled code and cryptography. Xcode, Rust, Terminal, and a developer account are not required to install it. Requires an Apple silicon Mac with macOS 14 or later. Configure Proximus under **AutoFill & Passwords** to use the signed extension.

Updates replace the app bundle while keeping its separate data store. Standalone source builds and provisioned releases use different vault containers. Before moving an existing standalone vault to the signed app, save an encrypted recovery kit including any local wallet keys, retain its backup password, and restore it in the signed app. Keep the original installation until recovery is verified. Standard `.proximusvault` exports exclude wallet keys.

### iPhone and iPad installation links

For distribution without a public App Store listing, Proximus uses the TestFlight workflow. Install Apple's free TestFlight app once, open the Proximus invitation link when published, and tap **Install**. Xcode, a cable, and Developer Mode are not needed by TestFlight users. The website will show the invitation once a build is available. No invitation has been configured yet.

Each TestFlight build expires after 90 days, so it needs replacement builds. App Store distribution is the permanent installation route for ordinary users. A GitHub IPA download or pairing QR does not bypass Apple's installation requirements. Region-specific alternative distribution has separate eligibility and account requirements. [Apple TestFlight workflow](https://developer.apple.com/help/app-store-connect/test-a-beta-version/testflight-overview/), [Apple Web Distribution](https://developer.apple.com/support/web-distribution-eu/)

All Proximus application code, the relay, build tools, installers, packaging scripts, and release validation remain open source under Apache-2.0. Packaged downloads are provided for convenience. The same source can be inspected and built independently. Dependency licenses and Apple SDK/tool requirements remain separate.

## Source build requirements

| Component | Requirement |
| --- | --- |
| Mac | Apple silicon, macOS 14 or later |
| iPhone and iPad | iOS 17 or iPadOS 17 or later |
| Passkeys, wallet keys, and paired-device unlock | Secure Enclave and a configured device passcode or password |
| Apple build tools | Xcode 16.1 or later, with an SDK compatible with the target device |
| Cryptography build | Rust, Cargo, and Apple ARM64 targets |
| Project generation | Python 3 |
| Sync relay | Go 1.27.3 or later, or Docker |
| Physical-device installation | Apple signing team, provisioning profiles, App Groups, and AutoFill capability |

The app uses SwiftUI, AuthenticationServices, CryptoKit, Keychain, LocalAuthentication, and Network.framework. A Rust library supplies Argon2id, AES-GCM, unbiased password generation, BIP-39, wallet address derivation, and restricted Solana/EVM/Bitcoin native-coin transaction construction and signing. The sync relay uses Go’s standard library.

## Installation from source

### Mac double-click installation

Install Xcode 16.1 or later and [Rust](https://rustup.rs), then open Xcode once to complete its setup. Clone this repository, open its folder in Finder, and double-click **[Install Proximus.command](Install%20Proximus.command)**.

The installer builds the app, verifies its local code signature, installs it at `~/Applications/Proximus.app`, and opens it. The first build downloads dependencies. No Apple Developer account or Proximus account is required for this local Mac installation. Existing vault data is preserved on updates, and the previous app bundle is retained for rollback. Build output is recorded in `build/install-mac.log`.

The same installation is available from Terminal:

```sh
./install
```

Browser AutoFill and passkey-provider integration require the signed setup below. The following phone instructions are for source builders. End users use the published installation links.

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
open 'build/local/Build/Products/Release/Proximus.app'
```

Local Mac builds use an isolated Application Support vault and the macOS login Keychain. The build script applies an ad-hoc signature and excludes the unprovisioned AutoFill extension. Password storage, generation, import, backup, device unlock, pairing, and encrypted sync remain available. Browser AutoFill and passkey-provider integration use the Apple-team-signed build.

For shared AutoFill, configure `Config/Local.xcconfig`, select the `ProximusPasswords-macOS` scheme, and run it on **My Mac**, or build from the terminal:

```sh
bash scripts/build.sh macos
```

Copy `build/macos/Build/Products/Release/Proximus.app` to `/Applications` or `~/Applications`. Keep the embedded AutoFill extension inside the application bundle.

### iPhone and iPad source installation

After configuring the Apple signing team above, connect and unlock the device, approve **Trust This Computer**, and enable **Developer Mode**. Run:

```sh
./install --phone
```

The installer selects the only connected iPhone or iPad, or offers a choice when several are connected. It builds with automatic provisioning, verifies the signed application, installs it, and opens it. The phone can then scan the Mac’s pairing QR code. The first signing setup can require completing App Groups and AutoFill capability registration in Xcode. Apple approval screens cannot be skipped by a pairing QR code.

```sh
./install --phone --list
./install --phone --device DEVICE_ID --team TEAM_ID --bundle-prefix org.yourname.passwords
```

Build logs are saved in `build/install-phone.log`. An already trusted device can also be selected over an Xcode-supported network connection. A connected USB cable is the initial setup path. Manual Xcode installation remains available:

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

**Create a vault** generates a random 256-bit vault key and a separate 256-bit recovery key. The master passphrase has a minimum length of 12 UTF-8 bytes. **Generate from BIP-39** fills both passphrase fields with 24 English words generated from 256 random bits plus the BIP-39 checksum. Save this phrase separately from the recovery key and use it only for the vault. Wallet recovery phrases are generated independently. The recovery key and master passphrase together unlock an encrypted backup.

The recovery key can be remembered in the device’s local Keychain. **Use Face ID or Touch ID to unlock** during profile creation, or **Settings → Enable device unlock**, adds a Secure Enclave protected unlock path. Subsequent unlocks can use Face ID or Touch ID on supported hardware. Device owner authentication can also accept the device passcode or password. Biometric data is handled by the operating system and is not sent to Proximus. Device unlock does not replace the recovery credentials needed on a new device.

**Settings → Import passwords from CSV** accepts UTF-8 exports with `name` or `title`, `url` or `website`, `username`, `password`, and optional `notes` columns. Chrome, Safari, and password-only Bitwarden aliases are supported. Imports add validated records without replacing existing items. OTP secrets are rejected rather than discarded.

**Settings → Export encrypted backup** writes a `.proximusvault` file. **Restore an encrypted backup** restores that file on a device without an existing vault, using the master passphrase and recovery key. Hardware-bound passkey private keys and device-local wallet secrets are excluded from vault backups.

### Encrypted iCloud recovery kits

During profile creation, enable **Automatically save an encrypted recovery kit**, or open **Settings → iCloud & recovery**. Choose a folder through Files or Finder. Select a folder in iCloud Drive to use the signed-in Apple account, or a local folder for local storage. Proximus does not create an Apple account or an online Proximus account.

Use a separate backup password of 16–1024 UTF-8 bytes and save it outside the vault. The kit is encrypted on the device with AES-256-GCM. Its key uses Argon2id v19 with 64 MiB, 3 iterations, 1 lane, and a random 16-byte salt. The backup password is not stored. A device-bound Secure Enclave wrapper protects the derived key between sessions.

| File or operation | Contents | Restore credentials |
| --- | --- | --- |
| `.proximusvault` export | Encrypted password vault and public wallet metadata | Original master passphrase and vault recovery key |
| `.proximusrecovery` kit | Password vault and recovery phrases/private keys held on the exporting device | Separate backup password |
| Pairing, nearby sync, relay sync | Password vault and public wallet metadata | Authorized pairing / vault unlock |

Hardware passkey private keys are never exported. Wallets whose keys exist only on other devices contribute public metadata to this device's kit. Monero kits contain the spend and view keys, not a word mnemonic. RPC endpoints and authentication credentials are excluded.

While the vault and backup session are unlocked, edits automatically update the encrypted kit. Device authentication resumes backup access after unlocking. Canceling that prompt pauses backup. **Resume backup / back up now** includes local wallets created while backup was paused. The sidebar and Settings show failed writes or missing wallet keys. A successful save means the encrypted file was written to the chosen folder, not that iCloud finished uploading. iCloud needs connectivity to upload. Proximus does not run backups while the vault is locked.

**Restore an iCloud recovery kit** opens a selected kit on a device without a vault. Enter its backup password, choose a new master passphrase, and save the new vault recovery key. Restoration creates a new vault identifier and stores recovered wallet keys under this device's protection. Re-pair devices and configure a backup folder after restoration. No plaintext recovery file is downloaded or exported automatically.

Changing the backup password does not revoke older encrypted copies. Turning off automatic backup leaves existing encrypted files in the selected folder and the local encrypted cache. Old files and iCloud version history can still recover previously included secrets. Keep independent recovery details and verify access to a saved kit before replacing a device.

## Wallet keys and recovery

Choose **+ → Crypto wallet** to create or restore a wallet. Each new wallet gets independent randomness. Use **Back up or reveal recovery details**, authenticate with Face ID, Touch ID, or the device password/passcode, and save the recovery details separately. They hide after 60 seconds, when the vault locks, or when the app enters the background.

| Network | First address | Recovery and key format |
| --- | --- | --- |
| Solana | `m/44'/501'/0'/0'`, SLIP-0010 Ed25519 | 24-word English BIP-39 phrase, Base58 64-byte keypair |
| Ethereum / EVM | `m/44'/60'/0'/0/0`, secp256k1, EIP-55 | 24-word English BIP-39 phrase, hex private key |
| Bitcoin mainnet | `m/84'/0'/0'/0/0`, native SegWit | 24-word English BIP-39 phrase, compressed WIF private key |
| Monero mainnet | Standard deterministic address | Hex private spend key and derived private view key |

BIP-39 restoration accepts valid English phrases with no extra BIP-39 passphrase and derives only the first address at the path above. Other paths, account discovery, and additional addresses are not included. Monero restoration accepts a canonical private spend key and derives its view key using Keccak-256 and scalar reduction. It does not import Monero word mnemonics or wallets with independently chosen view keys. To recover in Monero software, use the address, spend key, and view key. Scan from height 0 if the original restore height is unknown. [BIP-84](https://github.com/bitcoin/bips/blob/master/bip-0084.mediawiki), [SLIP-0010](https://github.com/satoshilabs/slips/blob/master/slip-0010.md), [EIP-55](https://eips.ethereum.org/EIPS/eip-55), [Monero address format](https://docs.getmonero.org/public-address/standard-address/)

Wallet recovery phrases and private keys stay in a separate app-private store, encrypted under a dedicated Secure Enclave wrapping key requiring device owner authentication. The files are excluded from system backups, and their wrapping keys cannot be used on another device. There is no vault-passphrase fallback for this store. Vault snapshots, relay sync, nearby sync, pairing, and `.proximusvault` files contain public wallet metadata only. Opt-in `.proximusrecovery` kits include local wallet secrets. Explicit restoration from a kit or separately saved recovery phrase/key can create a wallet on another device.

The **Delete item** action removes local wallet keys when no other current record references that wallet. A deletion received through sync only removes the address record and does not erase another device's key store. Standard vault exports cannot recover deleted wallet keys. Older recovery kits can recover keys included before deletion, even after newer kits remove them. Keep the separate recovery details before deleting, uninstalling, or replacing a device.

Proximus displays native-coin balances and sends reviewed transfers through configured RPC nodes. Solana, EVM, and Bitcoin transactions are signed locally after device authentication. Monero uses a separately configured local wallet companion on Mac. dApp connections, tokens, contract calls, and on-chain multisig are not included. Apple Secure Enclave protects wallet keys at rest; the networks use signing curves that require decryption into app memory when signing or revealing keys. A compromised operating system can expose these keys or interfere with transactions. [Apple Secure Enclave key restrictions](https://developer.apple.com/documentation/security/protecting-keys-with-the-secure-enclave)

### Balances and sending

Open a wallet, choose **RPC settings**, save your node, then select **Refresh balance**. The wallet list and details show the chain and its native symbol. Balances include their refresh time and remain in memory until the vault locks. No third-party balance service or default public RPC is selected automatically.

| Network | Balance and sending | Requirements |
| --- | --- | --- |
| Solana mainnet | SOL balance, local Ed25519 signing, preflight and submission | Solana JSON-RPC matching the mainnet genesis hash |
| Ethereum / EVM | Native gas-coin balance, local EIP-155 signing | Ethereum (ETH), BNB Smart Chain (BNB), Polygon PoS (POL), Avalanche C-Chain (AVAX), or Ethereum Sepolia (test ETH) |
| Bitcoin mainnet | Confirmed safe outputs, local native SegWit signing | Synced Bitcoin Core wallet RPC tracking the public address; 1–32 inputs per transfer |
| Monero mainnet | Unlocked and total balance, companion preparation and relay | Mac with an authenticated local `monero-wallet-rpc` holding the matching wallet |

1. Choose **Send crypto** and enter the destination address and a decimal amount.
2. Select **Review transfer**. Check the chain, full source and recipient addresses, amount, fee, and total. EVM shows a maximum fee; unused gas is not charged.
3. If configured, obtain approval from the paired device for this exact review.
4. Select **Authenticate & send** and approve Face ID, Touch ID, or the device password/passcode.
5. Keep the transaction ID and use **Check confirmation**. A node accepting a transaction does not mean it is confirmed.

Amounts use exact atomic-unit arithmetic. The app reconstructs Solana, EVM, and Bitcoin transaction bytes from the review before signing. It rechecks the chain, Solana blockhash and fee, EVM pending nonce and account code, or Bitcoin input availability before broadcasting. Bitcoin input values and source scripts come from complete previous transactions, and change returns to the source address. Native EVM sending supports plain accounts with no contract/delegation code and empty calldata. Networks with additional data fees, tokens, contract interactions, send-max, replace-by-fee, and integrated Monero payment-ID addresses are not supported.

The sender must be the device holding this wallet's keys. A paired address-only record can display balances and receive funds, but cannot sign. Transfer reviews expire; an expired review needs fresh preparation and approval. The expected transaction ID is saved before submission. Timeouts retain an unknown-status record and never automatically retry or create a replacement payment. Check the previous ID before explicitly creating another transfer.

### Custom RPC nodes

Open **Settings → Custom RPC nodes**, or **RPC settings** inside a wallet. Endpoints and credentials stay in this device's Keychain and are excluded from recovery kits. Remote nodes require HTTPS. HTTP is accepted only for loopback addresses; Monero wallet companions require literal `127.0.0.1` or `[::1]` and RPC authentication. Redirects are rejected. Connection-check responses are capped at 256 KiB; transaction RPC responses at 2 MiB.

Connection checks use `getGenesisHash` (Solana), `eth_chainId` (EVM), `getblockchaininfo` (Bitcoin), and `get_info` (Monero daemon) or `get_version` (Monero wallet companion). They do not send wallet addresses or private keys. Refreshing a balance discloses the public address to the configured node. Sending submits the reviewed signed transaction. A node's chain, balance, and confirmation responses are claims from that node, not independent chain verification.

For Bitcoin, create or use a Bitcoin Core watch-only descriptor wallet, import `addr(YOUR_BITCOIN_ADDRESS)` with its descriptor checksum and an appropriate rescan timestamp, and let the rescan finish. Configure the wallet endpoint, such as `http://127.0.0.1:8332/wallet/proximus`, with Core RPC authentication. An untracked address produces a setup error instead of a misleading zero balance. Core does not need the private key. [Bitcoin descriptor import](https://bitcoincore.org/en/doc/30.0.0/rpc/wallet/importdescriptors/), [descriptor checksums](https://bitcoincore.org/en/doc/30.0.0/rpc/util/getdescriptorinfo/)

For Monero on Mac:

1. Install the official Monero CLI tools and verify their download using the [Monero download instructions](https://www.getmonero.org/downloads/).
2. Open or manually restore the matching wallet in Monero software. Its primary address must match the Proximus address. Use the separately saved spend/view keys and restore height when needed; Proximus never transfers them automatically.
3. Run `monero-wallet-rpc` on loopback with RPC authentication and the matching wallet loaded. Let it scan through the current chain height. The companion maintains its own wallet files and key protection, separate from Proximus.
4. In Proximus **RPC settings → Monero**, enable **Local wallet companion**, enter `http://127.0.0.1:18082/json_rpc` (or your configured local port), and enter its RPC username/password. HTTP Digest authentication is supported.

Preparing XMR asks the companion to construct and sign with `do_not_relay: true`. Proximus then shows its returned amount and fee, binds the prepared metadata digest and transaction ID into any paired approval, and calls `relay_tx` only after final device authorization. The prepared metadata stays on the sending Mac; approval files contain its digest, not the signed payload. Proximus trusts the local companion for Monero transaction construction and does not independently decode its confidential outputs. A watch-only companion cannot sign, and the companion's own interfaces can operate outside Proximus's approval policy. [Monero wallet RPC](https://docs.getmonero.org/rpc-library/wallet-rpc/), [wallet companion configuration](https://docs.getmonero.org/interacting/monero-wallet-rpc-reference/)

Exchanging addresses and approval codes with someone nearby can happen offline, including QR scanning or AirDrop file exchange. A blockchain payment still needs a connected node to broadcast and the network to confirm it. Nearby exchange alone does not settle a payment. [Solana submission](https://solana.com/docs/rpc/http/sendtransaction), [Ethereum JSON-RPC](https://ethereum.org/developers/docs/apis/json-rpc/), [Bitcoin submission](https://bitcoincore.org/en/doc/30.0.0/rpc/rawtransactions/sendrawtransaction/)

### Paired-device transfer approval

1. Pair and sync the vault so both devices have the same wallet's public record.
2. Open **Device approvals** on both devices and show each device's approval code.
3. Import the other device's code on each side. Compare the full fingerprint on the actual device screens before choosing **Trust this device**.
4. On the wallet's original device, open **Device approval**, select the trusted approver, and save. Changing or disabling the requirement needs device authentication.
5. Prepare a transfer and choose **Create approval request**. On the other device, choose **Device approvals → Review a transfer**, import or scan the request, check all details, and authenticate.
6. Return its approval code to the sender, then authenticate and send. Large Bitcoin requests use exported files/AirDrop because full input transactions may not fit a QR code.

Each device uses an independent Secure Enclave P-256 approval identity, separate from the shared vault encryption key. Requests and responses use different signature domains. The signature binds the vault, wallet, source device, unique review identifier, chain, recipient, exact amount, fee, transaction construction data, and expiry. The approver reconstructs Solana/EVM/Bitcoin unsigned bytes from the review. A changed, expired, wrongly signed, or already submitted review is rejected. Fingerprints, wallet approval policies, and the latest transfer record are local device data and are not synced or included in recovery kits. Configure trust and policies again after recovery on another device.

This is **app-enforced paired-device approval**, not blockchain multisig. The chain receives a normal single-key transaction. It cannot stop someone who controls the signing device, the Monero companion, or a separately restored recovery phrase from using another signing path.

## Pair a device

1. Install Proximus on both devices.
2. Unlock the source vault and choose **Pair a device**.
3. On the new device, choose **Pair with another device**.
4. Scan the QR code or paste the pairing link.
5. Compare the six-digit code on both screens.
6. Approve the matching code on both devices.

Pairing uses Network.framework with peer-to-peer Wi-Fi enabled. Devices can connect directly without a router or internet access, or through an existing local network. Wi-Fi must remain enabled, and Local Network access must be allowed. Invitations expire after two minutes and accept one connection. The QR contains a temporary public key, session identifier, and expiry. The encrypted transfer contains the password vault, its authenticated checkpoint, and optional relay configuration. Passkey private keys and wallet recovery phrases/private keys remain on their original device. Wallet address metadata can sync.

### Nearby sync after pairing

Unlock the vault on both devices and open **Nearby sync** on each. The apps discover and authenticate each other and exchange encrypted changes automatically for that session. A new QR scan is not required. Discovery identifiers rotate for each session and do not contain vault identifiers or device names. Authentication requires possession of the existing vault key, and an ephemeral P-256 exchange derives fresh session encryption keys. Directional sequence numbers reject reordered or replayed records. Conflicting edits require an explicit keep-both merge.

Keep both apps open and Wi-Fi enabled. A shared Wi-Fi network and internet access are unnecessary. Nearby sync ends when its screen closes, the vault locks, or its two-minute window expires. Each session is limited to 64 MiB of message data. This transport uses Apple peer-to-peer Wi-Fi, not Bluetooth-only mesh networking. [Apple peer-to-peer networking](https://developer.apple.com/forums/thread/751839)

Remote synchronization between devices outside nearby range uses the optional relay. Each device continues to read, edit, and generate passwords while offline.

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
| Recovery kit | AES-256-GCM, separate backup password, Argon2id v19 64 MiB / 3 iterations / 1 lane |
| Recovery envelope | Argon2id v19, 64 MiB, 3 iterations, 1 lane, 16-byte salt, separate 32-byte secret |
| Authenticated context | Format, vault identifier, revision, parent snapshot hashes |
| Device unlock | Secure Enclave P-256 agreement, HKDF-SHA-256, authenticated wrapping |
| Passkeys | Secure Enclave P-256 signing, ES256, user verification, `none` attestation |
| Pairing | Ephemeral P-256 agreement, pinned QR public key, HKDF-SHA-256, AES-GCM |
| Local secrets | Non-synchronizing `WhenUnlockedThisDeviceOnly` entries in provisioned builds, login Keychain in standalone Mac builds |
| Local writes | Atomic replacement and interprocess locking |
| Network requests | HTTPS, no redirects, no cookies, bounded responses |

Titles, usernames, websites, passwords, notes, collections, and device names are encrypted inside snapshots. The unencrypted header contains format and recovery-envelope data. Locking drops session data and clears the dedicated key buffer. SwiftUI and operating-system APIs can retain temporary plaintext copies while an item is in use.

Storage encryption protects locked vault data. A website receives a password when it is filled. A compromised operating system can capture passwords in use or misuse a signed-in session. Secure Enclave keeps passkey signing keys and wallet wrapping keys non-exportable. Wallet signing keys use other curves and are decrypted into app memory when signing or revealed. Session security and account recovery remain separate controls.

Disconnecting sync does not revoke keys already held by a paired device. Lost-device response includes account session revocation, password rotation, and migration to a fresh vault and relay namespace.

## Password generation

The generator uses operating-system cryptographic randomness and rejection sampling. Default length is 24 characters. Supported lengths are 12 to 128 characters, with or without symbols.

| Uniform random selection | Approximate search-space entropy |
| --- | --- |
| 20 characters from 62 letters and digits | 119 bits |
| 24 characters from 62 letters and digits | 143 bits |
| 6 words from a 7,776-word list | 77.5 bits |
| 7 words from a 7,776-word list | 90.5 bits |
| 24 BIP-39 words generated from random entropy | 256 bits |

Long, independently random passwords resist guessing. Unique passwords prevent one leak from opening other accounts. Predictable substitutions, quotations, birthdays, and reused base passwords do not provide equivalent randomness. Six or seven independently selected dice words provide a practical master passphrase. [EFF passphrase generation](https://www.eff.org/dice)

Replace weak, reused, or exposed passwords. Investigate account sessions, recovery methods, and connected apps when compromise is suspected. Strong, unique passwords do not require arbitrary periodic replacement. [NIST password guidance](https://pages.nist.gov/800-63-4/sp800-63b.html#passwordver)

## Verification

```sh
bash scripts/verify.sh
bash scripts/verify.sh --apple
cargo install cargo-audit --version 0.22.2 --locked
bash scripts/security-audit.sh
```

Transfer tests cover exact amounts, unsigned-byte reconstruction, EIP-155 reference signatures, Solana signature and preflight handling, Bitcoin prevout/fee/signature validation, Monero address matching and no-relay preparation, RPC response IDs and size limits, and approval tampering, expiry, wrong-key and domain-reflection rejection. No live funds are moved by these tests.

Version 0.4.0 verification: 15 Rust tests, 31 Swift tests (including a real loopback HTTP Digest exchange), Go race tests/vet, and five release-tool tests pass. Mac and iPhone/iPad app and AutoFill targets compile. Funded end-to-end transfers, physical-device biometric approval, and a real synced Monero companion have not been exercised by the automated suite.

Tests cover BIP-39, BIP-84, SLIP-0010, EIP-55 and Monero derivation vectors, wallet recovery, device ownership and metadata binding, exclusion of wallet secrets from ordinary snapshots and vault exports, encrypted recovery-kit round trips and tamper rejection, read-only RPC requests and endpoint validation, bounded file reads, known-answer encryption vectors, corrupted snapshots, recovery factors, concurrent edits, backup restoration, exact-origin matching, pairing transcripts, nearby authentication and replay rejection, encrypted socket transfers, nearby push/pull and conflict handling, WebAuthn encoding, CSV imports, relay compare-and-swap, and slow-upload isolation. Physical-device verification must additionally cover provisioning, biometric wallet recovery, iCloud upload/download and bookmark persistence, recovery on a replacement device, browser registration and assertions, password AutoFill, and peer-to-peer radio connectivity. Automated tests use an isolated protection implementation for wallet file storage and do not validate biometric hardware.

Go 1.27.3 includes the October 2026 X.509 security update. [Go release history](https://go.dev/doc/devel/release)

## Security review - 2026-10-23

Scope: this app repository, its Rust/C cryptography, Swift app and AutoFill extension, Go relay, installers, CI, and release packaging. Baseline: `0d1fb43637a2c97f82e8ad9055b2c346f0c3c677`. The changes in 0.3.0 include the fixes below. Sibling website, sandbox, and security repositories are outside this audit. This is a source and dependency review with automated tests, not an independent security certification or proof that every vulnerability is known.

| Finding | Assessment and disposition |
| --- | --- |
| Slow authenticated relay requests held a global storage mutex | Medium availability issue, fixed. Request-body reads and object streaming release the lock. Head updates recheck compare-and-swap after reading. Large uploads are capped at four concurrent requests. A regression test proves a stalled upload does not block a head read. |
| File size checked before an unbounded read | Low resource-exhaustion risk if the file changes between checks, fixed. Vault imports, local wallet files, and recovery cache now read at most the limit plus one byte. |
| Release packaging accepted any valid signature | Supply-chain hardening, fixed. Public packaging now checks the expected Developer ID team, notarization ticket, and Gatekeeper result. Ad-hoc local installers remain separate. |
| CI actions used mutable major tags and Node 20 | Supply-chain hardening, fixed. Checkout and setup-go are pinned to reviewed commit IDs using Node 24. Git checkout credentials are not persisted. CI runs RustSec and pinned govulncheck. The Go container builder is pinned to its registry digest. |
| C secp256k1 context blinding | Defense in depth, added. Each derivation context receives fresh operating-system randomness. This was not a confirmed key-extraction exploit. |
| Build-host software needs updates | Open. Host Node 23.9.0 is end of life, Python 3.13.2 and Xcode 16.1 are older than current security releases, and macOS 26.3.1(a) is behind the supported patched OS releases. Global host software was not changed by this review. |

| Check | Recorded result |
| --- | --- |
| RustSec / cargo-audit 0.22.1 | 90 lockfile packages checked, zero advisories and no warnings. Database has 1,350 advisories, commit `f7b2f6bc663452200bbe639ebb75e0c762b3422b`, updated 2026-10-23. CI pins cargo-audit 0.22.2 for subsequent scans. |
| OSV cross-check | 89 registry package versions plus the vendored C commit queried. No registry-package matches. One inferred C commit match required manual review, described below. |
| Go / govulncheck 1.9.0 | Symbol-level scan with Go 1.27.3, no findings. Database timestamp 2026-10-21. Go vet and race-enabled tests pass. |
| Rust tests and Clippy | Ten tests pass, Clippy denies warnings. |
| C sanitizer run | Ten Rust crypto tests pass with vendored secp256k1 C compiled under AddressSanitizer and UndefinedBehaviorSanitizer. Rust code itself was not sanitizer-instrumented. This is vector/round-trip coverage, not a fuzz campaign. |
| Swift tests | Twenty-one tests pass, including chosen-folder kit storage and restoration into a new vault, encryption/tamper checks, public-only wallet sync, RPC request restrictions, and bounded reads. |
| Apple builds | Mac and iOS app/AutoFill targets compile without signing. Provisioning, biometric prompts, iCloud transfer, and physical radio behavior require device testing. |
| Node runtime | No Node runtime or npm dependency tree is shipped by this native app. Node appears in CI and optional branding tooling. |

The vendored C revision in `secp256k1-sys 0.10.1` is `1ad5185cd42c0636104129fcc9f6a4bf9c67cc40`. OSV's inferred Git mapping returned `CVE-2021-38195` against bitcoin-core/secp256k1. The advisory describes the separate Parity Rust crate `libsecp256k1 < 0.5.0`, which is absent from this dependency graph. The upstream RustSec record and fix point to that Parity implementation. This match is assessed as a package-mapping false positive, not silently suppressed. The audit script stops on OSV matches for manual review. Empty upstream GitHub advisory lists are not evidence that C code has no defects. [Upstream RUSTSEC-2021-0076](https://rustsec.org/advisories/RUSTSEC-2021-0076.html)

Rust 1.94.1 includes the Cargo archive-extraction fixes for CVE-2026-33055 and CVE-2026-33056. Rust supports its latest stable toolchain, so release builds should use the current patched stable version. Go 1.27.3 includes the current X.509 security update. Node 24.22.1 was used in an isolated build directory for the separate website change, without replacing the host's Node installation. [Rust 1.94.1 security fixes](https://blog.rust-lang.org/2026/03/26/1.94.1-release/), [Rust support policy](https://rust-lang.org/security), [Go release history](https://go.dev/doc/devel/release), [Node end-of-life policy](https://nodejs.org/en/about/eol), [Node 24.22.1 security release](https://nodejs.org/en/blog/release/v24.22.1), [Python 3.13.2 superseded](https://www.python.org/downloads/release/python-3132/), [Apple security releases](https://support.apple.com/en-us/100100)

Raw scan output and build/test logs are local artifacts under `build/security-audit/` and `build/`. `scripts/security-audit.sh` refreshes the inventory, dependency databases, and OSV queries. These scans do not cover unpublished vulnerabilities, a compromised build machine, malicious paired devices, a rooted operating system, or third-party sites receiving filled passwords. No production penetration test, long-running fuzz campaign, signed release verification, or physical iCloud restore test was performed. Existing encrypted snapshots and external backups can retain deleted data. Paired vault keys cannot be remotely revoked.

## Version control and releases

Version 0.4.0 adds chain labels, native-coin balances and sending, paired-device approval, and a local Monero companion on Mac. Version 0.3.1 added DMG packaging, source revision metadata, signed release validation, GitHub publication tooling, and iOS distribution archive commands. Version 0.3.0 added local profile setup with device unlock, opt-in encrypted recovery kits, custom read-only RPC settings, and security fixes. Version 0.2.0 introduced the Proximus name, BIP-39 generation, and wallet key storage. Bundle identifiers and existing vault paths are unchanged. The installer retains the previous app bundle. Upgrade all paired devices before adding wallet records, because older versions cannot read the new item kind.

`VERSION` matches `MARKETING_VERSION` in `Config/Base.xcconfig` and the Rust crate version. Vault format version `1` is independent of the application version. Unsupported formats are rejected.

```sh
git status
git log --oneline
git switch -c feature/short-description
```

Release tags use `vMAJOR.MINOR.PATCH`. The application version is **v0.4.0**, build **5**. The public artifact is `Proximus-0.4.0-macOS.dmg`.

<!-- release-notes:start -->
### Proximus 0.4.0

Free, open-source storage for passwords, passkeys, secure notes, and wallet keys.

- Native Mac app with a drag-to-Applications DMG. No Xcode or developer tools needed to install.
- Encrypted local vaults with Face ID or Touch ID unlock on supported devices.
- Password generation, BIP-39 passphrase generation, and password AutoFill.
- Solana, EVM, Bitcoin, and Monero wallet addresses, keys, and recovery.
- Optional encrypted recovery kits saved to iCloud Drive or a chosen local folder.
- QR device pairing, nearby encrypted sync, and an optional self-hosted relay.
- Custom RPC endpoints, chain-aware balances, and reviewed native-coin sending.
- Optional paired-device approval with independent hardware-protected signing identities.
- Local Monero companion support on Mac; no automatic key transfer.
- Official download verification against an approved SHA-256 checksum.

Official downloads are listed at https://www.proximus.sh/proximus-app. Open the Mac DMG and drag Proximus to Applications. Requires an Apple silicon Mac with macOS 14 or later.

Native sending covers SOL, supported EVM gas coins, BTC, and XMR through a local Mac companion. Tokens, dApps, and blockchain multisig are not included. Paired-device approval is enforced by the app. iPhone and iPad source is included, with a separate TestFlight invitation to follow once distribution is configured.

Source: https://github.com/orithellama/proximus_password_and_keygen_storage
License: Apache-2.0. All Proximus features are free.
<!-- release-notes:end -->

## Repository layout

```text
install                  Mac and iPhone/iPad installation entry point
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

## License

[Apache License 2.0](LICENSE). Copyright 2026 PROXIMUS Research Labs Foundation. Source use, modification, redistribution, and commercial use follow that license. Proximus names and marks remain separate from the software license. Sora and Space Grotesk use the SIL Open Font License included in `apps/Fonts/`. [NOTICE](NOTICE)
