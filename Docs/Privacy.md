# Privacy

This page states what YTMuse keeps on this Mac, what leaves it, and what it never does. It describes the behaviour of the code in this repository; each claim has a test under `Packages/NativeMusic/Tests/Security` or an earlier lane's suite, named in [Security-Model.md](Security-Model.md).

## What leaves the Mac

Only requests to Google and YouTube for the features you use: sign-in, catalog and library requests, artwork, and the hidden YouTube Music player's own traffic. [Network-Destinations.md](Network-Destinations.md) lists every host. There is no analytics, no crash reporting, no advertising SDK, no listening-history collection and no remote configuration. YTMuse works without sending anything else anywhere.

Diagnostics are local. The Diagnostics screen reads a bounded in-memory log. **Export** writes one file to a place you choose after you have read exactly what it contains; nothing is uploaded. The exported text is redacted: cookies, authorization headers, tokens, signed URL parameters, email addresses, the names of your private playlists and your search terms are removed, including when they arrive encoded inside a redirect. Media files and credentials are not inputs to the bundle at all.

## What stays on this Mac, and how it is protected

| Data | Where | Protection |
|---|---|---|
| Sign-in session (cookies) | macOS Keychain, one record per account | The Keychain's own protection; never in the database, a log, a preference or a file. The hidden player holds the session in memory only |
| Account list, queue, outbox of unsent changes, preferences, library cache, local history | SQLite database and small files in the app's private folder | Owner-only permissions (folders `0700`, files `0600`), write-ahead log and sidecars protected the same way, `secure_delete` on. **Not encrypted at rest** beyond FileVault: titles, artists and playlist names in these files are readable by anyone who can read your files as you |
| Downloaded media | Encrypted objects in the app's private folder | Encrypted with a key kept in the Keychain. The **names, titles and sizes** of downloads are in the download ledger and are not encrypted |
| Artwork cache | Account-partitioned folder | Owner-only; images only; size-bounded |
| Widget snapshot | The App Group folder | A title, an artist, a small thumbnail and an account stamp for the playing item; a redacted file with no content when signed out or the screen is locked. The widget refuses any file with a field it does not know |
| Spotlight entries | The system index | **Off until you turn it on**; your private playlists, history and uploads are indexed only if you also turn that option on, and leave the index when you turn it off |
| Handoff, notifications, share links | The system | A Handoff activity carries the public link of the song, album, artist, podcast or episode page being viewed and nothing else (never a playlist, a title or an account). A song-change notification carries the title and artist you can already see, and exists only after you turn it on. A shared link is always the item's own public identifier |

## When you remove an account or reset

**Sign out** removes the account's session record and makes its private data unreachable. **Remove** additionally deletes the account's roster entry, its database partition (with backups, search index and write-ahead log), queued changes that were not yet sent, its downloads and their keys, its artwork, history and Spotlight and widget entries. It never deletes anything at Google: your Google account, your playlists and your library are untouched, and a change that was queued but not yet sent is discarded, not sent. If a step fails halfway, the account stays "removal pending", cannot be used, and the removal is retried (at the next Remove and at launch) until it completes. Removing the active account does not make another account active.

**Reset All Local Data** (Settings) removes every account's local state and the app's own index and snapshot entries; it does not touch remote data either.

## What YTMuse does not do

It does not ask for your Google password in its own windows, copy your browser's cookies, read another app's session, send your listening history anywhere, like or follow anything automatically, or fabricate listening events. A pasted link can only open a page: it never plays, changes your account, or makes the app connect to the address in it.
