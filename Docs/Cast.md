# Cast: the native Chromecast sender (W39)

Contract for ROUTE05-ROUTE10 (and the Cast parts of ROUTE01-ROUTE03, PLAY17, WIN03, DATA03). Code: `Packages/NativeMusic/Sources/OutputRoutes/Cast/` (protocol, session, relay, driver, the only real network code), the route model in `OutputRoutes/` (W22, extended, not duplicated), `Sources/AppShell/Output/` (transport adapter, composition, picker sentences) and `Sources/Features/OutputPicker/`. Tests: `Tests/Routes/Cast*.swift`, `Tests/PlaybackTests/Routes/CastApp*.swift` (`scripts/test.sh --suite T39`).

Real Chromecast hardware is **not** exercised by anything in this repository. Every test talks to a simulated receiver that speaks the same protocol; the real-device checks (T39.1, T39.5) are the end-of-project live list at the bottom (W40) and are never counted as passes.

## What can be cast, and what cannot

| Item | Cast? | Why |
| --- | --- | --- |
| Owned and local audio (the bundled owned signals today; any plain audio file the native session plays) | **Yes** | The Mac serves the file to the receiver through the scoped local relay (ROUTE07). |
| Kept (downloaded) YouTube Music items | **No** | They are encrypted at rest under the offline entitlement. A receiver cannot decrypt them and the app does not decrypt them for a receiver. The picker says so. |
| **YouTube Music** (the hidden player) | **No** | There is no public, sanctioned way for a native sender to make a receiver play authenticated YouTube Music without handing over the account's web session. Driving YouTube's private TV-pairing protocol would be an alternate client and is excluded by the no-circumvention rule (`Docs/Playback-Addendum.md`); handing a receiver cookies or refresh tokens is excluded by ROUTE06. YouTube Music has no output picker at all (it follows the Mac's sound output), so no Cast target is ever offered for it; the native picker says "Only owned and local audio can be cast. YouTube Music can't be cast from this app." This is on the end-of-project list for the account holder, who might accept a different route later. |
| Owned test video | No | It has no audio file; the relay serves audio only. |

The receiver is **never** sent a cookie, token or account identifier. The only messages are the Cast protocol's own (connect, launch of Google's Default Media Receiver `CC1AD845`, load, play/pause/seek/stop/volume, close), and a LOAD carries a media address and its title/artist. `CastSessionTests.nothingSentToTheReceiverCarriesCookiesTokensOrAccountData` scans every byte the simulated receiver got.

## Architecture

```
PlaybackSession (native; owns queue, intent, transport commands: PLAY01)   <- the engine is a SILENT clock while a receiver renders
        ^  CastLocalTransport (AppShell: NativeCastTransport)
CastRouteDriver ---- CastSession ---- CastChannel (NWCastChannel | SimulatedCastReceiver)
        |                |
        |                +-- CASTV2: TLS :8009, length-prefixed protobuf, JSON namespaces
        +-- CastRelayServer (NWListener on ONE private address)  <- the receiver fetches the file here
        |
OutputRouteCoordinator (W22 route model: RemoteSession(kind: .cast), RouteMode.castReceiver, losses, Play here, preferred route)
```

There is **one** route model. `OutputRouteID` gained `cast:<device id>`; `RemoteSession` gained a `kind` (`.airPlay` or `.cast`), the receiver's reported capabilities and volume; `RouteMode` gained `.castReceiver`; `RouteCapabilities` gained the Cast row; `RouteLoss.canReconnect` takes the receivers currently seen. Losses, the Play here gate, handoffs, stale-event rejection and the timer note are the W22 code, unchanged.

### Protocol coverage (what is implemented)

| Layer | Implemented | Not implemented (stated, not hidden) |
| --- | --- | --- |
| Discovery | DNS-SD `_googlecast._tcp` through `NWBrowser` with TXT records: `id` (the device's own identifier, the route key), `fn` (friendly name), `md` (model), `ca` (capability bits; a receiver that states no audio output is not offered; groups are flagged) | No mDNS responder, no SSDP, no manual IP entry |
| Wire | CastMessage protobuf encode/decode written from the public description, four-byte big-endian frames, 64 KiB cap enforced before buffering, unknown fields skipped, groups/overlong varints/invalid UTF-8/missing required fields refused (`CastWireTests`, against hand-written bytes) | Binary payloads are decoded but no binary namespace is used |
| Transport | TLS to port 8009 over **IPv4 only** (the relay is IPv4, so the control connection is held to it; keep-alive, 10 s connect bound, no cellular). A receiver's certificate chains to Google's device authority, not a system root, and it is **regenerated from time to time**, so the system cannot validate it and remembering one across connections would refuse a genuine device after a reboot or rotation. The channel therefore pins the leaf certificate (SHA-256) **for one connected session only**: a different certificate presented on that same connection is refused, and a later connection (after a loss, a reboot, a rotation or a relaunch) is accepted as a new session (`CastCertificatePinTests`). It is the one reviewed exception to W29's rule against weakening certificate validation (`sec_protocol_options_set_verify_block` in `CastNetwork.swift` only; the guard asserts it stays one call that compares the pin). | **Device authentication (the CASTV2 auth challenge) is not performed** and the pin establishes no identity: a spoofed receiver is accepted as a new session. This sender cannot prove a device is genuine (end-of-project decision item, beside YouTube Music casting). What it sends a receiver contains no account data, only a media address on the Mac's own LAN address with a random token, so a spoofed "receiver" on the LAN could fetch the one item the person chose to cast, nothing else. |
| Connection | CONNECT / CLOSE to `receiver-0` and to the application's transport; the receiver closing either is a loss | |
| Heartbeat | PING every 5 s, PONG to the receiver's PINGs, any message counts as life, **lost after 15 s of silence** (tests: 14 s ok, 16 s lost, and a PONG renews the allowance) | |
| Receiver | GET_STATUS, LAUNCH (Default Media Receiver), STOP (application), SET_VOLUME (level, mute); RECEIVER_STATUS applications/volume; our application disappearing is a loss | Custom receiver apps, registration, CAF |
| Media | LOAD (BUFFERED stream, music-track metadata, start position, autoplay), PLAY, PAUSE, SEEK, STOP, GET_STATUS; MEDIA_STATUS state, `currentTime`, duration, `supportedMediaCommands`, `idleReason`, volume; LOAD_FAILED / LOAD_CANCELLED / INVALID_REQUEST / INVALID_PLAYER_STATE | Queues (`QUEUE_LOAD`), text tracks, live streams, repeat modes |

### Position, state and capabilities come from the receiver (ROUTE09)

`CastSession` emits a `CastMediaReport` only when a MEDIA_STATUS arrives. The driver hands exactly that to `OutputRouteCoordinator.remoteEvent`; the transport bar, mini-player, popover and Now Playing already read `remotePosition()` (W22). It is never advanced by a timer, an older reading never replaces a newer one, and a reading older than 10 s is withheld (the bar shows a dash). The sleep-timer, volume and seek affordances follow the receiver's reported `supportedMediaCommands`; the picker says "While you cast, the volume slider sets the receiver's volume. The Mac's volume stays as it was." **While an owned or local item is cast through the relay, the volume slider (bottom player, mini-player, status item and the scripting `volume`) shows and drives the receiver's own level** (TH4). It starts at the level the receiver reports (the app asks for its status when it connects) and follows a level the receiver changes itself; a move sends SET_VOLUME with the level clamped to 0...1, and the newest level wins (it is handed to the driver synchronously, with a generation, so task order never decides). This level is kept apart from the Mac's app volume (`requestedGain`), which is neither read nor changed while casting: when the cast ends the slider is the Mac's again, exactly as it was, and the next local playback does not start quiet or loud. Nothing is sent, and the slider is disabled with a short reason, when the receiver has not yet reported its level or abilities ("Waiting for the receiver's volume."), when it reports a fixed volume control ("This receiver's volume is fixed."), or when its media status says it cannot set the stream volume ("This receiver can't change its volume from here."). Connecting never sets the receiver's level. A level of 0 makes the receiver silent (it is a level, not the receiver's mute, which the app does not use). The Mac's own system volume is never touched.

### One uncontrolled player never plays beside another (ROUTE08)

While a receiver renders, the native session stays the owner of the queue and the transport commands but its engine is a **silent clock**: `PlaybackSession.setRemoteRendering(true)` forces every output stage muted (the `AVPlayer` and the decoded graph), on top of, and independent of, the person's own mute (which is kept underneath and restored). The driver:

1. connects and launches the receiver (no sound yet);
2. silences the local engine and requires the engine's OWN state, read back, to be silent (the `AVPlayer` reads muted and, for the decoded graph, the refresh succeeded and its output mixer reads zero; a refresh error is not swallowed); **if it cannot be confirmed the receiver is never asked to play** and the attempt is abandoned with everything as it was;
3. only then loads the item and, if the person was playing, plays it on the receiver.

A native session started while casting is silenced in `attach`, before any item starts. Starting YouTube Music while casting first stops the receiver (`beginHandoff`). Leaving a receiver by the person's choice pauses the local session at the position the receiver last reported, **then** makes it audible-capable again: choosing a Mac output never starts the Mac's speakers by itself (ROUTE09).

Commands reconcile with the receiver, not with a guess. Play/pause from the person is sent to the receiver and is "expected"; a matching report confirms it; a contradicting report inside the 3 s settle window is the late echo of an earlier command and is ignored; outside it the receiver wins (another app or a remote paused it) and the silent local session follows. Seeks are forwarded from `PlaybackSession`'s seek observer. A report that names an earlier load (a retired media session identifier, or media the sender never loaded) is dropped and counted (`ignoredStale`); a status for different media on our application is another sender taking over and is a loss. Delayed sessions are rejected by the coordinator's session identifier (DATA03).

**Item changes.** The silent local clock drives the queue; the driver loads the next item on the receiver when the queue moves. If the receiver is within 4 s of the end of the previous item it is let finish it (the next LOAD waits for the receiver's FINISHED, with a bound), so the end of a track is not cut by the local clock running slightly ahead. Whether the gap between tracks is acceptable on a real receiver is a live observation.

### Loss, Reconnect, Play here, preferred route (ROUTE02, ROUTE03, ROUTE09)

- A lost connection, a heartbeat timeout, the application ended elsewhere, or another sender taking over is a **route loss** for the local engine (reason "receiver disconnected"): recorded before anything awaits, the session paused with a route-loss reason, the engine made audible-capable only after that pause settled, and Play held for the existing inline **Play Here** confirmation ("The Cast receiver disconnected, so playback paused. Playing now uses ..."). Nothing is audible while the question stands; Cancel leaves it silent.
- **Reconnect** is offered when the same receiver (matched by device identifier, never by name) is seen again. It connects, loads the item **paused** at the last position the receiver reported, and never plays. If the session still says "play" (its loss pause had not landed) it is paused to agree.
- **Play here** moves the session to the Mac's output, clears the loss and does not erase the remembered receiver.
- The preferred route is the stable `cast:<id>`; it is saved only when a connection succeeds (a failed attempt leaves the remembered route alone). At launch **nothing connects and nothing is browsed**; a remembered receiver is listed as "Remembered Cast receiver / Used last time" (unavailable) until it is seen, and never replaced by a look-alike with the same name. A later explicit choice replaces it.

### Quit (ROUTE10, WIN03)

Explicit Quit runs `CastRouteDriver.prepareForQuit()` first (through `AppPlaybackAuthority.beforeQuit`), bounded by 1.5 s inside the 3 s shutdown deadline, so a receiver that stops answering cannot hold the app open.

| Situation | Plan |
| --- | --- |
| Not casting | nothing is sent |
| The Mac relays the media (**every Cast session this app can start today**) | **Stop** the receiver application and disconnect, and say so beforehand: the picker line "Playback on the receiver stops when you quit, because this Mac is serving the audio." A remembered "Leave" is **never** honoured for a relayed session. |
| The receiver fetches a public https address itself (`CastLocalSource.direct`; no call site produces one today) | Ask Stop or Leave, default **Stop**, remember the choice (`local.native-music.cast-quit-choice`); a remembered Leave closes the connection and leaves the receiver playing |

Direct sources are validated (`CastDirectSourcePolicy`): https only, no embedded credentials, no IP literal or local name, and never a Google or YouTube host, so account media cannot be handed to a receiver. The ask/Leave UI is not built because no direct source exists to need it; the policy, the stored choice and the Leave shutdown are implemented and tested.

### Sleep timer (PLAY17)

A receiver cannot be faded by this app, so a Cast route's timer is `pauseOnly` and the existing "This receiver can't fade the sleep timer" confirmation appears before the timer is enabled (once per receiver session). At expiry the session pauses and the pause is mirrored to the receiver.

## The scoped local relay (ROUTE07)

Needed because a receiver fetches media from a URL and owned/local media is a file on the Mac. No relay exists for anything else. All of the following are enforced in `CastRelayCore` (decisions, no sockets) and `CastRelayServer` (bytes), and each is attacked in `CastRelayTests` both at the decision layer and over a real loopback connection:

| Rule | Mechanism | Abuse tests |
| --- | --- | --- |
| **Token** | 128-bit random per-relay token and a random per-item tag in the path `/c/<token>/<tag>.<ext>`; constant-time comparison; every miss is the same 404 that never echoes the token | wrong/truncated/extended/upper-cased token, wrong tag or extension, guessed paths, fresh tokens differ |
| **Method** | `GET` only (a Range header is a GET). Every other method is refused with 405 **before** the path is read, so the answer reveals nothing about which paths exist; a GET with a body or transfer-encoding is 400 | POST PUT DELETE PATCH HEAD OPTIONS TRACE CONNECT PROPFIND, lower-case, malformed |
| **Path** | The request path never names a file: the one file is fixed on the server when the item is registered. Any query, fragment, percent-encoding, dot segment, second slash or backslash after the right path is a 404. Only an allowlist of audio types can be registered (`wav mp3 m4a aac flac ogg opus`); the file must be a regular file after symlinks are resolved, under a size cap; it is pinned by size and modification time and a changed file is a 404 | traversal attempts, `%2e%2e`, encoded slashes, absolute paths, `file://`, forbidden types and a symlink to a forbidden target, directory, missing file, replaced file |
| **Network** | Bound to **one** private-network address (the Mac's own address on the interface the receiver connection uses): IPv4 (RFC 1918 or link-local) or, since TH4, IPv6 (a unique-local `fc00::/7` address, or a link-local `fe80::/10` address that names its interface, such as `fe80::1%en0`; the URL given to the receiver brackets it and encodes the zone), `acceptLocalOnly`, never a wildcard, a public (global unicast), multicast or IPv4-mapped IPv6 address, or a hostname; IPv6 is matched by its 128 bits, never by text, and the zone is not part of a peer's identity, with the two families never mixed; connections are served **only to the receiver's own address** (and loopback only when the relay itself is bound to loopback, which is how tests run); anything else is dropped without a word and does not even use up the request budget. Outside a loopback bind the relay needs the real-network switch, which no test process can turn on | every address class, strict address parsing, peers by exact match, connection cap, header limit, slow-sender read timeout |
| **Lifetime** | Absolute lifetime (6 h), request budget (4,000), connection cap (6), 8 KiB head limit, 10 s read timeout; the listening socket itself is closed at the end of the lifetime, on revoke, at session end and at Quit. A new item retires the previous item's path | expiry by clock, socket closed after the lifetime, revoke, budget, replaced item |
| **No leakage** | No filesystem path, token echo, account data, cookie or server banner in any response; a developer backend is not involved at all | head scan |

`Access-Control-Allow-Origin: *` is sent because the Default Media Receiver's player may need it; the token in the path is the access control and no cookie or credential exists to be abused cross-origin. Every response closes the connection (simple and bounded; a receiver reconnects per range).

**Cost, measured separately** (`CastRelayServerTests.relayCostIsMeasuredSeparatelyFromPlayback`, in-process loopback, client and server in one process, so it over-states the server alone): serving 24 MiB as 384 range requests of 64 KiB took about 0.2-0.3 s wall and about 0.4 s process CPU. A receiver playing the 1.5 Mbit/s owned signal pulls roughly 190 KB/s. The relay's steady cost at that rate is dominated by the per-request connection setup (Connection: close), not the bytes; a real-receiver CPU/network measurement is on the live list.

## Network safety (what the account holder can rely on)

- `CastNetworkGate` starts **denied**. The app composition turns it on only in a normal (non-isolated) launch, and it refuses to turn on inside a test process. `NWCastDirectory.startBrowsing`, `NWCastChannelFactory.open` and `CastRelayServer.init` each ask it first (pinned by a source test). Real network types exist in exactly their files (`CastNetworkGuardTests.theRealNetworkTypesLiveInExactlyTheirFiles`).
- **Local Network permission** is requested only when a person opens the output picker in a non-isolated app: browsing starts from the one `updateCastBrowsing()` call in `OutputController` (pinned), never at launch, never from the composition. `Info.plist` declares `NSLocalNetworkUsageDescription` and `NSBonjourServices = [_googlecast._tcp]` and nothing else; the picker tells the person that macOS will ask the first time.
- Tests and isolated launches get a **simulated receiver** (`SimulatedCastReceiver`, Debug builds only, absent from Release) and a scripted receiver list. The only socket they open is the relay on 127.0.0.1 inside the process; the only client is a loopback-only helper in two support files (pinned).
- `CastNetworkGuardTests` fail if any test source names a real browser, listener, receiver connection, the real-network switch, a socket `bind/listen/accept` call, or binds the relay to anything but a loopback literal; each rule fires on its own sample and the sweeps assert they read something. W26's permission guard was updated to name the Cast discovery file as the one approved browser (it still forbids every other).
- Release builds are never built by this lane.

## Limitations (stated)

- Real receivers are unverified (live list). The Default Media Receiver's acceptance of a LAN `http://` address, of `audio/wav` PCM, of GET-only without HEAD, and of `Connection: close` ranges is the first thing a real device will confirm or refute.
- No device authentication; the certificate is pinned for one session only, not validated against a root (above). The control connection is IPv4 only (the relay itself can serve IPv6 since TH4, but nothing makes the app use it until the pin below is released after a live check). One receiver at a time. No groups/multiroom control beyond what a group device exposes as one receiver.
- The volume slider drives the receiver's level for owned and local media (TH4, above); whether a real receiver applies a level, and how its `controlType` reads on real hardware, is on the live list. A receiver that reports a fixed control, or no stream-volume support, is never sent a level.
- The equalizer, normalization and crossfade do not apply to a receiver (it plays the original file); the picker says so for the decoded backend.
- Kept downloads and YouTube Music cannot be cast (above).
- Ask-on-Quit UI for direct sources is not built (no direct source exists).

## Live list for W40 (never counted as passes)

T39.1 / T39.5 on a real Chromecast (including a dual-stack receiver: the control channel is held to IPv4 and must still connect; then release that pin as an experiment and check the relay over IPv6, unique-local and link-local; and the volume slider starts at a real receiver's own level and moves it, and a fixed-volume device (a TV or soundbar behind the Cast dongle) disables it) (audio, Nest speaker, and a group if available): discovery and the Local Network prompt in the real app; the TXT `id/fn/md/ca` fields as real devices publish them; connection, launch and LOAD of the relay URL (does the receiver accept `http://<LAN address>`, `audio/wav`, ranges without HEAD); seek/pause/volume reported back; the credential-inspected transport trace (no cookie/token on the wire); heartbeat loss by unplugging the receiver and by Wi-Fi off; reconnect after a receiver reboot; Mac sleep/wake while casting; another phone taking over; the gap between tracks and end-of-track behaviour with the silent-clock hand-off; the measured relay CPU and network cost with a real receiver; Quit while casting and the receiver actually stopping; the timer warning on a real route.
