# Local native development

Prerequisites: an Apple Silicon Mac running macOS 27 or later with Xcode **27.2 (27B52)** selected through `xcode-select`, Apple Swift **6.4.2** and macOS SDK **27.2**; the deployment target stays macOS 27.0. W01 established the baseline on Xcode 27.1 (27A9275), Swift 6.4 and SDK 27.0 on macOS 27.0.1 (26A434). On 2026-10-30 the Mac updated itself to Xcode 27.2 and macOS 27.2 (26B123), the old toolchain was no longer installed, and the operator moved the pin (`artifacts/harness/toolchain-rebaseline-2026-10-30.json`). `toolchain.json` and `scripts/check-toolchain.sh` pin the observed baseline. No stable-toolchain change was needed. Swift language compatibility mode is 6; compiler and package tools version are 6.4.

From the checkout root:

```sh
./scripts/build.sh
open .build/xcode/Build/Products/Release/YTMuse.app
./scripts/test.sh --suite T01
```

The build uses arm64, deployment target 27.0, a checked-in shared Xcode scheme, and a local Swift package. No account, signing team, certificate, private `.xcconfig`, downloaded dependency or service credential is needed. UI tests require a logged-in macOS graphical session with Xcode testing automation enabled. Domain tests alone: `swift test --package-path Packages/NativeMusic`. Discovery: `swift test --package-path Packages/NativeMusic list`. `TEST_RESULT_PATH` selects a new xcresult output path, and `BUILD_DIR` changes the derived-data path. Build arguments after `scripts/build.sh` are passed to xcodebuild; failures propagate. The test runner accepts `--suite T01`, `T02`, `T03` and `T04`; unknown or unimplemented suites fail with exit 64.

Use File → Open (Command-O) to open/focus the native main window, YTMuse → Settings (Command-comma) for appearance, and Quit (Command-Q) to terminate. Settings supports System/Light/Dark, stores the choice locally, applies it to all windows, and restores the default. Service accounts are unconnected. Authentication, catalog, playback and downstream features remain assigned to their nodes, with all release gates open.

`local.native-music.development` is a reversible local development bundle identity, not an owned public distribution identity. Local app signing is ad-hoc; it does not demonstrate Developer ID, notarization or distribution acceptance. UI test runners disable hardened runtime to load local ad-hoc test bundles. Release app configuration requests hardened runtime; inspect actual signing when making release claims.

### Stable local signing (optional)

Every ad-hoc build has a different code signature, so macOS no longer recognises the app that wrote the YouTube Music session to the login keychain. YTMuse never shows Keychain UI (`KeychainInteraction` disables it process-wide and every vault query carries `kSecUseAuthenticationUIFail`). After an ad-hoc rebuild, the saved session therefore reads as **Session expired — sign in again**, and signing in once writes a record the new build can read. Local data is kept.

To avoid that on every rebuild, sign local Release builds with your own Apple Development certificate. Its designated requirement does not change between builds:

```sh
security find-identity -v -p codesigning          # pick your "Apple Development: …" identity
YTMUSE_CODESIGN_IDENTITY="Apple Development: Your Name (TEAMID)" ./scripts/build.sh
```

`YTMUSE_CODESIGN_IDENTITY` takes the identity name or its 40-hex SHA-1. The script:

- refuses any value that is not an Apple Development identity name or SHA-1 (exit 64);
- before signing, resolves the value with `security find-identity -v -p codesigning` and refuses (exit 65) unless it names a valid identity whose certificate is `Apple Development: …`, so a Developer ID or unknown SHA-1 never signs the bundle;
- builds with the widget extension embedded (only a build given an identity embeds it) and signs **inner to outer** through `scripts/sign-bundle.sh`: the extension first, then the app, with the same identity, hardened runtime and the entitlements `App/NativeMusic.entitlements` and `Extensions/NativeMusicWidget.entitlements` in which `$(TeamIdentifierPrefix)` is filled in from the identity's Team ID (learned by signing a throwaway copy; the Team ID is never written into the repository or printed). See `Docs/Widgets-Spotlight.md`;
- verifies the signature strictly;
- fails (exit 65) unless the leaf authority is `Apple Development: …` and the app and the extension carry the same team, restoring ad-hoc signing first (both, with entitlements that hold no App Group) so a refused identity is never left on the bundle;
- prints only a fixed line ("YTMuse.app and its widget extension signed with the configured identity (extension first)"), never the identity name or team ID.

Without an identity the build is ad hoc: **no widget extension is embedded and no App Group is claimed**, so the app never touches a group container.

`Tests/Build/test-build-signing.sh` exercises these rules with shimmed `xcodebuild`, `codesign` and `security`; it never touches a real keychain. Unset, the build stays ad-hoc exactly as before. No identity, team or certificate is stored in the repository. The first launch after switching to a signed build still sees the old ad-hoc record as unreadable, so sign in again once. This is local development signing only: it is not Developer ID, notarization or distribution evidence.

## Structure and dependencies

`Packages/NativeMusic/Package.swift` declares all 15 specification modules. `scripts/module-dependencies.json` is the reviewed dependency direction. `scripts/check-boundaries.py` checks the actual manifest, cycles, undeclared source imports and provider/JSON/network contamination in Domain and views. AppShell composes Features, DesignSystem and Domain. Domain contracts, SQLite persistence and local account lifecycle are implemented by W02–W04; live providers/network/playback implementations remain with their assigned nodes. The test target contains a real persistence-value validation and fallback assertion for the currently working preference.

`Extensions` provides unembedded native extension support scaffolding, with production extension registration deferred to W24–W25 where the required platform behavior and identity are verified. Extensions never own credentials or an independent player.

No third-party dependencies are used. `Packages/NativeMusic/Package.resolved` records zero remote pins; no remote resolver operation is necessary. If adding dependencies later, retain compatible licenses and lock exact revisions. Python 3 is used only for local project/boundary tooling; it is not bundled or run by the application. Project regeneration is deterministic: `python3 scripts/generate-project.py`. The checked-in project is directly buildable without regeneration.

## Clean local checkout

```sh
git clone --no-local /absolute/path/to/youtube-music /tmp/native-music-clean
cd /tmp/native-music-clean
./scripts/build.sh
./scripts/test.sh --suite T01
open .build/xcode/Build/Products/Release/YTMuse.app
```

Keep fixtures sanitized under `Fixtures` and license records under `Resources`. Credentials never belong in either. T01 establishes only the native W01 baseline; it cannot close G01–G09 or qualify live service, hardware, performance or release acceptance.

W02 domain contracts and deterministic actor/property checks run with
`./scripts/test.sh --suite T02`. This route requires nonempty discovery of
`DomainContractTests` and does not request service accounts. `T01` continues to
build extensions, run all package tests and exercise the native app UI. Unknown
suite IDs fail with exit 64. See `Docs/Architecture.md` and
`Fixtures/W02/manifest.json` for isolation and synthetic evidence rules.

W04 local lifecycle, isolated native Keychain and synthetic-account UI checks run with `./scripts/test.sh --suite T04`. The separate `NativeAccountTestHost.app` is a test-only product and is not embedded in `YTMuse.app`. The normal app has no invented accounts and keeps Google sign-in unavailable until the verified Music browser/session adapter is supplied. The account module now depends on Persistence for the SQLite roster; Features depends on AccountSession, and AppShell composes both. These edges preserve the provider/UI boundary.

## Reproducible CI, the updater and the repository checks (W30, suite T30)

`./scripts/test.sh --suite T30` is the secret-free pull-request suite. It runs, in order: the toolchain pin; the module boundaries; the dependency, licence and SBOM checks (`scripts/check-distribution.py`); the workflow rules (`scripts/check-workflows.py`); the repository scan (`scripts/scan-repository.py`); the documentation checks, **which execute the examples marked `sh run`** (`scripts/check-docs.py`); the signed-package script over shimmed tools (`Tests/Build/test-package-release.sh`); the updater tests, counted (discovered against executed); a Debug build of the app and the inspection of that binary for any browser, Python or Node runtime. `T30_WHOLE_PACKAGE=1` adds every headless package test, counted; `T30_HEADLESS=1` skips the one native UI test; `T30_SCAN_ALL=1` adds the history and screenshot scans.

`scripts/ci.sh` is `T30` with the whole package and no UI; `.github/workflows/ci.yml` runs it, and `scripts/clean-checkout.sh` runs it in a fresh clone under `~/Projects` with `env -i` (so no token or credential of the caller can reach it) and then deletes the clone:

```sh
./scripts/clean-checkout.sh
```

CI has no secrets. A release needs the account holder's Developer ID identity, a notarization profile and the update feed key; those are read from the environment by `scripts/package-release.sh`, which only the operator runs. The updater's design, the signed feed and its rules are in [Distribution.md](Distribution.md); what must happen before anything is published is in [Publishing-Checklist.md](Publishing-Checklist.md).
