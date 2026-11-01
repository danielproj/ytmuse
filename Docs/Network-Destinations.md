# Network destinations (SEC02)

The machine-readable inventory is [`Network-Destinations.json`](Network-Destinations.json). `scripts/check-destinations.py` fails when a host in the source, the property lists or a built bundle is not in it, and `SecurityTests.DestinationTests` probes every request policy in the code with a corpus of telemetry and hostile hosts at run time and fails when a policy accepts a host the inventory does not name for that purpose. This page says why each entry exists.

No account data is sent to an unrelated service for search, lyrics, translation, recommendations or analytics. There is no developer-operated server: no telemetry, no crash reporting, no listening-history collection, no advertising SDK, no remote configuration (ARCH10, SEC01).

## What the application's own code contacts

| Host | Why | What it carries |
|---|---|---|
| `music.youtube.com` | Catalog, search and library requests (`/youtubei/v1`) and the hidden player's document | Public requests carry no credential. The signed client sends the account session (cookies and a hash header) only to four read paths and the explicit write paths, from one policy (`SignedMusicPolicy`) that refuses every other host, path, query, method and header shape |
| `accounts.google.com` | Google sign-in in an app-owned web view; the OpenID discovery document | Nothing from the app. The password is typed into Google's page and never reaches app code |
| `oauth2.googleapis.com` | OAuth token exchange | An authorization code and its PKCE verifier. No client secret is packaged |
| `www.googleapis.com` | Google's public signing keys, to verify ID tokens | Nothing |
| `i.ytimg.com`, `yt3.ggpht.com` / `yt4.ggpht.com`, `lh3`..`lh6.googleusercontent.com` | Thumbnails, album art and avatars | Nothing: no cookie, no authorization header, no redirect followed outside this set, a hard size cap |

## What the page does, not the application

The hidden YouTube Music player and the sign-in view are web pages from Google and YouTube. The native code initiates none of the following; the page does, as it does in any browser (`Docs/Playback-Addendum.md`: advertising is YouTube's and is never blocked):

`*.youtube.com`, `*.google.com`, `*.gstatic.com`, `*.googleapis.com`, `*.googlevideo.com` (the media streams), `*.ytimg.com`, `*.googleusercontent.com`, and the advertising infrastructure YouTube loads in its own player.

These are enumerated by class, not by host, because YouTube decides them. The limits the application does impose: the player's **main frame** may only be `music.youtube.com`; the sign-in view's main frame may only be the sign-in hosts above; subframes and resources of either may only be `https`, `blob` or `data` (no `http`, `file`, custom scheme or `javascript:`); the player's script bridge accepts messages only from `music.youtube.com` in the current document generation.

## Links that are only names

`www.youtube.com`, `youtube.com`, `m.youtube.com` and `youtu.be` are accepted in pasted or dropped links and are **never requested** (`LinkPolicy` is pure: it parses text and returns a destination or a refusal). Artist and album descriptions can contain links to `*.wikipedia.org`, `*.wikimedia.org` and `*.creativecommons.org`; they open in the person's own browser on an explicit click and the application requests nothing from them.

## Local network

| Endpoint | Direction | Notes |
|---|---|---|
| `127.0.0.1:<ephemeral>` | inbound, loopback only | The sign-in callback listener: bound to loopback, alive only during a sign-in attempt (three minutes at most), four connections, five seconds each, sixteen kilobytes per request, one request that is parsed strictly and answered with a page that echoes nothing |

No code opens a connection to a device on the local network. AirPlay and the system's routes are the operating system's. The Cast addendum (owned media through a scoped local relay) is **not implemented yet**; when it is, it must add its entry here and the matching Info.plist usage description, and the audit will fail until it does.

## Updates

`github.com` (the opt-in static update feed and release notes) and `*.githubusercontent.com` (the release asset a download redirects to, the only redirect the updater follows, https only) are used by the W30 updater (`Packages/NativeMusic/Sources/Updates`). The updater is off until the person turns update checking on, validates the feed signature, version order and release provenance before anything is installed (SEC09; W30's `UpdatesTests`), and sends no account data. It launches exactly one process: the system's `/usr/bin/hdiutil`, to attach and detach the downloaded disk image, at a fixed path with fixed verbs; the audit allows that one launch by name (`reviewedProcessLaunches` in the inventory) and fails on any other.

## What the audit proves, and what it does not

It proves that the source and a built Debug bundle name no host outside this list, no analytics or advertising SDK, no external package, no remote-code mechanism (`dlopen`, process launch, `JSContext`, plug-in loading, a privileged helper), no entitlement from the denied list and no usage description for a permission whose feature the person has not activated. It does not observe live traffic: a packet capture of a real session, and the same audit on the signed Release bundle (which only the operator builds), are separate evidence.
