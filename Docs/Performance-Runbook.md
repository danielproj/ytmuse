# Performance runbook — the official W44 measurements (operator, end of project)

Status: prepared by W44-prep and kept as a reference. The account holder decided not to run the official Release measurement (W44) or the soak (W45), so no official run is planned; nothing in this file has been run as an official measurement. The numbers W44-prep produced are **indicative** (optimized Debug build, isolated stores, synthetic data) and are never W44 results; they are listed in `artifacts/harness/nodes/W44-prep/report.md`.

Spec sources: `Docs/Product-Specification.md` §20 (budgets, PERF01–PERF10), W44 brief `artifacts/harness/briefs/W44.md` (T44.1–T44.6).

## 1. Why the operator runs this, and why not in a lane

The official run needs a **Release** build. A Release `YTMuse.app` has no isolation layer: it always opens the account holder's real stores — the YouTube Music account database and window state under Application Support, the Keychain items under the service name `local.native-music.development.sessions`, the owned-audio and offline stores, the WebKit data stores and the app preferences (`Docs/Harness-Brief.md`, "Release builds"). Lanes and critics never build or launch it. Only the operator does, and only in one of the safe set-ups below.

## 2. Making the Release run safe (pick one; both need the account holder's consent)

**A. A dedicated, fresh macOS user account (recommended).** A second local user (standard user, no iCloud, no shared folders, FileVault as usual) has its own home folder, its own login Keychain and its own Application Support, preferences and WebKit stores. The Release build run there cannot see the account holder's data. Steps:
1. The account holder creates the user (System Settings → Users & Groups) and agrees to the measurement window; the account is deleted afterwards (Delete the user, "Delete the home folder").
2. Build Release once as the operator (`scripts/build.sh`, signed) in the operator's own session; copy the `.app` to a shared location readable by the new user (for example `/Users/Shared/ytmuse-perf/`), and **do not launch it** from the operator's session.
3. Fast-user-switch to the new account. Sign in to a *test* YouTube Music account there (the measurement account, never the account holder's personal one, per §3 below).
4. Run every measurement in that session. Copy only the raw result files out (see §6), then delete the account.

**B. A disposable app identity in the same account — not available today.** A different bundle identifier alone is *not* enough: the Keychain service name is a constant (`KeychainVault.applicationNamespace`), so a second identity would read and write the same login-Keychain namespace, and Application Support is derived from the same defaults. This option needs code (a bundle-identifier-derived namespace and data root for a "Performance" configuration) that has not been written. Do not use it until it has been written, reviewed and proven by a snapshot diff.

**The synthetic dataset is Debug-only.** `DevelopmentPerformance` (PERF04: 50,000 library songs, 1,000 playlists, a 10,000-entry playlist, a 5,000-item queue, six artwork source sizes) exists only in Debug builds and only on an isolated launch. T44.3 requires the standard dataset in the official run as well. The operator therefore has to decide, before W44, between:
- a **Performance build configuration** (Release optimization, the compile condition `PERFORMANCE_FIXTURES` that includes the dataset seam, a distinct bundle identifier and forced isolated storage, built *only* for the dedicated account) — recommended for the PERF04 scale rows; and
- the plain **Release** build against the real test account's corpus for the cold-launch, item-start, CPU and memory rows.
Both builds are measured; the report says which row came from which build. This runbook does not choose for the operator; W44-prep only prepared the seam in Debug.

## 3. Test account and corpus

Use a YouTube Music account dedicated to measurement, with a representative library (large enough to page; the PERF04 stress rows come from the synthetic dataset, not from the account). Premium and non-Premium results are labelled separately. Never use the account holder's personal playlists or listening history.

## 4. Conditions to record and to vary (T44.4, PERF09)

Record in the environment manifest for every run: macOS build, Xcode/Swift versions, hardware model and RAM, display mode and refresh rate, power source (AC or battery), Low Power Mode, thermal state, build identifier and commit, adapter/source/route, account type, network (link rate and median RTT), time and date. `scripts/perf-run.sh` writes `environment.json` with the items it can read (power source, Low Power Mode, thermal text, versions, cores, memory); the operator adds the display refresh rate, route and network figures by hand.

Matrix to cover (untested cells are marked **missing** in the report, never omitted):

| Axis | Values |
|---|---|
| Power | AC, battery |
| Power mode | normal, Low Power Mode |
| Display | 60 Hz, ProMotion |
| Output | local speakers, wireless route (AirPlay / Bluetooth) |
| Network (T44.5) | primary: ≥ 50 Mbps, median RTT ≤ 40 ms, zero injected loss; constrained and offline measured separately |
| Scenario | audio, video, casting, bulk download (separate; an audio budget is never claimed from an unrelated empty screen — PERF03) |

Counting rules: browser sign-in time, source advertising duration and network outages are **not** local render time, but they are reported as end-to-end wait next to the component timing (T44.5). Failed operations are reported on their own line and never dropped from the denominator (PERF01).

## 5. Budgets (T44.2, spec §20 — adopted targets, never revised in a run)

| Metric | Target |
|---|---|
| Cold process launch to interactive cached shell | p95 ≤ 1,000 ms; no network dependency |
| Warm reopen of main window | p95 ≤ 250 ms |
| Cached navigation | p95 ≤ 100 ms |
| User action to visible transport feedback | p95 ≤ 50 ms |
| Play command to first decoded audible sample | p95 ≤ 2,000 ms under the primary audio conditions |
| Cached offline item start | p95 ≤ 250 ms |
| Local library query | p95 ≤ 50 ms on 50,000 indexed items |
| Scroll and transition cadence | fewer than 1% missed display intervals in the standard interaction trace (actual 60/120 Hz) |
| Long visible hitch | no attributable main-thread stall over 100 ms in the standard trace |
| Hidden audio-only app CPU | mean ≤ 2% of one logical core over 10 minutes after warm-up |
| Paused hidden CPU | mean ≤ 0.2% of one logical core, excluding an explicit task |
| Hidden steady audio memory | physical footprint ≤ 200 MiB |
| Visible normal browsing memory | physical footprint ≤ 350 MiB for the standard fixture |
| Eight-hour audio soak | no crash, unexpected stop or unbounded memory/resource growth |
| Post-warm-up memory trend | ≤ 20 MiB sustained growth over the soak, after cache stabilization and comparable state |
| Decorative background rendering | zero ongoing decorative animation while all windows are hidden |

Sample counts (PERF01, T44.1): at least **50 cold launches**, at least **200 item starts** over a representative corpus, and repeated scripted scroll and navigation traces; report p50, p95 and worst for each, and the failed operations separately. A miss needs a fix and a rerun, or an explicit operator/user contract change — never a threshold edited in a run (T44.6, PERF10).

## 6. What to run, and how

All commands run in the dedicated account's session, from a checkout of the commit under test, with `scripts/bin` first on `PATH`. Before any heavy step: memory pressure level 1 and at least 25% free (`sysctl -n kern.memorystatus_vm_pressure_level`, `memory_pressure`).

1. **Signposts.** The app emits `os_signpost` intervals in subsystem `local.native-music.performance`, category `interval`, with the names `launch`, `firstItemStart`, `navigation`, `listPage`, `artworkDecode`, `libraryQuery` (plus the point event `mainStall` when the stall monitor runs). The labels are fixed destination or engine names, never titles or ids. They are present in Release builds; the JSON-lines copy (`performance-intervals.jsonl`) that `perf-report.py` reads is Debug-isolated only, so for Release record with Instruments:
   `xcrun xctrace record --template 'App Launch' --output launch-N.trace --launch -- /path/to/YTMuse.app` (50 repetitions for the launch row), and `--template 'SwiftUI'`, `'Animation Hitches'`, `'Time Profiler'`, `'Allocations'`, `'Leaks'`, `'Power Profiler'` for the scripted traces. Export the signpost table with `xcrun xctrace export --input X.trace --toc` and choose the signpost schema from the table of contents. Keep every `.trace` (not in git; pin by hash) next to the raw exports.
2. **Scripted interaction.** The native UI performance tests (`testW44P…` in `Tests/NativeMusicUITests/NativeMusicUITests.swift`) drive launch, navigation, library scroll, playlists and the queue with `XCTApplicationLaunchMetric`, `XCTOSSignpostMetric`, `XCTHitchMetric`, `XCTClockMetric`, `XCTCPUMetric` and `XCTMemoryMetric`. In the dedicated account they run against the performance build (not the plain Release, which has no dataset): `YTMUSE_PERF_LAUNCHES=50 YTMUSE_PERF_ITERATIONS=10 scripts/perf-run.sh ui` — or the same `xcodebuild test` invocation with the Performance configuration. Results are `.xcresult` bundles (gitignored; they can contain desktop screenshots).
3. **CPU and footprint, all processes.** `scripts/perf-sample.py --app-path-prefix <path of the app bundle>/ --out process-samples.jsonl --stop-file <file>` samples every 2 s: CPU is the sum over the app and every descendant process (100% = one fully used logical core, PERF02) and the physical footprint (`footprint`, PERF03) is summed likewise. XPC helpers launched through `launchd` (WebKit content/network processes of the hidden player, the widget extension) are *not* descendants: add them by hand to the sample set for hidden-audio and extension rows (`footprint -p <pid>` and `top -pid`), and record their names. Run the hidden-audio rows for 10 minutes after a warm-up, the paused-hidden row likewise, and the soak for 8 hours with the samples kept at 60 s.
4. **System audio and network activity** (PERF02): record `nettop -P -J bytes_in,bytes_out -L 1` for the app's PID during the audio rows and the route/engine in use, so route differences are visible instead of hidden outside the app number.
5. **Report.** `python3 scripts/perf-report.py --dir <run dir> --out report.md --json result.json` gives p50/p95/worst with the failed operations, the main-thread stall counts and the CPU/footprint summary. The operator adds the Instruments findings and the web-experience comparison (matched content, route and quality; observed ratios only, no claim of automatic superiority — PERF05).
6. **Evidence.** Raw samples, environment manifests, traces (hashes), the budget/mode matrix with missing cells marked, and failed-operation counts go to `artifacts/harness/performance/`; the node report to `artifacts/harness/nodes/W44/`.

## 7. Known characteristics from the indicative run (read before interpreting official numbers)

See `artifacts/harness/nodes/W44-prep/report.md` for the figures. In short: the library, playlist and queue models were measured at the PERF04 scale on an optimized Debug build, and the bottlenecks found there (quadratic paging, per-update re-sorting and re-searching of 50,000 rows) were fixed; rows still to be judged on Release are the SwiftUI rendering rows (scroll cadence at 50,000 rows, the 10,000-entry playlist page and the 5,000-item queue) because only the Release trace shows the true frame cost.
