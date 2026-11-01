# Output routes: local outputs and AirPlay (W22)

This is the contract for ROUTE01-ROUTE04, ROUTE08, ROUTE09, ROUTE11, PLAY17 (remote timer) and DATA03 (stale route events). The code is `Packages/NativeMusic/Sources/OutputRoutes/` (model, policy, coordinator, the only real device code), `Sources/AppShell/Output/` (engine adapters, composition, picker mapping), `Sources/Features/OutputPicker/` (views) and the engine hooks in `Playback`. The tests are `Tests/Routes/` and `Tests/PlaybackTests/Routes/` (`scripts/test.sh --suite T22`).

Chromecast is `Docs/Cast.md` (W39): a `cast:<id>` route in this same model, the receiver as a remote session, and the Cast capability row (receiver sets the volume, pause-only timer, quit stops because the Mac relays). Real AirPlay receivers, USB DACs, AirPods buttons and sample-rate changes are the end-of-project live list at the bottom (W40).

## What each engine can route, and why

There are two engines behind the one playback owner (PLAY01, `Docs/Playback-Addendum.md`). They have different public APIs, so they route differently. `RouteCapabilities.resolve(engine:backend:mode:)` is the single table; the picker, the volume control, the sleep-timer warning and the quit behaviour all read it.

| Engine | Choose an output in the app | AirPlay | Why (public API) |
| --- | --- | --- | --- |
| Owned and local media, `AVPlayer` backend | **Yes**, by stable CoreAudio UID | **Yes**, through the system picker (`AVRoutePickerView`, attached to this `AVPlayer`) and AVFoundation external playback | `AVPlayer.audioOutputDeviceUniqueID` (macOS 10.9+) is per player. `AVRoutePickerView.player` is the public macOS way to route one player to AirPlay. |
| Owned and local media, decoded `AVAudioEngine` backend (EQ, normalization, crossfade) | **Yes**, by stable UID | **No picker** (the picker takes an `AVPlayer` only). An AirPlay speaker the system has made an output is just an output | `AUAudioUnit.setDeviceID` on the engine's output node is per engine. |
| YouTube Music (hidden `WKWebView`) | **No.** It follows the Mac's output | **No.** WebKit's AirPlay is switched off for the page | See below: no public per-element choice is usable. |

### The hidden YouTube Music player follows the Mac

The addendum asks to check `HTMLMediaElement.setSinkId`, media-device selection and WebKit's playback-target picker in the SHIPPED WebKit. `OutputCapabilityProbe` (a fresh process, a non-persistent view, one local document, no media, nothing played or routed) measured, on macOS 27.2 / Xcode 27.2 / WebKit as shipped:

- `HTMLMediaElement.prototype.setSinkId` **exists**, and `setSinkId('')` resolves, but `setSinkId` of any other identifier is refused (`NotFoundError`).
- `navigator.mediaDevices.enumerateDevices()` returns **zero audio outputs** (no identifier, no label) without capture permission. `selectAudioOutput` is **undefined**. `AudioContext.setSinkId` is undefined.
- The identifiers a page may pass to `setSinkId` therefore cannot be obtained, except by granting the page capture permission (a microphone permission for `music.youtube.com`), which this app never does; even then the identifiers are per-origin hashes with no mapping to a CoreAudio UID.
- `webkitShowPlaybackTargetPicker` and `RemotePlayback` **exist** as page APIs (measured: the probe only checks that they exist, and never calls one, because that would show system UI). That they need a user gesture inside the page is documented WebKit behaviour and our reasoning, not something the probe measured: the hidden page is never shown and the app never synthesises input into it, so there is no supported way for the app to open one. The app also sets `allowsAirPlayForMediaPlayback = false` for the page (WebKit's own default, measured, is on).

So the picker says so, at the route: "YouTube Music plays through this Mac's sound output. Change it in Control Center." It lists the Mac's outputs read-only, offers no selection it cannot honour, and no AirPlay choice. If the person makes an AirPlay speaker the Mac's output in Control Center, the page simply follows it, like every other app.

`WebKitCapabilityProbeTests` asserts these facts. If a WebKit update starts listing outputs or adds a permission-free chooser, that test fails and the decision is made again; the new capability does not silently go unused.

**Never** (ROUTE11 and the no-circumvention rule), and swept by `OutputRoutesGuardTests`: capture, tap, record or re-route the page's audio (no Core Audio process taps, aggregate devices or virtual drivers); change the system default output, volume, AirPlay or Bluetooth state; use private WebKit, MediaRemote, Bluetooth or output-context APIs; grant the page capture.

## Public APIs used, and where

| API | Used for | File |
| --- | --- | --- |
| `AudioObjectGetPropertyData` and friends (read) | the live output list, default output, UID, name, transport type, data source (headphone jack), whether a device has a level | `CoreAudioOutputDirectory.swift` |
| `AudioObjectAddPropertyListenerBlock` (main queue) | device list, default output, per-device alive state, data source and jack changes | `CoreAudioOutputDirectory.swift` |
| `AVPlayer.audioOutputDeviceUniqueID` | point the `AVPlayer` at a UID, or back at the system default | `HardwareOutput.swift` |
| `AUAudioUnit.setDeviceID` (via `AVAudioNode.withAUAudioUnit`) | point the decoded graph's engine at a UID | `HardwareOutput.swift` |
| `AVRouteDetector` | "AirPlay receivers are around" for the picker's hint (it lists nothing) | `HardwareOutput.swift` |
| `AVRoutePickerView` + delegate | the system AirPlay picker for the local `AVPlayer`; the delegate marks that a person is choosing | `OutputViews.swift` |
| `AVPlayer.isExternalPlaybackActive` (KVO), `allowsExternalPlayback` | a receiver took over, or stopped | `NativePlayer.swift` |

The app **cannot enumerate AirPlay receivers** with a public API; the system picker does. ROUTE01's "verified wireless targets" are therefore the receivers the picker shows plus any AirPlay speaker CoreAudio lists as a system output; the app does not claim a receiver list of its own.

The real implementations are named in exactly one composition file (`OutputComposition.swift`) plus their own definitions. An isolated launch (UI automation, design mode) and every unit test get a scripted directory and an applier that moves nothing.

## Routes and the persisted choice (ROUTE01, ROUTE02)

- `OutputRouteID` is `system-default` or `coreaudio:<UID>`. It is the only thing persisted (preferences key `local.native-music.preferred-output-route`). A display name is never stored or matched: two pairs of earbuds with one name are two routes.
- The default is the system output until a person explicitly selects a route. Selecting the system output is also a choice and is persisted.
- At launch a preferred route that is a live output (matched by UID) is restored and the local engine is pointed at it. One that is not live leaves the session on the system output with a short notice, **and starts nothing**; it is not replaced by a look-alike and it is not erased, so it applies again when the device is back. Nothing plays at any launch.
- A later explicit selection replaces the remembered route and clears a pending route loss (ROUTE03). A device that is not a live output cannot be selected, and an AirPlay-transport device is chosen in the system picker, not by name.
- The picker lists the system output first (naming what it follows) and then each live output with its attachment (built-in, USB, Bluetooth, HDMI, ...), the current route, the route-specific volume statement and the actions that route does not support. Software loopback devices are hidden unless in use.

## Route loss (ROUTE03, ROUTE09)

**Each engine is judged against the route it is actually audible on.** The hidden player has no choice: it plays through the system default output. The local engine plays on the device it was pointed at while that is a live output, otherwise on the default. The coordinator keeps one identity per engine (`currentOutput(for:)`), so a USB DAC chosen for owned media does not hide the loss of the AirPods YouTube Music plays through, and unplugging that DAC does not pause the page. The YouTube Music picker marks the system output as its current route whatever the local engine chose, and the wake check (W21) records the same per-engine identity (`PowerTransporting.audibleRoute()`): the default for the hidden player, the chosen device for a pinned local engine, compared against that device itself at the wake, not against the default.

**Detection.** CoreAudio's listeners run on the main queue and call `OutputRouteCoordinator.directoryChanged()` in the turn the system announces the change. The coordinator re-reads the list and compares, for each engine, what its sound was leaving through (`RouteIdentity`: UID, transport and the built-in data source) with what is live now (`RouteLossPolicy`):

- the device is no longer a live output: **lost** (Bluetooth, USB, HDMI, an AirPlay output);
- the built-in output stopped driving headphones (the jack switched back to the speakers): **lost**, although the device stays;
- the system or a person made another live output the default, or headphones were plugged in: **not a loss**, sound continues where it was put;
- the system moved the default off a detachable device and, within 800 ms, that device is announced as gone: **lost**. CoreAudio announces the default change and the departure separately and the order is not specified. In the real case this rule exists for, the speakers have been playing since the default moved, so the rule **bounds** the leak to the gap between the two announcements; it does not prevent it. The opposite misreading (a person's own move to the speakers followed by an unrelated unplug inside that window) is a false pause, which costs a tap on Play. Whether CoreAudio delivers this order on real hardware, and how long the gap is, is on the live list.
- **Quiet losses.** When a device that an engine sounded on is lost, every OTHER engine whose route was the same device holds the loss too (it was not playing, so nothing is paused). Without it, a new item on the other engine would start on the speakers that took over, with no Play here. An engine on a different device (for example the DAC the local engine was pointed at) is not held. Play here for one engine clears the other's loss of the same device.

**Effect.** The loss record is written before anything awaits, so every resume path that looks sees the loss from that instant. Every engine that was audible on the lost route is paused INSIDE the announcement's turn (`Task.immediate` runs the pause's first segment inline, so the command is issued before the listener returns; a test asserts it at the page without a single suspension):

- the hidden player: `WebMusicPlayer.pauseForRouteLoss()` sends the existing `pause` command to the page, sets the intent off, records `pausedByRouteLoss`, and moves the command revision so a sleep hold taken earlier cannot resume over it. A page that still reports playing is paused again, at most three times;
- the native engine: `AVPlayer.pause()` is called in the same turn (`silenceNow`), then `PlaybackSession.routeInvalidated` (the machine's `changeRoute`, one actor hop later): intent `pause(.routeLoss)`, a new playback generation, late events of the old route dropped, `.prepared`, `.started`, `.seekCompleted` and `.networkRecovered` cannot start sound, and a wake cannot resume it. The decoded graph's engine is stopped by that later hop.

This holds while the engine is preparing/loading, playing or seeking (T22.1). A loss is also recorded when nothing was audible but the engine had sounded on that route in this session (a person's pause, then the headphones leave), so a later Play cannot silently fall onto the speakers.

**Leakage window.** The pause cannot precede the physical removal: CoreAudio tells the app after the device is gone, and the system may already have switched to the speakers. What the app controls is the time from that notification to the pause being issued, and for the hidden player that is zero suspensions: the `pause` command is at the page when the listener returns (measured at the fake page; the cost is the synchronous work of the loss record and the page call, tens to a few hundred microseconds). What follows is WebKit's own round trip to the media element and the hardware notification latency, neither measured headlessly; both are on the live list. Earlier revisions of this document claimed the same-turn property while the pause was a queued task one main-actor hop later (0.5-0.9 ms idle, 30 ms in a full test run, up to 1 s under load); that was wrong and is fixed.

**Reconnect and Play here.** After a loss the picker shows the reason and:

- **Reconnect**, when the lost output is live again: re-points the local engine and clears the loss. It plays nothing. Reconnection by itself never resumes anything.
- **Play Here...**: an inline confirmation naming where sound would come out ("Playing now uses Built-in Speakers"). Nothing is audible until its button is pressed; Cancel leaves everything silent. Confirming moves the session to this Mac's current output (not persisted: the remembered route stays), clears the loss and runs the held Play. A prompt the outputs outlived (a device came or went while it was up) is dropped and must be asked again.

Every audible start goes through this gate while that ENGINE's loss stands: the transport Play buttons of both engines, **Next and Previous on the hidden player** (YouTube plays the next item), media keys and accessory buttons for all of these (`PlaybackModel.remote`), the mini-player and the menu popover (they share the controls), starting a new YouTube Music item, and starting a new native item (an owned item, the owned video, a kept download). A held start keeps the start permit captured at the click; an account barrier (switch, sign-out, removal, quit) discards the prompt and rejects the permit, so a prompt raised under one account never starts anything under another (DATA03). Previous that merely restarts the current item is a seek and makes no sound, so it is not gated. A wake never resumes over a loss (`WakeFacts.routeLost`, first of every reason after "nothing was playing").

AirPods and device buttons arrive as the system's remote-command events through the one existing handler (`PlaybackModel.remote`, W06/W21); W23 owns Now Playing and accessory command ownership. No Bluetooth protocol, private framework or exclusive-pairing behaviour exists in the code (swept). The app never writes a device's sample rate or format, so a USB DAC's sample-rate transition is the system's and the engines follow; the listeners do not observe sample-rate properties.

## Handoffs and stale callbacks (ROUTE08, DATA03)

- `beginHandoff(to:)` moves the route generation first, then stops every OTHER engine and requires its confirmation of silence before returning `ready`. A refusal (an engine that cannot confirm) means the new engine is not started: two uncontrolled players never coexist. A newer handoff supersedes an older one whose stop is still in flight. The hidden player confirms through the page's reply to `pause`, and drops the page if it cannot (a dropped page is certainly silent); the native engine confirms by pausing the session. `PlaybackModel` calls it before starting owned, kept or YouTube Music playback, in both directions. The owner also still closes the previous engine's resources before opening the next.
- Every selection, handoff, loss and system route change advances `generation`. A completion that carries an older value changes nothing: a slow `apply` for an earlier choice returns `superseded` and leaves the newer selection and the persisted route alone; a pending Play here prompt from an earlier generation is dropped.
- Remote (AirPlay external playback) sessions have an identifier and a generation. `remoteEvent(_:session:)` drops anything naming another session, a non-finite or negative position, or arriving after the session ended. A receiver that disappears without a person's choice (the picker had not been used within five seconds) is a route loss; a choice in the picker is not.
- **Position.** While external playback is active the transport bar, the mini-player, the popover and Now Playing show the last reading the receiver side reported (`PlaybackTimelineModel.receiver`, fed by `OutputRouteCoordinator.remotePosition()`), with the instant it was observed (AVFoundation drives the `AVPlayer` clock from the receiver). It is never extrapolated with a local timer, an older observation never replaces a newer one, and a reading older than 10 seconds is withheld: the bar then shows a dash and Now Playing keeps what it had, rather than a guess. That AVFoundation really derives the clock from the receiver is a live observation.
- The decoded graph cannot be handed to a receiver (the picker cannot reach it); starting a remote session while it is the backend silences it instead.

## Capabilities govern the controls (T22.4)

| Route | Selection | Volume | Sleep timer | Grouping | Quit |
| --- | --- | --- | --- | --- | --- |
| Any Mac output, hidden player | follows the Mac | app level; the output's level is the Mac's | fade, then pause (the page element's own volume over 5 s, never during an advertisement: `Docs/Playback.md`, P17-WEB) | not offered | stops |
| Built-in, USB, Bluetooth, HDMI: native `AVPlayer` or graph | by stable UID in the app | app level | fade, then pause | not offered | stops |
| AirPlay speaker as a system output | system picker only | app level | fade, then pause | system picker only | stops |
| AirPlay external playback (`AVPlayer` to a receiver) | system picker only | **set by the receiver** | **pause only, no fade** | system picker only | stops |

- The app never changes system volume. "Route-specific volume" in the picker says which of the two applies.
- **Timer (PLAY17).** Enabling the sleep timer, or starting playback with one running, on a route that cannot fade shows "This receiver can't fade the sleep timer" first, with Turn On Timer / Cancel. Once per receiver session. A local output needs no warning.
- **Grouping.** There is no grouping control in the app. Multiroom exists only inside the system's own picker, to the extent the system exposes and supports it (ROUTE04); the picker says that.
- **Quit (ROUTE10).** On every route here quitting ends the sound, so there is no stop-or-continue question. A Cast route adds `stopsBecauseMacRelays`: the Mac serves the media, so playback cannot continue after quitting, and the picker says so beforehand (`Docs/Cast.md`).

## Real-data safety

- No test changes the system default output, volume, AirPlay or Bluetooth state, and none reads a real device: tests inject a scripted directory and recording engines. `OutputRoutesGuardTests` sweeps every Swift source for calls that could change them (`AudioObjectSetPropertyData`, aggregate devices, process taps, `IOBluetooth`, `CoreBluetooth`, `MediaRemote`, `AVOutputContext`, `dlopen`, private frameworks) and every test source for the names of the real implementations; each rule fires on its own sample, and each sweep asserts it read something.
- The per-player/per-engine calls (`audioOutputDeviceUniqueID`, `setDeviceID`) exist in one file. They act on the player or engine they are handed and never on the system default; `HardwareOutput.swift` has no reference to the default-output property.
- An isolated UI launch lists a scripted output set ("Scripted Headphones", "Scripted Speakers"); two Debug controls remove and restore the scripted headphones.

## Live list (W40, never counted as passes)

Whether CoreAudio can announce the default output moving to the speakers before the lost device's departure (the 800 ms rule above is built for it; the real order is unmeasured). Real AirPlay receivers (discovery by the system picker, connection, buffering, latency, volume, grouping as far as the system allows, wake and reconnect behaviour, and that the `AVPlayer` position really follows the receiver); USB DAC attach/detach and sample-rate transitions with other apps playing; Bluetooth headphones and AirPods disconnect (headphones unplugged from the jack, earbuds removed from the case) with the measured time from the event to silence on the hidden player and the native engine; AirPods and accessory buttons end to end; the system AirPlay picker's behaviour when the local engine switches between the `AVPlayer` and decoded backends while a receiver plays; whether `AVRouteDetector` reports receivers on the account holder's network.
