# Feature and capability matrix

BUILD03 asks for a feature/capability matrix. This one is deliberately blunt: it says what the code does **today**, and separates *built and tested against fixtures* from *proved against the real service or hardware*. Nothing in this project has yet been proved against a real YouTube Music account, so no row says "complete". The specification is [Product-Specification.md](Product-Specification.md); its release gates G01–G09 are all open.

Status vocabulary (checked by `scripts/check-docs.py`):

* **Built, fixtures only** — native code with automated tests over sanitized fixtures, synthetic data or owned audio. Live behaviour unverified.
* **Built, live unverified** — as above, and a live check is specified but has not been done.
* **In progress** — being built or reviewed; do not rely on it.
* **Not started** — no implementation.
* **Not available** — the service does not offer this to a third-party client; the app says so instead of imitating it.

| Area | Status | Notes and limits |
| --- | --- | --- |
| Google sign-in (system browser, PKCE) and local account lifecycle (add, switch, remove, Keychain isolation) | Built, live unverified | Implemented against a development registration. Real Music sign-in, refresh and revocation are gate G01 and not verified. No manual cookie copying is offered. |
| Home, Explore, search, library, history, playlists, podcasts, lyrics, Samples, tuner, Recap, badges | Built, fixtures only | Parsers and flows are tested with sanitized and real anonymous public captures and development data. Signed account reads and every account mutation are unverified (gate G06). |
| Playback of YouTube Music | Built, live unverified | Through the user-approved hidden player, which is the system WebKit; the app does not ship a browser. It cannot choose or report codec, bitrate or sample rate. Free-account advertising follows the service and is shown, never skipped (G03). |
| Native playback engine, queue, gapless, crossfade, EQ and normalization | Built, fixtures only | For music from files on this Mac. The hidden YouTube Music player is never processed. |
| Video and live | Built, live unverified | Hidden-player video surface and audio/video continuity tested against a stand-in page. |
| Downloads and offline | Not available (YouTube Music) / Built, fixtures only (local files) | YouTube Music offers no offline route to this app (G05 cannot be met for it). A download scheduler and an encrypted store exist for files added from this Mac. |
| Output routes and AirPlay | Built, live unverified | Route model and policy are tested; real AirPlay hardware is unverified (G07). |
| Cast | Not started | Needs a sender and an authorized receiver path (G07). |
| Now Playing, media keys, menu bar, windows, sleep and wake | Built, live unverified | Tested with in-process stand-ins; real hardware, lock screen and Control Center are unverified (G08). |
| App Intents, Shortcuts, widgets, Spotlight | Built, live unverified | An installed widget and real Siri behaviour are unverified (G08). Spotlight and widgets are opt-in and carry no credentials. |
| Links, scripting, sharing, Handoff, notifications, global shortcuts | Built, live unverified | Strict link policy; permission prompts only after an explicit choice. |
| Settings, storage controls, local diagnostics | In progress | Complete Settings is under review. |
| Accessibility and the complete locale catalog | In progress | Human translation review is a separate, unstarted gate (G08). |
| Update checks and install | Built, live unverified | In-repository updater with a signed public feed pinned into the 0.1.0, 0.1.1, 0.1.2 and 0.1.3 previews ([Distribution.md](Distribution.md)); feed signature and final asset hashes were checked, and the published 0.1.1 feed verifies as an offer to a 0.1.0 build. Source builds have no pinned key/feed and check nothing. Real install and restart on a signed build remain gate G09. |
| Signed, notarized DMG and release | Built, live unverified | The public 0.1.3 development preview app and DMG (as 0.1.0, 0.1.1 and 0.1.2 before it) are Developer ID signed, notarized and stapled; signatures and Gatekeeper acceptance were checked on the packaging Mac. Clean-second-Mac installation and a real signed update/rollback rehearsal remain unverified (G09). |
| Mac App Store build | Not started | Optional; see [Distribution.md](Distribution.md#app-store-feasibility-a-short-note-not-a-commitment). |

This table is a snapshot of the source at this commit. Regenerate your own view by running the suites; do not read a row as a promise about a release.
