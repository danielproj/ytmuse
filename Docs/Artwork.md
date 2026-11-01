# Bounded native Artwork (W09)

`Artwork` depends only on `Domain` and native SDK frameworks. It provides immutable Sendable `CGImage` rasters and subdued palettes, with no view wrapper, provider JSON, endpoint, credential, player, timer-driven decoration, or catalog fixture. Shell/feature code owns presentation, semantic foreground contrast, transitions, and task lifetimes. Original brand/icon resources are untouched.

## Consumer API

```swift
import Artwork
import Domain

// App composition injects ONE long-lived, query-independent account producer.
let pipeline = ArtworkPipeline(source: source, diskDirectory: privateArtworkDirectory)
let owner = ArtworkOwner(account: accountContext)
// Only the authoritative account lifecycle calls this, never an image view.
try await pipeline.setAccountGeneration(owner: owner, generation: accountGeneration)
await pipeline.startPressureMonitoring()

let request = ArtworkRequest(
    resource: try ArtworkResource(namespace: "adapter-issued-source", identifier: opaqueID, revision: revision),
    size: try ArtworkSize(pointsWidth: 72, pointsHeight: 72, scale: displayScale),
    policy: sourceCachePolicy,
    context: requestContext
)
let response = try await pipeline.image(for: request)
// Before mutating MainActor feature state:
// guard !Task.isCancelled, response.context == latestRequestContext else { return }
// response.image.cgImage; response.image.palette
```

This is a usage fragment with composition-supplied values, not executable service onboarding. `ArtworkSource` is the injected typed boundary:

```swift
public protocol ArtworkSource: Sendable {
    func load(resource: ArtworkResource, owner: ArtworkOwner,
              generation: UInt64, maximumBytes: Int) async throws -> ArtworkSourceData
}
```

Its result contains encoded `Data` and an `ArtworkCachePolicy`. The source must resolve opaque resources through an approved account-owned adapter, enforce `maximumBytes` during receipt (including redirects/streaming), and honor cancellation. It must apply its network/account fence before sending. It must not capture a consuming feature's query-scoped client. The explicit account generation is available to that producer; query generation is absent by construction. No live source adapter is established here. Known `DomainError` and `ArtworkError` categories survive; unknown source errors become `.sourceUnavailable` without forwarding diagnostic strings.

## Authority, identity and cancellation

One pipeline is one **foreground authority domain**, with one current account/channel/region and a global monotonic account-generation highwater. Equal generations permit only the same current owner. Switching A→B revokes old A reads, pending waiters, memory publication and final disk rename without requiring features to rebind old facades. Returning to A requires a newer generation. Sign-out/session revocation calls `invalidateForeground(generation:)` with a newer generation, retaining files but authorizing no foreground owner; reactivation requires a still newer generation. The lifecycle must publish the switch before admitting new feature reads. `removeAccount(accountID:)` permanently tombstones that local UUID in this pipeline, cancels its work, removes all channel/region memory and disk variants, and reports purge failures; revocation survives storage failure. Re-adding uses a new local account UUID. Tombstones are authority metadata, not image bytes. Reconstructing a pipeline requires reestablishing authority from AccountSession, not trusting persisted artwork.

The key includes account UUID, channel, region, source namespace, opaque resource identity, content revision, pixel dimensions and requested cache-policy/deadline. Account generation authorizes a request; query generation identifies a waiter. Neither generation orders cached content. An authorized new generation may reuse the same owner's retained, unexpired variant. Different owners are never shared, including apparently public images. Different sizes/revisions/policies cannot coalesce. Signed URLs/credentials are resolved inside the source and are neither keys nor disk filenames.

Each `image(for:)` task has its own waiter and echoed `RequestContext`. Cancel/supersede that task on query change, disappearance, fast navigation or account switch, and compare its returned context against the consuming feature's latest context before UI publication. Artwork does not maintain a global feature/query highwater: query 4 in one feature must not suppress query 8 in another. Cancelling the creator or a joiner removes only that waiter. The final waiter cancels the producer, removes pending admission, and prevents caching of abandoned work. An uncooperative source keeps its actual active slot until it exits; cancellation cannot grant unbounded replacement slots. No client can retract a value already returned before cancellation/switch, hence the final feature-context check is part of the contract.

Disk publication uses a tiny shared authority lock around the final rename only, closing the gap between an actor check and asynchronous disk completion. File read/write, hashing, decode and palette work never hold that lock. Publication IDs make abandoned-load cleanup conditional, so old cleanup cannot delete a newer peer's variant. The staging-race test changes the authority after bytes are actually written and before rename.

## Work, cache and input limits

Defaults are hard upper ceilings; configuration may lower them:

| Resource | Bound / behavior |
| --- | --- |
| Retained raster cache | 64 MiB, charged by actual `CGImage.bytesPerRow * height`; LRU eviction before admission |
| Disk cache | 512 MiB across all owners in this pipeline; charge max(logical file length, allocated 512-byte blocks), reserve staging space before writes |
| Metadata entries | At most 4,096 retained entries per cache |
| Source bytes | At most 8 MiB, rechecked before ImageIO |
| Source dimensions | At most 32,768 on either axis and 100 million pixels; validated before thumbnail decode |
| Display variant | Finite positive dimensions, scale at most 4, at most 2,048 pixels per axis |
| Production work | Two active source loads, 32 total active/pending distinct loads, 128 waiters; all configurable downward |
| Native work | One serial off-main ImageIO/palette executor; no original full-resolution `CreateImage` decode path |
| Disk startup | Incremental fixed 16-byte expiry headers, at most 8,192 entries processed plus one directory-name overflow probe; reject an overpopulated/unusable directory with observable failure |

Display decode fits both dimensions, applies EXIF orientation and produces an eager, normalized 8-bit sRGB raster. Supported single-frame sources are PNG/JPEG/HEIC/TIFF; malformed, animated/multiframe or unsupported inputs fail. Palette extraction uses a one-pixel native sample and a subdued neutral blend, once per retained variant. A disk hit restores its validated palette. No-store and evicted memory-only variants necessarily recalculate when requested again. Palette colors never establish essential text/control contrast.

`ArtworkDemandWindow.indices(visible:totalCount:isVisible:nearby:maximumCount:)` selects at most 24 indices by default, including at most two neighbors on either side. Hidden/empty windows select none, even for a 50,000-item collection. Features incrementally request this bounded window and, separately, at most the next eligible playback item. They cancel obsolete tasks rather than prefetching an entire album or retrying `.overloaded` in a loop. This helper supplies demand only; UI list/grid virtualization belongs to the shell lane.

`ArtworkCachePolicy` is `.noStore`, `.memory(until:)` or `.disk(until:)`. Request and source-response policies are intersected: either no-store prevents all retained raster/palette/disk state; either memory-only prevents disk; the earlier deadline wins. Expired entries cannot be served. Memory is swept on image demand; fixed expiry headers permit disk expiry cleanup without decoding every object on startup. Disk access, explicit `purgeExpired()` (for lifecycle/wake), pressure or cache clearing perform cleanup. There is no background polling or guarantee of wall-clock file deletion while the app is asleep/not running. An adapter whose source requires stricter physical retention must choose `.noStore`; source retention permission is never inferred from test fixtures. A changed source identity/revision/cache policy must be supplied by the adapter; a retained cache cannot discover new upstream restrictions without source contact.

Disk objects have hashed flat filenames, versioned bounded headers, full envelope identity/dimensions/deadline checks, PNG magic and SHA-256 checks, and validated palette channels. Reads use bounded `openat`/`O_NOFOLLOW`, regular-file/size/link/permission checks and a retained directory descriptor. Writes use 0700 directories, exclusive 0600 staging files and atomic relative rename. Symlinked cache roots, unexpected directories, oversized files, invalid records and unsafe permissions cannot become images or external paths. Corrupt entries are removed and the approved source may reload; disk failures degrade to memory-only results and increment counters. Removal/clear failures throw `.storageUnavailable` rather than claiming deletion.

Compose one pipeline with one dedicated cache directory. Concurrent independent pipelines must not share a directory or each independently consume the whole app budget. A deliberate background-account authority would require separately allocated budgets/lifecycle integration; foreground facades do not gain background authority by default. Private cache files are access-controlled, **not encrypted**. They are not offline media and provide no G05 entitlement.

`handlePressure(.warning)` revokes outstanding work with `ArtworkError.pressureRevoked` and trims memory to half the configured ceiling; `.critical` clears it. This typed case is distinct from caller `CancellationError` and account `.staleAccount`. A still-visible/current consumer may perform at most one delayed re-request per unchanged demand, checking its own cancellation, owner and latest context before retry/publication. Repeated pressure stops recovery until a new explicit demand. The pipeline does not retry or poll; consumer recovery belongs to the shell. `startPressureMonitoring()` installs an OS dispatch pressure event source; `stopPressureMonitoring()` removes it. Static art has no ongoing frame work or decorative poll.

## Oracles and headless validation

`snapshot()` exposes source attempts, coalesced/cancelled/abandoned waiters, actual active/peak admissions, memory costs/hits/evictions, delivery decode/palette counts and storage failures. `nativeSnapshot()` independently counts actual ImageIO attempts/completions, palette computations, largest encoded input/raster and main-thread violations, including work whose delivery was later discarded. `diskSnapshot()` exposes retained allocated bytes, peak including staging, entries, evictions, corruptions, failures, cumulative startup names encountered, startup-limit failures and off-main violations. `startupEntriesScanned` includes the rejected overflow name (8,193 for the default limit); that entry is rejected before metadata/content processing. Unusable-root preparation and failed open/stat/read operations increment `failures`, not `corruptions`; malformed/unsafe persisted entries increment `corruptions`. A storage read failure preserves an otherwise-valid entry for a later retry. None exposes account/resource names or raw source diagnostics. All filesystem/decode/palette/hash work is actor-isolated off MainActor; only consumer publication belongs on MainActor.

Focused command (never the full package suite, whose PlaybackTests can produce audio):

```sh
swift test --package-path Packages/NativeMusic --scratch-path .build-artwork-w09 --filter 'ArtworkTests|ArtworkDiskTests'
```

Tests synthesize original solid/noise pixels with fixed local seeds and native ImageIO encoders; they fetch no artwork or catalog data. They cover creator/joiner/sole cancellation, peer query contexts, A→B→A highwater, removal across channels, in-flight and actual disk-staging races, native display/orientation/static decode, malformed/oversize input, byte/entry/admission bounds, disk restart/corruption/ownership/expiry/hash/palette/permissions/symlinks, source no-store/retention intersections, native palette reuse and pressure eviction. Real default ceilings are exercised with eighteen 4 MiB raster variants and more than 512 MiB cumulative native PNG disk writes, reconciling disk counters to actual filesystem allocation.

These are bounded implementation/native-resource tests, not full process-footprint, display cadence, energy, reference-Mac performance, UI acceptance or live YouTube evidence. ImageIO temporary allocations, source transport buffering, caller-retained images, Swift metadata and filesystem metadata lie outside the retained raster/file-payload cache counters. The source must stream within its byte contract; an arbitrary injected implementation cannot be forced to cooperate. W44/W45 must measure complete app footprint/energy/soak under real workloads. Shell integration must connect AccountSession authority/removal, request cancellation, pressure/lifecycle hooks and semantic contrast. All G01–G09 remain open; this lane does not mark W09 Done.

## W09 rework-1 regression evidence

The original lane evidence remains immutable. `artifacts/harness/nodes/W09/artwork/rework-1/` archives the exact critic input, a failing pre-fix three-read symlink-root repro, native 0600-positive/0644-negative permission controls, and actual 8,192/8,193 valid-record directory tests using default 4,096-entry retention and 512 MiB disk budgets. These startup tests distinguish retention eviction from the startup work-admission failure; all fixtures have valid native PNGs and envelopes. M10/M12 fault probes must change runtime behaviour and be caught, with green baseline and equivalent-survivor controls. Pressure recovery is an additive typed signal; combined visible-view acceptance remains owned by the shell. Native E1 requires subsequent user-authorized observation and is not waived by these headless checks.
