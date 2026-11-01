# Downloads — W15 durable scheduler, retention and the Downloads screen

Status: implemented and tested headlessly (suite `T15`); native UI run pending an unlocked console. No live service, account or
network was used. The offline gate for YouTube Music stays open (`artifacts/harness/W15-offline-source-decision.json`).

## Source reality

Under `Docs/Playback-Addendum.md` YouTube Music media plays only through YouTube's own web player. Its web client offers no
downloads, and obtaining files would need the circumvention the addendum forbids. So **no YouTube Music item is ever queued**:
`DownloadEligibility.of(_:)` answers `notOffered(.youTubeMusicNoMacDownloads)` for it, `DownloadScheduler.download` returns that
without asking any source, and the UI shows the sentence "YouTube Music doesn't offer downloads on Mac." at the item
(`DownloadCapabilityNote`, song and collection pages) and on the Downloads screen. It is words, not a control.

What is kept:

| Origin | Identifier | Source | Permission |
|---|---|---|---|
| owned | exactly the bundled identifiers (`MediaOrigin.bundledOwnedIdentifiers`, pinned to `OwnedMedia` by a test) | bundled licensed synthetic signals | the owned license (`LocalFileDownloadSource(exactVariant: true)`) |
| local file | `local-file:<uuid>` | a file the account holder picks ("Add Audio File…") | the holder's own declaration of ownership; app policy window of 400 days, renewed 30 days before its end |
| publisher grant | `publisher-grant:…` | none registered | a source that publishes an explicit download permission would supply it. **Nothing in this codebase does** (searched: no catalog, resolver, renderer or fixture carries a download permission), so none is invented; an origin with no registered source is refused, not queued |

The local-file "permission" is an app policy, not a service rule and not a 30-day-style invention about YouTube. A source states
issuer, rights, validation time, expiry, renewal reference and source encryption (`DownloadPermission`), and that maps one to one
onto the W14 `RetentionGrant`.

## Engine (`Packages/NativeMusic/Sources/Downloads`)

* `DownloadScheduler` (actor) — the only owner of jobs. One logical job per (account, media). Implements `DownloadsControlling`
  (what the UI drives) and `AccountLifecycleParticipant` (detach / restore / remove).
* `DownloadLedger.swift` — atomic, fsynced JSON ledger per account under a private root (`PrivateDirectory`: descriptor-relative,
  no-follow, 0700/0600). A damaged ledger is set aside (`ledger.damaged-<t>.json`) and the account starts clean; a ledger naming
  another account is never adopted. A tiny `usage.json` per account lets the budget span accounts without opening their ledgers.
* `RangeSet` — completed ranges, sorted, disjoint and merged; a damaged set fails to decode. A range is recorded only after its bytes
  are fsynced into the staging file, so a crash can lose progress but never claim bytes that are not there.
* `DownloadSource` — `describe` (variant, validator, length, ranges?, address expiry, optional digest, permission), `read(offset,count)`,
  `renew`. `RetentionSink` — the store operations; `EncryptedStoreSink` is the W14 encrypted object store.
* `DownloadPolicy` — pure rules: 20 GiB default budget across accounts; reserve `max(5 GiB, 5% of the volume)`; automatic cap 25% of
  the budget; concurrency 2 (1 in Low Power Mode); `RetryPolicy` (exponential, half-to-full jitter, capped, bounded count).
* `SystemNetworkPath` / `SystemPowerState` — `NWPath.isConstrained` / `isExpensive` as measured, and `isLowPowerModeEnabled`.

### State machine (OFF06)

`queued → resolving → downloading → validating → available`, plus `paused` (with a cause), `renewing`, `expired`, `failed` (with a
reason). Every transition is persisted before the work it announces. After a crash or quit a `resolving/downloading/validating`
job returns to `queued` with its ranges; `renewing` returns to `available`.

* **Variants (OFF07).** The job binds the first descriptor's variant + validator + length. A later descriptor that differs discards the
  staging file and the ranges and starts that variant from byte 0 — bytes of two variants are never combined. A source without ranges
  restarts from 0. Total length unknown ⇒ no percentage anywhere (`DownloadProgress.fraction` is nil, the aggregate has no total).
* **Address expiry.** `urlExpired` ⇒ describe again and continue from the recorded ranges; at most three refreshes without progress,
  then a backoff.
* **Ranges and bytes are one thing.** A progress range exists only beside the exact staging file that holds it (the job records the file's device:inode; `removeStaging` clears the ranges with the file; launch recovery drops ranges whose file is missing, shorter or replaced). A failed job carries no progress, and Try Again starts from byte 0.
* **Validation.** Completeness (ranges cover the length, file is exactly that long), then the staged digest must equal what the source holds (a published digest, or one the source states itself: the local-file source hashes the file it reads read-only), then `retain` into the encrypted store, and the store's own plaintext hash from `verify` must equal the staged digest, plus a length check. Only then `available`; only after that is durable is the
  cleartext staging copy removed. Orphan or non-resumable staging files are deleted at launch.
* **Priority (OFF05).** current playback > the newest explicit download > older explicit > collection members > automatic. A
  higher-ranked current-playback job takes the slot of the lowest-ranked running one (which keeps its ranges and requeues); a smaller
  limit (Low Power Mode) sheds the surplus the same way. Never more than the limit running.
* **Network (OFF05).** offline ⇒ everything waits. Constrained or expensive ⇒ automatic jobs wait and cannot be overridden; a manual
  job waits too until the person presses "Download on This Connection" for that job. A running job stops when the path turns metered.
* **Retries (OFF13).** transient failure ⇒ `attempts+1`, delay `base·2^(n−1)` capped at 300 s with jitter, honouring a longer server
  `Retry-After`; six consecutive failures without progress ⇒ `failed(retriesExhausted)` with Try Again. Progress resets the count.
  A repeated request or reconnect finds the existing job; it never creates a second.
* **Safe quit (OFF13).** `quit()` cancels everything, waits a bounded time, halts a source that ignores cancellation (its late return
  writes nothing), persists the checkpoint and finishes. Nothing keeps running; the next launch resumes by itself.

### Storage (OFF03, OFF04)

Admission is one function. Order: volume reserve (the staged copy and the encrypted copy briefly coexist, so the need counts both),
Smart cap for automatic content, then the budget: automatic content never evicts anything; manual content may evict only automatic
content, oldest first. If pinned or collection-referenced content fills the budget the job **pauses** (`storageBudgetFull`) and the
screen offers choices (raise the limit, remove downloads, remove automatic downloads, free disk space). Nothing is deleted for room
except automatic content, and **no setting change deletes anything**: lowering the limit only decides what may start; switching Smart
Downloads off stops new automatic downloads (pending ones that never started are dropped; stored ones stay until the person removes
them). Smart Downloads is off by default and requires the explicit switch; an automatic request while off is refused. **Nothing on this Mac can suggest items** (no permitted source), so the switch is not offered: the Storage card states that Smart Downloads isn't available yet and that nothing is downloaded automatically, and the engine refuses to be switched on (`smartDownloadsAvailable` is false unless a composition supplies a suggestions source). The 25% cap counts stored and in-flight automatic bytes together, so concurrent starts cannot overrun it.

### Retention (LIST07, OFF11)

References are strings in the store object: `manual`, `smart`, `collection:<id>`; `manual` also sets the pin. `setCollection` turns
"Download this playlist" on/off, `reconcileCollection` applies new membership: additions join the queue (duplicates collapse),
removals drop only that collection's reference — an object other references or a pin still hold stays, readable. The last reference
gone ⇒ the store deletes the object and the job disappears. A song the person removes by hand stays out of that collection's download
until it leaves the playlist and rejoins. No UI toggle calls `setCollection` yet: no permitted source has playlists (YouTube Music is
refused), so there is nothing to attach it to; the engine and its tests are complete for when one exists (W36 / a future source).

### Failure and recovery (OFF12)

| Condition | State | Recovery offered |
|---|---|---|
| address expired | resolves again, continues | — |
| volume reserve reached / budget full | `paused(volumeReserve / storageBudgetFull)` | free space, raise limit (resumes by itself), remove downloads |
| store out of space | `paused(diskFull)` | Resume |
| bytes fail digest / stored copy fails verification | one clean restart, then `failed(corruptBytes)`; partial and object removed | Download Again, Remove |
| key missing | `failed(missingKey)` (no retry loop) | Download Again, Remove |
| account revoked / signed-out identity restored | `failed(accountRevoked)`, partials removed, other accounts untouched | Download Again, Remove |
| account switch or sign-out (detach) | unfinished transfers lose their cleartext partials at once and start again from byte 0 when the account returns; a quit keeps its partial to resume | — |
| kept copy whose key or object is gone | audited at every bind: `failed(missingKey / corruptBytes)`, never Downloaded | Download Again, Remove |
| account removed | ledger and staging for that account deleted | — |
| grant ending / source refuses renewal | `renewing` → `available` (extended) or `expired` (only at the stated end) | Renew, Download Again, Remove |
| lost network | `paused(offline)`, resumes by itself | — |

A stale account generation cannot rebind the scheduler; every operation is bound to one `RequestContext`.

## Playing kept items

A kept owned or picked item plays through the **native AVFoundation session** from the W14 encrypted store, offline: `RetainedAssets` (a `NativeAssetProvider`, resource loader over `EncryptedStore`, content type from the picked file) and `RetainedPlayback` (resolver + capabilities that resolve only what is currently Downloaded). `NativePlayer` admits the `retained-encrypted` scheme only through `RetainedMediaAdmission` (retained-download authorization AND an authorized-native session); a URL alone grants nothing and a network URL is never admitted. The store re-checks account, key, rights and expiry on every read; seek follows the retained grant's seek right. `AppPlaybackAuthority.retained` opens the session as the single playback owner (never beside the hidden player), `PlaybackModel.playKept` starts it, and the native session now publishes Now Playing and answers media keys. Play appears on a Downloads row and in the Library's Downloaded-only section **only when a player is wired and the item is Downloaded**. The queue is in memory only. Headless proof: `PlayableDownloadsTests` renders the decoded output into a buffer at the 0.001 gain cap with the cleartext source deleted.

## Not covered (stated, not hidden)

* Source-time renewal and authorized-source grants for kept media: W36.
* A damaged job record is set aside; the retained objects it described cannot be listed again, so their size keeps counting toward the limit (`unlistedBytes`) and is shown on the screen. Removing them needs the account's data to be removed.
* The staging file is cleartext of media the holder already holds in the clear at its source. It is a 0600 file in a 0700 private
  directory, removed on completion, cancel, failure, revoke, account removal and at launch if orphaned. OFF09's "remove partial
  cleartext files" is met by removal, not by encrypting the partial.
* Live service, region, Premium and entitlement behaviour: unobserved. `G05` and the offline row of the release gates stay open.
* Native UI run: `scripts/test.sh --suite T15` exits 75 on a locked console; the UI part is written and pending (see the report). Not exercised by any run: Now Playing and media keys of a kept-item session on a real session, and audible playback.
