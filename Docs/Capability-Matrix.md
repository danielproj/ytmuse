# Feature and capability matrix

BUILD03 asks for a feature/capability matrix. This one is deliberately blunt: it says what the code does **today**, and separates *built and tested against fixtures* from *proved against the real service or hardware*. Bounded live checks with a real YouTube Music account cover only the core (playback, mixes and radio starts, the queue, playlist editing on a disposable playlist), and the account holder accepted the remaining working-core checklist on 2026-11-05, including filters, update restart and playback/media-key/cold-launch checks. [The backlog](Backlog.md) records this reported acceptance and deferred work; no row claims full specification completion. The specification is [Product-Specification.md](Product-Specification.md); its release gates G01–G09 are all open.

Status vocabulary (checked by `scripts/check-docs.py`):

* **Built, fixtures only** — native code with automated tests over sanitized fixtures, synthetic data or owned audio. Live behaviour unverified.
* **Built, live unverified** — as above, and a live check is specified but has not been done.
* **In progress** — being built or reviewed; do not rely on it.
* **Not started** — no implementation.
* **Not available** — the service does not offer this to a third-party client; the app says so instead of imitating it.

| Area | Status | Notes and limits |
| --- | --- | --- |
| Google sign-in (system browser, PKCE) and local account lifecycle (add, switch, remove, Keychain isolation) | Built, live unverified | Implemented against a development registration. Real Music sign-in, refresh and revocation are gate G01 and not verified. No manual cookie copying is offered. |
| Home, Explore, search, library, history, playlists, podcasts, lyrics, radio tuner | Built, fixtures only | Parsers and flows are tested with sanitized and real anonymous public captures and development data. Core Search/library/playlist and radio flows have bounded live checks and account-holder acceptance; the full signed service/account matrix is deferred (gate G06). |
| Comments: reading (sort orders, more pages, replies) | Built, fixtures only | Included in the 0.1.6 preview. Reading is implemented: nothing is requested until **Show comments**, each sort/more/replies press is one request, pages are bounded (10 per sort, 5 reply pages per thread), and reading needs no account. Parser and transport are tested against sanitized real anonymous responses and test fakes. Signed comment responses were never observed; live, signed, layout and VoiceOver behaviour are unverified. |
| Comments: posting, replies, likes, moderation | Not started | No write is implemented. The app says posting and moderating are not available from it and sends nothing. |
| Share and Copy Link on songs, videos, albums, artists, playlists and Now Playing | Built, live unverified | Included in the 0.1.6 preview. Shares only the item's canonical `music.youtube.com` link; private service media, local-file and malformed items are refused; no network request. Targets, link validation, menus and the isolated stand-in are tested; the live macOS share sheet's presentation and layout are unverified. |
| Recap: service message and error states | Built, fixtures only | Included in the 0.1.6 preview. Signed in, an explicit open or Retry sends one read and shows the service's message verbatim; sign-in, rate-limit, server and unreadable answers have their own states. Tested against a sanitized signed capture whose text was redacted; its meaning is unknown. |
| Recap: summary figures | Not started | No successful Recap response has been captured, so no parser exists and no figures are shown. |
| Samples and account badges | Not started | No service route has been found; the screens say they are not available yet. The preview-playback rules for Samples are built and tested but no clip can start. Explicit/live badges on items are shown and are not achievements. |
| Playback of YouTube Music | Built, live unverified | Through the user-approved hidden player, which is the system WebKit; the app does not ship a browser. It cannot choose or report codec, bitrate or sample rate. Core audible playback was accepted by the account holder on 2026-11-05. Free-account advertising follows the service and is shown, never skipped; the wider G03 matrix remains deferred. |
| Native playback engine, queue, gapless, crossfade, EQ and normalization | Built, fixtures only | For music from files on this Mac. The hidden YouTube Music player is never processed. |
| Video and live | Built, live unverified | Hidden-player video surface and audio/video continuity tested against a stand-in page. |
| Downloads and offline | Not available (YouTube Music) / Built, fixtures only (local files) | YouTube Music offers no offline route to this app (G05 cannot be met for it). A download scheduler and an encrypted store exist for files added from this Mac. |
| Output routes and AirPlay | Built, live unverified | Route model and policy are tested; real AirPlay hardware is unverified (G07). |
| Cast of files on this Mac | Built, live unverified | A local relay sender for files you own is implemented and tested with stand-ins; real receiver hardware is unverified (G07). |
| Cast of YouTube Music | Not started | Needs an authorized receiver path (G07); deferred. |
| Now Playing, media keys, menu bar, windows, sleep and wake | Built, live unverified | Tested with in-process stand-ins; real hardware, lock screen and Control Center are unverified (G08). |
| App Intents, Shortcuts, widgets, Spotlight | Built, live unverified | An installed widget and real Siri behaviour are unverified (G08). Spotlight and widgets are opt-in and carry no credentials. |
| Links, scripting, sharing, Handoff, notifications, global shortcuts | Built, live unverified | Strict link policy; permission prompts only after an explicit choice. Media Share buttons have their own row above. |
| Settings, storage controls, local diagnostics | In progress | Complete Settings is under review. |
| Accessibility and the complete locale catalog | In progress | Human translation review is a separate, unstarted gate (G08). |
| Update checks and install | Built, live unverified | In-repository updater with a signed public feed pinned into the 0.1.0 to 0.1.15 previews ([Distribution.md](Distribution.md)); feed signature and final asset hashes were checked, and the published 0.1.1 feed verifies as an offer to a 0.1.0 build. Source builds have no pinned key/feed and check nothing. A real update into 0.1.3 was checked by hand and crashed the old app as it quit; 0.1.4 fixes that; the account holder accepted update restart after the fix on 2026-11-05. Wider G09 checks remain deferred. |
| Signed, notarized DMG and release | Built, live unverified | The public 0.1.15 development preview app and DMG (as 0.1.0 to 0.1.14 before it) are Developer ID signed, notarized and stapled; signatures and Gatekeeper acceptance were checked on the packaging Mac. A clean install of the 0.1.3 preview was checked by hand; G09 remains open. |
| Mac App Store build | Not started | Optional; see [Distribution.md](Distribution.md#app-store-feasibility-a-short-note-not-a-commitment). |

This table is a snapshot of the source at this commit. Regenerate your own view by running the suites; do not read a row as a promise about a release.
