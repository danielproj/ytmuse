# Native playback, scheduling and DSP backends

## Ownership and supported routes

NativePlayer is the sole engine owner used by PlaybackSession and the shared Domain
command layer. AVPlayer remains primary for routes without an admitted decoded
path. The normal session selects a decoded native graph for compatible gapless
playback even when effects are off. Independent direct-engine clients can retain
the primary off/flat path. Off/flat native scheduling bypasses EQ, TimePitch,
limiting and unity-gain/balance loops. It does not normalize, transcode or resample.

The measured decoded routes are stereo 44.1/48 kHz PCM, AAC in M4A and native Opus
in CAF. Consecutive sources must share the native sample rate/channel format;
incompatible pairs retain ordinary item preparation, rather than secretly converting
them to make a gapless claim. Native source precision is decoded to the Float32
planar buffers required by this graph. This is not a claim of bit-perfect physical
output: the selected system/wireless device can impose other transformations.

NativeAssetSession.DecodedAccess is an explicit trusted-provider capability, not a
new source grant. OwnedMedia grants its licensed bundled files. LocalFirstOwnedAssets
admits retained owned WAVE only after W14's real grant, identity, expiry/time,
integrity and scoped storage checks. NativePlayer keeps its existing file/owned-
encrypted admission rules. HTTP/service/other encryption routes are not enabled by
codec support and remain W34/W36 implementation/evidence obligations. Unsupported
routes return typed errors and capability states; no functional-looking UI was added.

## Durable queue handoff

QueueCommands computes exactly the next occurrence using the real repeat/shuffle/
consumption rules. It persists an optional QueueHandoff intent in the existing
versioned SQLite metadata transaction before native next-item admission. The intent
binds current token, next occurrence, future token, plan UUID and source version.
It contains no URL, key or credential. Cold restoration clears it, creates a fresh
token and stays paused. User edits/transport invalidations cancel native speculation
before a changed queue is committed. Passive position checkpoints preserve the plan.

PlaybackQueueBoundary's preparation hook runs after current engine preparation and
before Play. PlaybackSession validates next eligibility/expiry via the same resolver
and resolves a future PlaybackContext without selecting or consuming that occurrence.
NativePlayer owns the provider session, analysis and bounded decoder. Every awaited
result is fenced by account/item/route/operation/queue-plan ownership. Only one
upcoming preparation/normalization job is admitted; failed speculation is not current
playback failure and is rate-limited rather than retried every render quantum.

AuthorizedPCMInput and IncrementalDecodedPlayer produce one contiguous native stream.
At the first logical sample of the next item (the start of an overlap, if any), the
engine invokes the owner on the control path, never from an audio callback. The queue
atomically saves consumption, the new token/current position and one local listening
transition; then native identity and Domain state adopt that prepared context without
another stop/resolve/prepare/play cycle. Composite snapshots wait on a continuation
while adoption publishes. The durable prepared intent authorizes native scheduling
through the transition while an actual filesystem commit completes. A failed adoption
stops the prepared pipeline; queue state is never published before its commit.

An overlap's logical history transition occurs at fade start, although the old source
continues its authorized audible tail. Its provider session remains live/revocable
until that tail is retired. This is local logical listening history, not an assertion
of source-service play/reporting semantics. W34/W35 still require actual source events.
Normal non-handoff EOF records the final local interval once. Repeat gets a fresh
token/context, even for the same occurrence. Natural EOS cannot also run the ordinary
ended-to-prepare path for a transition already adopted by native scheduling.

## Crossfade and sample timing

Crossfade is 0–12 seconds, default 0. Linear equal-gain envelopes are calculated on
bounded PCM before native scheduling; their weights sum to one for coherent inputs.
Overlap is clamped down to half each remaining item to avoid three simultaneous
voices on short tracks. The 12-second endpoint is measured on 24-second sources.
Zero crossfade is continuous concatenation. Spoken items default to no overlap;
live media and required advertisement/immutable barriers are not prefetched through.
Unavailable, expired or revoked future media cannot silently become current audio.

Native AVAssetReader/container handling already applies edit/packet-table trimming
on measured AAC/M4A and Opus/CAF. The production decoder does not subtract supplied
priming integers again. Actual native encoding and AudioFilePacketTableInfo show
AAC 2,112 priming frames and Opus 312 on the discovery corpus; valid logical counts,
first PTS and independently decoded references determine boundary assertions.
PCM tolerances are fixed at 2e-6 absolute sample error with exact logical counts;
compressed amplitude is compared to a separate AVAudioFile decode, with exact counts
and at most one source-frame timestamp uncertainty. Tolerances were not widened to
fit failures. Native source boundaries, short impulses and multiple transitions are
checked through the real queue/owner, not merely NativeDecodedRenderer.renderPair.

## Processing and resource boundaries

The graph is AVAudioPlayerNode -> ten-band AVAudioUnitEQ -> native TimePitch ->
Apple PeakLimiter -> mixer. EQ centers are 31, 62, 125, 250, 500, 1k, 2k, 4k, 8k and
16k Hz. Positive boosts retain their requested small-signal response: there is no
fixed summed-band attenuation. A bounded feed-forward preamp measures each staged
input window (at most 4,096 frames, after normalization/app gain/balance/mixing),
and predicts its output peak using the maximum magnitude of the octave-peaking
filter cascade. The response is evaluated once on control changes at 2,049
log-spaced frequencies plus the band centers, retaining only its maximum scalar.
If the predicted peak exceeds 0.75 (-2.50 dBFS), the entire stereo window receives
one shared reduction. Quiet windows keep unity preamp. This preserves channel
balance and boost response below the headroom threshold; loud windows can have
block-level amplitude modulation. Frequency-response magnitude is a sinusoidal
estimate, not a proof of an arbitrary waveform's time-domain peak. The downstream
native PeakLimiter remains enabled for positive boosts/normalization to catch
transient overshoot. Cut-only/flat requests without upward normalization bypass
both protections. There is no whole-output or whole-track peak scan, added PCM
storage, custom render callback, or system-volume change. Component and selected
production transport use the same preamp/limiter policy. Manual measurements cover
low-level single/uniform/preset response, loud tones, a square transient and quiet
recovery after loud input. Hardware, perceived modulation and sustained resource
acceptance remain unmeasured.

The native limiter alone reduced sustained over-range boosted tones to near silence
on the installed offline graph; a native dynamics-processor attempt instead left
over-range peaks. Both failed development observations are preserved in the W16
rework-1 DSP evidence. The input-peak preamp prevents sustained overload while the
native limiter handles transient peaks. Independent app gain, mute, fade and channel
balance apply only to app PCM. Control rebuilds retire old baked buffers and clear
filter tails at the current logical sample. When a reset discards an adopted outgoing
fade, its source registration is removed and its provider session disposed exactly
once. Current and still-planned-next sessions remain owned. Each output-permit
callback also carries its source ID, so a callback captured before unregistration
cannot later retract an unrelated current source. Natural tail retirement uses the
same disposal path; a still-needed tail retains its authorization until retired.

Automatic normalization is unweighted whole-track stereo RMS, **not LUFS**: target
-18 dBFS RMS, at most +24 dB boost, no boosting below -80 dBFS RMS. A cancellation-aware,
constant-memory analysis decoder scans the authorized source before normalized output
starts and caches only a scalar within that preparation. It adds a decode-pass startup
cost, not a track-sized memory buffer or pumping adaptive gain. A process-wide lane
admits one analysis decoder and at most 16 cancellation-aware waiting requests. Reader
cancellation and repeated provider checks prevent a cancelled/expired analysis from
publishing or continuing as a new owner's permission.

Current+next share one 32,768-frame native scheduling window, at most two native
pending source blocks of 16,384 frames, bounded 4,096-frame conversion/mixing slices
and a 1,024-frame manual output. Including conservative analysis native/copy blocks,
the declared application-managed PCM ceiling is 925,696 bytes. Retained scheduled+
pending source frames are at most 65,536. W14 separately bounds decoder byte delivery
to authenticated 64 KiB chunks under its existing protected lease. Metadata, native
framework-private allocation, object/allocator overhead, ciphertext work and physical
footprint are additional and unmeasured; this is not a process-memory budget pass.

No application audio render/completion callback performs disk/network work, locks,
actor waits or allocation. Control-plane refill/retirement is polled at 10 ms while
playing, or driven by native offline rendering in tests. Paused/ended decoded output
stops its pump, and EOF pauses the graph. Startup/refill I/O or physical underrun
latency still requires reference-device/source measurements; no acoustic result is
inferred from offline rendering. The old opt-in W06 RenderProbe is test instrumentation,
not the production decoded callback.

## Encrypted authorization and cancellation

LocalFirstOwnedAssets revalidates play authority on decoded admission/refill, separate
from actual user seeking. Play-only grants decode normally but user seek remains
forbidden. Session invalidation synchronously retracts native scheduled output through
a control-plane permit; no render-thread lock or actor hop is added. Revocation cannot
race a later native start/schedule past the permit. Resource-loader store work drains
before erasure; held observation callbacks without leases remain cancelled and must
pass cancellation checks before any future store access. No key/plaintext file export,
ignore-rights API or Playback-to-Downloads dependency was introduced.

Pause, seek/scrub, manual Next, shuffle/removal/replacement, route loss, account teardown
and Quit invalidate speculation. Quit reserves Domain's new generation and stops native
output before durable checkpoint waits, so late preparation cannot start after Quit.
Source callbacks, reader/permission completions and queued observations retain their
scope/render-generation fences. Route tests inject lifecycle events only; they do not
change the physical or global output.

## Evidence and limits

Use scripts/test.sh --suite T16 for complete **local owned-native** cases, with real
manual rendering enabled before graph start. New transport Play tests have no hardware
output. Existing T06 hardware-capable checks retain their <=0.001 admission. T06's
legacy classes are dispatched separately from T16 to avoid inflating repeated totals.
Tests/AudioEffects/measure.sh runs the same local audio cases; W16_CORPUS_OUTPUT can
retain generated owned source/encoded files in a unique evidence directory.

Stage 0 and B remain preserved at commits 4bbee60 and 6cca72d and their original
artifacts. Stage C records successful and failed development/validation attempts,
actual source/helper/product/log hashes, codec provenance and independent oracles.
No physical route/acoustics, live Music/ad/quality/offline source grant, full resource
budget, soak, human review, notarization or distribution acceptance is claimed.
W06/W14 later-source obligations remain explicit. All G01–G09 remain open.
