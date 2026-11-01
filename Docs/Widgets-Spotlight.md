# Widgets and Spotlight indexing (W25)

The contract for MAC05, MAC06, ARCH03 and ARCH09 as the app ships them. Code: `Packages/NativeMusic/Sources/WidgetShared/` (the snapshot, the store, the command gate and button intent, the timeline provider and the views), `Sources/SystemIntegration/Spotlight/` (the Spotlight rules and indexer), `Sources/AppShell/Widgets/` and `Sources/AppShell/Spotlight/` (the app's side), `Extensions/Sources/NativeMusicWidget/` (the extension's entry point), `App/Sources/SystemWidgetSupport.swift` and `App/Sources/SystemSearchableIndex.swift` (the only files that name WidgetCenter, the App Group container and the system's Spotlight index). Tests: `Packages/NativeMusic/Tests/PlaybackTests/Extensions/` (`scripts/test.sh --suite T25`); `scripts/check-widget.py` and `scripts/check-intents.py` read the built bundle.

## The widget (MAC06)

One WidgetKit widget, small and medium families, in one sandboxed app extension (`NativeMusicWidget.appex`, bundle id `local.native-music.development.widget`, extension point `com.apple.widgetkit-extension`). Its whole job is to read **one file** from the App Group and draw it.

```
app: Now Playing owner --onChange--> WidgetSnapshotPublisher --atomic write--> <App Group>/now-playing-snapshot.json
                                                          \--coalesced--> WidgetCenter.reloadTimelines (app target only)
extension: TimelineProvider.read() --> WidgetDisplay --> Small/MediumNowPlayingView   (policy .never; no timer, no request, no player)
widget button: WidgetTransportIntent (AudioPlaybackIntent) --system runs it IN THE APP--> WidgetCommandBridge --> W24's channel --> PlaybackModel.remote(_:)
```

### The snapshot (what is in the App Group)

`now-playing-snapshot.json`, at most 96 KB, owner-only (0600), replaced atomically (staged in the same directory, swapped in with `replaceItemAt`). Keys, and only these (the reader refuses a file with any other key): `schema`, `state`, `title`, `artist`, `artwork`, `capabilities`, `scope`, `serial`, `writtenAt`.

| Field | Contents |
| --- | --- |
| `state` | `playing`, `paused`, `advertisement`, `idle`, `signedOut`, `locked` |
| `title`, `artist` | the playing item's, each at most 120 characters; absent in every state but `playing` / `paused` |
| `artwork` | one JPEG thumbnail (at most 192 px, at most 32 KB) made from the bytes the app already holds; no URL is ever written or fetched |
| `capabilities` | `playPause`, `next`, `previous` booleans, computed from the same capabilities the media keys use |
| `scope` | `accountToken` (the first 16 bytes of SHA-256 over a fixed label and the account id, hex) `generation` (the account session's generation within one launch) and `launch` (a random nonce made once per process: the generation restarts at every launch, so on its own it cannot tell this launch from the last). The account id itself is never written |

**Never** in the group: a cookie, token, account email, request, queue, history, or any private playlist's name. A redacted state (`signedOut`, `locked`) is validated to carry no title, artist, picture, scope or button; `isConsistent` is checked on write and on read, and an advertisement carries no song. Nothing else is written into the group: no cache, no log, no second file (a staging file exists only inside one replace; `delete` removes any leftover).

When the file is written: only when the *visible* content differs from the last write (a moving clock changes nothing the widget shows), so a burst of Now Playing updates is one write; a timeline reload is requested after a write, at most once per two seconds, the trailing one delivered. The publisher is driven by `NowPlayingCenter.onChange` (the one place the app already publishes the playing item and its commands), by the user-session notifications, and by account barriers. It never polls and reads no store.

| App situation | Snapshot |
| --- | --- |
| signed in, item playing / paused | `playing` / `paused`, title, artist, thumbnail, buttons per capabilities |
| advertisement | `advertisement`, no title / artist / picture, buttons per capabilities (an ad cannot be skipped) |
| signed in, nothing published (after the item ended, or never played) | the last item as `paused` with every button off, or `idle` with no content |
| the Mac's user session is not the active one (fast user switching) | `locked`, contentless |
| **sign-out, account switch, removal of the live account** | the snapshot is **replaced by the contentless signed-out one** (no title, artist, picture, stamp or button; the widget shows "Sign in to YouTube Music in YTMuse."), the reload is immediate, and nothing is written for the ended session again |
| **quit** | the file is **deleted** and the reload is immediate (not coalesced: the process is going), so no stamped button survives |
| removal of another account | nothing changes here |
| the app finished starting with nobody signed in | the signed-out snapshot; before that is known (the account is still being restored) no file |

The widget turns a missing (after quit, or before the app has run), unreadable or foreign file into the "Open YTMuse" redacted view, `signedOut` / `locked` into the redacted view with one sentence and **no title**, and, whatever was cached, draws the locked view when the system asks for privacy redaction (`redactionReasons.contains(.privacy)`). The gallery preview is fixed sample text.

### How the surfaces follow the account lifecycle

The playback authority is the lifecycle participant that clears the live account, and it clears it BEFORE its plain barrier handlers run, so those cannot tell who is leaving. It therefore hands listeners a **barrier event** (`quit`, `detach` = sign-out or switch, `removal`) that carries the departing account and session, captured before it clears its own scope, and tells them when an account becomes live (`onScopeBound`). The widget publisher and the Spotlight controller are wired to those events in one place (`SystemSurfaceWiring`); `SurfaceBarrierTests` drives the authority's real `detach`, `removeLocal` and `quit` and reads what is left in the group directory and the index (deleting a removal line fails a test). A refresh that is in flight when an account is removed or switched cannot put the account back: Spotlight refreshes are fenced by account and session (a removal bumps the account's epoch; a stale fence is dropped, and what an in-flight write put in after the removal is deleted again).

### Where a button's action executes

`WidgetTransportIntent` conforms to the SDK's `AudioPlaybackIntent`: the system runs such an intent **in the app's process**, not in the extension (the built metadata records it as an audio-starting system intent and `isDiscoverable == false`, which `check-intents.py` requires). So the action meets the one playback owner and the same gates as the window and the media keys; the extension holds no player and no session. If the system ever ran it inside the extension anyway, `WidgetCommandReceiver.shared` has no handler there, the intent says "Open YTMuse to use this button." and does nothing: there is no independent fallback. The public mechanism is the audio-playback intent protocol; running it in the app is the system's behaviour, **observed only on an installed widget (W41)**, never inferred from a build.

In the app: `WidgetCommandBridge` checks the stamp the button was drawn with (`accountToken`, `generation`, `launch`) against the live scope (`WidgetCommandGate`): signed out, another account, or any other session of the same account is refused, with one sentence that names no account ("This widget is out of date. Open YTMuse and it will refresh."). The scope is read **again** immediately before the command is sent, because waiting for the channel is where an account can change. A current stamp goes through W24's `IntentCommandChannel` (`toggle`, `next`, `previous`), i.e. `PlaybackModel.remote(_:)`: capabilities, advertisement rules, Play here, Now Playing. Nothing is queued: a command is the intent call itself, so there is no stale command to replay after a relaunch; a widget drawn in an earlier LAUNCH carries that launch's random nonce (the per-launch generation counter alone would repeat) and is refused, whatever the generation. A widget button is not a user action in the window, so it donates nothing.

### What the extension can and cannot do

Sandboxed; entitlements exactly `com.apple.security.app-sandbox` and the one Team-ID-prefixed App Group. No network client or server, no Keychain access group, no file access, no temporary exception. It links Foundation, SwiftUI, WidgetKit, AppIntents, AppKit, CryptoKit, ImageIO and the app's `WidgetShared` / `DesignSystem` only; no WebKit, Security, Network or AV frameworks, no `URLSession`, `SecItem`, `WKWebView` or `AVPlayer` symbol (`check-widget.py`, source and built binary). The timeline policy is `.never`; the extension never calls WidgetCenter. The app has one entitlement: the same group.

### The App Group id and signing (F2)

On macOS 15 and later a non-App-Store app reaches an App Group container without the "would like to access data from other apps" prompt only if the group id starts with the app's **Team ID** (or a provisioning profile authorises it). So the group is `<TEAMID>.local.native-music.development`:

* Both entitlement files (`App/NativeMusic.entitlements`, `Extensions/NativeMusicWidget.entitlements`) say `$(TeamIdentifierPrefix)local.native-music.development`. **No Team ID is ever written into the repository** (a test and `check-widget.py` fail on a literal one). The prefix is filled in at signing time from the signing identity's team.
* Every Xcode build (ad hoc, unsigned, test, worktree) signs with `App/NativeMusic-adhoc.entitlements` (no entitlement) and `Extensions/NativeMusicWidget-adhoc.entitlements` (the sandbox only). Such a build **embeds no extension** (`scripts/embed-widget.sh` defaults to NO and signs nothing), holds **no App Group**, and the code never looks the container up: the app and the extension read the group id from their Info.plist key `YTMuseAppGroup`, whose value is `$(TeamIdentifierPrefix)local.native-music.development`; without a team prefix that is not a valid id, `WidgetIdentity.appGroup(in:)` returns nil and no `containerURL` call is made (neither prompt nor creation). The widget is built beside the app (the app depends on it) but not copied into it.
* `scripts/build.sh` embeds the extension **only when it is given `YTMUSE_CODESIGN_IDENTITY`**, then calls `scripts/sign-bundle.sh`: it learns the identity's Team ID by signing a throwaway COPY of the extension, expands the entitlement templates into private temporary files, writes the full group id into both Info.plists, then signs **the extension first, then the app, with the same identity** (hardened runtime), verifies the bundle, requires an Apple Development authority and the same team on both, and otherwise restores ad-hoc signing (no group) and fails. It never prints the identity or the team. `scripts/check-signing.py --self-test` proves the order, the content and the failures against a stub `codesign` (run by T25, as is `Tests/Build/test-build-signing.sh`).
* `scripts/check-intents.py --app` decides by the bundle's signature: with no Team ID it requires NO extension and NO App Group; with a team it requires exactly the widget, signed by the same team, and exactly the team-prefixed group in both signatures with nothing else in the extension. The signed branch is proved on planted bundles and is observed on the operator's own signed Release build (`check-intents.py --app <that build>`).

**Not established here** (live list): that a real Apple Development identity signs a real bundle this way and that macOS then lets the app and the sandboxed extension use the group with no prompt; the extension loading at all with a development identity and no profile.

### Embedding and registration

A worktree build never embeds the extension, so the system is never offered one from a build directory; `YTMUSE_EMBED_WIDGET` defaults to NO (and `scripts/test.sh` exports NO for UI runs). Only a build with a signing identity embeds it. Because the setting changes what the app bundle holds, use a separate `BUILD_DIR` if you embed by hand (flipping it in one derived-data folder leaves a stale seal). No test adds a widget, opens the gallery or Notification Center, or queries or alters installed widgets (`WidgetSpotlightGuardTests` sweeps for `WidgetCenter`, `pluginkit`, `chronod`, `lsregister`, `notificationcenterui`).

## Real-data safety

* **App Group location.** A normal launch passes the group container in from the app target (`SystemServices.groupDirectory`, evaluated lazily, and nil without a Team-ID-prefixed group id). An isolated launch and every test never ask for it: `LocalAccountBootstrap.resolveSystemSurfaces` gives them `<isolation root>/app-group` (removed with the isolation root), a recording reloader and an in-memory index, and applies `WidgetSnapshotStore.refusesRealContainer` as a fatal `precondition`. The guard sweeps every package source, test, script and the UI tests for the container call, the folder name, `WidgetCenter` and the system's Spotlight index; only `App/Sources/SystemWidgetSupport.swift`, `App/Sources/SystemSearchableIndex.swift` and the extension's entry file may name them (and each rule is proved on planted lines). `ProductionStoreGuardTests` carries the same rule for tests.
* **Spotlight.** `CSSearchableIndex` writes to the account holder's real index, so nothing in a package, test, probe or mutation can name it. Tests and isolated launches use `InMemorySearchableIndex`.

## Spotlight (MAC05)

**Opt-in, off by default** (Settings > Spotlight; both choices are stored in the app's preferences store, a throwaway plist in an isolated run). The second choice cannot be turned on before the first.

| Entry | Indexed when | Domain |
| --- | --- | --- |
| saved songs, liked songs, saved albums, library and followed artists (public catalog items) | indexing is on | `…spotlight.account.<token>.catalog` |
| app actions (Play or Pause, Next, Previous, Search, Show Queue): a title, no account data | indexing is on | `…spotlight.actions` |
| library playlists, uploads, this Mac's listening history | indexing is on **and** the private option is on | `…spotlight.account.<token>.private` |

The library page does not say whether a playlist is private, so every library playlist is treated as private and shown only with the second choice. Podcasts and saved episodes are not indexed (not covered by this node). Only rows the windows have already loaded are indexed; indexing makes no request. A domain holds at most 2,000 entries. An entry is a title, one line (artist or detail), and an identifier that carries the account token and the item's service ids (never its title).

Lifecycle (`SpotlightIndexer`, `SpotlightController`): the first reconcile of a domain in a launch deletes the domain and indexes the current set (an item unsaved while the app was closed does not outlive it); later reconciles send only the difference. Turning the private option off deletes the private domain; turning indexing off deletes the app's whole root domain; **sign-out** (no live scope) removes every account's entries and keeps only the actions; **switching accounts** removes the previous account's entries as soon as the next account is live; **removing an account** (and the account barrier) deletes both of that account's domains, public and private, at once, through the lifecycle participant and the barrier handler. Removal and sign-out run from the authority's barrier events (see above), not from a plain barrier handler. Opening a result is accepted only for this app's identifiers and, for an item, only if its account token is the live account's; it then goes through the same channel as everything else (`play`, `toggle`, `next`, `previous`, `showQueue`), so Play here, the ledger and the permits apply. An upload opens the window (uploads do not play from here).

## Live checks (never counted as passes)

Installed-widget behaviour is W41's. Not observed in this node:
* the widget in the gallery on a real desktop (small and medium), its look in light and dark, with and without artwork, and the redacted views including the system's privacy redaction;
* that the button intent really runs in the **app's** process from an installed widget (and what the system does when the app is not running: a background launch, how long it takes, that a cold-launched app refuses the old stamp and nothing plays);
* with a REAL Apple Development identity: that `build.sh` produces a bundle macOS accepts, that the extension loads, that the app and extension reach the Team-ID-prefixed group with no prompt (and whether any prompt remains), and `check-intents.py --app` on that build;
* the extension's process activity: no network request, no wake-up outside timeline reloads (Activity Monitor / `nettop` on an installed widget);
* timeline reloads reaching the widget promptly after a track change, and not otherwise;
* fast-user-switching and screen-lock behaviour of the `locked` state (only the public user-session notifications are used; the screen lock itself is not observed);
* Spotlight: the entries appearing and disappearing in the real Spotlight UI after enabling, the private option, sign-out and account removal; clicking a result; the app actions in Spotlight's actions; index size limits and throttling;
* that a worktree Debug build (without the extension, via `YTMUSE_EMBED_WIDGET=NO`) is not offered by the system, and what LaunchServices does with the embedding builds.

## Limits (stated, not hidden)

* There is no intent extension (W24); the single extension is the widget. The "command channel" is the intent call itself, in the app process; no command file is written into the group.
* `locked` is the user-session case only. A screen lock is not observed (no public notification), and the system's privacy redaction covers surfaces that ask for it.
* The quit barrier deletes the snapshot (and reloads at once), so between a quit and the next launch the widget shows the "Open YTMuse" view rather than the last item.
* Native-engine media (owned audio, downloads) plays with no YouTube Music scope; with no account scope the widget has no file, by design.
