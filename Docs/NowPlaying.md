# Now Playing, media keys and accessory commands (W23)

This is the contract for MAC01, MAC02 and ARCH03 on the playback owner. The code is `Packages/NativeMusic/Sources/SystemIntegration/` (`NowPlaying.swift`, `RemoteCommands.swift`) and `Sources/AppShell/` (`RemoteCommandLayer.swift`, `PlaybackPanel.swift`); the tests are `Tests/PlaybackTests/SystemMedia/` (`scripts/test.sh --suite T23`).

## What is published (MAC01, T23.1)

| Field | Value |
| --- | --- |
| Title, artist, album, artwork | the item's own; an album or picture the source did not give is absent, never invented |
| Duration | the item's length; **absent** for a live stream and for an advertisement |
| Elapsed time | the position at the moment of the update (the update is the timeline anchor); absent for a live stream and an advertisement. While a receiver plays (AirPlay external playback) it is the receiver's own last report, never the local clock |
| Rate | the page element's real speed while playing (W18), 0 whenever the clock is not advancing (paused, buffering, a route lost, an advertisement) |
| State | playing only when the page is playing **and** the person wants it playing, so a pause is shown the moment it is commanded, not a report later |
| Route (W22) | part of the published item (`NowPlayingRoute`: this Mac's output name, or AirPlay). MediaPlayer has no key for a route, so it is not forced into the title or artist; macOS shows the real output route itself. The route changes the state the system is told (a lost route is a pause) and is replaced in the same update as the item |
| Advertisement | the system is shown "Advertisement" as the title and nothing else: no artist, album, picture, duration or clock of the song the ad interrupts, and no title invented for the ad. The state is playing; seek and skip are off |

An item change, an advertisement or an account barrier replaces everything in one update. The dictionary is rebuilt from the new item alone, so the previous artwork, state and route cannot survive it.

## One owner (T23.2)

`PlaybackModel.nowPlaying` is the only `NowPlayingCenter` in the app, and `PlaybackModel.remote(_:)` the only entry for a remote command. Windows, the mini-player, the status popover and full-screen Now Playing read the model; none of them registers anything (`RemoteOwnershipTests` sweeps for it). The system object (`RemoteCommandSystem`) holds the registrations for exactly one owner: a second `NowPlayingCenter` asking for them is refused and publishes nothing, and asking again while owning is one registration, not two.

The owner **attaches** the moment there is an item to act on (a started item, one loading, or a restored paused item) and **detaches** — removes every target, switches every command off and clears Now Playing in the same step — when:

- the account changes, signs out, is removed, or the app quits (the authority's barrier does it for every barrier handler, so it works with no window open);
- the finished item has nothing after it, for the hidden player and for a native session alike (a 10 s grace, because the queue may move on by itself; Now Playing says stopped at once, and a finished item that already let go never takes the keys back on a device or route change; only a new item or Play does);
- the page is torn down, or the native session closes.

A native session keeps Now Playing right on its OWN events: `PlaybackSession` tells its owner after every engine event except position ticks (an item ended, the next one started, a failure), and the playback model reads the session once per burst and publishes. So a single item that ends is published stopped and released, and a queue that advances shows the second item, with no window, popover or mini-player open. The UI observer only draws.

Another media application can then take the keys. A native session an account barrier let go of is fenced: it publishes nothing more while it winds down.

A YouTube Music sleep timer (P17-WEB) publishes through the same two events and nothing else: while it fades the item is still playing, and its pause (the existing `pause()` path, which moves the player's snapshot) reaches Now Playing as paused with no window, popover or mini-player open (`NowPlayingSleepTimerTests`). The advertisement rule holds there too: the timer never fades an ad, so an ad is published as it is.

## The command table (ARCH03, T23.3)

Each command is switched on in the system **only while the owner would perform it**, from the same function (`remoteCapabilities()`) that decides what a command that arrives may do. A command that arrives while off is refused (`commandFailed`), never dropped. Each command that is off while an item exists has a sentence saying why (`RemoteCapabilities.reasons`; the player bar, the expanded player and the mini-player show the Like and Dislike reasons).

| Command | On when | Goes through | Gates |
| --- | --- | --- | --- |
| Play, Toggle | an item exists | `WebMusicPlayer.resume` / `playPause`, native `nativeStart` | Play here after a route loss (the prompt comes first, nothing sounds before the confirmation); the receiver-timer note |
| Pause | an item exists | `WebMusicPlayer.pause` / native `pause` | allowed during an ad |
| Next, Previous | the transport bar's `canSkip` (not an ad, not a restored item, a playlist exists) | `WebMusicPlayer.next` / `previous` | Play here (they start sound); the player's own ad refusal |
| Seek | the bar's `canSeek` (not an ad, length known or a live window) | `WebMusicPlayer.seek` (clamped by its admission) | ad refusal |
| Skip back / forward | an episode is playing and seekable | `PodcastPlaybackModel.skipBack` / `skipForward` (the chosen lengths, offered to the system as the preferred intervals) | ad refusal; not for songs |
| Change speed | an episode with a known show, seekable, not an ad | `PodcastPlaybackModel.setRate` (the show's speed, so the follow-the-item rule cannot undo it) | range 0.5-3 only |
| Like, Dislike, Save to Library (the system asks for a STATE: a press on an on button asks for off; if the ledger is already there nothing is pressed) | the song published that control: its row on a page that was read, or (Like and Dislike) its own rating read when it started playing (`NowPlayingRatings`, see Library.md); never during an ad; never for owned or local media | `RemoteLibraryControlling.remoteLibraryPress` → the shell's `pressLike` → `LibraryControlPress` → the **W12 ledger**; a Dislike the ledger holds on the playing song then skips to the next song | the ledger's account scope and its one-operation rule; pressed only by a physical button or Control Center, never by reading capabilities or a track change |

Capabilities are recomputed on every page report and after every library press from any surface (a Like or Dislike from the player bar or the mini-player updates the system's buttons). A live stream or an advertisement publishes no clock, so its moving position does not rewrite Now Playing. A song's page read with the player paused is picked up at the next report.

## No global taps (MAC02, T23.4)

Media keys and accessories arrive through `MPRemoteCommandCenter` only. `scripts/check-system-media.py` (run by `scripts/test.sh --suite T23` and by `SystemMediaGuardTests`) fails on an event tap, a global event monitor, a system-defined (media-key) monitor, IOHID access, the private MediaRemote framework, `dlopen`/`dlsym`, a private entitlement, a Mach-lookup exception for MediaRemote or HID, MediaRemote or IOKit in the linkage, and the same symbols or libraries in the built objects and the built app. `--self-test` proves the guard flags each kind and passes a clean tree. The app's entitlements file is empty.

## The hidden page's own media session

What the code does (and `SystemMediaGuardTests` pins): the page's bootstrap script (`WebMusicScripts.bootstrap`) replaces `navigator.mediaSession.setActionHandler` with a function that clears the handler it is given, makes `metadata` write-only (native code reads what the page sets; the getter returns null), and fixes `playbackState` at `"none"`, all non-configurable. Nothing in the player scripts alters an advertisement.

What this does **not** establish, and nothing offline can: that WebKit publishes no Now Playing session of its own for the page. WebKit may publish Now Playing and default remote-command handling for a playing `<video>` or `<audio>` element whether or not the page registered handlers (clearing a handler to `null` can restore WebKit's default action rather than remove its listener), and the page's own Web Audio use is unobserved here. The reasoning is that the native `MPNowPlayingInfoCenter` and command centre are the only session the app itself publishes, and that the page's handlers and metadata are kept away from WebKit; whether macOS nevertheless shows or acts on a second, page-originated session is a live observation (end-of-project list), not a result of this node.

## Tests never take the Mac's media keys

A unit-test process (one stand-in per model, because suites run in parallel) and an isolated UI launch (ONE stand-in shared by every model in the process, so a second owner built anywhere in the app is refused and shows as `refused=1` in the Debug census) build the owner on a recording stand-in (`NowPlayingSystem.recording()`), so running the suites never holds the account holder's keys. The one test on the real centres is inside `CallbackIsolationTests` (serialized with the other tests that use them); it takes and releases them within the test.

## Live observations (end-of-project list, never counted as passes)

Real media keys with another media app open (which app receives them before, during and after), AirPods and headset buttons, Control Center and the Lock Screen widget showing the metadata, the Ad title, the elapsed clock at 1.5×, the route during AirPlay, whether macOS shows the Like and Save buttons for a music app, the Dislike and Bookmark buttons' state after a ledger change, and what macOS shows for the hidden page's media session — in particular whether WebKit publishes a Now Playing session of its own for the page's `<video>` or `<audio>` element, and whether the page's Web Audio use does — and, with another media application open, which app receives the keys before, during and after.
