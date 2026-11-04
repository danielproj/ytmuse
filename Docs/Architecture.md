# Native Music architecture

The established package is `Packages/NativeMusic`. W02 extends it; there is no second Domain package. The macOS 27 / Swift 6.4 baseline and native app composition from W01 remain in place. This document describes typed boundaries and the implemented domain behavior, not live service access. G01–G09 remain open.

| Module | Responsibility and boundary |
| --- | --- |
| AppShell | Process lifecycle, scenes, windows, menu bar, Settings and dependency composition. Supplies real implementations to `InfrastructureDependencies` and `MusicServices`; never constructs provider requests in a view. |
| DesignSystem | Tokens and reusable native components; no service requests. |
| Features | Home, Search, Library, Playlists, Downloads, Now Playing, Podcasts and Settings. Each destination uses MainActor `FeatureState<Value>` and an independent query generation. |
| Domain | Stable immutable entities, typed errors/results, capability decisions, commands, transition rules and use cases; no UI, provider JSON, networking implementation, decoder, or credential values. |
| AccountSession | Actor-owned identity/session lifecycle, Keychain references, account generations and renewal. Implements `AccountService` and `CredentialStore`. |
| YouTubeMusicAdapter | Authentication integration, request construction, parsing, pagination, mutations and source error mapping. Wire formats and cursor-to-provider-token mappings stay here. |
| StreamResolver | Variant discovery, authorization context and renewal. Protected authorization references cross Domain; signed URLs and secrets remain in protected adapter/engine memory. |
| Playback | Actor-isolated native engine backends, DSP, position, transitions and scheduling. Implements `PlaybackEngine` and drives shared `PlaybackCommands`; one transport owner. |
| Queue | Occurrence identity, context order, shuffle, repeat, undo and persistence. Implements `PlaybackLifecycleSink.advance`; no track-ID deletion or duplicate advancement. Full queue algorithms are W05. |
| Downloads | Actor-owned scheduling, storage, verification, local access and entitlement renewal through `DownloadCoordinator` and `OfflineMediaStore`. |
| Persistence | Actor-owned SQLite, migrations, normalized entities, local search and durable outbox. Implements `PersistenceStore`, `MutationOutbox` and checkpoint sink. |
| Artwork | Coalesced bounded caches, downsampling, palette extraction. Decode and disk access run outside MainActor. |
| SystemIntegration | Now Playing, App Intents, shortcuts, widgets, Spotlight, login items and AppleScript. Calls the same command use cases as UI; extensions use a minimal snapshot/channel, never independent sessions or general credentials (W25: `WidgetShared`, `Docs/Widgets-Spotlight.md`). |
| OutputRoutes | Local/Core Audio, AirPlay and Cast implementations of `RouteProvider`. Capabilities and scoped receiver state are explicit. |
| Diagnostics | Redacted local logs, signposts, performance counters and user-exported support bundles. |

The package graph is checked by `scripts/check-boundaries.py`. Production targets cannot depend on test targets or fixture files. Fixtures and support implementations exist only in `Tests/DomainContractTests` and `Fixtures/W02`. Neither a fixture provider nor a default fake adapter is composed into the app. Existing app actions only open windows/Settings or edit local appearance; playback and remote mutation entrypoints added by later nodes must use `PlaybackCommands`, `MutationCommands`, and `SessionCommands`.

MainActor mutates destination-scoped observable state. `FeatureState` accepts only a matching account/channel/region, active account generation and latest query generation, including error responses. A playback timeline is an immutable `PlaybackSnapshot` sampled with a monotonic instant; no process-wide observable playback tick is introduced. Session, playback, persistence and download service protocols require actor implementations. Network parsing, image decoding, hashing, collection diffing and media decoding belong in their worker modules outside MainActor and the real-time audio callback.

## Contracts

All async service operations return `ServiceResult<T>` or `PlaybackResult<T>`, including void operations and failures. These echo initiating scope. Provider adapters translate unauthorized, forbidden, unsupported, unavailable content, region restriction, rate limit with Retry-After, offline, malformed response, expired media, and transient transport errors. A successful transport does not establish operation success. No provider error body, token, or signed URL is a Domain error payload.

| §18 contract | Typed operations in `Domain/Contracts.swift` |
| --- | --- |
| MusicCatalog | `home`, `search`, `suggestions`, `details`, `library`, `radio` with typed tuner seeds/controls, `canonicalLink` |
| AccountService | `identities`, `authenticate`, `refresh`, `capabilities`, `switchIdentity`, `revoke`, `removeLocalIdentity` |
| LibraryService | `apply` save/remove, like/dislike, follow/unfollow, pause/clear history; `reconcile` |
| PlaylistService | `items`, `suggestions`, `apply` create/edit/delete, add, remove/move occurrences, join/leave/invite collaboration |
| PlaybackResolver | `resolve`, `validateEligibility`, `refresh`, `report` source-required playback/advertising events |
| PlaybackEngine | `prepare`, `play`, `pause`, `seek`, `stop`, `setGain`, `setRate`, `scheduleNext`, scoped state/failure `events` |
| OfflineMediaStore | `resolve`, `verify`, `validateEntitlement`, `pin`, `unpin`, `delete` |
| RouteProvider | `discover`, `connect`, `disconnect`, `capabilities`, `transport`, `session` |
| LyricsProvider | `lyrics` with source text, optional timing, attribution and availability |
| MutationOutbox | `enqueue`, atomic `beginAttempt`, `reconcile`, `commit`, `fail`, `cancel`, `status` |

`PageCursor` contains an opaque local reference, initiating scope, collection and expiry. Validate all of them before use. Only the adapter knows the underlying provider cursor. On expiry, later pagination implementations restart and deduplicate occurrences, preserving duplicates of the same media item.

## Entities and invariants

| Entity | Representation and guard |
| --- | --- |
| Account | Local UUID must equal context UUID; service identity, channel, two-uppercase-letter region, display name and optional Keychain reference. |
| AccountCapabilities | Feature records retain state, source, checked time, expiry and exact account/channel/region. Reject mixed contexts. Absent/unknown/expired evidence requests verification, distinct from denial. Supported alone grants permission. |
| MediaItem | Stable nonblank ID, kind/title/artists, optional finite nonnegative duration, artwork, optional explicit flag and explicit availability. Unknown stays unknown. |
| Album / Artist / Podcast | Stable metadata, related references and typed incremental track/release/episode pages with scoped pagination. |
| Playlist | Owner, private default privacy, explicit permission states, optional provider version and local snapshot version. Missing provider version is never fabricated. |
| PlaylistItem | Provider occurrence ID or stable synthetic UUID separate from media ID. |
| QueueSession | Exact account, version, unique entry UUIDs, current occurrence must exist, finite nonnegative position, seed, repeat and autoplay. |
| QueueEntry | Unique UUID, media ref, source segment including source advertising, nonnegative original order and consumed state. Repeated media IDs remain distinct entries. |
| PlaybackSnapshot | Account/request/playback generation, current occurrence, state/item, position and monotonic anchor, rate, route, intent/pause reason and typed error. Only playing extrapolates position. |
| MediaVariant | Codec/container, positive actual bitrate/sample rate when observed, expiry, seekability and authorization reference. Unknown measurements remain nil. |
| DownloadJob | Account/media/variant, nonnegative ranges/size/retries, disjoint in-bounds ranges, references, state and verification. Completed requires verified integrity. |
| OfflineEntitlement | Explicit source-granted rights/account/media, expiry/renewal, last validation and availability. No rights inferred from Premium. Process-local `EntitlementLease` also bounds validity by monotonic elapsed time; backward wall time cannot extend its deadline. A new process must revalidate. |
| LibraryMembership | Account/entity, optional service membership, pending operation/sync state, sort date/key. Local pending state does not imply a confirmed service write. |
| HistoryEntry | Account/item, actual listening start/end (end cannot precede start), source/local provenance and sync state. No synthetic listening events are emitted by Domain. |
| PendingMutation | Operation UUID, account/target, typed intent, provider/local precondition, nonnegative attempts and outcome. Pending operation ID must equal the record ID. |
| ArtworkCacheEntry | Source key, positive dimensions, explicit source cache policy, nonempty hash, nonnegative byte usage and last use. |
| Preferences | Global/account/window scope, positive schema version, typed values with finite numeric values. |

IDs and fields are immutable. Persistence implementations can reconstruct validated values but cannot bypass their public initializer guards. Credential and authorization models contain references only and deliberately have no automatic serialization to view/extension snapshots. `TransportRequest/Response` are infrastructure-only byte envelopes; provider JSON is decoded in adapters, never Domain or Features.

## Generations, commands and transitions

`SessionCommands` advances active-account generation before awaiting identity work, invalidates playback and mutation ownership, and rejects late identity responses. Every account, item and route handoff increments the playback generation. Request generations are destination-scoped; playback contexts additionally carry occurrence and route identity. Engines must enforce the same context at their hardware boundary, including after any suspension. Domain checks both returned envelope and active context after each asynchronous step. Generation counters trap at exhaustion instead of wrapping to an old value.

`PlaybackCommands` checks account capability and item eligibility, resolves a real variant reference, prepares the injected actor engine and interprets deterministic `PlaybackMachine` effects. No native player, provider or route implementation is fabricated in W02. The command origin identifies the entry surface and never changes permission policy. `SessionCommands` owns authenticate/refresh/revoke/remove/switch use cases. `MutationCommands` validates account/capability, durably enqueues, atomically claims a first dispatch, invokes the appropriate service and records confirmed/failed/needs-reconciliation outcomes. A durable outbox must refuse a second claim; a timeout after submission requires a remote read rather than replay. Per-playlist roles and source operation success are enforced by the injected service in addition to the account capability check.

| §19 event | Implemented domain rule |
| --- | --- |
| Play selected item | Invalidate previous item, stop previous transport, check permission, resolve, prepare, play if intent still permits. |
| Pause during prepare | Retain pause reason through resolving/preparing; completion cannot autoplay. A late started event produces a pause effect. |
| Temporary network loss | Preserve monotonic position and play intent while buffering; recovery plays only if intent remains play. |
| Headphone/output loss | Invalidate route generation, stop old engine, pause with route-loss reason; reconnect alone never resumes. |
| Account switch | Invalidate account/playback ownership, stop/checkpoint old work and restore new state idle/paused. Durable account queue restore is W04/W05. |
| Seek during resolution | Retain latest target; preparation emits that seek before any play. Seek revisions reject superseded completions. |
| Stream expiry | Permit one refresh effect per selected item, retain position and pause intent; second expiry fails explicitly. |
| Item end | One advance effect per generation; queue sink applies repeat/context/autoplay in W05. |
| Sleep/wake | Checkpoint interrupted intent; wake resumes only with safe route, enabled preference and no intervening user/route/account pause. |
| Quit | Checkpoint, stop and invalidate late events; lifecycle owner cancels app background work and exits. |
| Entitlement revoked | Stop, invalidate playback generation, retain a source restriction error and pause reason. |

Wall clocks serve history/server expiry; monotonic clocks serve playback/latency and in-process expiry leases. No system wall change advances playback. Injectable transport, credential store, persistence, engine, clocks and capabilities are mandatory dependencies, with no global singleton or hidden default provider.

## W02 verification boundary

`./scripts/test.sh --suite T02` requires nonempty test discovery, checks package boundaries, and runs Swift tests for capabilities, generations, commands, transitions, invariants and fixture classification. `Fixtures/W02/manifest.json` records synthetic provenance and deterministic seeds. Test providers are compiled only into the test target. The manifest loader refuses live-service/release classification. Seed/step are included in failing property assertions. Fixture results establish domain behavior only; actual adapters, storage, audio output, source ads, account access, hardware and release evidence belong to their assigned later nodes and remain required.

## W02 transport-ordering correction

Account/item/route identity generations are complemented by an actor-owned transport
revision. Play reserves a revision before capability lookup; a newer Play, Pause,
select, route handoff, sleep/wake, quit or account switch supersedes that pending
intent. An obsolete authorization completion returns `staleContext` without
resuming. Late engine Play/Pause acknowledgements are checked before their result
can affect newer intent; a seek revision also prevents an older start acknowledgement
from finishing a newer seek. Engine implementations serialize actual transport
application before awaiting acknowledgements.

`PlaybackMachine` records whether a start is currently expected. Repeated starts
while already playing leave the clock anchor intact. A spontaneous pause captures
elapsed position before freezing the timeline; duplicate pauses remain idempotent.
Start/pause/position notifications cannot complete a pending seek, and an explicit
pause during seek retains both its pause intent and the seek completion. Only a new
validated play, recovery from buffering with preserved play intent, or completed
seek authorizes a later start. Queued engine
events carry `observedAt` from the shared injected monotonic clock at capture;
timed transport/position observations older than the current anchor are ignored. A nil timestamp is for an
immediate boundary observation, not for delayed callbacks.

Permanent transport regressions retain the three parent reproductions and add
controlled capability/engine suspensions, seek/notification interleavings, capture
versus delivery ordering and an independently accumulated seeded timeline oracle.
Earlier 22-test evidence did not establish these cases; its parent findings and
failing logs remain in the W02 evidence history.

## W02 authority-event correction

Time ordering applies to position, start, pause, buffering and network-recovery
observations. It does not establish authority: a newer position cannot renew rights
or prove recovery from a current-context failure/end. Current-context entitlement
revocation always stops, records the restriction and invalidates playback generation,
even when captured before the latest position. Failures and ends also terminate
without age suppression; end stops transport and advances at most once. All events
still require the exact active account/item/route context, so an old context cannot
revoke or terminate a new session.

Terminal transitions materialize position with a nondecreasing monotonic anchor.
The command boundary uses receipt time for authority/terminal handling and capture
time for ordered observations. Revocation's stop/checkpoint effects use the newly
invalidated context, so the stop reaches the engine after generation advancement.
Prepare/resolve completions use lifecycle state and identity, and seek completion
uses its revision, with a clamped anchor; unrelated newer timeline updates do not
silently discard valid completions. The R1/R2 intent and observation protections
remain covered alongside explicit positive/stale-context authority controls.
