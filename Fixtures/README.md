# Test fixtures

No live credentials or service captures are used in W01. Synthetic or sanitized fixtures added later must record provenance and must never be presented as live-service evidence.

W02 adds [the synthetic domain manifest](W02/manifest.json). Its `mode` is
`synthetic-test-only`, `live_eligible` is false, and allowed evidence layers are
`domain` and `fixture`. The test-only loader refuses live-service and release
classification. Seeds drive reproducible state/occurrence scenarios. There are
no captured provider responses or source media here; adapter capture provenance
must be added by its assigned node. No fixture target is linked into the app.

`E01-P1/` holds two synthetic, sanitized HTML documents for the hidden player's fresh-process probe (`WebMusicPlayerProbe`). They are served as simulated responses, so no network is used. `unsupported-browser.html` reconstructs only the observable shape of the page YouTube Music served the player on 2026-10-29 under WebKit's default user agent: no `ytmusic-app` element, plus the unsupported-browser wording. See `artifacts/harness/nodes/E01/hidden-player-live/20261029-first-play-attempt/`. `music-app-shell.html` is a bare `ytmusic-app` stand-in. Neither is YouTube's markup or live-service evidence.

`W10/` holds synthetic Music `search` responses (`mode: synthetic-test-only`, `live_eligible: false`), hand-written to the published unfiltered result shape: a top card, typed shelves (songs, videos, albums, artists, playlists, podcasts, episodes), a profile row the app does not present, a row that cannot be read, "did you mean" / "showing results for" / "no results" messages, a signed-out document and four shapes that must be reported as unrecognised. They are not captures of the service and carry placeholder identifiers; a live capture is on the end-of-project manual list.

`W10-real/` holds two REAL anonymous public YouTube Music search responses (no account, no cookies; `visitorData` redacted), copied byte-for-byte from the operator's captures with hashes in `manifest.json`. They define the real response shape for the parser tests; they are public catalog data, not account data and not evidence for the signed path.

`W11-real/` holds NINE real anonymous public YouTube Music browse responses (Home, Explore, Moods & Genres, New Releases, Charts, an artist, an album, a playlist and a podcast show; no account, no cookies; `visitorData`/`serializedContextData` redacted), copied byte-for-byte from the operator's captures with hashes in `manifest.json`. They define the real response shapes for the W11 parser tests. They are public catalog data, not account data, and not evidence for the signed path (a personalised Home looks different).

`W11/` holds `synthetic-test-only` edge cases the captures don't show (continuation envelopes, an unknown-variants page, adverse responses). `generate.py` assembles the containers by hand and copies the entries inside them unchanged from `W11-real/`; they are not captures and not live evidence.

`W18-real/` holds FOUR REAL anonymous public YouTube Music responses (no account, no cookies; `visitorData` redacted) for the podcast and lyrics parsers: a song's `next` (whose Lyrics tab carries the lyrics browse id), the lyrics page (plain text with a source footer, no timing), an episode page, and a podcast show (the same bytes as `W11-real/browse-podcast.json`), copied byte-for-byte with hashes in `manifest.json`. They are public catalog data, not account data and not evidence for the signed path.

`W18/` holds `synthetic-test-only` edge cases the captures do not show (an unselectable or missing Lyrics tab, lyrics messages, the reference clients' timed-lyrics shape with invented placeholder text, malformed timed answers, signed-shaped episode pages, part-played and malformed progress, a description with chapter timestamps). `generate.py` builds them around entries copied unchanged from `W18-real/`; they are not captures and not live evidence.
