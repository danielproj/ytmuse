# Playlist editing (W13)

Design notes for creating, editing, sharing and deleting the person's own playlists. Nothing here has been run against the live service; every
write is behind an explicit user action, and the tests use fake transports only. Real shapes: the W11 anonymous playlist capture
(`Fixtures/W13-real/browse-playlist.json`, public, no edit affordance) and, for the add action, the only real **signed** capture available
(`Fixtures/W12-kaset-real`, Kaset's). **Kaset's `playlist_detail.json` is a hand-written test fixture, not a signed capture** (its manifest says so).
Pages and answers for an editable playlist are `synthetic-from-real-renderers` (`Fixtures/W13`, generated, hash-pinned), never live evidence.

## Rules the code keeps

- **Deliberate, user-initiated only.** A playlist is changed only from `PlaylistEditSession.submit/retry/resolve/undoLast/deletePlaylist` and
  `PlaylistCreator.create`, which the views call from a button or a confirmation. Nothing loops, polls, runs on sync or replays a stored request;
  `load`, `refresh`, `check` and `checkDeletion` only read. A guard test pins the single `apply` call site per path and that no view submits from
  `onAppear`, `task`, a timer or a loop.
- **Permission comes from the service's page**, never from a name or a library list. `MusicPlaylistEditing` is read from the page's editable header
  (`musicEditablePlaylistDetailHeaderRenderer`): the wrapper means tracks can be changed, its edit header means title/description/visibility can,
  a `deletePlaylistEndpoint` in the header menu marks the owner. `MusicPlaylistRole`: owner (delete offered), collaborator (tracks only), saved
  (the page's Save toggle is on and nothing is editable), viewer. A removal also needs the row's own `playlistEditEndpoint` (`ACTION_REMOVE_VIDEO`
  naming that row's `setVideoId` and video); a row without one is listed but not removable. Only `PL…` playlist ids are ever edit targets (never
  albums, mixes, `LM`, `WL`, `SE`).
- **Tracks come only from the track shelf.** The page's section-list token reloads the *suggestions* and related items that follow the track list
  (ytmusicapi `get_playlist`), so it is never followed for tracks; a playlist whose shelf names no continuation was read to its end. Suggestions are
  read separately (`readSuggestions`, a bounded read, only for an editable playlist), shown as "Suggested songs", never mixed into the members; a
  suggestion row's `to_be_updated_by_client` is no occurrence. Commands and headers that name another playlist than the one read are not trusted.
- **Occurrence identity.** Every removal and move names the service's per-occurrence `setVideoId`; the same song twice is two occurrences. The
  reader (`PlaylistSnapshotReader`) keeps a repeated *row* once (by occurrence id) and a repeated *song* twice, restarts an expired continuation
  (bounded) and otherwise returns an honestly incomplete snapshot; a reorder is refused on an incomplete snapshot or while any row has no id.
- **Merge, don't replace.** Before anything is sent the playlist is read again and the change is reconciled against what is there now
  (`PlaylistReconciler`): a reorder elsewhere does not move your change (it is placed before the *same occurrence*, or the next one that survives);
  a removal already true is not sent; an add skips what a previous attempt already created. Only a collision becomes a question — the same
  occurrence relocated too and not already where you meant, a field changed to something else, a target gone or changed — and it is asked about
  that one thing with both versions kept (`PlaylistConflict.mine/theirs`). No action ever carries more than one occurrence or field; there is no
  "set the whole order".
- **Unknown outcomes are read, not replayed.** A request that left and got no usable answer is `needsReconciliation`; `check` reads and settles
  each action by occurrence (`PlaylistEditSession.settlement`); `retry` reads first and sends only what is still missing, and never replays an
  add without a successful read. A create is settled from the playlist list read before and after.
- **Confirmation names the selection.** A change touching more than one song (and a deletion) is accepted only with the prompt the session itself
  builds for that selection (`PlaylistIntent.prompt`): the count and the first five names. A dialog for another selection does not confirm it.
- **Private by default.** `PlaylistCreator.defaultPrivacy` is `.private` for the request and the form; the visibility is always stated in the body.
- **Share is explicit.** Copy Link / Share… hand out the canonical `/playlist?list=<id>` link on the Music host (validated; a pasted link is accepted only
  with https, a YouTube host, `/playlist`, one `list` value, no user/port/fragment). A private playlist's link says only the owner can open it.
- **Collaboration (owner only; ytmusicapi `edit_playlist` / `join_collaborative_playlist`, 4da34b6).** *Create Invite Link* =
  `ACTION_CREATE_COLLABORATION_INVITE_LINK` (the answer's `collaborationInviteLink` is shown only if it validates, names this playlist and carries a
  valid `jct`; Copy Invite Link is a separate press; nothing is sent to anyone). *Stop Contributions…* = `ACTION_SET_CLOSED_TO_CONTRIBUTIONS`
  `{closedToContributions: true}` after a confirmation naming the playlist; this app cannot reopen it. *Join Playlist…* reads a pasted invite link
  (a read), names the playlist, sends nothing if the person already edits it, and sends `ACTION_JOIN_COLLABORATION {joinCollaborationToken}` only
  after a confirmation naming the playlist. Each is a request of its own (never combined with another change), through the session's guards:
  signed in, owner (the page's delete command), precondition read. A lost reply is "unconfirmed" and settled by reading (join) or the same
  state-setting request again (invite, stop).
- **Adding several songs, and drag.** Songs from a Library selection (up to 50), a suggestion, or a drop go through one staged path
  (`addSongs`/`confirmAdd`): a single new song is added at once; several songs, or a song already there, ask first (the naming confirmation;
  Keep duplicates / Skip existing). A song row from search, an album/artist page or the Library is draggable (`PlaylistDraggedSong`, a checked
  value); a drop on an editable playlist page, a Library playlist card or the editor's list only *stages* an add. **Save queue as playlist** saves
  only queue entries the app knows as YouTube Music items; while YouTube Music's hidden player holds the queue it says why it cannot.
- **Undo is compensating and can fail.** Built from what was *confirmed* (new occurrence ids for an add, the original successor for a move, the
  previous title/description/visibility), run through the same reconcile-and-send path, and reported when refused; a removal's undo adds the songs
  back at the end (new occurrences). A deletion has no undo (the dialog says so).
- **Downloaded membership.** `PlaylistEditSession.onMembershipChange` reports the occurrences that came and went once per settled change; it decides
  nothing about retention (W15).

## Write requests compared with Kaset (`YTMusicClient.swift` @ `4c59ff2`)

| Action | Ours (`SignedPlaylistWrites.swift`) | Kaset | Same? |
|---|---|---|---|
| create | `POST playlist/create {title, privacyStatus, [description], [videoIds]}` | same keys; `privacyStatus` a parameter | yes; ours is `PRIVATE` unless chosen |
| add | `browse/edit_playlist {playlistId, actions:[{action:ACTION_ADD_VIDEO, addedVideoId, [dedupeOption: DEDUPE_OPTION_SKIP]}]}`; **Keep duplicates sends `DEDUPE_OPTION_SKIP`** (skips the service's duplicate check), **Skip existing sends none** (check stays on; filtered locally too) | ytmusicapi: `duplicates=True` → SKIP, otherwise the whole add is refused if a duplicate exists; Kaset: none, "server de-dupes" | **corrected in rework 1** (the first candidate had them inverted); a refused skip-existing add whose songs are now all there reads as "already there" |
| remove | `{action:ACTION_REMOVE_VIDEO, removedVideoId, setVideoId}` | same | yes |
| delete | `POST playlist/delete {playlistId}` | same | yes |
| move | `{action:ACTION_MOVE_VIDEO_BEFORE, setVideoId, [movedSetVideoIdSuccessor]}` | **none** | web-client convention (ytmusicapi); live list |
| rename / describe / privacy | `ACTION_SET_PLAYLIST_NAME/DESCRIPTION/PRIVACY` | **none** | same as ytmusicapi (it sends a description only if non-empty; clearing with `""` is **unverified**, live list) |
| invite / close / join | `ACTION_CREATE_COLLABORATION_INVITE_LINK`; `ACTION_SET_CLOSED_TO_CONTRIBUTIONS {closedToContributions:true}`; `ACTION_JOIN_COLLABORATION {joinCollaborationToken}` | **none** | same as ytmusicapi |

Differences on purpose: ids are stripped of `VL` and must be `PL…`; a request is built only from occurrence ids the page published; success needs
the service's `status: STATUS_SUCCEEDED` (edit), a `PL…` `playlistId` (create) — Kaset treats any non-error 200 as success; a lost reply is
`indeterminate`, not an error.

## Not verified live — the end-of-project list

Run only on a disposable, app-created playlist, never on an existing one:
- the signed form of the editable playlist page: `musicEditablePlaylistDetailHeaderRenderer` with `editHeader.musicPlaylistEditHeaderRenderer`
  (and whether a collaborator's header lacks it), the per-row `ACTION_REMOVE_VIDEO` menu item, the delete confirm dialog's
  `deletePlaylistEndpoint`, the suggestions shelf;
- the answers: `status: STATUS_SUCCEEDED` / `STATUS_FAILED`, `playlistEditResults` (nested or flat) carrying each added `setVideoId`, the create
  answer's `playlistId`, the delete answer (a bare 200 is treated as unconfirmed and settled from the list);
- `ACTION_MOVE_VIDEO_BEFORE` (and a move to the end with no successor), the three detail actions, `DEDUPE_OPTION_SKIP`, and what an add without a
  dedupe option does for a song already present;
- continuation behaviour for a long playlist: whether a stale token answers with something this parser reads as `unrecognised`;
- that a collaborator can reorder and add but not rename/delete; any invite/collaboration-link request path.
- rework 1 additions: the answer to an invite request (`collaborationInviteLink`, `jct`), closing to contributions, join (including a rejection for an existing member), the exact refusal shape of an add without `DEDUPE_OPTION_SKIP` for a present song (the app reads any refusal of a skip-existing add and checks the playlist), whether a body `continuation` (as used here) reloads the suggestions' section-list token (ytmusicapi sends it as URL parameters), clearing a description with `""`, and the Library list lag after a create or delete (two agreeing reads are used).
- rework 2 addition: **does a second invite-link request invalidate the earlier link?** (`ACTION_CREATE_COLLABORATION_INVITE_LINK` twice: whether the first `jct` still joins, and whether Create Invite Link on an already-open playlist is idempotent). Until seen, the app treats each answer's link as the only one it knows and shows a fresh one only after an explicit press.
