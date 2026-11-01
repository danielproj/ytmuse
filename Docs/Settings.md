# Settings, storage and local diagnostics (W27)

Code: `Packages/NativeMusic/Sources/Features/Settings/` (the registry, the store, the equalizer presets), `Sources/AppShell/Settings/` (the Settings window, the owner bindings, the local-data eraser and its real-root guard, the storage breakdown, the diagnostics centre, the composition), `Sources/Diagnostics/` (redaction, the bounded log, the run marker, the report, the support bundle, the opt-in profiler). Tests: `Packages/NativeMusic/Tests/SettingsTests/` and one scheduling test in `Tests/DownloadsTests/SchedulingTests.swift`; run with `scripts/test.sh --suite T27`.

## One table of settings

`SettingsRegistry.definitions` lists every setting once: its id, the exact section 16 row it belongs to, its category, its scope, its control, its default, where its value lives, whether the capability behind it exists, and a plain statement of the downstream effect. `specRows` is the section 16 table in the specification's own order, each row with the settings that implement it. `SettingsRegistryTests` parses section 16 out of `Docs/Product-Specification.md` and holds the registry to it: the same 26 rows in the same order, the exact default text, and the pinned default value of each setting.

Settings are kept in three **scopes**:

| Scope | Where | Key | Switching account |
| --- | --- | --- | --- |
| global (this Mac) | the app's one preferences store (the throwaway plist under QA isolation) | the setting's own key; the keys that existed before W27 are unchanged (`appearance`, `shell.resumeAfterWake`, ...) | unchanged |
| account | the same store | `settings.v1.account.<account uuid>.<id>` | only these change |
| window (reserved) | the same store | `settings.v1.window.<window uuid>.<id>` | unchanged |

The **window scope is reserved**: the store can keep a per-window value (tested with a synthetic definition) but no section 16 row is window-scoped in this build, so the Settings window offers none and `noSectionSixteenRowIsWindowScopedSoTheWindowScopeIsReservedAndSaysSo` pins that. `settings.schemaVersion` is stored; a store written by a newer build is never overwritten (an in-memory store is used and the newer one is left as it is). Removing an account deletes that account's keys and no one else's (SEC08). A damaged stored value reads as the default and is not rewritten.

## Categories, search, restore defaults

The Settings window has a sidebar of native categories (Accounts, General, Appearance, Playback, Library, Downloads, Integration, Privacy, Updates, Language, Storage, Diagnostics) and a search field above it: every word of the query must appear in a setting's title, detail, category, section 16 row or keywords, ignoring case and diacritics. **Restore Defaults** on a page restores only that page: stored keys of that category in the global scope and the live account's scope are removed, the owners of owner-held settings (login item, mini-player, download engine, output routes, notifications, Spotlight, global shortcuts, profiler) are asked to reset themselves once, and nothing else changes. No remote content is touched: there is no network type in any of this code (a source sweep proves it).

## What is real and what is not (T27.2)

A control is shown only when its capability exists. A row whose capability does not exist shows its reason and has no control:

| Section 16 row | State | Why |
| --- | --- | --- |
| Appearance, Artwork accent, Restore session, Mini-player always on top, Launch at login, New playlist visibility, Download storage, Smart Downloads, Automatic downloads on expensive networks, Track-change notifications, Spotlight private library indexing, Global shortcuts, Output | control | each calls its owner (`SettingsOwners`) and has an effect check |
| Crossfade / EQ / normalization | control, **scoped** | applied to every NATIVE session (music from files on this Mac). The hidden YouTube Music player is never processed. |
| Smart Downloads, Download storage | control, **scoped** | YouTube Music has no downloads on the Mac (`artifacts/harness/W15-offline-source-decision.json`); the limit applies to files added from this Mac; Smart Downloads has no source to suggest from |
| Motion, Background control, Dock icon, Headphone disconnect, Song/video preference, Analytics and remote crash submission | fixed policy, shown with its current effect | the specification gives a default and no alternative; W21, W22, W17 own the behaviour |
| Audio quality | **unavailable** (W34) | the hidden player chooses its own audio quality and the app cannot ask for another; a native quality choice arrives with the audio engine work in W34. Diagnostics shows what the player reported |
| Autoplay radio | **unavailable** (W05, W38) | YouTube Music continues playback with its own radio; an app-owned autoplay continuation is the queue's (W05) and the radio feature's (W38) |
| Replace explicit queue | control, **scoped** (W05) | applies to what starts music from files on this Mac: Ask (a question), Keep my queued songs, or Replace them, per account. YouTube Music keeps its own queue, so the choice does not apply to it |
| Download/error notifications (system opt-in) | control, **scoped** (W26) | a second opt-in on W26's notification system: downloads that finish and fail, and sign-in problems, are posted as system notifications only after the person turns it on, never when the notification permission is not granted, with a fixed headline and at most the item's title the person already sees in Downloads, and no account name, link, path or error text |
| Update checking, Automatic installation | control, **scoped** (W30) | wired to the updater (`Docs/Distribution.md`): the daily check only after opt-in; automatic installation is a background download that is held while playing and never swaps without the explicit Restart to Update. A build with no update feed (every source build) says so and does nothing |

The unavailable set is pinned by a test (`theRowsThatCannotBeHonouredAreExactlyTheKnownOnesAndEachSaysWhy`) and is the list that fails release coverage until each capability exists.

## Local-data actions and real-data safety

The privacy reset, clearing an account's cache, a per-category reset and removing an account work **only on the stores injected into the running session** (`LocalDataRoots`), and the guard checks what the destructive code actually touches, not what the session declares (Rework 1, review finding 1).

**One guarded wrapper per destructive API, enforced at the call.** Nothing in the product deletes, replaces or rewrites through a raw API:

| What | The only way | What it refuses at the call |
| --- | --- | --- |
| delete or replace a file or folder | `GuardedFiles` (Domain) | a path outside the directory its owner injected (`..` and symlinks resolved), and in an isolated process any path inside a real store: the application directory, the owned-audio store (`~/Library/Application Support/local.native-music.owned-audio`) and the App Group containers |
| Keychain delete / update | `GuardedKeychain` (AccountSession) | in an isolated process any service name that is not test-named |
| preferences write / remove | `GuardedDefaults` (Domain), bound to the session's own store | the real preferences domain in an isolated process |
| Spotlight index | the app target's `systemIndex()` | the call itself in an isolated process |
| move or copy a file or folder | `GuardedFiles.move` / `copy` (both ends inside the owner's directory, neither inside a real store) | the same as a delete |
| remove by name inside an open private directory | `unlinkat` in the artwork cache and the private download directory only | cannot leave the directory handle its owner opened without following links |

`GuardedFiles` has one public initializer, `init(root:)`: the process decides (`ProcessIsolation`) and the real stores are the real ones. A test's fake home and forced isolation go through an internal initializer, and the isolation option can only TIGHTEN the check, never loosen it (`isolated: false` is still refused in a test process). `RealStores.current` is internal to `DestructiveGuard.swift`; code that only compares a path with the real stores calls `RealStores.resolved(...)`, and the sweep forbids naming `.current` anywhere else.

`SettingsGuardTests.everyDestructiveCallInTheWholeProductSitsInsideItsOneGuardedWrapper` sweeps **all** of `Packages/NativeMusic/Sources`, `App/Sources` and `Extensions` and fails on `removeItem`, `trashItem`, `replaceItem`, `moveItem`, `copyItem`, `linkItem`, `createSymbolicLink`, `unlink`, `SecItemDelete`, `SecItemUpdate`, `UserDefaults.standard`, `UserDefaults()`, `UserDefaults(suiteName:)` outside the preferences factory, `removePersistentDomain`, `setPersistentDomain` and `CSSearchableIndex.default()` / `deleteAll...` outside their wrapper. Each rule proves itself on a planted line first; the mutation matrix plants each of the critic's forms and requires the sweep to catch it. The guards are tested so that a broken guard cannot perform the protected action: the Keychain wrapper takes an injectable backend (the tests pass a recording fake and never a production service name to a real call), the file wrapper is tested against a fake home, the defaults wrapper against a throwaway suite, and the verification is a pure decision function. Honest limits: files are still *created and atomically written* by their owners inside their own directory (a write cannot delete another store, but an owner handed a wrong directory would write there), and `unlinkat` in the two private-directory owners is trusted to stay within the directory handle it was given.

* `DestructiveActionGuard.verify(roots, touches:, confirmation:)` runs first in every action. `touches` (`LocalDataTouches`) is read from the **live objects** the eraser will use: the artwork cache directory, the widget snapshot directory, the owned-audio directory, the Keychain namespaces the vaults report, the preferences store and the index. In an **isolated** session (every test process, every Debug launch not explicitly opted in, every QA launch) it refuses any of them that is a real store, outside the temporary folder, not test-named, or different from what the session declared. A confirmation does not override it. A session that is **not** isolated acts only with a `PersonConfirmation`, which only the confirm button creates.
* **Restore Defaults** on a page goes through the same preflight (`SettingsStore.preflight`) before any key changes, resets only that page's own keys and owners, and never resets the remembered output device: that has its own action, *Forget Remembered Output*, because it is a choice of hardware rather than a preference of the page.
* The Debug build shows the guard's own verdict in the Settings sidebar (`localDataRoots`: `roots: isolated; guard=accepted; ...`), computed by `DestructiveActionGuard.verdict` over the roots and the touches; the UI test reads it before it changes or presses anything and refuses unless it says accepted.
* **The local reset** removes every account through the account lifecycle (its Keychain items and keys, database partition including queued writes, snapshots and indexes, private files, downloads, artwork, history, and its own settings), clears caches, the Spotlight entries and the widget snapshot, **the owned-audio store**, removes the diagnostics files, turns launch at login off, restores every setting of every scope (including account-scope settings of an account that no longer exists) and empties the preferences root. Every step runs even if an earlier one fails; the report names the failures; running it again finishes the job. Nothing is requested from YouTube, Google or any other host: a queued write that was never sent is deleted unsent.
* **Removing an account** by any path (the Accounts sheet, the Settings page, a retry at launch) deletes that account's settings, because the settings store is an account-lifecycle participant (SEC08).
* **Account-local cache clearing** removes one account's cached artwork (memory and disk) and nothing else: not its downloads, playlists, queue, history or queued writes.

## Storage breakdown (T27.3)

Settings > Storage shows, for each account on this Mac, the pinned and automatic download bytes and the cache bytes, and the total. The figures are the owners' own: download bytes come from the per-account usage summaries the download budget itself sums (`DownloadScheduler.usage(for:)`, `usageAcrossAccounts()`), cache bytes from the artwork pipeline (`cacheBytes(accountID:)`, `diskSnapshot()`). Bytes that belong to an account the roster no longer lists are shown on their own line, and the pane says whether everything adds up to what the download engine and the artwork cache report (`StorageBreakdown.reconciles`, with pinned and automatic bytes reconciled separately). The ledger is also compared with what W14's encrypted object store holds on disk, in the ledger's own terms (each object's ciphertext chunks plus its index files, charged at least the per-object allowance); a disagreement is shown, not hidden (`objectStoreAgrees`). Bytes in a download directory no listed account owns are enumerated from the directories themselves.

## Diagnostics (DIAG01, DIAG02, SEC03)

Settings > Diagnostics shows the app and macOS version, the service adapter and its own version (`MusicSessionReading.adapterVersion`, supplied by `YouTubeMusicAdapterInfo.version`), the account-capability status in words (no identity), the playback engine in use and the **actual** media quality: each of codec, bitrate, sample rate and route is a value or "not reported" with the reason. The hidden YouTube Music player reports none of the first three, and the screen says so. Cache sizes, a count per fault category and one line that tells a **source outage** (YouTube Music or the network did not answer, or answered in a shape the parser does not recognise) from a **local crash** (the previous run left no clean-quit marker) complete it.

* The log is local, redacted when an event is recorded and again when it is exported (with what the app has learned since), bounded to 200 entries / 14 days / 400 characters each, and its components are a fixed vocabulary.
* **Redaction** (`DiagnosticRedactor`) removes cookies, authorization headers, tokens and JWTs, signed query parameters (a URL keeps its host only when the host is one the app names: Google sign-in, YouTube Music and the artwork hosts; any other host, including a media host, is replaced whole), email addresses (plain, percent- and entity-encoded), home-folder paths, long opaque runs, and every string the app knows is private: account names and handles, library playlist names, search terms (matched ignoring case, diacritics and URL / JSON escaping). It is idempotent.
* **Support bundle**: one JSON document, previewed in full before saving; what is saved is byte for byte what was previewed, written to a destination chosen in the save panel (a temporary directory in tests), owner-only, at most 256 KiB, never sent anywhere. It holds no media, credentials, names, searches or links. When the report cannot be built the bundle still says what failed, redacted.
* **Profiling** is off until the person turns it on. While on it keeps aggregate timings for a fixed vocabulary of events in one JSON file of at most 64 KiB (at most 100 samples per event); turning it off deletes the file.

## Not covered here

Live observations are not unit-test results: a real Mac's reset against the real stores, an installed widget or Spotlight entry disappearing, a real notification prompt, and a hidden player reporting quality. See the node report for what was and was not observed.
