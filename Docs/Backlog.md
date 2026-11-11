# YTMuse backlog

Updated 2026-11-11. Latest public development preview: **[0.1.16](https://github.com/danielproj/ytmuse/releases/tag/v0.1.16)**. The additions below are included in the signed, notarized previews that introduced them; implementation and live-acceptance limits remain separate.

## Working core: accepted

After the core checklist, the account holder reported on 2026-11-05 that everything worked. The checklist covered signed-in radio filter loading and application, update restart after the quit-crash fix, audible playback, media keys and cold launch. This acceptance was reported by the account holder. It is not an automated test run, and no device matrix, exact update pair or per-filter results were recorded.

Together with the earlier bounded live checks, that acceptance covers the agreed working core:
- sign-in restoration and Search;
- playing songs, albums and playlists;
- mixes and radio, including radio tuning;
- the upcoming queue;
- basic playlist editing and Add to Playlist;
- the normal install and update flow.

It does not close the formal release gates G01–G09 ([capability matrix](Capability-Matrix.md)).

## Fixed in the 0.1.16 preview

The account holder reported that Play on the first "Listen again" card on Home, 10AGE "Так нужно", started a different song (NEMIGA and NAVAI "Пойдем в кино").

| Fix | What the code does | Not done or not verified |
| --- | --- | --- |
| A song's radio starts at that song | A song or video that is not inside an album or playlist played `watch?list=RDAMVM<id>` without `v=<id>`, and YouTube Music builds that radio as a mix that need not open with, or even contain, the seed. `CatalogActionPlan.target(for:)` (Home and catalog pages, the Library), Search's Play (`SearchActionPlan.startVideo(for:)`) and the Samples handoff now send the video id with the radio. `continuesCollection` still tells a collection track from a song's own radio. | Not tried in a live window. Checked against YouTube Music's anonymous `next` endpoint for `F4ZcHLhRyKU` on 2026-11-11: without `v=` the radio opened on another 10AGE song and the chosen one was not in its first four; with `v=` it opened on the chosen song. |

Every headless test batch ran and passed on the public snapshot in a clean checkout with no secrets (`ci: ok`, 2,270 Swift Testing tests executed of 2,270). The 0.1.16 app and DMG passed signature, notarization/stapling and local Gatekeeper checks. Uploaded assets were re-downloaded and matched, and the live signed feed offers build 17 to earlier releases.

## Changed in the 0.1.15 preview

The account holder asked for three changes: no status messages under an item once music is chosen from it, a click on the player bar opening Now Playing, and Queue and Lyrics opening without the page jumping.

| Change | What the code does | Not done or not verified |
| --- | --- | --- |
| No status line under a chosen item | The search row, the catalog `FeedbackLine` (Home, catalog pages, Library) and the Samples handoff line draw nothing for "starting" and "started"; the player bar shows the chosen item's title with "Starting YouTube Music…" and then its artist. Failures are still shown at the item and announced. | Not tried in a live window. |
| Player bar opens Now Playing | `TransportBar` takes an `open` action behind its content (the capsule's empty space), and the title block takes it too (`musicOpensPlayer`), for YouTube Music and owned media. Buttons, menus and the seek slider keep their own clicks. | Not tried in a live window; no UI test clicks the title yet. |
| Queue and Lyrics resize the page smoothly | `MusicTrailingPanelLayout` places the page and the panel from an animatable `reveal`, so the page is laid out again at every frame of the motion, like a live window resize; the panel keeps its width and slides in, and stays until its slide-out ends. A window too narrow for the inline panel and Now Playing opening change it at once. | The motion was not watched in a live window; `TrailingPanelLayoutTests` check the frames at each step. |

Every headless test batch ran and passed on the public snapshot in a clean checkout with no secrets (`ci: ok`, 2,270 Swift Testing tests executed of 2,270). The offscreen layout audits report the same 45 smallest-window player issues on this change as on 0.1.14, and none for the queue panel. The 0.1.15 app and DMG passed signature, notarization/stapling and local Gatekeeper checks. Uploaded assets were re-downloaded and matched, and the live signed feed offers build 16 to earlier releases.

## Changed in the 0.1.14 preview

The account holder asked whether the output button on the YouTube Music player should go: it opened a panel whose only working control was a link to System Settings.

| Change | What the code does | Not done or not verified |
| --- | --- | --- |
| No output button for YouTube Music | `OutputController.offersPicker` (the native engine owns playback) is the one rule: the YouTube Music transport in the bar and the expanded player has no output button, the owned-media controls hide it while a YouTube Music player is attached, and Choose Output… is disabled in the Playback menu and listed as unavailable in the command palette, with the reason "YouTube Music plays through this Mac's sound output. Change it in Control Center." The picker's follow-the-Mac mode (statement, Sound Settings button, read-only row, YouTube Music cast note) is removed. A route loss still raises the Play here prompt. | Not tried in a live window. The warning icon that used to replace the button after a route loss is gone for YouTube Music. Two strings the code no longer uses stay in the append-only string catalog. |

Every headless test batch ran on the public snapshot in a clean checkout with no secrets. At load average 134 two timing-sensitive playback tests (`testTimerSetInStagedWindow`, `T061ActualAppCompositionSQLiteRestoreAndAccountBarrier`) failed and then passed alone; the steps CI stops before were run separately in the same clean environment and passed. The 0.1.14 app and DMG passed signature, notarization/stapling and local Gatekeeper checks. Uploaded assets were re-downloaded and matched, and the live signed feed offers build 15 to earlier releases.

## Fixed in the 0.1.13 preview

The account holder reported that in 0.1.12 Like, Dislike, Shuffle and Repeat were all greyed out in full-screen Now Playing.

| Change | What the code does | Not done or not verified |
| --- | --- | --- |
| The hidden page's layout width | Below 616 CSS px (`matchMedia("(max-width: 615px)")`) the signed-in YouTube Music page renders a compact `ytmusic-player-controls` with no `ytmusic-wiz-player-controls` and no `segmented-like-dislike-button-view-model`; the hidden page was 480 pt wide, so 0.1.12 found none of the four. `NonInteractiveWebView` now sets `pageZoom` to `width / 800` (clamped to 0.1–1) on every frame change, so the page is laid out at least 800 CSS px wide; video surfaces are measured in the zoomed page's CSS pixels. | The account holder's Safari showed the controls at 1663 px and their absence at 574 px. `WebMusicLayoutWidthTests` checks the layout width in real WebKit at 480, 320 and 1200 pt. On 2026-11-10 the account holder confirmed that Like, Dislike, Shuffle and Repeat all work in the released 0.1.13 on their signed-in account. |

The 0.1.13 app and DMG passed signature, notarization/stapling and local Gatekeeper checks. Uploaded assets were re-downloaded and matched, and the live signed feed offers build 14 to earlier releases.

## Fixed in the 0.1.12 preview

The account holder reported that in 0.1.11 only Like worked: Dislike, Shuffle and Repeat were still greyed out.

| Change | What the code does | Not done or not verified |
| --- | --- | --- |
| The signed-in player | YouTube Music serves a signed-in account a player with no `ytmusic-player-bar`. Shuffle and Repeat are the first and last buttons of `ytmusic-wiz-player-controls` (found by position, as the labels are localised), each an `aria-pressed` toggle; Repeat all and one are told apart by the label in en/ru/de/es/fr, and an unreadable label leaves Repeat unreported. The rating is whichever toggle of `segmented-like-dislike-button-view-model` is pressed, read once the same song has played 1.5 s, because the toggles name no song. The signed-out player bar is still read as before. | The app's exact detection code, run in Safari on the account holder's signed-in page, read shuffle off, repeat off and `INDIFFERENT`; a liked or disliked song, Repeat all and one, and the buttons in a live window are unchecked. |

The 0.1.12 app and DMG passed signature, notarization/stapling and local Gatekeeper checks. Uploaded assets were re-downloaded and matched, and the live signed feed offers build 13 to earlier releases.

## Fixed in the 0.1.11 preview

The account holder reported that in 0.1.10 Like, Dislike, Shuffle and Repeat were all greyed out.

| Change | What the code does | Not done or not verified |
| --- | --- | --- |
| Like and Dislike | The rating is the one the hidden page's player bar shows for the playing song: its like button's data, the service's own `likeButtonRenderer`, reported only when it names that song and allows likes. It is taken once per song start. The 0.1.10 signed `next` request, whose answer for the account carried no usable like button, is removed. | That the signed-in page shows the account's own `LIKE`/`DISLIKE` (the live anonymous page reads `INDIFFERENT`); a like from the bar appearing in Liked Music; the skip on Dislike in a live window. |
| Shuffle and Repeat | YouTube Music's player bar now keeps shuffle in its own `shuffleOn` (no `aria-pressed`) and repeat in `repeat-mode` (not `repeat-mode_`). Both forms are read and watched. Checked on the live anonymous page. | The signed-in page in a live window. |

The 0.1.11 app and DMG passed signature, notarization/stapling and local Gatekeeper checks. Uploaded assets were re-downloaded and matched, and the live signed feed offers build 12 to earlier releases.

## New in the 0.1.10 preview

The account holder asked for Like and Dislike, chose that Dislike on the playing song skips to the next one, and that both buttons sit in the player bar. Automated tests cover it; **no live window and no signed-in answer has been checked**.

| Change | What the code does | Not done or not verified |
| --- | --- | --- |
| Like and Dislike in the player | The bottom bar, the expanded player, full screen and the mini-player show Like and Dislike for the playing song through the one library ledger; the system's buttons follow. A song no page showed gets its rating from one signed `next` read when it starts (the player overlay's like button); nothing is read during an ad, signed out or for owned media, and an account switch forgets every rating. A missing button reads as "not offered", never "not liked". Disliking the playing song skips once the ledger holds the dislike, only while that song still plays. A disabled button says why (four new messages in en/ru/de/es/fr). | That a signed `next` answer carries the account's own `LIKE`/`DISLIKE` where the anonymous captures read `INDIFFERENT`; a like from the bar appearing in Liked Music; the buttons, their reasons and the skip in a live window; whether the bar still fits at its narrowest width. |

The 0.1.10 app and DMG passed signature, notarization/stapling and local Gatekeeper checks. Uploaded assets were re-downloaded and matched, and the live signed feed offers build 11 to earlier releases.

## New in the 0.1.9 preview

The account holder asked to align the whole app's design in both styles with Apple's macOS 27 guidance, using the recommended option for every choice. The work was done as seven harness slices, each independently reviewed. Offscreen renders of the main pages were checked in both styles; **no live window has been checked**.

| Change | What the code does | Not done or not verified |
| --- | --- | --- |
| Design alignment | Solid content runs edge to edge, with one inspector column for the queue and lyrics. The accent is set at the window root: Standard follows the system accent, YTMuse uses red. The Play glyph is white unless white is below 3:1 on the fill. Buttons take primary, secondary or inline roles, at most one primary per page or sheet, and Return never repeats a write. Rows, cards (artwork-only lift), chips, artwork sizes, the placeholder, states, the type scale and sheets are shared. Settings uses the native sidebar. The layout audits run in both styles. | A live look in both styles: translucency, Liquid Glass, hover, keyboard and VoiceOver. Whether borderless buttons should take the accent colour. Content scrolling under the toolbar is deferred. The audit host does not inject the style's accent, so YTMuse audits draw the default accent. No playlist-sheet audit fixtures exist. |

The 0.1.9 app and DMG passed signature, notarization/stapling and local Gatekeeper checks. Uploaded assets were re-downloaded and matched, and the live signed feed offers build 10 to earlier releases.

## New in the 0.1.8 preview

One change the account holder asked for, in several steps. It has automated tests and was checked in a live window on the packaging Mac, in an isolated Debug copy with no account signed in.

| Change | What the code does | Not done or not verified |
| --- | --- | --- |
| Appearance style | Settings › Appearance › Style offers **Standard** (the default) and **YTMuse**. Standard sets the system window material on the main window, so the desktop shows through. Its panels and player are plain Liquid Glass with no scrim, and every other window and sheet uses the system background. YTMuse keeps the near-black canvas, the scrim and the red accent. Both styles use the native macOS 27 sidebar column with no panel behind the items. The style applies live to every window, and the video windows now follow Appearance too. | How Standard looks over the account holder's own wallpaper. Text legibility in Standard rests on the macOS material and is not computed. Only the opaque fallback (Reduce Transparency, Increase Contrast) is audited. Standard has no layout audit. The red accent does not yet follow the style. |

The 0.1.8 app and DMG passed signature, notarization/stapling and local Gatekeeper checks. Uploaded assets were re-downloaded and matched, and the live signed feed offers build 9 to earlier releases.

## New in the 0.1.7 preview

Two changes the account holder asked for. Both have automated tests and offscreen renders; **neither has been checked live in the native app**.

| Change | What the code does | Not done or not verified |
| --- | --- | --- |
| History | Only the rows on screen are built, and the next page of the service's history is read only when the end of the list is reached. A hosted test with 1,500 rows builds 9 rows when the page opens (1,501 before) and reads no page until the end. | Scrolling a long signed-in history in the live app. |
| Share in the player | **Share…** for the song that is playing is a button next to **Queue** in the player bar, Now Playing and the expanded mini-player, instead of an item in **⋯**. It is dimmed when no song can be shared. | The button in a live window. The share sheet still opens from a fixed point of the window, not from the button. |

The 0.1.7 app and DMG passed signature, notarization/stapling and local Gatekeeper checks. Uploaded assets were re-downloaded and matched, and the live signed feed offers build 8 to earlier releases.

## New in the 0.1.6 preview

The current scope is **Share buttons, reading comments and Recap service messages**. Each item has automated tests and has had an independent code review, for the current code. **None of it has been checked live in the native app**: the native share sheet, the comments panel with a signed-in account, the layout, and VoiceOver are all unchecked.

| Feature | What the code does | Not done or not verified |
| --- | --- | --- |
| Share | A visible **Share…** action, plus Copy Link, on:<br>• song and video pages;<br>• album, artist and playlist pages, including pages reopened by route;<br>• catalog, search and library item menus;<br>• the Now Playing player.<br>It shares only the item's canonical `music.youtube.com` link. It refuses private service media, local-file and malformed items rather than inventing a link, and sends no network request. | Presentation and anchoring of the live macOS share sheet. |
| Comments (reading) | A song's comments load only when you press **Show comments**. You can switch between the service's own sort orders, press **More comments**, and read replies with **View replies** and **More replies**. Reading needs no account. Pages are bounded to 10 per sort order and 5 reply pages per thread, and the app says when it reaches a bound. Playlists are marked as not offering comments. Parsing is tested against sanitized real anonymous responses. | Posting, replying, liking and moderating are **not available**: the app says so and sends nothing. No signed-in comment response has been observed. |
| Recap | With an account signed in, opening Recap (or pressing Retry) sends one read. The service's message is shown verbatim as the service's answer. Sign-in, rate-limit, server and unreadable answers each have their own state. | **Recap summary figures are not implemented.** No successful Recap response has ever been captured, so no parser for one exists. What the service's message means is unknown. |

The 0.1.6 app and DMG passed signature, notarization/stapling and local Gatekeeper checks. Uploaded assets were re-downloaded and matched, and the live signed feed offers build 7 to earlier releases.

## Deferred

When the scope was narrowed to the three features above, Samples, account badges and casting YouTube Music were deferred again. The app's screens for Samples and badges say they are not available yet, and no source route for them has been found. Cast currently supports only files on this Mac (see the matrix).

| Area | Remaining scope if resumed |
| --- | --- |
| Samples, badges, YouTube Music Cast | Find a real service route, or confirm there is none, before building on it. |
| Comment writes | Posting and moderating need observed signed responses and an authorized disposable target. |
| Recap figures | Needs a captured successful Recap response before any parser is written. |
| Account and playlist edge cases | Free/Premium and refresh/revocation matrix, account changes during operations, duplicates, collaboration and uncertain-write recovery. |
| Radio edge cases | Exhaustive filter, stale-context, advertising, pause-preservation and recovery checks beyond normal use. |
| YouTube Music offline | Needs service asset rights and offline grants. Local-file storage is separate. |
| Measured service audio quality | Establish what the service actually offers and reports. The Audio quality and Smart Downloads settings were removed in 0.1.5. |
| Localization and accessibility | Native-speaker review: non-English strings for new features are machine seeds. Also narrow layouts, keyboard use and VoiceOver. |
| Hardware and long sessions | Siri, widgets, sleep/wake, energy, performance and soak checks across devices. |
| Full distribution acceptance | Clean second-Mac rehearsal, refusal of tampered or downgraded feeds, rollback, and the wider G09 checks. Optional CI release automation is unconfigured. |

## Removed

Uploads were removed at the account holder's request and are not backlog work.

## Related documents

- [Capability matrix](Capability-Matrix.md): wider specification limits.
- [Discovery](Discovery.md): how the Recap and comments readers work.
- [GitHub releases](GitHub-Releases.md): packaging checks for each published preview.
