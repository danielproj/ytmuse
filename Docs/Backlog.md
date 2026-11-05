# YTMuse backlog

Updated 2026-11-06. Latest public development preview: **[0.1.6](https://github.com/danielproj/ytmuse/releases/tag/v0.1.6)**. The additions below are included in this signed, notarized preview; implementation and live-acceptance limits remain separate.

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
