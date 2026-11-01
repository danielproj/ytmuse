# YTMuse — YouTube Music playback addendum

On 2026-10-28 the account holder made playing actual YouTube Music the top priority and approved the playback approach of the open-source Mac client Kaset (`https://github.com/sozercan/kaset`, MIT, inspected at `4c59ff2`): YouTube Music's own web player runs hidden inside the app, signed in with the app's YouTube Music session, while every surface the user sees and touches stays native. Their answer to the question "may I allow YouTube Music's own web player to run hidden behind the native interface (the Kaset approach)?" was "Same as in the suggested repo". This is an authoritative addendum to the frozen original specification, in the same way `Docs/Visual-Direction.md` is. The original specification stays intact for audit.

## What it supersedes, for YouTube Music playback only

- The **Native boundary** row ("no … website renderer, hidden web player"): a single hidden `WKWebView` running `music.youtube.com`'s player is permitted as the YouTube Music audio source. Navigation, browsing, search, library, queue, settings and every visible control remain native; no web page is shown as app UI.
- **PLAY02** (AVFoundation as the primary implementation): YouTube Music items play through the hidden player. AVFoundation remains the engine for owned/local media and every non-YouTube path.
- **PLAY15** ("a hidden web player is not an accepted fallback"): accepted for YouTube Music, with the advertising rules below.

Everything else in the specification still applies, including PLAY01 (one application playback session owns account, queue, route, transport and current item), ARCH03 (the command layer is the only path to playback), privacy, accessibility, glass design, resource budgets and the evidence gates.

## Rules for the hidden player

- **No circumvention.** No stream extraction, signature deciphering, attestation/PoToken generation, DRM workarounds or alternate-client requests. The player obtains media exactly as YouTube Music's website does.
- **Advertising is YouTube's.** Never block, skip, mute, hide or speed up ads, and never load ad-blocking or other web extensions. Detect ad playback only to show an honest native "Ad" state and to refuse seeking during it.
- **Session.** The player is signed in with the account's Keychain session (the allowlisted `.youtube.com` cookies), loaded into an in-memory, non-persistent website data store while the app runs. Google's full web session is not written to disk. Cookie rotation observed in the player is written back to the Keychain record.
- **Scope.** The player loads only `music.youtube.com` and the Google/YouTube resources it needs; its script bridge accepts messages only from that origin and only in the current document generation. No credentials are exposed to page script beyond what the page itself already holds.
- **Sleep timer (P17-WEB).** At expiry the app may lower the page `<video>` element's own volume over 5 seconds and pause, and put the level back. It never does so while an advertisement shows: a fade of an ad is a mute in effect, so during an ad the timer pauses and does nothing else, and the page's own script refuses the step. The fade is the only thing the timer sends besides a pause; it never seeks, skips or changes the queue. `Docs/Playback.md`.
- **Native ownership.** Now Playing, media keys, the transport bar, queue and history stay native and are driven by the app's playback session; the web page's own media session must not compete with them.
- **No surprise audio.** Nothing plays at launch or after sign-in without an explicit user action.
- **Power while hidden (C1).** The App Nap activity is held only while the page is loading, buffering or playing (an ad counts as playing), never while it sits paused or ended. While the page is paused or ended (also when YouTube paused it by itself) the app sets its `inactiveSchedulingPolicy` to `.throttle` (never `.suspend`) through the live view's `WKPreferences`, and sets it back to `.none` before any command that could make it play (Play, next, previous, seek, volume, a new load); only the pause command is sent to a throttled page. The page is never torn down for being idle, so Play resumes the same track at the same position. That the policy reaches the live view is probed offline (`WebMusicPlayerProbe`); whether WebKit then really throttles the running page's WebContent process can only be seen on a live run. The page's periodic report posts only when something changed, and the page's `ytmusic-app` element wins over a "try Chrome" banner.
- **A native clock, not a rebuilt bar (C1).** The transport bar reads a coarse snapshot (title, artist, controls, volume) that position ticks never invalidate. The elapsed/remaining/progress row reads a separate clock that republishes once per displayed second and not at all while no window is visible. Now Playing keeps full-resolution positions.
- **Queue and Now Playing during YouTube Music playback (C1).** They show what the page reports (the playing item, its artist, the Ad state and the playlist it was started from) and say that YouTube Music manages the upcoming items. No upcoming item is invented and no reorder or remove control is offered for a queue the app cannot edit.

## Video surface (operator interpretation, flagged for the account holder's end review)

The account holder approved Kaset's approach ("Same as in the suggested repo"). Kaset shows YouTube video through YouTube's own player with native controls. By that precedent, for YouTube Music **music videos and live streams** the app may show **only the hidden player's own video picture** (the page's `<video>` element, scaled to fit, no page chrome, captions/controls/comments of the page hidden) inside a native window or the native Now Playing / full-screen surface. Every control stays native: play, pause, seek, Go live, quality, captions, full screen and Picture in Picture where WebKit's video element supports it. This supersedes MEDIA03's AVKit requirement for YouTube Music video only. AVKit stays the engine for owned and local video.

Audio-only selection must stop video decoding by asking YouTube's player for its audio (song) version where the service offers one, never by covering a playing video. Song/video switching keeps position only when the service publishes the counterpart mapping (MEDIA02); otherwise it reports a restart. One owner across the inline preview, the player, full screen and PiP; never overlapping audio. The no-circumvention and advertising rules above apply unchanged, and video ads are shown, never hidden.

This interpretation was made by the operator without an explicit instruction and is listed for the account holder's review at the end of the project. Record: `artifacts/harness/W17-video-surface-decision.json`.

## What this does not establish

A working hidden player proves playback through YouTube's own web client for this account. It does not establish native AVFoundation playback, offline downloads, Cast, measured quality or any G01–G09 release gate by itself. Those remain open and are evaluated against this addendum.

Decision record: `artifacts/harness/E01-user-decision-hidden-player.json`.
