# Search and the command palette (W10)

Persistent search lives in `Features/Search`, the palette in `Features/CommandPalette`, and the shell wiring in `AppShell/SearchShell.swift` and `AppShell/SearchComposition.swift`. The service request and its parser live in `YouTubeMusicAdapter` (`MusicSearchParser`, `PublicMusicClient.searchResponse`, `SignedMusicClient.search`) and the account-scoped call in `MusicSessionCoordinator.search`.

## How a keystroke is handled

1. Local matches are computed at once (no timer) from every `LocalSearchSource` that serves the chosen place. Today that is the signed-in account's library playlists (the read the Library already performs). `StoredMediaSearchSource` answers from the W03 FTS index but is not composed, because nothing saves media entities to the app store yet.
2. YouTube Music is asked after a 180 ms quiet period (`SearchModel`'s injected `Clock`). Return asks at once. Only the last query reaches the service.
3. The request is the real Music `search` call: signed with the account's `SAPISIDHASH` session when a connected account is active, otherwise the anonymous public request. The query travels only in the POST body.
4. A reply is accepted only if the query generation is still current **and** the account scope (a token over the active account and whether its session is live) is unchanged. A reply that fails the second test is dropped and the query is asked once more under the new scope; a second mismatch is reported, not looped. The coordinator also fences the call against the lifecycle, so a request started for one account is never returned after a switch.
5. A service failure keeps the local results and names the failure (offline, slow down, unreadable, unavailable). An answer the parser cannot read is `unrecognised`, never an empty result.

## What is promised, and what is not

- **No completeness claim.** The service answer is one page (`complete == false`); the UI says so. The Library scope is local only and says so.
- **Original query preserved.** `FoldedQuery` never rewrites what was typed. A respelling (the service's "did you mean", or a word from the library's own titles) is only offered; `applyCorrection()` is the one action that changes the query, and `revertCorrection()` restores the original exactly. A service that already ran the corrected query is labelled as such.
- **Tolerant local matching.** Text is folded (canonical composition, lowercase, then diacritics/width; `ß`, `ø`, `ł`, `æ`, `ı`… mapped) so accents, decomposed accents, case and full-width forms match. Alphabetic words of four or more letters tolerate 1 edit (2 from eight letters, a transposition counts as one); ideographs are exact and keep their order; such matches carry the *Approximate match* badge. This is local only; it makes no statement about the service.
- **Typing never acts.** Starting playback needs Return on a selected result, a Play button, or a menu item.
- **Parsing is by endpoint, not by words.** Result kind comes from the row's `pageType` / `musicVideoType`, never from localised shelf titles or the service's type label (which is stripped from the detail line because the app shows its own localised type name).

## Actions

`SearchActionPlan` is the single place that says what can be done. Only two actions exist, because only two are implemented:

| Result | Play | Copy Link |
|---|---|---|
| Song, Video | `RDAMVM<videoId>` (the track's own radio seed) through the hidden player | `watch?v=` |
| Album, Playlist, Podcast | the playlist the row's own play button names | `playlist?list=` |
| Artist | not offered | `channel/UC…` |
| Episode | offered but reported unavailable at the item: single episodes are not playable from search yet | `watch?v=` |

Play goes through `AppSearchPerformer` to `PlaybackModel.playMusic`, the same call the Library's Play uses, behind the permit captured at the action. A capability that cannot run (signed out, session ended, no play target, a start that failed or lost its permit) is reported on that row. Return on an artist reports that opening is not available yet.

`RDAMVM<videoId>` plays the song and then continues with YouTube Music's own radio for it: that is how YouTube Music's player starts a single track from a playlist-only entry point, not behaviour this app adds. Whether the live player accepts that entry is on the end-of-project manual list (see the W10 report).

## Keyboard

While the field is being edited: Up/Down move the selection (clamped, no wrap), Return acts on the selection or, with none, searches now, Escape clears the field (an empty field leaves Escape to the window or sheet). Space and every other key are never consumed, and nothing is consumed while an input method has marked text. Command-F opens Search and focuses the field; Command-K opens the palette. The palette lists commands first (the same closures the menus and toolbar use), selects the best command when typing, and never auto-selects a search result.

## Real response shape, recents and discovery (rework 1)

- **Real shape.** In real responses every result row sits in its own `itemSectionRenderer` beside the top `musicCardShelfRenderer`; there are no per-type shelves. The parser reads rows from item sections, shelves and the card, and **accounts for every row**: top result, listed item, `skippedRows`, `unsupportedRows` (profiles) or `duplicateRows` (a row repeating an item already listed). An entry or section the parser does not know counts as skipped. Tests assert `rows == classified + skipped + unsupported + duplicates` on both real captures and the synthetic shapes. The legacy shelf shape stays supported and tested.
- **Detail lines.** The parser keeps the parts of a detail line separate (`details`), split at the service's bullets and flex columns; presentation joins them with the catalog entry `detailSeparator`. The service's type label is dropped except for albums, where it is kept so a Single or EP stays a Single or EP.
- **Composing text.** `SearchField.route` asks the field editor (`NSTextInputClient.hasMarkedText()`) and passes the answer to the model's `composing` parameter; the palette does the same.
- **Recents (SEARCH02).** `SearchRecents` keeps up to 10 recent queries and 10 recent items per account in the app preferences store. A query is recorded when the person submits it or acts on a result, never per keystroke; an item when its Play started or its link was copied. Nothing is logged (a test sweeps the search sources for logging calls), the empty search offers Clear for each list, and `prune` erases the buckets of accounts that no longer exist. Recents are read back as results (Play and Copy Link work from them).
- **Discovery.** Explore is still a placeholder, so the empty search does not link to it; it says that suggestions and discovery arrive with the Home and Explore screens.
- **Development catalog.** Needs `YTMUSE_UI_DEVELOPMENT_DATA=1` **and** QA isolation.

## Evidence and fixtures

`Fixtures/W10-real` holds two real anonymous public captures (labelled `real-public-anonymous-capture`, hashes in the manifest) that fix the real shape; `Fixtures/W10` holds synthetic, hand-written response shapes (not captures). The Debug-only `DevelopmentSearch` catalog (flag `YTMUSE_UI_DEVELOPMENT_DATA=1`, labelled "Development data · Not YouTube Music") backs the isolated UI tests through the same `RemoteSearch` seam; no Release build contains it.
