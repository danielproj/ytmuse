# Automation: AppleScript, Shortcuts and links (W26)

This is the contract for MAC07, MAC08, MAC09, MAC11, MAC12 and ARCH03 on the app's outside doors. The code is `Packages/NativeMusic/Sources/SystemIntegration/` (the pure rules) and `Sources/AppShell/Integration/` (the AppKit side); the dictionary is `Resources/YTMuse.sdef`; the tests are `Tests/PlaybackTests/Integration/` (`scripts/test.sh --suite T26`).

Every door below ends in the same shared commands as a menu item or a media key (`PlaybackModel.remote(_:)`, the shell's window commands). None of them has a way to read or send an account token, a cookie, a header or an authenticated request.

## Keyboard (section 13)

One table drives the menus, the key router and the tests (`ShortcutTable`).

| Shortcut | Action | Where it is handled | Focus guard |
| --- | --- | --- | --- |
| ⌘F | Focus search | Edit menu | none |
| ⌘K | Command palette | Edit menu | none |
| Space | Play/Pause | key router | not while editing text, not while a button, slider, pop-up or switch has focus |
| ⌘→ / ⌘← | Next / Previous | key router | not while editing text (the field moves to the end or start of the line) |
| ⇧⌘→ / ⇧⌘← | Seek forward / back 10 seconds | key router | not while editing text |
| ⌘L | Reveal current item | Playback menu | none |
| ⌥⌘Q | Show queue | Playback menu | none |
| ⌘M | Minimize | the system's Window menu | system |
| ⇧⌘M | Mini-player | Window menu | none |
| ⌘, | Settings | the system's application menu | system |
| ⌘W / ⌘Q | Close the window / Quit | the system's menus | system |

The key router is a **local** event monitor: it sees this app's own key events only. It is not an event tap and not a global monitor (`scripts/check-system-media.py` fails on both). It takes only the five guarded chords above, because a text field also uses them. In a sheet, the Settings window, the sign-in page, the command palette or any text field, the focused control gets the key itself. Standard editing, minimize, window, full-screen, tiling and trackpad gestures stay with macOS.

In-app shortcuts are fixed in this node; remapping applies to the global shortcuts below (the standard commands are never remappable). A menu item's key equivalent can be changed in System Settings > Keyboard > Keyboard Shortcuts > App Shortcuts, but the five chords the key router handles (Space, ⌘→/←, ⇧⌘→/←) keep working as listed, because the router acts on those keys before the menu does.

### Global shortcuts (optional, unassigned by default)

Settings > Global shortcuts: Show or hide, Play/Pause, Next, Previous. None is set until you record one. A shortcut needs Command, Control or Option; it is refused when it is a standard editing, navigation or window shortcut (including ⇧⌘↑/↓, the Control-letter text bindings, ⌘[ and ⌘], ⌘B/I/G), one macOS reserves (Spotlight, the app switcher, Mission Control, screenshots, Force Quit, emoji…), **any menu shortcut the app itself defines** (the §13 table, ⌥⌘P, ⌘R, ⌘N, ⌘O and the rest, read from the table and checked against every `keyboardShortcut` in the sources), Option (with or without Shift) alone on a letter or mark (it would type a character), one already assigned here, or one the system lists as enabled. A key the registrar has no code for is refused as such, and a registration the system declines says so ("could not be registered"), never that macOS "reports" it taken. Keys are named by key code, so Shift-⌘3 is the screenshot chord; F1 to F12 are supported. They use the public hot-key registration (`RegisterEventHotKey`), which delivers only the chords registered. It lives in `App/Sources/NativeMusicApp.swift` alone; no test can reach it.

## Links (MAC07)

Accepted: `https://music.youtube.com/` (watch, playlist, browse, channel), the `youtube.com` / `www.youtube.com` / `m.youtube.com` song, playlist and channel forms, `https://youtu.be/<video id>`, and the app's own `ytmuse://` scheme. Exact hosts, exact paths, identifiers whose shape matches their kind; nothing else. A link **opens a page**: it never plays, never changes the account, never runs a command, follows no redirect and fetches nothing. Opening a link to a song shows the song; starting it is the same Play press as anywhere.

| Form | Opens |
| --- | --- |
| `https://music.youtube.com/watch?v=<11 characters>` | the song (a `list` that rides along must itself be a playlist id and is not followed) |
| `https://music.youtube.com/playlist?list=<id>` | the playlist |
| `https://music.youtube.com/browse/<MPREb_…>` | the album |
| `https://music.youtube.com/channel/<UC…>` or `/browse/<UC…>` | the artist |
| `https://youtu.be/<11 characters>`, `https://www.youtube.com/watch?v=…` | the song |
| `ytmuse://song/<id>`, `album`, `artist`, `playlist`, `podcast`, `episode` | the item |
| `ytmuse://home`, `explore`, `search`, `library`, `downloads`, `history`, `uploads`, `podcasts`, `queue` | the screen |

Refused, with one sentence that names nothing: another scheme (`http`, `file`, `javascript`, `data`), another host or a look-alike (`music.youtube.com.example`, a trailing dot, an IP or `localhost`), user information, a port, a fragment, any percent-encoding, hidden or bidirectional characters, a path that is not exactly one of the above, an unknown or repeated query parameter, an identifier of the wrong shape, and any query at all on a `ytmuse://` link (there are no action parameters to hide a command in). Links reach the app by the system opening one, by File > Open Link from Clipboard, by dropping one on a window, by the Services menu and by AppleScript `open link`.

**Universal links are out of scope.** They need a domain the project controls, serving an `apple-app-site-association` file over HTTPS. No such domain exists, and the app never claims `youtube.com`.

## Share, Services and drag-and-drop (MAC08)

* **Share** (Playback menu: Share Current Song…, Copy Link to Current Song) acts only when you choose it and hands out only `https://music.youtube.com/watch?v=<id>` — never a signed URL, a cookie, a token, a tracking parameter or a local path. Owned audio, local files and advertisements have no link and the commands are off.
* **Services > Open in YTMuse** takes selected text or a URL from any app and opens it through the link rules above.
* **Drag and drop**: dropping a supported link (a URL or text) on a browser window opens its page; anything else shows the one refusal sentence.

## Handoff (MAC12)

While an item page (song, album, artist, podcast or episode) is in front, the app advertises an `NSUserActivity` of type `local.native-music.browse` carrying the **public canonical link** and the navigation context (kind and identifier) — no title, account, cookie, token or local path, and nothing for the Library, History, Downloads, Uploads, the queue or a playlist (which may be private). Receiving-app limits: Handoff only reaches another device signed in to the same Apple Account, nearby, with Bluetooth and Wi-Fi on. The activity carries a web address, so a device without YTMuse opens it in its default browser. There is no iPhone companion, and nothing here is a Spotify Connect-like server. A custom-activity handoff between two YTMuse builds needs both signed by the same team; a development build does not meet that, and the browser is what you get. An automated (isolated) launch advertises nothing.

## Notifications and permissions (MAC08)

Settings > Notifications > "Notify when the song changes" is **off by default**. Turning it on is the only thing that asks macOS for permission to show notifications; a notification shows the title and artist and nothing else, never for an advertisement. If permission is refused the switch goes back off and says why. Launch at login (W21) is off by default and is registered only by its Settings switch. Local network access, Siri, Shortcuts donation and Apple-event sending are not requested by anything in this node: the app asks for local network access only when casting (W39) is used, and sends no Apple events at all.

## AppleScript (MAC11)

`Resources/YTMuse.sdef` is the dictionary (open it in Script Editor with File > Open Dictionary). Everything is carried out through the shared commands, so the same admission applies: an advertisement refuses seeking and skipping; a restored item waits for Play.

| Command or property | Does |
| --- | --- |
| `play`, `pause`, `playpause` | resume, pause (allowed during an advertisement), toggle |
| `next track`, `previous track` | skip; refused during an advertisement |
| `seek to <seconds>`, `seek by <seconds>` | move the position; exactly one of the two |
| `player volume` (read/write, 0-100) | the volume |
| `player state` | `stopped`, `playing`, `paused` or `advertisement` |
| `current track` | the playing item: `name`, `artist`, `duration`, `position`, `public link` (missing where unknown) |
| `add to queue "<link>"`, `play next "<link>"` | queue a song by its public link: refused while YouTube Music plays, because YouTube Music manages its own upcoming items; for the app's native queue it is the shared queue command |
| `open link "<link>"` | show a page (navigation only) |

Errors carry a number (4601 nothing playing, 4602 not allowed right now, 4603 bad argument, 4604 bad link, 4605 queue not editable) and a sentence. The standard `open location` also works and goes through the same link rules.

### Examples

These run. `T26` executes every block below through the command dispatcher against an isolated, recording instance in the test process (`ScriptingExampleTests`), and fails if a line is not in the dictionary. The blocks use `tell application "YTMuse"`.

Transport:

```applescript
tell application "YTMuse"
    play
    pause
    playpause
    next track
    previous track
end tell
```

Seeking and volume:

```applescript
tell application "YTMuse"
    seek to 30
    seek by -10
    set player volume to 40
end tell
```

Reading the current track:

```applescript
tell application "YTMuse"
    get player state
    get name of current track
    get artist of current track
    get public link of current track
end tell
```

Opening a page and queueing a song:

```applescript
tell application "YTMuse"
    open link "https://music.youtube.com/watch?v=dQw4w9WgXcQ"
    open link "ytmuse://library"
    play next "https://music.youtube.com/watch?v=dQw4w9WgXcQ"
    add to queue "https://youtu.be/dQw4w9WgXcQ"
end tell
```

### From the command line, and as Shortcuts actions

The same scripts run from Terminal with `osascript`, and from the Shortcuts app with a **Run AppleScript** action (paste the script into it) or a **Run Shell Script** action:

```sh
osascript -e 'tell application "YTMuse" to playpause'
osascript -e 'tell application "YTMuse" to next track'
osascript -e 'tell application "YTMuse" to open link "ytmuse://queue"'
```

The first time any program sends YTMuse an Apple event, macOS asks the person at the Mac whether that program may control YTMuse (Settings > Privacy & Security > Automation). That prompt is macOS's, and YTMuse neither triggers nor suppresses it.

**Never address the app from a test, a probe, a mutation run or an unattended script — not by bundle identifier, not by name, not through the `ytmuse:` scheme.** LaunchServices resolves the name `YTMuse`, the bundle identifier and the `ytmuse:` scheme to whichever registered copy it finds first, and starts one that is not running. A Debug build falls back to scratch storage when it loses its environment, but **a Release build always uses the real stores and shares the name and the bundle identifier**, so such an event could open the account holder's real data. (Release builds are never made by the harness; stale copies are deleted.) The examples above are for a person at the keyboard; tests execute them in-process through the dispatcher.

The rule is positive: a test reaches the app only through `XCUIApplication`, launched with the isolation environment, or through the process-id descriptor of an instance it launched itself, and only inside `Tests/NativeMusicUITests`. `LaunchGuardTests` sweeps every script-like file — any extension, extensionless ones with a `#!` line, JXA, AppleScript with `¬` continuations — in `Packages/NativeMusic/Tests`, `Tests`, `scripts`, `App`, `Extensions`, `Tools` and `artifacts/harness` for: `tell app` or `tell application` (by name, by `id`, abbreviated, split over lines), the OSA command line, JXA `Application("…")`, Apple-event descriptors built from a bundle identifier or any non-process-id form, the Apple-script and OSA APIs, `NSWorkspace` opening or launching, `LSOpen`/`LSLaunch`, and `open -a` / `open -b` / `open ytmuse:` in any shell or subprocess form. Its self-test plants every one of those forms (each must be found, in its own file) beside harmless controls (which must not be). Exactly three files are allow-listed, each with a reason: `scripts/ui-preflight.py` (window positions from System Events) and two recorded W09 evidence scripts. The App Shortcuts and Siri phrases are W24's.

## What is not claimed

Live Services, share-sheet, Handoff, global hot-key, notification, Automation-permission and `osascript` behaviour on a real Mac are observations that no offline test makes. They are listed in the node report and never counted as passes.
