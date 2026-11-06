# YTMuse backlog

Updated 2026-11-06. Latest public development preview: **[0.1.8](https://github.com/danielproj/ytmuse/releases/tag/v0.1.8)**. The additions below are included in the signed, notarized previews that introduced them; implementation and live-acceptance limits remain separate.

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
