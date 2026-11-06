# Distribution, updates and the App Store question

This is the design for how YTMuse is built, delivered and updated (specification section 22, BUILD01–BUILD08, SEC09, SEC10, ARCH05, ARCH10). The cleaned source repository is public; its owner/name is supplied at packaging time. The [0.1.7 development preview](https://github.com/danielproj/ytmuse/releases/tag/v0.1.7) includes a Developer ID-signed, notarized and stapled app and DMG, checksums, an SBOM and a signed update feed. Local signature, Gatekeeper and feed checks passed. By hand, on the 0.1.3 preview, the maintainer checked a clean install and a real signed update; that update crashed the old app as it quit, which 0.1.4 fixes. On 2026-11-05 the account holder confirmed the remaining core checks work, including update restart after the fix. Wider G09 distribution checks remain deferred; see the [backlog](Backlog.md). See [GitHub-Releases.md](GitHub-Releases.md) for current setup and [Publishing-Checklist.md](Publishing-Checklist.md) for the release checks.

## Delivery

* **Primary path: a GitHub release** with an arm64 DMG, its SHA-256, release notes, the source tag, the SBOM ([sbom.cdx.json](sbom.cdx.json)) and the signed update feed `feed.json`. The app is free; signing and hosting costs are the maintainer's and never become an in-app purchase (BUILD05).
* **Source builds stay available** to anyone without signing credentials: `./scripts/build.sh` for a local Release build, `scripts/test.sh` for the suites. A source build is ad-hoc signed, has no feed and no pinned key, and therefore **never contacts an update server** (see below).
* The build, test and licence checks that run on every pull request need no Google account and no signing secret ([`.github/workflows/ci.yml`](../.github/workflows/ci.yml)); a clean clone runs the same steps locally with `scripts/clean-checkout.sh`.

## The updater: in this repository, not Sparkle

BUILD06 asks for "a maintained native updater such as Sparkle only after checking current compatibility and licensing". The decision for this repository:

| | In-repository updater (`Packages/NativeMusic/Sources/Updates`) | Sparkle |
| --- | --- | --- |
| Dependencies | none; Foundation, CryptoKit and Security only. `toolchain.json` keeps `external_dependencies: []`, and `Package.resolved` has zero pins | a binary framework with its own XPC services and helper tool inside the app bundle, plus its bundled third-party code |
| Auditability | about 900 lines, all covered by tests that tamper, downgrade, replay and run the real code-signature and disk-image paths | large and mature, but not reviewed here |
| Feed | one signed JSON file; data only | appcast XML with EdDSA signatures |
| Fit with ARCH05 | no new runtime, nothing downloaded and executed | acceptable if its licence and macOS 27 compatibility were verified |

Sparkle's licence and its compatibility with the macOS 27 SDK were **not checked in this work** (no outward contact was made), so it was not pinned. The in-repository updater does not depend on that check. If it is ever replaced by Sparkle, the same rules in [Updater rules](#updater-rules) must be proved for it before it is pinned, and `toolchain.json`, the SBOM and `THIRD_PARTY_NOTICES.md` change in the same commit.

### Trust model

* The app pins, in its own signed Info.plist: the feed URL, the repository (`owner/name`) and one or two **Ed25519 public keys**. The repository carries none of them, so a source build has no feed (`UpdateConfiguration(infoDictionary:)` returns nil and the Settings pane says so).
* The feed is an envelope: `{"format":1,"keyID":…,"payload":<base64>,"signature":<base64>}`. The signature is Ed25519 over `"YTMuse-update-feed-v1\n"` plus the payload bytes, so it cannot be replayed as a signature over anything else. The payload is read only after the signature holds.
* Every object in the payload has an **exact key set**. An extra field (a script, a URL to run, a replacement key, a request for credentials) makes the whole feed invalid rather than being ignored. **No unsigned remote configuration can execute code, change trust policy or reveal credentials** (SEC09): the feed cannot add a key, change the repository or change the channel.
* The signing key is a secret and is **never in the repository**. The operator creates it once, at release time, with `ytmuse-feed keygen` (the tool refuses to write a private key inside a git work tree or over an existing file). CI signs a release only from a protected `release` environment secret. Tests use throwaway keys made in a temporary folder.

### Feed payload

```json
{
  "schema": 1, "channel": "stable", "sequence": 7,
  "issuedAt": "2027-01-15T10:00:00Z", "expiresAt": "2027-04-15T10:00:00Z",
  "releases": [{
    "version": "1.2.0", "build": 120, "minimumSystemVersion": "27.0", "publishedAt": "2027-01-15T09:00:00Z",
    "notesURL": "https://github.com/OWNER/REPO/releases/tag/v1.2.0",
    "asset": { "url": "https://github.com/OWNER/REPO/releases/download/v1.2.0/YTMuse-1.2.0.dmg", "length": 123456789, "sha256": "<64 hex>" },
    "provenance": { "repository": "OWNER/REPO", "tag": "v1.2.0", "commit": "<40 hex>", "sbomSHA256": "<64 hex>" }
  }]
}
```

### Updater rules

Each rule is a test in `Packages/NativeMusic/Tests/UpdatesTests` (suite `T30`).

| Rule | Where it is enforced |
| --- | --- |
| Reject a tampered payload, a flipped signature bit, an unpinned key, a signature without the domain prefix, a non-canonical encoding, an oversized feed | `FeedVerifier.verify` |
| Reject a **downgrade**: a release is offered only if its version **and** build are strictly newer than the running app and it supports this macOS | `FeedVerifier.verify`, again in `UpdateStager.verifyBundle` and `BundleInstaller.install` |
| Reject a **replayed older feed**: the highest accepted `sequence` is remembered and an older one is a rollback; a stale feed expires | `FeedVerifier.verify`, `UpdateState.lastAcceptedSequence` |
| Validate **provenance**: the repository is the pinned one, the tag is `v<version>`, the asset and notes URLs are exactly that tag's download and release pages | `FeedVerifier.checkProvenance` |
| Verify the **asset**: length and SHA-256 equal the signed values before the image is ever opened | `UpdateStager.verifyAsset` |
| Verify the **app inside**: same bundle identifier, the version and build the feed described, newer than the running app, and **signed by the same identity as the running app** (its own designated requirement, read at run time; no Team ID is in the repository) | `UpdateStager.verifyBundle`, `SecurityCodeSignatureChecker`, `RunningSignature` |
| **Never install during playback**: asked at the start, after verification and immediately before the exchange; also holds automatic downloads while music plays | `BundleInstaller.install`, `UpdateController` |
| **Never install without an explicit restart**: installation needs a `RestartConfirmation`, which only the Restart to Update button creates (a source sweep proves it) | `RestartConfirmation`, `UpdaterGuardTests` |
| One **atomic exchange**: the staged app is copied beside the installed one, verified again as the copy that will run, then swapped; any refusal happens before anything is replaced | `BundleInstaller.install` |

An ad-hoc or unsigned build has no designated requirement a release could be matched against, so it cannot install an update. An install location the user cannot write is refused up front with a clear message; the person then replaces the app by hand.

### Checks and the daily schedule

* **Off by default; asked once** (BUILD06, T30.3). Until the person answers, no automatic request is made. The question appears once; either answer is recorded and it is not asked again. **Check Now** is an explicit action and always works.
* After opt-in the app checks **at most once every 24 hours while it is running** (one hour after a failure). There is no launch agent or daemon, so nothing runs when the app is not running.
* **"Automatic installation"** downloads and verifies the update in the background, never while music plays. It never swaps the app: the explicit restart is always the person's.
* **What a check sends:** one `GET` of `…/releases/latest/download/feed.json` with exactly four headers set by the updater (`Accept`, `User-Agent: YTMuse-Updater`, `Accept-Encoding: identity`, `Accept-Language: en`, a constant so the Mac's language list is not sent) plus the three the transport adds itself (`Host`, `Connection`, `Cache-Control`). No query string, no body, no cookie, no credential, no identifier, no version. The session is ephemeral with no cookie jar, credential store or cache; redirects are followed only to https on GitHub's release hosts. `RequestContentTests` captures the raw bytes on a loopback socket while a cookie and a credential for that host sit in the process's shared stores.

### Wiring to Settings (W27)

Both section 16 rows are wired to the updater through the settings store's `updates` owner (`SettingsOwners`), and the **Updates** page shows the updater's own section (`UpdatesSettingsSection`), which writes through the same store, so the page, Restore Defaults and search use one path.

| Row | Setting values | What it does |
| --- | --- | --- |
| Update checking ("Ask once; daily background check only after opt-in") | `askOnce` (default), `daily`, `manualOnly` = `UpdateController.state.mode` (`undecided`, `daily`, `manualOnly`) | nothing is requested until the person chooses; `daily` runs at most one check a day while the app runs; `manualOnly` leaves only Check Now; choosing `askOnce` or Restore Defaults asks again and checks nothing |
| Automatic installation ("Off while playing; explicit restart required") | on/off (default off) = `UpdateController.state.automaticInstallation` | **Download updates automatically**: an update is downloaded and verified in the background when nothing is playing. It is never installed by itself: installing is the **Restart to Update** button, which refuses while anything plays |

The rows say plainly that a source build has no feed: the controller is unavailable there, the same writes change nothing, nothing is requested, and the Updates page shows the reason instead of controls. Behavioural tests drive the real settings store, owner and controller (`SettingsEffectTests`: `updateChecking`, `automaticInstallation`, `withoutAFeedTheUpdateRowsWriteNothingAndNothingIsRequested`).

## Packaging and verification

| Script | What it does | Needs |
| --- | --- | --- |
| `scripts/package-release.sh` | Release build with a version, Developer ID signing (hardened runtime), DMG, notarization, stapling, checksum, SBOM, binary inspection, feed payload and signature | a Developer ID identity, a notarytool keychain profile and the feed key file, all named by environment variables; refuses to run without them, and with `--dry-run` only prints the plan |
| `scripts/check-distribution.py` | pins, licences, SBOM freshness; with `--app` inspects a built bundle for any browser, Python or Node runtime and any non-system library | nothing |
| `scripts/make-sbom.py` | writes or checks `Docs/sbom.cdx.json` | nothing |
| `scripts/scan-repository.py` | scans the tree, the whole history and the screenshots for sessions, cookies, tokens, keys, e-mail addresses, Team IDs and personal data | nothing |
| `scripts/make-public-snapshot.sh` | builds the publishable tree (without the harness evidence) in a new directory and scans it | a committed HEAD |
| `scripts/clean-checkout.sh` | clones the committed repository under `~/Projects`, runs the CI steps with no secrets, deletes the clone | nothing |

Feed tooling (`ytmuse-feed`) is the `FeedTool` executable of the package. This example runs as written: it makes a throwaway key and a sample feed in a temporary folder, verifies it as the app would, and deletes everything.

```sh run
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
tool="scripts/bin/swift run --package-path Packages/NativeMusic --quiet FeedTool"
printf 'pretend disk image' > "$work/YTMuse-1.2.0.dmg"
printf '{"bomFormat":"CycloneDX"}' > "$work/sbom.json"
$tool keygen --private-out "$work/feed.key" --public-out "$work/feed.pub"
$tool make-payload --repository example-owner/example-repo --version 1.2.0 --build 120 --asset "$work/YTMuse-1.2.0.dmg" --sbom "$work/sbom.json" \
  --commit 0123456789abcdef0123456789abcdef01234567 --sequence 1 --issued 2027-01-01T00:00:00Z --expires 2027-12-31T00:00:00Z --out "$work/payload.json"
$tool sign --key "$work/feed.key" --payload "$work/payload.json" --out "$work/feed.json"
$tool verify --feed "$work/feed.json" --public-key "$work/feed.pub" --repository example-owner/example-repo --current-version 1.0.0 --current-build 100 --now 2027-02-01T00:00:00Z
```

## What the binary inspection proves, and the one embedded-web allowance

`scripts/check-distribution.py --app YTMuse.app` walks the bundle and refuses any Python, Node, Electron, Chromium or CEF file or framework, any interpreter script, any marker string of those runtimes in a Mach-O, any non-arm64 slice, any library that is not under `/System` or `/usr/lib`, and an App Transport Security opt-out. **The hidden YouTube Music player is the system WebKit** (`WKWebView`), which is part of macOS: the app links `/System/Library/Frameworks/WebKit.framework` and ships no browser engine of its own. That is the single embedded-web allowance of the Playback addendum, and the inspection report records it (`uses_system_webkit`). There are no remote executable adapters: the page scripts the player runs are compiled into the app, and the source sweep refuses `dlopen`, run-time bundle loading, `JSContext` and starting an interpreter.

## App Store feasibility (a short note, not a commitment)

A Mac App Store variant is **optional** and Store approval is never mandatory for this project (BUILD07). Constraints known today:

* It would use the Store's update mechanism, so the in-app updater is compiled out (`UpdateComposition` already treats a build without a feed as unavailable).
* The Store requires the App Sandbox. The hidden WebKit player, App Groups, App Intents and the Keychain sharing already in use are sandbox-compatible in principle; the loopback OAuth listener, Apple Events scripting and the global hot keys need entitlements or exceptions that review may refuse. None has been tried.
* A variant must keep the same core functionality for eligible accounts and may not hide features from review or switch on unreviewed downloading later. Because the YouTube Music offline route is not available to this app at all (see the capability matrix), there is nothing to hide today.
* Store review of an app that plays a third-party service's streams through its own player may fail on service terms regardless of technical compliance. This is unassessed.

No App Store submission, identity or listing exists, and none is planned by this work.
