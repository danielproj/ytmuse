# Discovery extras and social workflows (W20)

Samples, the music tuner, Recap, badges, and comments / ratings / invitations / moderation. This node was built **source reality first**:
each feature was checked against the real public YouTube Music captures on `main` before any UI was built on it. Where a source surface is
present the app uses its real shape; where it is absent the affected place says so plainly and offers no control that pretends to work.
Live verification of every route is W38. Nothing here is live evidence.

## What the real captures carry

Searched: `Fixtures/W10-real`, `W11-real`, `W12-kaset-real`, `W13-real` (anonymous public YouTube Music responses, hashes pinned in their
manifests) and Kaset's MIT fixtures (read-only, `/tmp/kaset-src.*`). `SourceRealityTests` repeats the structural sweep on every run, with
positive controls so an absence cannot be a blind sweep.

| Feature | In the captures | What the app does |
| --- | --- | --- |
| Samples | No structure names a sample, short clip or vertical feed. The word appears only in podcast episode text. | `UnresolvedSamplesSource`: the screen says Samples aren't available yet. No clip list, no preview control. |
| Radio (service context) | **Present.** An entry's own menu offers a "Start mix" action (menu item with the `MIX` icon) whose endpoint is a watch endpoint with a playlist, a track for songs, and parameters (`wAEB` in every capture); artist and album/playlist pages publish a radio button or menu item the same way. **Not radios:** `RDCLAK…` editorial playlists, `RDAO…` artist shuffles and `RDTMAK…` mixes appear in the same captures with play/shuffle endpoints only. | Seeds are exactly the entries and pages that present a radio action (`MusicRadioAction`, read by the browse parser); an `RD` prefix is never enough. Starting one sends the action's playlist, track **and parameters** to the shared playback session. On the 7 real browse captures this gives 280 seeds, every one a presented radio with its endpoint's own parameters, none an editorial playlist (`SourceRealityTests`). |
| Tuner diversity / discovery controls | **Present in the R1 real anonymous public capture** (`Fixtures/R1-real/next-radio.json`, provenance in `manifest.json`): 13 queue filter chips. All publish an autoplay queue update with `fetchContentsCommand.watchEndpoint`, true dedupe and dedupe sync mode; Workout and Gothic Funk also carry opaque `playerParams`. By 2026-11-05 YouTube Music had moved every chip to the main queue section (`QUEUE_UPDATE_SECTION_QUEUE`; `Fixtures/R2-real/next-radio-artist.json`), which the R1-only parser rejected, so every live radio reported "Radio filters couldn’t load". The parser now accepts exactly those two sections, and each chip sends back the section it published. On the official page, applying a `QUEUE` chip (by clicking it, or through the app’s own command) kept the current song and playlist id and replaced the upcoming songs; an `AUTOPLAY` command only appended songs after the queue. | Production uses `QueueRadioControlsSource` and the bounded real queue parser/reader after an explicit radio start; no startup read. Publisher order and selected flags remain source truth. Canonical filters use the existing official player’s resolver as scoped queue controls, preserving current playback intent and owner. Missing/stale scope, absent readable queue, unsupported performer or an ad refuses application. Isolated automation retains the unresolved source. Source/build evidence only; signed-session application and UI/runtime acceptance remain open. |
| Recap | Absent (the only "recap" is a YouTube video title). | `UnresolvedSummarySource`: stated as not readable yet. |
| Badges | The `musicInlineBadgeRenderer` badge present marks an **explicit** entry (`MUSIC_EXPLICIT_BADGE`), and a live badge marks a live item. They are not achievements. | Same unresolved state; account achievements are not invented from them. |
| Comments, moderation | Absent from every music capture (comment structure exists only in YouTube watch pages, which are not Music). | `UnresolvedCommentsTransport`: Comments say they aren't available; nothing can be read, posted or moderated. |
| Ratings | **Present** (`likeStatus` on track rows). | Already W12's: written only through the Library ledger. W20 adds the role check and the outcome record. |
| Invitations | **Present** for playlists the account owns (W13's collaboration actions). | Written only by W13's `PlaylistEditSession`; W20 routes the editor's buttons through `SocialSurface` for the role check and the outbox result. |

An unresolved or absent route is **not** an account restriction. The states are different on purpose: `unresolved` (no route known in this app),
`payloadMissing` (a route answered with nothing), `accountUnsupported` (the service said this account lacks it), `signInRequired`,
`sessionEnded` and `failed`.

## Previews and Samples (DISC04, T20.1)

`PreviewArbiter` (Features/DiscoveryExtras) is the one place that decides what previews:

- one clip previews at a time; asking for another stops the first and waits for it to be silent before the second starts. Requests are
  carried out strictly in order; a request a newer one overtook does not start (scrolling quickly leaves exactly the last clip);
- a preview that starts by itself (`autoplay`, from focusing a clip) obeys `PreviewPolicy`: refused on Low Power Mode, on a constrained or
  metered connection, when the person chose Off, and when something else is playing. A press on Preview is never refused by the policy. When
  the conditions turn against an automatic preview it stops; one the person asked for continues. The choice (`Automatic` default, `Off`, `On`)
  is kept for the session only; where it is stored belongs to Settings (W27);
- **Play** stops the preview, waits for silence, and only then asks the shared playback session to play the clip's own item, with the
  playlist and parameters the clip carried (`SearchActionPerformer.play`, the same path Search and the Library use);
- nothing starts at launch, on load or on sign-in. An account change stops the preview and discards a start that was in flight.

In the application a preview is the clip playing in the **one shared playback session** (`SessionPreviewEngine`): the hidden player already
owns picture and audio (W17's single-owner surfaces), so there is no second player and nothing can overlap. Stopping pauses that same player,
and only while it is still on the previewed clip. A previewed clip is reported to the local history as a preview, never as a play. The device
conditions come from `ProcessInfo` (Low Power Mode) and a passive `NWPathMonitor` (`isConstrained || isExpensive`); the monitor sends nothing.

A preview is one clip. Played through a radio, a clip would run on into the radio's next tracks, so the preview is watched (`PreviewWatcher`): it ends at the clip's stated length or when the player reports the clip ended, a player that ran on into another item by itself (nobody asked it for one since the preview began) is paused, and a player that moved because something else asked it simply stops being previewed. Only an explicit Play continues past the clip. A preview shares the one player, so pressing Preview while something plays replaces it (the Samples screen says so); Stop pauses rather than restoring what was playing. When a source supplies clips, the previewing row shows the picture in W17's single-owner inline surface (`WebVideoPreview` over `VideoSurfaceOwnership`), or that surface's placeholder if another surface holds it.

Because no source route for Samples exists, **no preview can start in the shipping app today**; the arbitration is exercised end to end
against scripted engines and, in Debug UI runs, against labelled development data.

## Tuner (DISC03, T20.2)

`TunerModel`: seeds → explicit start → context → metadata controls. Seeds retain the service’s own start endpoint. Production now reads the radio queue through the R1 reader and presents the published filters; read failure is retryable, distinct from a successful response with no controls. Metadata retry does not play anything.

Canonical chip selection updates the section of the existing radio’s queue that the chip names, through `SearchActionPerformer.applyRadioFilter` and the official page’s `resolveCommand`. A captured scope binds the controls to the existing owner, document/load and current radio content; account replacement, another start, local media or a replaced document invalidates it. There is no owned-start permit, engine handoff, held start, cookie installation, document creation, current-item/artwork reset or forced resume. Native queue admission and immediate page-side ad detection refuse unsafe dispatch. The exact bounded command preserves `watchEndpoint`, params, optional playerParams and the published section/dedupe/sync constants; there is no invented URL mapping. Legacy performers refuse it rather than dropping fields.

Router acceptance alone is unconfirmed. A bounded control-specific wait requires a fresh ordered upcoming-video change for the applicable current content, while allowing the original playlist/video and paused state to remain. Timeout or absent evidence reports an unconfirmed control without failing healthy playback. The metadata read uses the selected published fetch target and its params/playerParams separately from the unchanged active playback scope. Fresh metadata selection flags remain authoritative; the requested choice never overwrites them. This is conservative: a service-applied filter with no later readable queue change remains unconfirmed. Ordinary endpoint and genuine Shuffle confirmation retain their existing contracts.

R1 and R3 artifacts record the frozen capture, source changes and Release/static checks. R3 regression sources have only been syntax-parsed, not executed. Actual signed-account filter effects, queue/report timing, native layout/accessibility and W38/G01–G09 acceptance are still open. Historical W20 reports describe the earlier unresolved implementation and remain historical evidence.

## Recap and badges (T20.3)

`AccountSummaryModel`. Entries are the source's own text (`SummaryEntry.value` is never parsed, rounded or summed). A payload with no
entries is `payloadMissing`, not an empty Recap. This Mac's own record (`LocalListeningSummary`, from the local history) is a separate
property on its own screen under its own title, **On this Mac** (an Explore entry of its own, not part of the Recap screen), labelled "not YouTube Music's Recap", `isOfficial == false`, and never fills a missing Recap.

## Comments, ratings, invitations, moderation (MEDIA10, T20.4)

`SocialSurface` rules: every write is one explicit call for one item; `SocialPolicy` decides the role before anything is sent (signed out → all
denied; only a playlist's owner may invite or close contributions, from the rights the playlist published); moderation is offered only where
the source offered that exact action **on that exact comment**, and a destructive one needs the confirmation the question named (`ModerationConfirmation`: which offer, on which comment, by whom, saying what — compared with what the page shows now); the comment list is only ever what
the source returned (a confirmed post is shown by reading again, never by inserting text); an unknown outcome — including a reply to a sent request that could not be read — is shown as unconfirmed, read back before anything is sent again, and never retried by itself; "nothing was sent" is said only for offline, signed-out and ended-session failures. Every action leaves one `SocialOutboxEntry` with its result (`pending`, `confirmed`, `failed(sent:)`, `unconfirmed`,
`denied`, `sourceUnresolved`) and whether anything was sent. A transport takes a `SocialSubject` (a service id), never an address, so there is no
path to read arbitrary external comments (`W20SourceGuardTests` sweeps for it). Ratings and invitations are written only by the Library ledger
and the playlist edit session; the like and dislike buttons run the role check and outcome record (`SocialSurface.rate`) around the button's own ledger call, so the ledger's single submit call site is unchanged; the app still has the single `awaitedMusic().write(` call site.

## Where things live

`Features/DiscoveryExtras`, `Features/Social`, `AppShell/DiscoveryComposition.swift` (live composition, preview engine, device conditions),
`AppShell/DevelopmentDiscovery.swift` (Debug only: labelled scripted sources behind `YTMUSE_UI_DEVELOPMENT_DISCOVERY` plus the library flags and QA
isolation; the Release binary carries none of it), Explore's "Discovery" row, the song detail's Comments section.
Tests: `DiscoverySocialTests`, `PlaybackTests/SessionPreviewEngineTests`, `NavigationTests/DiscoveryCompositionTests`, UI `testW20…`.

## For W38 (live verification)

Find the real route (or confirm there is none) for each remaining unresolved surface: Samples feed and clip shape; Recap and badges payloads; comments, posting and moderation, including who is offered what. For the implemented radio queue reader and scoped filters, authorized signed-session validation must establish actual application, unchanged pause/ownership behavior, ad refusal, stale-context fencing and source-selected UI state against the final build. The R1 anonymous capture and R3 source/build evidence do not complete these live gates. Then run the preview rules against real clips: Low Power Mode and Low Data
Mode on real hardware, one hidden player doing both preview and playback without a gap, and the history marking.
