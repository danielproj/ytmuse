# Window, menu-bar and sleep/wake lifecycle (W21)

This is the app-shell contract for WIN01-WIN10, PLAY17 (wake) and MOTION04. The code is `Packages/NativeMusic/Sources/AppShell/Lifecycle/`; the tests are `LifecycleTests`-named suites in `PlaybackTests` (`scripts/test.sh --suite T21`).

## One owner, many surfaces

`ShellCoordinator` is created once with the one `PlaybackModel` (PLAY01) and is the only `ShellCommanding` conformer (ARCH03). The status item and its popover, the mini-player and full-screen Now Playing read `ShellTransportState` (the coarse snapshot; never the position clock) and send play/pause, next, previous and volume through the same `remote(_:)` admission that media keys use. An advertisement shows the honest Ad state and turns skip off; nothing in the shell skips, seeks, hides or speeds up an ad. Command-N windows share the bootstrap, so there is exactly one account, player and Now Playing owner; `LifecycleOwnershipTests` pins each construction site. The one Now Playing owner, what it publishes, when it attaches and detaches and the remote-command table are in `Docs/NowPlaying.md` (W23).

## Windows and the Dock

Only a window that registers a role (`ShellWindowRole`) can keep the Dock icon: browser windows, the full-screen Now Playing window and Settings. The hidden player's host window, the mini-player (a non-activating utility panel that is never main), the popover, sheets and alerts never count, and the host window and mini-player stay out of the Windows menu and Command-` cycling. When no regular window is on screen or minimized (and the app is not hidden), the activation policy becomes `.accessory` after a short settling time (so a Space or full-screen transition cannot flicker it); any window opening again, a Dock click, the status item's Show Window or a launch restores `.regular` at once and activates. The policy never drops before a regular window has been on screen once.

## Sleep, lock and wake

| Event | Source | Audio | UI work |
| --- | --- | --- | --- |
| screen locked / unlocked | `com.apple.screenIsLocked` / `Unlocked` | continues | stops / resumes |
| display sleep / wake | `NSWorkspace.screensDidSleep` / `DidWake` | continues | stops / resumes |
| system sleep | `NSWorkspace.willSleep` | checkpoint, then held | stops |
| system wake | `NSWorkspace.didWake` | resumes only when `SleepWakePolicy` says so | resumes |

A hold pauses the hidden page itself (so it cannot start by itself on wake) without recording a person's pause. A wake resumes only when playback was wanted at the sleep, the same account/player/item is still there, no command (pause, play, skip, seek, media key) arrived since, no sleep timer ran out (the hidden player's own timer counts too, P17-WEB: a deadline that passed while the Mac slept, or a pause the timer made, is remembered until a person's command), the "resume after wake" setting is on (default) and the default output route is confirmed. A route-loss pause (headphones, a device or a receiver went away; `Docs/Routes.md`) outranks every one of these: a wake never resumes over it. Otherwise the page is kept quiet (checked again 3 s later). The app takes no power assertion and prevents no sleep; its only activity is the hidden player's App Nap activity while it plays, which allows idle system sleep.

## Launch

A manual cold launch shows the last YouTube Music session paused (a per-account private file on this Mac: playlist, item, title, artist, position; written on item and play-state changes, every 20 s while playing and at sleep and quit) with nothing loaded; Play loads it and moves to the saved position. Nothing plays at any launch. Launch at login is off by default; the Settings toggle is the only thing that registers it, through `LoginItemService`. The real `SMAppService.mainApp` is named in exactly one file (`App/Sources/NativeMusicApp.swift`), chosen only for a non-isolated launch, so no test target can reach it. A login launch (`keyAELaunchedAsLogInItem`) is menu-bar only: no window, no audio.

## What is verified where

Headless (`T21`): policy tables, coordinator and real owner with a fake page, window census and panel rules, menu model, login item and launch rules, restore, occlusion gating and the structural guards. Isolated UI (`T21` UI part): last-window-closed with Show Window, Command-N sharing one player, mini-player size/pin/expand/focus, simulated login launch with the Settings toggle, minimized-window responsiveness, full-screen Now Playing. Real lock, sleep, wake, a real login launch, Spaces and Mission Control behaviour, the status item on a real menu bar over time, and WebKit really throttling the hidden page are live observations and are listed in the node report, never counted as passes.
