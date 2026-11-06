#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
# Operator rule (2026-10-31): every swift build/test and xcodebuild below goes through scripts/bin, which caps compiler
# parallelism (YTMUSE_BUILD_JOBS, default 6). Uncapped builds from several lanes ran the Mac out of memory.
export PATH="$PWD/scripts/bin:$PATH"
# C1 rework 1: a test process never inherits the real-stores opt-in (it would be passed to every test process
# and UI app launch); the launch-argument form is refused outright.
unset YTMUSE_USE_REAL_STORES
for argument in "$@"; do [[ $argument != -YTMuseUseRealStores ]] || { echo 'refusing -YTMuseUseRealStores: tests never use the real stores' >&2; exit 64; }; done
if [[ $# != 2 || "$1" != --suite || ( "$2" != T01 && "$2" != T02 && "$2" != T03 && "$2" != T04 && "$2" != T05 && "$2" != T06 && "$2" != T07 && "$2" != T08 && "$2" != T09 && "$2" != T10 && "$2" != T11 && "$2" != T12 && "$2" != T13 && "$2" != T20 && "$2" != T50 && "$2" != T51 && "$2" != T52 && "$2" != T53 && "$2" != T44P && "$2" != T21 && "$2" != T22 && "$2" != T23 && "$2" != T24 && "$2" != T25 && "$2" != T26 && "$2" != T27 && "$2" != T28 && "$2" != T29 && "$2" != T30 && "$2" != T39 && "$2" != T14 && "$2" != T15 && "$2" != T16 && "$2" != T17 && "$2" != T18 ) ]]; then
  echo 'Usage: scripts/test.sh --suite T01|T02|T03|T04|T05|T06|T07|T08|T09|T10|T11|T12|T13|T14|T15|T16|T17|T18|T20|T21|T22|T23|T24|T25|T26|T27|T28|T29|T30|T39|T50|T51|T52|T53|T44P (other suites are not implemented)' >&2
  exit 64
fi
./scripts/check-toolchain.sh
python3 scripts/check-boundaries.py --self-test
python3 scripts/check-boundaries.py
python3 scripts/check-test-preferences.py --self-test
python3 scripts/check-test-preferences.py
python3 scripts/check-accessibility-containers.py --self-test
python3 scripts/check-accessibility-containers.py
python3 scripts/count-tests.py --self-test > /dev/null || { echo 'test-count self-check failed (scripts/count-tests.py --self-test)' >&2; exit 1; }
# C1 item 12: `swift test` has been seen to exit 0 after running only part of a suite. Every suite below runs
# through these helpers, which compare the discovered tests with the executed ones (XCTest per id, Swift
# Testing by count; skips are reported) and fail when fewer ran than were discovered.
SUITE_ID="${2:-}"   # for messages from helpers, whose own positional parameters are not the script's
counted_swift_test() {   # counted_swift_test <filter regex or ''> [swift test options before the subcommand...]
  local filter=$1; shift
  local list log status
  list=$(mktemp); log=$(mktemp); local prefs_before; prefs_before=$(mktemp)
  # Operator rule (2026-11-01): no suite may leave a key in the test runner's preferences; key names only are compared (scripts/check-test-preferences.py).
  python3 scripts/check-test-preferences.py snapshot "$prefs_before" > /dev/null
  swift test --package-path Packages/NativeMusic "$@" list > "$list"
  set +e
  if [[ -n "$filter" ]]; then swift test --package-path Packages/NativeMusic "$@" --filter "$filter" 2>&1 | tee "$log"
  else swift test --package-path Packages/NativeMusic "$@" 2>&1 | tee "$log"; fi
  status=${PIPESTATUS[0]}
  set -e
  python3 scripts/check-test-preferences.py compare "$prefs_before" >> "$log" 2>&1 || { echo 'PREFERENCES GUARD: this test run left a key in the test runner preferences (see scripts/check-test-preferences.py)' >&2; python3 scripts/check-test-preferences.py compare "$prefs_before" >&2 || true; status=1; }
  rm -f "$prefs_before"
  # TH1 (AB1): no test run may reach the account holder's Contacts store. A run whose output shows the AddressBook store or contactsd fails, whatever
  # else it printed (see counted_whole_package for the one way a run used to do it without any test touching Contacts).
  if grep -qE 'AddressBook-v[0-9]+\.abcddb|com\.apple\.contactsd' "$log"; then
    echo 'CONTACTS GUARD: this test run reached the Contacts store (AddressBook / contactsd in its output); see artifacts/harness/nodes/TH1/report.md (Rework 1)' >&2
    status=1
  fi
  if [[ $status == 0 ]]; then python3 scripts/count-tests.py check --list "$list" --filter "$filter" --log "$log" || status=1; fi
  rm -f "$list" "$log"
  return $status
}
# TH1 (AB1): the whole package, with every test counted, WITHOUT letting XCTest enumerate every class in the process. Cause (found with lldb, not by
# reading the Contacts store): given XCTest names from more than one test bundle in a single run (an unfiltered `swift test`, or a filter that selects
# XCTest tests of two modules), `xctest` resolves them through `+[XCTestCase allSubclasses]` -> `objc_copyClassList` -> `realizeAllClasses()`, which
# initialises every Objective-C class of every loaded image, including ContactsUICore's (loaded through QuickLookUI -> ScreenTimeUI -> ContactsUI), and
# that class's `+[CNContactStore initialize]` connects to contactsd for the AddressBook store. No test calls Contacts. So each module that has XCTest
# tests runs by itself, and the modules that have only Swift Testing tests run together in one more invocation: the same tests, counted the same way.
counted_whole_package() {
  local list modules xcmodules rest m
  list=$(swift test --package-path Packages/NativeMusic list)
  modules=$(sed -nE 's/^([A-Za-z0-9_]+)\..*/\1/p' <<<"$list" | sort -u)
  xcmodules=$(grep -E '^[A-Za-z0-9_]+\.[^/]+/[^()]+$' <<<"$list" | sed -E 's/\..*//' | sort -u)
  [[ -n $modules ]] || { echo 'whole-package discovery found no module' >&2; return 1; }
  rest=$modules
  for m in $xcmodules; do
    counted_swift_test "^$m\\." || return 1
    rest=$(grep -vx "$m" <<<"$rest" || true)
  done
  if [[ -n $rest ]]; then counted_swift_test "^($(paste -sd'|' - <<<"$rest"))\\." || return 1; fi
}
counted_ui_test() {      # counted_ui_test (<expected test names...> | --all-in <swift file>) -- <command...>
  local names=() all_in="" log status
  if [[ $1 == --all-in ]]; then all_in=$2; shift 2; fi
  while [[ $1 != -- ]]; do names+=("$1"); shift; done; shift
  # Operator rule (Docs/Harness-Brief.md): UI runs never start from outside ~/Projects (a runner built under /tmp
  # can launch the app with its environment dropped, i.e. not isolated) and always hold the cross-lane UI lock.
  [[ "$PWD" == "$HOME/Projects/"* ]] || { echo "refusing UI tests outside ~/Projects ($PWD)" >&2; return 64; }
  # W25: no worktree build embeds the widget extension (the embed phase defaults to NO); the setting is exported anyway so that a stray YES in the environment cannot reach a UI build.
  export YTMUSE_EMBED_WIDGET=NO
  # Operator rule (2026-11-01): build the UI test bundle BEFORE the idle and console gates (a build launches nothing), then
  # run the already-built tests after them. Building took ~6 min after the gate opened, and the account holder often
  # returned in that window, so most UI runs ended "blocked". YTMUSE_UI_PREBUILD=0 restores build-and-test in one step.
  local -a ui_cmd=("$@") ui_pre=() ui_run=(); local ui_i ui_x=-1 ui_t=-1 ui_skip=0
  for ui_i in "${!ui_cmd[@]}"; do
    [[ $ui_x -lt 0 && ${ui_cmd[$ui_i]} == xcodebuild ]] && ui_x=$ui_i
    [[ $ui_x -ge 0 && ${ui_cmd[$ui_i]} == test ]] && ui_t=$ui_i
  done
  if [[ ${YTMUSE_UI_PREBUILD:-1} == 1 && $ui_x -ge 0 && $ui_t -gt $ui_x ]]; then
    for ui_i in "${!ui_cmd[@]}"; do
      [[ $ui_i -lt $ui_x ]] && continue
      if [[ $ui_skip == 1 ]]; then ui_skip=0; continue; fi
      [[ ${ui_cmd[$ui_i]} == -resultBundlePath ]] && { ui_skip=1; continue; }
      if [[ $ui_i == "$ui_t" ]]; then ui_pre+=(build-for-testing); else ui_pre+=("${ui_cmd[$ui_i]}"); fi
    done
    ui_run=("${ui_cmd[@]}"); ui_run[$ui_t]=test-without-building
    echo "${SUITE_ID:-suite} UI prebuild: ${ui_pre[*]:0:1} … build-for-testing"
    "${ui_pre[@]}" > "${TMPDIR:-/tmp}/ytmuse-ui-prebuild.$$.log" 2>&1 || { tail -40 "${TMPDIR:-/tmp}/ytmuse-ui-prebuild.$$.log" >&2; rm -f "${TMPDIR:-/tmp}/ytmuse-ui-prebuild.$$.log"; echo "${SUITE_ID:-suite} UI prebuild failed" >&2; return 65; }
    rm -f "${TMPDIR:-/tmp}/ytmuse-ui-prebuild.$$.log"
    set -- "${ui_run[@]}"
  fi
  # Every UI part checks the console first. A locked screen cannot activate the application, which would otherwise surface as a test
  # failure ("Failed to activate application"); this reports the environment instead, with a status (75) distinct from a test failure.
  if ioreg -n Root -d1 | python3 -c 'import sys; sys.exit(0 if chr(34)+"CGSSessionScreenIsLocked"+chr(34)+"=Yes" in sys.stdin.read() else 1)'; then
    echo "${SUITE_ID:-suite} UI ENVIRONMENT BLOCKED: console locked" >&2
    return 75
  fi
  # Operator rule: never take over the account holder's mouse/keyboard while they are using the Mac.
  # UI runs start only after YTMUSE_UI_MIN_IDLE_SECONDS (default 300, lowered from 600 on 2026-11-01 for pace) of no human input; otherwise report blocked (75).
  local idle min=${YTMUSE_UI_MIN_IDLE_SECONDS:-300}
  idle=$(ioreg -c IOHIDSystem | awk '/HIDIdleTime/ && !seen {v=int($NF/1000000000); seen=1} END {print v}')   # read all input: an early awk exit SIGPIPEs ioreg under pipefail (exit 141)
  if [[ -n "$idle" && "$idle" -lt "$min" ]]; then
    echo "${SUITE_ID:-suite} UI ENVIRONMENT BLOCKED: account holder active (idle ${idle}s < ${min}s)" >&2
    return 75
  fi
  # Operator rule: a system dialog or notification banner over the test window turns clicks under it into false failures
  # ("Falling back to element center point"). Check right before the suite starts, inside the lock (the queue can be long),
  # and report blocked (75). Only positions are read; nothing is touched. After a failed run, note any such window.
  set -- bash -c 'python3 scripts/ui-preflight.py && exec "$@"' ui-preflight "$@"
  if [[ "${YTMUSE_UI_LOCK_HELD:-}" != 1 ]]; then set -- ./scripts/ui-run-lock.sh "$@"; fi
  log=$(mktemp)
  set +e; "$@" 2>&1 | tee "$log"; status=${PIPESTATUS[0]}; set -e
  if [[ $status != 0 && $status != 75 ]]; then python3 scripts/ui-preflight.py --after-failure || true; fi
  if [[ $status == 0 ]]; then
    if [[ -n $all_in ]]; then python3 scripts/count-tests.py ui --expect-file "$all_in" --log "$log" || status=1
    else python3 scripts/count-tests.py ui --expect "${names[@]}" --log "$log" || status=1; fi
  fi
  rm -f "$log"
  return $status
}
# W17 rework (F6): the production-store guard (runtime refusal rule, source sweep over every test target, and the guard's own rules) runs in the
# preamble of EVERY suite, through the counted helper like everything else, so no lane can skip it and a filter that selects nothing fails.
counted_swift_test 'ProductionStoreGuardTests|ProductionStoreGuardRuleTests'
echo 'production-store guard: ok'
if [[ "$2" == T08 ]]; then
  swift Tests/ServiceAccess/ValidateDossier.swift
  exit 0
fi
if [[ "$2" == T17 ]]; then
  # W17: native video, live playback and audio/video continuity. Representation mapping, live window, decoder and surface ownership,
  # the native AVKit decoder measurement, the fresh-process WebKit video/live probe and (below) the isolated native UI part.
  # The hidden-player regression classes (WebMusic*) run with it, since W17 extends that code.
  discovery=$(swift test --package-path Packages/NativeMusic list)
  for required in RepresentationTransitionTests WebMusicLiveTransportTests WebMusicSurfaceTests VideoSurfaceOwnershipTests NativeVideoTests OwnedVideoSessionTests VideoProbeProcessTests VideoAuthorityTests; do
    [[ "$discovery" == *"$required"* ]] || { echo "T17 missing active class: $required" >&2; exit 1; }
  done
  counted_swift_test 'VideoTests|WebMusic|W09ConvergedTransportTests|CallbackIsolationTests'
  if [[ "${T17_HEADLESS:-0}" == 1 ]]; then
    echo 'T17 headless only; native UI explicitly not run'
    exit 0
  fi
  if ioreg -n Root -d1 | python3 -c 'import sys; sys.exit(0 if chr(34)+"CGSSessionScreenIsLocked"+chr(34)+"=Yes" in sys.stdin.read() else 1)'; then
    echo 'T17 UI ENVIRONMENT BLOCKED: console locked' >&2
    exit 75
  fi
  args=(-project App/NativeMusic.xcodeproj -scheme NativeMusic -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath "${BUILD_DIR:-$PWD/.build/xcode}" -disableAutomaticPackageResolution -only-testing:NativeMusicUITests/NativeMusicUITests/testW17OwnedNativeVideoDecoderAndSingleSurfaceOwner test)
  if [[ -n "${TEST_RESULT_PATH:-}" ]]; then args+=(-resultBundlePath "$TEST_RESULT_PATH"); fi
  counted_ui_test testW17OwnedNativeVideoDecoderAndSingleSurfaceOwner -- xcodebuild "${args[@]}"
  exit 0
fi
if [[ "$2" == T16 ]]; then
  discovery=$(swift test --package-path Packages/NativeMusic list)
  for required in AudioEffectsTests DecodedTransportTests CodecBoundaryTests QueueNativeHandoffTests RetainedDSPTests DSPReworkTests QueueIntervalReworkTests QueueAdoptionReworkTests StagedResetReworkTests HandoffPersistenceFaultTests; do
    [[ "$discovery" == *"$required"* ]] || { echo "T16 missing active class: $required" >&2; exit 1; }
  done
  counted_swift_test 'AudioEffectsTests|DecodedTransportTests|CodecBoundaryTests|QueueNativeHandoffTests|RetainedDSPTests|DSPReworkTests|QueueIntervalReworkTests|QueueAdoptionReworkTests|StagedResetReworkTests|HandoffPersistenceFaultTests'
  echo 'T16 complete LOCAL owned-native cases only; live/source/physical/resource/release gates remain open'
  exit 0
fi
if [[ "$2" == T09 ]]; then
  discovery=$(swift test --package-path Packages/NativeMusic list)
  [[ "$discovery" == *NavigationTests.* && "$discovery" == *ArtworkTests.* ]] || { echo 'T09 discovery is incomplete' >&2; exit 1; }
  counted_swift_test 'NavigationTests|ArtworkConsumerTests|ArtworkTests|ArtworkDiskTests|DesignSystemTests'
  if [[ "${T09_HEADLESS:-0}" == 1 ]]; then
    echo 'T09 headless only; native UI explicitly not run'
    exit 0
  fi
  if ioreg -n Root -d1 | python3 -c 'import sys; sys.exit(0 if chr(34)+"CGSSessionScreenIsLocked"+chr(34)+"=Yes" in sys.stdin.read() else 1)'; then
    echo 'T09 UI ENVIRONMENT BLOCKED: console locked' >&2
    exit 75
  fi
  args=(-project App/NativeMusic.xcodeproj -scheme NativeMusic -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath "${BUILD_DIR:-$PWD/.build/xcode}" -disableAutomaticPackageResolution -only-testing:NativeMusicUITests/NativeMusicUITests/testW09NavigationAndAdaptiveShell -only-testing:NativeMusicUITests/NativeMusicUITests/testW09ExpandedVariantAndIndependentWindowTint -only-testing:NativeMusicUITests/NativeMusicUITests/testW09ScrollSelectionQueryFilterHistoryAndKeyboard -only-testing:NativeMusicUITests/NativeMusicUITests/testW09QueuePageContextActionsKeepGlobalOccurrenceOrder -only-testing:NativeMusicUITests/NativeMusicUITests/testW09AdaptivePanelResizeKeepsLyricsSelection -only-testing:NativeMusicUITests/NativeMusicUITests/testW09LaunchSizesDefaultMinimumAndClamp -only-testing:NativeMusicUITests/NativeMusicUITests/testW09NativeEdgeResizeGestureManualOnly -only-testing:NativeMusicUITests/NativeMusicUITests/testW09UnavailableWindowStateRequiresExplicitConfirmedReset -only-testing:NativeMusicUITests/NativeMusicUITests/testW06OwnedNativeBottomTransport -only-testing:NativeMusicUITests/NativeMusicUITests/testPlayer1FloatingCapsule -only-testing:NativeMusicUITests/NativeMusicUITests/testPlayer1CapsuleInLightMode test)
  if [[ -n "${TEST_RESULT_PATH:-}" ]]; then args+=(-resultBundlePath "$TEST_RESULT_PATH"); fi
  counted_ui_test testW09NavigationAndAdaptiveShell testW09ExpandedVariantAndIndependentWindowTint testW09ScrollSelectionQueryFilterHistoryAndKeyboard testW09QueuePageContextActionsKeepGlobalOccurrenceOrder testW09AdaptivePanelResizeKeepsLyricsSelection testW09LaunchSizesDefaultMinimumAndClamp testW09NativeEdgeResizeGestureManualOnly testW09UnavailableWindowStateRequiresExplicitConfirmedReset testW06OwnedNativeBottomTransport testPlayer1FloatingCapsule testPlayer1CapsuleInLightMode -- xcodebuild "${args[@]}"
  exit 0
fi
if [[ "$2" == T10 ]]; then
  discovery=$(swift test --package-path Packages/NativeMusic list)
  [[ "$discovery" == *SearchTests.* && "$discovery" == *SearchPlayRoutingTests* ]] || { echo 'T10 discovery is incomplete' >&2; exit 1; }
  counted_swift_test 'SearchTests|SearchPlayRoutingTests|MusicWebSessionTests|ConnectionTests'
  if [[ "${T10_HEADLESS:-0}" == 1 ]]; then
    echo 'T10 headless only; native UI explicitly not run'
    exit 0
  fi
  if ioreg -n Root -d1 | python3 -c 'import sys; sys.exit(0 if chr(34)+"CGSSessionScreenIsLocked"+chr(34)+"=Yes" in sys.stdin.read() else 1)'; then
    echo 'T10 UI ENVIRONMENT BLOCKED: console locked' >&2
    exit 75
  fi
  # Typed text needs an ASCII-capable input source (restored afterwards); every launch is isolated.
  args=(-project App/NativeMusic.xcodeproj -scheme NativeMusic -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath "${BUILD_DIR:-$PWD/.build/xcode}" -disableAutomaticPackageResolution -only-testing:NativeMusicUITests/NativeMusicUITests/testW10SearchFieldGroupsKeyboardAndItemErrors -only-testing:NativeMusicUITests/NativeMusicUITests/testW10CorrectionScopesAndCommandPalette -only-testing:NativeMusicUITests/NativeMusicUITests/testW10RecentSearchesRecentItemsAndHonestDiscoveryNote -only-testing:NativeMusicUITests/NativeMusicUITests/testW09F2SearchRestoresQueryScopeSelectionAndResultsPositionAcrossTwoVisits test)
  if [[ -n "${TEST_RESULT_PATH:-}" ]]; then args+=(-resultBundlePath "$TEST_RESULT_PATH"); fi
  counted_ui_test testW10SearchFieldGroupsKeyboardAndItemErrors testW10CorrectionScopesAndCommandPalette testW10RecentSearchesRecentItemsAndHonestDiscoveryNote testW09F2SearchRestoresQueryScopeSelectionAndResultsPositionAcrossTwoVisits -- python3 scripts/test-native-latin.py xcodebuild "${args[@]}"
  exit 0
fi
if [[ "$2" == T11 ]]; then
  discovery=$(swift test --package-path Packages/NativeMusic list)
  [[ "$discovery" == *CatalogTests.* ]] || { echo 'T11 discovery is incomplete' >&2; exit 1; }
  counted_swift_test 'CatalogTests|MusicWebSessionTests|SearchTests'
  if [[ "${T11_HEADLESS:-0}" == 1 ]]; then
    echo 'T11 headless only; native UI explicitly not run'
    exit 0
  fi
  if ioreg -n Root -d1 | python3 -c 'import sys; sys.exit(0 if chr(34)+"CGSSessionScreenIsLocked"+chr(34)+"=Yes" in sys.stdin.read() else 1)'; then
    echo 'T11 UI ENVIRONMENT BLOCKED: console locked' >&2
    exit 75
  fi
  # Typed text needs an ASCII-capable input source (restored afterwards); every launch is isolated.
  args=(-project App/NativeMusic.xcodeproj -scheme NativeMusic -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath "${BUILD_DIR:-$PWD/.build/xcode}" -disableAutomaticPackageResolution -only-testing:NativeMusicUITests/NativeMusicUITests/testW11HomeShelvesChipsActionsAndRefresh -only-testing:NativeMusicUITests/NativeMusicUITests/testW11ExploreChartsAndMoods -only-testing:NativeMusicUITests/NativeMusicUITests/testW11AlbumArtistSongPlaylistDetailsAndPagination -only-testing:NativeMusicUITests/NativeMusicUITests/testW09F2CatalogPagesRestoreTheirShelfAndTheRowWithinAListShelf test)
  if [[ -n "${TEST_RESULT_PATH:-}" ]]; then args+=(-resultBundlePath "$TEST_RESULT_PATH"); fi
  counted_ui_test testW11HomeShelvesChipsActionsAndRefresh testW11ExploreChartsAndMoods testW11AlbumArtistSongPlaylistDetailsAndPagination testW09F2CatalogPagesRestoreTheirShelfAndTheRowWithinAListShelf -- python3 scripts/test-native-latin.py xcodebuild "${args[@]}"
  exit 0
fi
if [[ "$2" == T12 ]]; then
  discovery=$(swift test --package-path Packages/NativeMusic list)
  [[ "$discovery" == *LibraryTests.* ]] || { echo 'T12 discovery is incomplete' >&2; exit 1; }
  # Library and history (T12.1-T12.4), the live-transport guard, and the older suites the W12 changes touch (catalog, session coordinator, signed transport).
  counted_swift_test 'LibraryTests|MusicWebSessionTests|CatalogTests|ConnectionTests'
  if [[ "${T12_HEADLESS:-0}" == 1 ]]; then
    echo 'T12 headless only; native UI explicitly not run'
    exit 0
  fi
  if ioreg -n Root -d1 | python3 -c 'import sys; sys.exit(0 if chr(34)+"CGSSessionScreenIsLocked"+chr(34)+"=Yes" in sys.stdin.read() else 1)'; then
    echo 'T12 UI ENVIRONMENT BLOCKED: console locked' >&2
    exit 75
  fi
  # Typed text needs an ASCII-capable input source (restored afterwards); every launch is isolated and uses labelled development data only.
  args=(-project App/NativeMusic.xcodeproj -scheme NativeMusic -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath "${BUILD_DIR:-$PWD/.build/xcode}" -disableAutomaticPackageResolution -only-testing:NativeMusicUITests/NativeMusicUITests/testW12ProgrammaticSelectionReachesTheEquatableList -only-testing:NativeMusicUITests/NativeMusicUITests/testW12LibraryKindsStatesPagingSearchSortAndSelection -only-testing:NativeMusicUITests/NativeMusicUITests/testW12OptimisticChangesRollBackRetryAndNeverClaimWhatTheServiceDidNotConfirm -only-testing:NativeMusicUITests/NativeMusicUITests/testW12HistoryKeepsTheServicesRecordAndThisMacsApartAndNeverImitatesRemoteControls -only-testing:NativeMusicUITests/NativeMusicUITests/testW09F2LibraryRestoresSearchOrderSelectionScrollKindAndKeptOnlyPerEntry -only-testing:NativeMusicUITests/NativeMusicUITests/testW09F2HistoryRestoresItsScrollOffsetPerEntry test)
  if [[ -n "${TEST_RESULT_PATH:-}" ]]; then args+=(-resultBundlePath "$TEST_RESULT_PATH"); fi
  counted_ui_test testW12ProgrammaticSelectionReachesTheEquatableList testW12LibraryKindsStatesPagingSearchSortAndSelection testW12OptimisticChangesRollBackRetryAndNeverClaimWhatTheServiceDidNotConfirm testW12HistoryKeepsTheServicesRecordAndThisMacsApartAndNeverImitatesRemoteControls testW09F2LibraryRestoresSearchOrderSelectionScrollKindAndKeptOnlyPerEntry testW09F2HistoryRestoresItsScrollOffsetPerEntry -- python3 scripts/test-native-latin.py xcodebuild "${args[@]}"
  exit 0
fi
if [[ "$2" == T20 ]]; then
  discovery=$(swift test --package-path Packages/NativeMusic list)
  [[ "$discovery" == *DiscoverySocialTests.* ]] || { echo 'T20 discovery is incomplete' >&2; exit 1; }
  # Samples / preview arbitration, the music tuner, Recap and badges, comments / moderation / invitations (T20.1-T20.4), the real-capture source
  # findings, the source guards, and the older suites the W20 changes touch (the Library ledger and guard, the playlist session, the catalog
  # parser, the session coordinator and signed transport, the playback routing the preview engine uses).
  counted_swift_test 'DiscoverySocialTests|SessionPreviewEngineTests|DeviceConditionsMonitorTests|DiscoveryCompositionTests|LibraryTests|PlaylistTests|CatalogTests|MusicWebSessionTests|ConnectionTests'
  # The static + built-binary isolation proof (no network API in the W20 sources, unresolved production sources, Release carries no development
  # discovery data, still one signed-write call site, isolated UI tests) is part of the suite: it inspects the Release binary, so that is built first.
  ./scripts/build-proof-products.sh
  BUILD_DIR="${BUILD_DIR:-$PWD/.build/xcode}" python3 artifacts/harness/nodes/W20/isolation-proof.py > /dev/null || { echo 'T20 isolation proof failed (see ${BUILD_DIR:-.build/xcode}/w20-isolation-proof.json)' >&2; exit 1; }
  echo 'T20 isolation proof: ok'
  if [[ "${T20_HEADLESS:-0}" == 1 ]]; then
    echo 'T20 headless only; native UI explicitly not run'
    exit 0
  fi
  if ioreg -n Root -d1 | python3 -c 'import sys; sys.exit(0 if chr(34)+"CGSSessionScreenIsLocked"+chr(34)+"=Yes" in sys.stdin.read() else 1)'; then
    echo 'T20 UI ENVIRONMENT BLOCKED: console locked' >&2
    exit 75
  fi
  # Typed text needs an ASCII-capable input source (restored afterwards); every launch is isolated and uses labelled development data only.
  args=(-project App/NativeMusic.xcodeproj -scheme NativeMusic -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath "${BUILD_DIR:-$PWD/.build/xcode}" -disableAutomaticPackageResolution -only-testing:NativeMusicUITests/NativeMusicUITests/testW20DiscoveryExtrasSayPlainlyThereIsNoSourceAndInventNothing -only-testing:NativeMusicUITests/NativeMusicUITests/testW20OneSamplePreviewsAtATimePlayHandsOffAndLowPowerModeTurnsAutoplayOff -only-testing:NativeMusicUITests/NativeMusicUITests/testW20TunerShowsOnlySuppliedControlsAndRecapShowsOnlySuppliedFigures test)
  if [[ -n "${TEST_RESULT_PATH:-}" ]]; then args+=(-resultBundlePath "$TEST_RESULT_PATH"); fi
  counted_ui_test testW20DiscoveryExtrasSayPlainlyThereIsNoSourceAndInventNothing testW20OneSamplePreviewsAtATimePlayHandsOffAndLowPowerModeTurnsAutoplayOff testW20TunerShowsOnlySuppliedControlsAndRecapShowsOnlySuppliedFigures -- python3 scripts/test-native-latin.py xcodebuild "${args[@]}"
  exit 0
fi
if [[ "$2" == T13 ]]; then
  discovery=$(swift test --package-path Packages/NativeMusic list)
  [[ "$discovery" == *PlaylistTests.* ]] || { echo 'T13 discovery is incomplete' >&2; exit 1; }
  # Playlist editing (T13.1-T13.5), the live-transport guard (LibraryTests), and the older suites the W13 changes touch (signed transport, catalog, session coordinator).
  counted_swift_test 'PlaylistTests|LibraryTests|MusicWebSessionTests|CatalogTests|ConnectionTests'
  if [[ "${T13_HEADLESS:-0}" == 1 ]]; then
    echo 'T13 headless only; native UI explicitly not run'
    exit 0
  fi
  if ioreg -n Root -d1 | python3 -c 'import sys; sys.exit(0 if chr(34)+"CGSSessionScreenIsLocked"+chr(34)+"=Yes" in sys.stdin.read() else 1)'; then
    echo 'T13 UI ENVIRONMENT BLOCKED: console locked' >&2
    exit 75
  fi
  # Every launch is isolated and uses labelled development playlists only (no account, no service, no network).
  args=(-project App/NativeMusic.xcodeproj -scheme NativeMusic -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath "${BUILD_DIR:-$PWD/.build/xcode}" -disableAutomaticPackageResolution -only-testing:NativeMusicUITests/NativeMusicUITests/testW13NewPlaylistsArePrivateByDefaultAndNothingIsCreatedUntilCreateIsPressed -only-testing:NativeMusicUITests/NativeMusicUITests/testW13EditorKeepsDuplicatesApartConfirmsBulkRemovalNamingTheSelectionAndUndoCanFail -only-testing:NativeMusicUITests/NativeMusicUITests/testW13ALostReplyIsSettledByReadingAndAConcurrentMoveAsksAboutThatOneSong -only-testing:NativeMusicUITests/NativeMusicUITests/testW13CollaborationInviteStopAndJoinAreExplicitAndConfirmed -only-testing:NativeMusicUITests/NativeMusicUITests/testW13SeveralSongsAreAddedThroughTheNamingConfirmationFromTheLibrarySelection -only-testing:NativeMusicUITests/NativeMusicUITests/testW13RolesFollowTheServiceAndAViewerGetsNoEditor test)
  if [[ -n "${TEST_RESULT_PATH:-}" ]]; then args+=(-resultBundlePath "$TEST_RESULT_PATH"); fi
  counted_ui_test testW13NewPlaylistsArePrivateByDefaultAndNothingIsCreatedUntilCreateIsPressed testW13EditorKeepsDuplicatesApartConfirmsBulkRemovalNamingTheSelectionAndUndoCanFail testW13ALostReplyIsSettledByReadingAndAConcurrentMoveAsksAboutThatOneSong testW13CollaborationInviteStopAndJoinAreExplicitAndConfirmed testW13SeveralSongsAreAddedThroughTheNamingConfirmationFromTheLibrarySelection testW13RolesFollowTheServiceAndAViewerGetsNoEditor -- python3 scripts/test-native-latin.py xcodebuild "${args[@]}"
  exit 0
fi
if [[ "$2" == T28 ]]; then
  # T28_UI_ONLY=1 runs only the native UI part (the headless parts already passed in this checkout): a UI job that has waited for a quiet console should not
  # spend two minutes of it on work that needs no console, because the account holder may come back meanwhile (exit 75).
  if [[ "${T28_UI_ONLY:-0}" != 1 ]]; then
  # W28: accessibility and localization. Static guards first (each proves itself with --self-test): the catalog and manifest against the specification's
  # exact 47 + 6 locales, and the rule that no test writes a persistent preferences domain.
  python3 scripts/l10n/build-catalog.py --check
  python3 scripts/l10n/sync-universe.py --check
  python3 scripts/check-localization.py --self-test
  python3 scripts/check-localization.py
  discovery=$(swift test --package-path Packages/NativeMusic list)
  for required in LocaleSetTests LanguageRegionIndependenceTests CatalogCoverageTests NaturalOrderTests PseudolocalizerTests ContrastModelTests ContentScaleTests ContentLocaleRequestTests UILanguageOverrideTests AnnouncementPolicyTests TransportAnnouncementTests AccountAnnouncementTests MotionTests KeyboardAndVoiceOverPathTests TestPreferencesGuardTests LocaleLayoutAuditTests; do
    [[ "$discovery" == *"$required"* ]] || { echo "T28 missing active class: $required" >&2; exit 1; }
  done
  # The test runner's preferences must not change during this run: key names of every domain before and after (names only), failing on any key a test
  # could have written to switch locale or text behaviour (the 2026-11-01 incident: a test set NSDoubleLocalizedStrings in the shared persistent domain).
  # T28.1-T28.6, in-process: locale set and fallback, independence of the three language choices, catalog completeness and plurals, natural order and search,
  # pseudolocalization, the contrast model over every palette/appearance/mode, announcements, motion, and the non-drag alternatives.
  counted_swift_test 'AccessibilityLocalizationTests'
  # The layout audit under double-length pseudolanguage and right-to-left: its own invocation, so no string was resolved at normal length first. Isolated
  # synthetic content only; the pseudolanguage is switched on through the in-memory registration domain.
  export YTMUSE_NATIVE_DESIGN_TEST=1 YTMUSE_UI_DEVELOPMENT_DATA=1 YTMUSE_UI_DEVELOPMENT_LIBRARY=1 YTMUSE_UI_DEVELOPMENT_PLAYLISTS=1
  counted_swift_test 'LocaleLayoutAuditTests'
  unset YTMUSE_NATIVE_DESIGN_TEST YTMUSE_UI_DEVELOPMENT_DATA YTMUSE_UI_DEVELOPMENT_LIBRARY YTMUSE_UI_DEVELOPMENT_PLAYLISTS
  echo 'T28 complete LOCAL cases only: real VoiceOver, human translation review (W42), live service and hardware observations remain open'
  fi
  if [[ "${T28_HEADLESS:-0}" == 1 ]]; then
    echo 'T28 headless only; native UI explicitly not run'
    exit 0
  fi
  if ioreg -n Root -d1 | python3 -c 'import sys; sys.exit(0 if chr(34)+"CGSSessionScreenIsLocked"+chr(34)+"=Yes" in sys.stdin.read() else 1)'; then
    echo 'T28 UI ENVIRONMENT BLOCKED: console locked' >&2
    exit 75
  fi
  args=(-project App/NativeMusic.xcodeproj -scheme NativeMusic -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath "${BUILD_DIR:-$PWD/.build/xcode}" -disableAutomaticPackageResolution -only-testing:NativeMusicUITests/NativeMusicUITests/testW28KeyboardAndAccessibilityTraversal -only-testing:NativeMusicUITests/NativeMusicUITests/testW28RouteSelectionHasAKeyboardPath -only-testing:NativeMusicUITests/NativeMusicUITests/testW28LanguageChoicesTextSizeAndRelaunch test)
  if [[ -n "${TEST_RESULT_PATH:-}" ]]; then args+=(-resultBundlePath "$TEST_RESULT_PATH"); fi
  counted_ui_test testW28KeyboardAndAccessibilityTraversal testW28RouteSelectionHasAKeyboardPath testW28LanguageChoicesTextSizeAndRelaunch -- python3 scripts/test-native-latin.py xcodebuild "${args[@]}"
  exit 0
fi
if [[ "$2" == T29 ]]; then
  # W29: privacy, security and failure-path hardening (T29.1-T29.5). The destination audit first (it proves each of its rules on a planted violation, then reads the source, the
  # property lists, the entitlement files and the dependency manifests against Docs/Network-Destinations.json).
  python3 scripts/check-destinations.py --self-test
  python3 scripts/check-destinations.py
  discovery=$(swift test --package-path Packages/NativeMusic list)
  for required in CanaryPathTests SafeErrorTextTests HostileLinkTests HostileRouteTests BadTLSTests HostileCallbackTests HostileImageTests HostileArtworkFetchTests HostileBodyTests HostileMetadataTests HostileProbeTests DestinationTests AccountDeletionTests ThreadAffinityTests; do
    [[ "$discovery" == *"$required"* ]] || { echo "T29 missing active class: $required" >&2; exit 1; }
  done
  # T29.1 canaries (cookie, token, email, private playlist name, search term, signed URL) through the real inputs of sixteen paths (transport failures and redirects, the sign-in callback
  # and the loopback parser, the log, the bundle and its exported file, error text, the notification, the widget file, Spotlight, Handoff, share links and link refusals), each path proving
  # its canaries were delivered and the control rendering still holds them; T29.2 hostile links, routes, TLS failures, forged and replayed callbacks, image and compression bombs,
  # lying lengths, endless bodies, oversized metadata; T29.3 the destination inventory against the policies, probed at run time with a corpus of telemetry and hostile hosts, plus the
  # dependency, entitlement, usage-description and remote-code sweeps; T29.4 an account removed during a download, outbox writes, a Spotlight run, a widget flush and a key cleanup
  # that fails halfway; T29.5 a recording seam on the widget publisher's file and image work driven from the main actor, the artwork and download pipelines driven the same way, the
  # main-actor blocking-call sweep and the audio-thread sweep. Everything is a fake, a scratch directory or a local URL protocol: no real store, host or local network is touched.
  counted_swift_test 'SecurityTests'
  # T29.3 on the built bundle: the Debug app's executables and frameworks against the same inventory, the telemetry deny list, the linked-framework deny list and the entitlements it was signed with.
  ./scripts/build-debug.sh
  derived="${BUILD_DIR:-$PWD/.build/xcode}"
  python3 scripts/check-destinations.py --binary "$derived/Build/Products/Debug/YTMuse.app"
  echo 'T29 complete LOCAL cases only; a Release-signed bundle audit, live TLS interception and the account holder review remain separate evidence'
  exit 0
fi
if [[ "$2" == T30 ]]; then
  # W30: reproducible CI, the native updater, the inspectable repository (T30.1-T30.5). Static checks first; each proves itself with --self-test.
  python3 scripts/scan-repository.py --self-test
  python3 scripts/check-distribution.py --self-test
  python3 scripts/check-distribution.py --source-only
  python3 scripts/check-workflows.py --self-test
  python3 scripts/check-workflows.py
  python3 scripts/check-docs.py --self-test
  python3 scripts/check-docs.py            # documented examples EXECUTE here (T30.5)
  bash Tests/Build/test-package-release.sh # the signed-package script over shimmed tools (no Release build, identity, notarization or key of anyone's)
  discovery=$(swift test --package-path Packages/NativeMusic list)
  for required in FeedVerificationTests StagingTests InstallTests ControllerTests RequestContentTests SystemVerificationTests UpdaterGuardTests FeedToolTests; do
    [[ "$discovery" == *"$required"* ]] || { echo "T30 missing active class: $required" >&2; exit 1; }
  done
  # The updater (T30.2, T30.3): the signed feed, tamper / downgrade / replay / provenance refusals, the staged-asset and bundle checks, the real code-signature and
  # disk-image paths on throwaway ad-hoc bundles, the explicit-restart and playback gates, the ask-once and daily consent, the request on a loopback socket and the guards.
  counted_swift_test '^UpdatesTests\.'
  # T30.1: CI runs EVERY headless package test, counted (discovered vs executed), on a fresh clone with no secrets (scripts/ci.sh, scripts/clean-checkout.sh).
  if [[ "${T30_WHOLE_PACKAGE:-0}" == 1 ]]; then
    # CI runs the same headless whole-package suite as T50 (its crash-worker builds, quit-timing run and the counted whole package: found by the snapshot run, which failed three
    # crash tests without them). The runner's own guard (ContactsStoreGuardTests) allows exactly the call sites T50 and T01 have, so T30 delegates instead of adding one.
    T50_HEADLESS=1 ./scripts/test.sh --suite T50
  fi
  # T30.4 on the built binary: the Debug app (a Release build is the operator's, never a lane's) is inspected for any browser, Python or Node runtime and any non-system
  # library. The same inspection runs on the Release bundle inside scripts/package-release.sh. The hidden player is the system WebKit.
  ./scripts/build-debug.sh
  derived="${BUILD_DIR:-$PWD/.build/xcode}"
  python3 scripts/check-distribution.py --app "$derived/Build/Products/Debug/YTMuse.app" --json "${T30_INVENTORY:-/dev/null}"
  # T30.5: the working tree must hold no session, cookie, token, key or Team ID (history, screenshots and personal data: T30_SCAN_ALL=1 or the checklist).
  python3 scripts/scan-repository.py --tree --fail-on high
  if [[ "${T30_SCAN_ALL:-0}" == 1 ]]; then python3 scripts/scan-repository.py --history --images --fail-on high; fi
  if [[ "${T30_HEADLESS:-0}" == 1 ]]; then
    echo 'T30 headless only; native UI explicitly not run'
    exit 0
  fi
  if ioreg -n Root -d1 | python3 -c 'import sys; sys.exit(0 if chr(34)+"CGSSessionScreenIsLocked"+chr(34)+"=Yes" in sys.stdin.read() else 1)'; then
    echo 'T30 UI ENVIRONMENT BLOCKED: console locked' >&2
    exit 75
  fi
  # Isolated launch: no feed, so Settings says updates are unavailable and nothing asks to check.
  args=(-project App/NativeMusic.xcodeproj -scheme NativeMusic -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath "${BUILD_DIR:-$PWD/.build/xcode}" -disableAutomaticPackageResolution -only-testing:NativeMusicUITests/NativeMusicUITests/testW30UpdatesAreUnavailableWithoutAFeedAndNothingAsksToCheck test)
  if [[ -n "${TEST_RESULT_PATH:-}" ]]; then args+=(-resultBundlePath "$TEST_RESULT_PATH"); fi
  counted_ui_test testW30UpdatesAreUnavailableWithoutAFeedAndNothingAsksToCheck -- xcodebuild "${args[@]}"
  exit 0
fi
if [[ "$2" == T27 ]]; then
  # W27: complete Settings, storage controls and local diagnostics (T27.1-T27.5). The static guards first (check-boundaries ran above; the source sweeps for the destructive
  # actions, the network-free settings code and the absence of an analytics SDK are SettingsGuardTests, each proving itself on planted lines).
  discovery=$(swift test --package-path Packages/NativeMusic list)
  for required in SettingsRegistryTests SettingsScopeAndResetTests SettingsSearchTests SettingsEffectTests WiringTests DownloadEventDetectorTests LocalDataEraserTests ComposedLocalDataTests StorageBreakdownTests DiagnosticRedactionTests SupportBundleTests DiagnosticsReportTests ProfilerTests SettingsGuardTests; do
    [[ "$discovery" == *"$required"* ]] || { echo "T27 missing active class: $required" >&2; exit 1; }
  done
  # T27.1 the section 16 table read from the specification against the registry and every default; scopes (global / account / window), per-category reset; T27.2 one
  # downstream-effect check per setting through the real owners (login item, mini-player, download engine, output coordinator, notifications, Spotlight and shortcut opt-ins),
  # and the capabilities the app cannot honour stated with their reason; T27.3 the destructive actions over a real account lifecycle, SQLite store and test Keychain, the
  # real-root guard (a hard-coded real path is refused), and the storage breakdown reconciled with a real download ledger and artwork pipeline; T27.4 canaries through the
  # real inputs on the happy and error paths; T27.5 actual adapter version, quality unknowns, source outage vs crash, and the opt-in bounded profiler. Nothing touches a real
  # store: the unit-test process is isolated, every root is a temporary one, and the sweeps prove no test or source names a real one outside the guard.
  counted_swift_test 'SettingsRegistryTests|SettingsScopeAndResetTests|SettingsSearchTests|SettingsEffectTests|WiringTests|DownloadEventDetectorTests|LocalDataEraserTests|ComposedLocalDataTests|StorageBreakdownTests|DiagnosticRedactionTests|SupportBundleTests|DiagnosticsReportTests|ProfilerTests|SettingsGuardTests|SchedulingTests/testAnAutomaticDownloadRunsOnAnExpensivePathOnlyWhenAllowedAndNeverOnAConstrainedOne'
  if [[ "${T27_HEADLESS:-0}" == 1 ]]; then
    echo 'T27 headless only; native UI explicitly not run'
    exit 0
  fi
  if ioreg -n Root -d1 | python3 -c 'import sys; sys.exit(0 if chr(34)+"CGSSessionScreenIsLocked"+chr(34)+"=Yes" in sys.stdin.read() else 1)'; then
    echo 'T27 UI ENVIRONMENT BLOCKED: console locked' >&2
    exit 75
  fi
  # Isolated launch: throwaway preferences, in-memory Spotlight index, temporary App Group, throwaway Keychain files. The UI test reads the Debug readout of the active roots and
  # refuses to press Reset All Local Data unless it says they are isolated.
  args=(-project App/NativeMusic.xcodeproj -scheme NativeMusic -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath "${BUILD_DIR:-$PWD/.build/xcode}" -disableAutomaticPackageResolution -only-testing:NativeMusicUITests/NativeMusicUITests/testW27SettingsCategoriesSearchResetStorageDiagnosticsAndTheIsolatedLocalDataReset test)
  if [[ -n "${TEST_RESULT_PATH:-}" ]]; then args+=(-resultBundlePath "$TEST_RESULT_PATH"); fi
  counted_ui_test testW27SettingsCategoriesSearchResetStorageDiagnosticsAndTheIsolatedLocalDataReset -- python3 scripts/test-native-latin.py xcodebuild "${args[@]}"
  exit 0
fi
if [[ "$2" == T26 ]]; then
  # The static guards first: no global tap or monitor (the hot-key allowance is one file and the guard's self-test proves the rest still fail), and the
  # system-permission names (notification center, hot-key registration, Apple-event sending) confined to the app target.
  python3 scripts/check-system-media.py --self-test
  python3 scripts/check-system-media.py
  discovery=$(swift test --package-path Packages/NativeMusic list)
  for required in LinkPolicyTests CanonicalLinkTests ShortcutTableTests GlobalShortcutTests ScriptDispatcherTests ScriptingShellTests ScriptingDictionaryTests ScriptingExampleTests LaunchGuardTests TestPreferencesStayInMemoryTests ShareTests HandoffTests NotificationOptInTests PermissionDefaultsTests IntegrationLocalizationTests; do
    [[ "$discovery" == *"$required"* ]] || { echo "T26 missing active class: $required" >&2; exit 1; }
  done
  # Links, shortcuts, scripting, sharing, Handoff and permissions (T26.1-T26.5), all in-process: the strict link policy and its malicious corpus, the
  # shortcut table with the focus guard on real AppKit responders, the global shortcuts against a recording registrar, the AppleScript dictionary against its
  # Cocoa classes and the documented examples executed through the dispatcher, the canonical share links, Handoff, and the opt-in notification and permission
  # guards against recording stand-ins. No Apple event is sent, no hot key registered, no authorization requested and no system sheet shown by any of it.
  # Real Services, share sheet, Handoff, hot keys, notification prompts, Automation consent and real scripted Apple-event runs are live observations, never counted here.
  counted_swift_test 'LinkPolicyTests|CanonicalLinkTests|ShortcutTableTests|GlobalShortcutTests|ScriptDispatcherTests|ScriptingShellTests|ScriptingDictionaryTests|ScriptingExampleTests|LaunchGuardTests|TestPreferencesStayInMemoryTests|ShareTests|HandoffTests|NotificationOptInTests|PermissionDefaultsTests|IntegrationLocalizationTests'
  if [[ "${T26_HEADLESS:-0}" == 1 ]]; then
    echo 'T26 headless only; native UI explicitly not run'
    exit 0
  fi
  if ioreg -n Root -d1 | python3 -c 'import sys; sys.exit(0 if chr(34)+"CGSSessionScreenIsLocked"+chr(34)+"=Yes" in sys.stdin.read() else 1)'; then
    echo 'T26 UI ENVIRONMENT BLOCKED: console locked' >&2
    exit 75
  fi
  # Isolated launch: the hot keys, the notification center and the share sheet are in-process stand-ins, the clipboard is private, and the preferences are a
  # throwaway plist. Typed text needs an ASCII-capable input source (restored afterwards).
  args=(-project App/NativeMusic.xcodeproj -scheme NativeMusic -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath "${BUILD_DIR:-$PWD/.build/xcode}" -disableAutomaticPackageResolution -only-testing:NativeMusicUITests/NativeMusicUITests/testW26KeyboardGuardsMenusAndOptInSettingsOnAnIsolatedLaunch test)
  if [[ -n "${TEST_RESULT_PATH:-}" ]]; then args+=(-resultBundlePath "$TEST_RESULT_PATH"); fi
  counted_ui_test testW26KeyboardGuardsMenusAndOptInSettingsOnAnIsolatedLaunch -- python3 scripts/test-native-latin.py xcodebuild "${args[@]}"
  python3 scripts/check-system-media.py   # again, now over the freshly built app binary as well
  exit 0
fi
if [[ "$2" == T25 ]]; then
  # W25: widgets and privacy-aware Spotlight indexing (T25.1-T25.4). The static guards first; each proves itself with --self-test.
  python3 scripts/check-widget.py --self-test
  python3 scripts/check-widget.py --source-only
  python3 scripts/check-intents.py --self-test
  python3 scripts/check-intents.py --source-only
  python3 scripts/check-signing.py --self-test
  bash Tests/Build/test-build-signing.sh   # build.sh's signing rules over shimmed tools: extension first, embed only with an identity
  discovery=$(swift test --package-path Packages/NativeMusic list)
  for required in WidgetSnapshotStoreTests WidgetDisplayTests WidgetPublisherTests WidgetCommandTests SpotlightIndexTests SpotlightControllerTests SystemSurfacesCompositionTests WidgetSpotlightGuardTests ProductionStoreGuardTests SurfaceBarrierTests; do
    [[ "$discovery" == *"$required"* ]] || { echo "T25 missing active class: $required" >&2; exit 1; }
  done
  # The snapshot schema and store (atomic, strict, deleted completely), the widget's display, timeline provider and real small/medium views, the publisher over the real Now
  # Playing owner (no polling, coalesced reloads, deletion at an account barrier, locked/signed-out redaction), the widget button's account and session fence over the real
  # playback owner (T25.2), the Spotlight policy / indexer / controller over an in-memory index (T25.3), and the guards that no test reaches the real index, WidgetCenter or the
  # real App Group folder (T25.4). An INSTALLED widget, the Spotlight UI and a Shortcut are live observations (W41), never counted here.
  counted_swift_test 'WidgetSnapshotStoreTests|WidgetDisplayTests|WidgetPublisherTests|WidgetCommandTests|SpotlightIndexTests|SpotlightControllerTests|SystemSurfacesCompositionTests|WidgetSpotlightGuardTests|ProductionStoreGuardTests|SurfaceBarrierTests'
  # T25.4 on the built bundle: build the real Debug app, then read its signature, entitlements and App Intents metadata, and the widget extension PRODUCT's linkage.
  # A worktree build is ad hoc, so it embeds NO extension and holds NO App Group (check-intents.py decides by the signature's team); the extension is built beside the app
  # (the app depends on it) and inspected as the standalone product. The signed branch (extension + team-prefixed group) is proved by check-signing.py on a stub
  # codesign and by the self-tests, and observed by the operator's signed Release build. This never installs or launches anything.
  ./scripts/build-debug.sh
  derived="${BUILD_DIR:-$PWD/.build/xcode}"
  python3 scripts/check-intents.py --app "$derived/Build/Products/Debug/YTMuse.app"
  python3 scripts/check-widget.py --appex "$derived/Build/Products/Debug/NativeMusicWidget.appex"
  python3 scripts/check-intent-donations.py --self-test
  python3 scripts/check-intent-donations.py Packages/NativeMusic/.build "$derived/Build/Intermediates.noindex" "$derived/Build/Products/Debug/YTMuse.app/Contents/MacOS"
  python3 scripts/check-system-media.py
  if [[ "${T25_HEADLESS:-0}" == 1 ]]; then
    echo 'T25 headless only; native UI explicitly not run'
    exit 0
  fi
  if ioreg -n Root -d1 | python3 -c 'import sys; sys.exit(0 if chr(34)+"CGSSessionScreenIsLocked"+chr(34)+"=Yes" in sys.stdin.read() else 1)'; then
    echo 'T25 UI ENVIRONMENT BLOCKED: console locked' >&2
    exit 75
  fi
  # Isolated launch: the Spotlight index is in memory, the App Group is a temporary directory and the widget reload is a recording one; the app carries no extension.
  args=(-project App/NativeMusic.xcodeproj -scheme NativeMusic -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath "${BUILD_DIR:-$PWD/.build/xcode}" -disableAutomaticPackageResolution -only-testing:NativeMusicUITests/NativeMusicUITests/testW25SpotlightIsOptInAndPrivateEntitiesNeedASecondChoice test)
  if [[ -n "${TEST_RESULT_PATH:-}" ]]; then args+=(-resultBundlePath "$TEST_RESULT_PATH"); fi
  counted_ui_test testW25SpotlightIsOptInAndPrivateEntitiesNeedASecondChoice -- xcodebuild "${args[@]}"
  python3 scripts/check-intents.py --app "${BUILD_DIR:-$PWD/.build/xcode}/Build/Products/Debug/YTMuse.app"   # the UI build is the same ad-hoc bundle, and must still pass
  exit 0
fi
if [[ "$2" == T24 ]]; then
  # W24: App Intents, entities and the audio schemas (T24.1-T24.4). The static guards first (the intents check also proves itself with --self-test).
  python3 scripts/check-intents.py --self-test
  python3 scripts/check-intents.py --source-only
  python3 scripts/check-intent-donations.py --self-test
  discovery=$(swift test --package-path Packages/NativeMusic list)
  for required in IntentIdentityTests IntentQueryScopeTests IntentResolverTests IntentTransportTests IntentPlayTests IntentLibraryTests IntentWindowAndTimerTests IntentDefinitionTests IntentInventoryTests IntentDonationGuardTests IntentDonationBehaviourTests SearchRequestInboxTests; do
    [[ "$discovery" == *"$required"* ]] || { echo "T24 missing active class: $required" >&2; exit 1; }
  done
  # Intent unit/integration tests against the REAL playback owner, command layer, ledger path and Play here gate over a fake hidden page, with fake catalogs:
  # entity identity and scope (T24.2), every MAC03 command through the shared use cases (T24.1), cold-launch restore, cancellation-by-refusal and
  # confirmation (T24.3), the phrase and inventory matrix, and the donation guard (no test reaches the system's donation, Shortcuts or Siri state).
  counted_swift_test 'IntentIdentityTests|IntentQueryScopeTests|IntentResolverTests|IntentTransportTests|IntentPlayTests|IntentLibraryTests|IntentWindowAndTimerTests|IntentDefinitionTests|IntentInventoryTests|IntentDonationGuardTests|IntentDonationBehaviourTests|SearchRequestInboxTests'
  # T24.4: build the real app, then read what the SDK's metadata processor wrote into the bundle (compile, Shortcuts and Siri are reported separately).
  # There is no UI part: an intent can only be invoked through Shortcuts or Siri, which no test may do.
  ./scripts/build-debug.sh
  derived="${BUILD_DIR:-$PWD/.build/xcode}"
  python3 scripts/check-intents.py --app "$derived/Build/Products/Debug/YTMuse.app"
  # What the compiler emitted, not what the text says: no object file or binary (tests included) references the system's donation symbols.
  python3 scripts/check-intent-donations.py Packages/NativeMusic/.build "$derived/Build/Intermediates.noindex" "$derived/Build/Products/Debug/YTMuse.app/Contents/MacOS"
  python3 scripts/check-system-media.py
  exit 0
fi
if [[ "$2" == T23 ]]; then
  # The static guard first: no global tap or private accessory protocol in sources, entitlements, linkage or built symbols (its own self-test too).
  python3 scripts/check-system-media.py --self-test
  discovery=$(swift test --package-path Packages/NativeMusic list)
  for required in NowPlayingMetadataTests RemoteOwnershipTests RemoteCommandRulesTests SystemMediaGuardTests CallbackIsolationTests NowPlayingMappingTests NativeNowPlayingReworkTests FinishedItemNowPlayingTests RemoteReworkTests NativeNoWindowNowPlayingTests NowPlayingSleepTimerTests; do
    [[ "$discovery" == *"$required"* ]] || { echo "T23 missing active class: $required" >&2; exit 1; }
  done
  # Now Playing, media keys and accessory command ownership (T23.1-T23.4): the published metadata, the one owner and its attach/detach rules, the
  # remote commands held to the window's own capabilities, ad restrictions, ledger and Play here gate, and the no-tap guard, against RECORDING stand-ins
  # for MPNowPlayingInfoCenter and MPRemoteCommandCenter; plus one hosted test on the real centres inside the isolated test process
  # (inside CallbackIsolationTests, which is serialized). Real media keys, AirPods buttons, Control Center and the Lock Screen widget are live observations, never counted here.
  counted_swift_test 'NowPlayingMetadataTests|RemoteOwnershipTests|RemoteCommandRulesTests|SystemMediaGuardTests|CallbackIsolationTests|NowPlayingMappingTests|NativeNowPlayingReworkTests|FinishedItemNowPlayingTests|RemoteReworkTests|NativeNoWindowNowPlayingTests|NowPlayingSleepTimerTests'
  if [[ "${T23_HEADLESS:-0}" == 1 ]]; then
    echo 'T23 headless only; native UI explicitly not run'
    exit 0
  fi
  if ioreg -n Root -d1 | python3 -c 'import sys; sys.exit(0 if chr(34)+"CGSSessionScreenIsLocked"+chr(34)+"=Yes" in sys.stdin.read() else 1)'; then
    echo 'T23 UI ENVIRONMENT BLOCKED: console locked' >&2
    exit 75
  fi
  # Isolated launch: Now Playing and the remote commands are a recording stand-in, so the run never holds the account holder's media keys.
  args=(-project App/NativeMusic.xcodeproj -scheme NativeMusic -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath "${BUILD_DIR:-$PWD/.build/xcode}" -disableAutomaticPackageResolution -only-testing:NativeMusicUITests/NativeMusicUITests/testW23OneNowPlayingOwnerAcrossWindowsMiniPlayerAndPopover -only-testing:NativeMusicUITests/NativeMusicUITests/testP17SleepTimerRemainingOnTheBarPopoverMiniPlayerAndNowPlaying test)
  if [[ -n "${TEST_RESULT_PATH:-}" ]]; then args+=(-resultBundlePath "$TEST_RESULT_PATH"); fi
  counted_ui_test testW23OneNowPlayingOwnerAcrossWindowsMiniPlayerAndPopover testP17SleepTimerRemainingOnTheBarPopoverMiniPlayerAndNowPlaying -- xcodebuild "${args[@]}"
  python3 scripts/check-system-media.py   # again, now over the freshly built app binary as well
  exit 0
fi
if [[ "$2" == T22 ]]; then
  discovery=$(swift test --package-path Packages/NativeMusic list)
  for required in RouteLossTests PreferredRouteTests RouteHandoffTests RouteCapabilityTests PlayHereTests OutputRoutesGuardTests WebKitCapabilityProbeTests MusicRouteLossTests NativeRouteLossTests NativeSessionRouteLossTests EngineHandoffTests NativePlayHereResumeTests PerEngineRouteTests RouteGateTests OutputPickerContentTests; do
    [[ "$discovery" == *"$required"* ]] || { echo "T22 missing active class: $required" >&2; exit 1; }
  done
  # Local output and AirPlay (T22.1-T22.5): the route model, the capability table, the route-loss pause for both engines, the preferred route, handoffs,
  # receiver sessions, Play here and the remote-timer note, all against SCRIPTED outputs and recording engines; the shipped WebKit's capability probe
  # in a fresh process; and the guards that no test target can reach a call that changes the Mac's outputs, volume, AirPlay or Bluetooth state.
  # Real AirPlay receivers, USB DACs, AirPods buttons and sample-rate changes are live observations (W40), never counted here.
  counted_swift_test 'RouteLossTests|PreferredRouteTests|RouteHandoffTests|RouteCapabilityTests|PlayHereTests|OutputRoutesGuardTests|WebKitCapabilityProbeTests|MusicRouteLossTests|NativeRouteLossTests|NativeSessionRouteLossTests|EngineHandoffTests|NativePlayHereResumeTests|PerEngineRouteTests|RouteGateTests|OutputPickerContentTests'
  if [[ "${T22_HEADLESS:-0}" == 1 ]]; then
    echo 'T22 headless only; native UI explicitly not run'
    exit 0
  fi
  if ioreg -n Root -d1 | python3 -c 'import sys; sys.exit(0 if chr(34)+"CGSSessionScreenIsLocked"+chr(34)+"=Yes" in sys.stdin.read() else 1)'; then
    echo 'T22 UI ENVIRONMENT BLOCKED: console locked' >&2
    exit 75
  fi
  # Isolated launch: the outputs are a scripted list (never a real device), the applier moves nothing, the preferences are a throwaway plist.
  args=(-project App/NativeMusic.xcodeproj -scheme NativeMusic -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath "${BUILD_DIR:-$PWD/.build/xcode}" -disableAutomaticPackageResolution -only-testing:NativeMusicUITests/NativeMusicUITests/testW22OutputPickerLossAndPlayHereConfirmation test)
  if [[ -n "${TEST_RESULT_PATH:-}" ]]; then args+=(-resultBundlePath "$TEST_RESULT_PATH"); fi
  counted_ui_test testW22OutputPickerLossAndPlayHereConfirmation -- xcodebuild "${args[@]}"
  exit 0
fi
if [[ "$2" == T39 ]]; then
  discovery=$(swift test --package-path Packages/NativeMusic list)
  for required in CastWireTests CastMessageTests CastDeviceRouteTests CastCertificatePinTests CastSessionTests CastRelayCoreTests CastRelayServerTests CastRouteTests CastCapabilityTests CastQuitTests CastNetworkGuardTests CastAppTests CastLaunchAdoptionTests RemoteSilenceTests OutputRoutesGuardTests; do
    [[ "$discovery" == *"$required"* ]] || { echo "T39 missing active class: $required" >&2; exit 1; }
  done
  # Native Cast sender (T39.2-T39.4, with T39.1/T39.5 on the live list): the Cast V2 wire format against hand-written bytes, the namespace JSON, the sender session
  # against a simulated receiver that speaks the protocol, the scoped local relay (token, method, path, network, lifetime abuse tests at the decision layer AND
  # over loopback, plus its measured cost), the route driver inside the W22 route model (loss, Reconnect, Play here, preferred IDs, Quit), the app integration
  # with a real PlaybackSession, and the guards that no test target can browse, connect or listen on a real network. NOTHING here touches a real device or LAN;
  # real Chromecast checks are the end-of-project live list (W40).
  counted_swift_test 'CastWireTests|CastMessageTests|CastDeviceRouteTests|CastCertificatePinTests|CastSessionTests|CastRelayCoreTests|CastRelayServerTests|CastRouteTests|CastCapabilityTests|CastQuitTests|CastNetworkGuardTests|CastAppTests|CastLaunchAdoptionTests|RemoteSilenceTests|OutputRoutesGuardTests'
  if [[ "${T39_HEADLESS:-0}" == 1 ]]; then
    echo 'T39 headless only; native UI explicitly not run'
    exit 0
  fi
  if ioreg -n Root -d1 | python3 -c 'import sys; sys.exit(0 if chr(34)+"CGSSessionScreenIsLocked"+chr(34)+"=Yes" in sys.stdin.read() else 1)'; then
    echo 'T39 UI ENVIRONMENT BLOCKED: console locked' >&2
    exit 75
  fi
  # Isolated launch: scripted receivers and an in-process simulated one; nothing browses or connects to the network.
  args=(-project App/NativeMusic.xcodeproj -scheme NativeMusic -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath "${BUILD_DIR:-$PWD/.build/xcode}" -disableAutomaticPackageResolution -only-testing:NativeMusicUITests/NativeMusicUITests/testW39CastPickerReceiverLossAndLeave test)
  if [[ -n "${TEST_RESULT_PATH:-}" ]]; then args+=(-resultBundlePath "$TEST_RESULT_PATH"); fi
  counted_ui_test testW39CastPickerReceiverLossAndLeave -- xcodebuild "${args[@]}"
  exit 0
fi
if [[ "$2" == T21 ]]; then
  discovery=$(swift test --package-path Packages/NativeMusic list)
  for required in LifecyclePowerTests LifecycleSleepWakeTests LifecycleNativeSessionSleepTests LifecycleWindowTests LifecycleStatusTests LifecycleLaunchTests LifecycleResumeTests LifecycleOcclusionTests LifecycleOwnershipTests LifecycleLikeTests QuitDeadlineTests QuitSheetAndDeadlineLogTests WebKitStoreProcessTests WebMusicPlayerTests WebMusicAuthorityTests WebMusicTimelineIsolationTests WebMusicSleepTimerTests WebMusicSleepTimerScriptTests WebMusicSleepTimerGuardTests LifecycleWebSleepTimerTests; do
    [[ "$discovery" == *"$required"* ]] || { echo "T21 missing active class: $required" >&2; exit 1; }
  done
  # Window, menu-bar and sleep/wake lifecycle (T21.1-T21.5): the shell's own cases (power, sleep/wake, windows and activation policy, status item,
  # launch and login item, cold-launch restore, occlusion, ownership), the existing quit-path cases (they must stay green), and the hidden
  # player's and the owner's regression classes the lifecycle code extends. The real login item, Dock and system settings are unreachable by
  # construction (LifecycleLaunchTests sweeps for it).
  # The quit-timing classes and the fresh-process probes (quit; the hidden player's never-suspended page policy) run first, in their own invocation.
  counted_swift_test 'QuitDeadlineTests|QuitSheetAndDeadlineLogTests|WebKitStoreProcessTests'
  counted_swift_test 'LifecyclePowerTests|LifecycleSleepWakeTests|LifecycleNativeSessionSleepTests|LifecycleWindowTests|LifecycleStatusTests|LifecycleLaunchTests|LifecycleResumeTests|LifecycleOcclusionTests|LifecycleOwnershipTests|LifecycleLikeTests|LifecycleWebSleepTimerTests|WebMusic|ProductionStoreGuard'
  if [[ "${T21_HEADLESS:-0}" == 1 ]]; then
    echo 'T21 headless only; native UI explicitly not run'
    exit 0
  fi
  if ioreg -n Root -d1 | python3 -c 'import sys; sys.exit(0 if chr(34)+"CGSSessionScreenIsLocked"+chr(34)+"=Yes" in sys.stdin.read() else 1)'; then
    echo 'T21 UI ENVIRONMENT BLOCKED: console locked' >&2
    exit 75
  fi
  # Every launch is isolated (throwaway stores, preferences and the in-process fake login item); the status item it adds to the real menu bar goes
  # when the copy quits. A login launch is simulated by an environment variable that only an isolated launch honours.
  args=(-project App/NativeMusic.xcodeproj -scheme NativeMusic -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath "${BUILD_DIR:-$PWD/.build/xcode}" -disableAutomaticPackageResolution -only-testing:NativeMusicUITests/NativeMusicUITests/testW21LastWindowClosedKeepsAudioAndStatusItemThenReopensAndTwoWindowsShareOnePlayer -only-testing:NativeMusicUITests/NativeMusicUITests/testW21MiniPlayerCompactExpandedPinnedAndNeverStealsFocusOnATrackChange -only-testing:NativeMusicUITests/NativeMusicUITests/testW21LoginLaunchIsMenuBarOnlyWithNoWindowAndNoAudioAndTheSettingsToggleDrivesOnlyTheFake -only-testing:NativeMusicUITests/NativeMusicUITests/testW21MinimizedWindowKeepsTheTransportAndTheStatusItemResponsive -only-testing:NativeMusicUITests/NativeMusicUITests/testW21FullScreenNowPlayingShowsTransportAndLeavesPlaybackAlone -only-testing:NativeMusicUITests/NativeMusicUITests/testWindowSettingsPreferenceAndQuit test)
  if [[ -n "${TEST_RESULT_PATH:-}" ]]; then args+=(-resultBundlePath "$TEST_RESULT_PATH"); fi
  counted_ui_test testW21LastWindowClosedKeepsAudioAndStatusItemThenReopensAndTwoWindowsShareOnePlayer testW21MiniPlayerCompactExpandedPinnedAndNeverStealsFocusOnATrackChange testW21LoginLaunchIsMenuBarOnlyWithNoWindowAndNoAudioAndTheSettingsToggleDrivesOnlyTheFake testW21MinimizedWindowKeepsTheTransportAndTheStatusItemResponsive testW21FullScreenNowPlayingShowsTransportAndLeavesPlaybackAlone testWindowSettingsPreferenceAndQuit -- xcodebuild "${args[@]}"
  exit 0
fi
if [[ "$2" == T18 ]]; then
  discovery=$(swift test --package-path Packages/NativeMusic list)
  for required in RealCaptureManifestTests RealEpisodePageTests RealShowPageTests RealLyricsTests LyricsParserTests LyricsTransportTests LyricsModelTests TimedLyricsTests LyricsAutoScrollTests LyricsFollowModelTests PodcastRateTests PodcastSkipIntervalTests PodcastPreferenceModelTests PodcastPlaybackBehaviourTests EpisodeChapterTests EpisodeProgressResolverTests EpisodeProgressRecorderTests PodcastLocalFileStoreTests EpisodeDownloadPermissionTests EpisodeLaterWireTests EpisodeLaterLedgerTests PodcastsLyricsGuardTests LyricsPanelRenderTests EpisodeScreenRenderTests RateReconciliationTests PlayerControlsInjectionTests PodcastRateDisplayTests ShowPageStartTests EpisodeStartFailureTests EpisodeLaterOfferTests WebMusicSleepTimerTests WebMusicSleepTimerScriptTests WebMusicSleepTimerGuardTests; do
    [[ "$discovery" == *"$required"* ]] || { echo "T18 missing active class: $required" >&2; exit 1; }
  done
  # Podcasts, episodes and source lyrics (T18.1-T18.4) on the real anonymous captures first, then the hand-written edge cases, plus the older suites the
  # W18 changes touch: the Library's ledger and its guards (Episodes for Later is a ledger write), the catalog parser and hub (episode rows and routes),
  # search (episode results), the session coordinator and signed transport (`next`), the playlist write guards (Episodes for Later is the one named
  # removal by video id) and the hidden player's commands (the speed command).
  counted_swift_test 'PodcastsLyricsTests|LibraryTests|PlaylistTests|CatalogTests|SearchTests|MusicWebSessionTests|ConnectionTests|NetworkingTests|WebMusic|DownloadsTests.EligibilityTests'
  if [[ "${T18_HEADLESS:-0}" == 1 ]]; then
    echo 'T18 headless only; native UI explicitly not run'
    exit 0
  fi
  if ioreg -n Root -d1 | python3 -c 'import sys; sys.exit(0 if chr(34)+"CGSSessionScreenIsLocked"+chr(34)+"=Yes" in sys.stdin.read() else 1)'; then
    echo 'T18 UI ENVIRONMENT BLOCKED: console locked' >&2
    exit 75
  fi
  # Every launch is isolated and uses labelled development data only (no account, no service, no network).
  args=(-project App/NativeMusic.xcodeproj -scheme NativeMusic -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath "${BUILD_DIR:-$PWD/.build/xcode}" -disableAutomaticPackageResolution -only-testing:NativeMusicUITests/NativeMusicUITests/testW18EpisodesShowProgressChaptersAndNeverAnInertDownloadControl -only-testing:NativeMusicUITests/NativeMusicUITests/testW18LyricsStayPlainWithTheSourceNoLyricsAndCouldNotLoadAreDifferent test)
  if [[ -n "${TEST_RESULT_PATH:-}" ]]; then args+=(-resultBundlePath "$TEST_RESULT_PATH"); fi
  counted_ui_test testW18EpisodesShowProgressChaptersAndNeverAnInertDownloadControl testW18LyricsStayPlainWithTheSourceNoLyricsAndCouldNotLoadAreDifferent -- python3 scripts/test-native-latin.py xcodebuild "${args[@]}"
  exit 0
fi
if [[ "$2" == T15 ]]; then
  discovery=$(swift test --package-path Packages/NativeMusic list)
  [[ "$discovery" == *DownloadsTests.ResumeTests* && "$discovery" == *DownloadsTests.QuotaTests* && "$discovery" == *DownloadsTests.SchedulingTests* && "$discovery" == *DownloadsTests.RetentionTests* && "$discovery" == *DownloadsTests.RecoveryTests* && "$discovery" == *DownloadsTests.EligibilityTests* ]] || { echo 'T15 discovery is incomplete' >&2; exit 1; }
  # Durable download engine (T15.1-T15.5) on owned/synthetic media with fake transports, the real W14 encrypted store in an isolated
  # test keychain, and the live-transport guard. No account, network or production store is used.
  counted_swift_test 'DownloadsTests'
  if [[ "${T15_HEADLESS:-0}" == 1 ]]; then
    echo 'T15 headless only; native UI explicitly not run'
    exit 0
  fi
  if ioreg -n Root -d1 | python3 -c 'import sys; sys.exit(0 if chr(34)+"CGSSessionScreenIsLocked"+chr(34)+"=Yes" in sys.stdin.read() else 1)'; then
    echo 'T15 UI ENVIRONMENT BLOCKED: console locked' >&2
    exit 75
  fi
  args=(-project App/NativeMusic.xcodeproj -scheme NativeMusic -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath "${BUILD_DIR:-$PWD/.build/xcode}" -disableAutomaticPackageResolution -only-testing:NativeMusicUITests/NativeMusicUITests/testW15DownloadsStatesRecoveryStorageAndTheYouTubeMusicExplanation -only-testing:NativeMusicUITests/NativeMusicUITests/testW09F2DownloadsRestoresItsFilterAndScrollOffsetPerEntry test)
  if [[ -n "${TEST_RESULT_PATH:-}" ]]; then args+=(-resultBundlePath "$TEST_RESULT_PATH"); fi
  counted_ui_test testW15DownloadsStatesRecoveryStorageAndTheYouTubeMusicExplanation testW09F2DownloadsRestoresItsFilterAndScrollOffsetPerEntry -- xcodebuild "${args[@]}"
  exit 0
fi
if [[ "$2" == T14 ]]; then
  discovery=$(swift test --package-path Packages/NativeMusic list)
  [[ "$discovery" == *OfflineStoreTests.* ]] || exit 1
  counted_swift_test OfflineStoreTests
  exit 0
fi
if [[ "$2" == T07 ]]; then
  discovery=$(swift test --package-path Packages/NativeMusic --scratch-path "$PWD/.build/w07" list)
  [[ "$discovery" == *NetworkingTests.* ]] || { echo 'T07 discovery is empty' >&2; exit 1; }
  counted_swift_test NetworkingTests --scratch-path "$PWD/.build/w07"
  exit 0
fi
if [[ "$2" == T06 ]]; then
  discovery=$(swift test --package-path Packages/NativeMusic list)
  [[ "$discovery" == *PlaybackTests.* ]] || { echo 'T06 discovery is empty' >&2; exit 1; }
  printf '%s\n' "$discovery"
  # T16 owns the new DSP/codec/handoff classes. Keep T06's original transport,
  # permissions and account-composition cases without inflating repeated totals.
  counted_swift_test 'NativePlaybackTests|PlaybackPolicyTests|OfflineCompositionReworkTests|StageBCommandPermissionTests|StageCCompositionTests'
  if [[ "${T06_HEADLESS:-0}" == 1 ]]; then
    echo 'T06 native-media/domain only; UI explicitly not run'
    exit 0
  fi
  if ioreg -n Root -d1 | python3 -c 'import sys; sys.exit(0 if chr(34)+"CGSSessionScreenIsLocked"+chr(34)+"=Yes" in sys.stdin.read() else 1)'; then
    echo 'T06 UI ENVIRONMENT BLOCKED: console locked' >&2
    exit 75
  fi
  args=(-project App/NativeMusic.xcodeproj -scheme NativeMusic -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath "${BUILD_DIR:-$PWD/.build/xcode}" -disableAutomaticPackageResolution -only-testing:NativeMusicUITests/NativeMusicUITests/testW06OwnedNativeBottomTransport test)
  if [[ -n "${TEST_RESULT_PATH:-}" ]]; then args+=(-resultBundlePath "$TEST_RESULT_PATH"); fi
  # W06 uses click/slider/menu controls, so no input-source wrapper is needed.
  counted_ui_test testW06OwnedNativeBottomTransport -- xcodebuild "${args[@]}"
  exit 0
fi
if [[ "$2" == T51 ]]; then
  discovery=$(swift test --package-path Packages/NativeMusic --scratch-path "$PWD/.build/e01" list)
  [[ "$discovery" == *ConnectionTests.ConnectionTests/* ]] || { echo 'T51 discovery is empty' >&2; exit 1; }
  counted_swift_test ConnectionTests --scratch-path "$PWD/.build/e01"
  exit 0
fi
if [[ "$2" == T53 ]]; then
  # Screenshot-only design review. Isolated Debug fixtures, no playback or service writes.
  args=(-project App/NativeMusic.xcodeproj -scheme NativeMusic -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath "${BUILD_DIR:-$PWD/.build/design-review}" -disableAutomaticPackageResolution -only-testing:NativeMusicUITests/NativeMusicUITests/testDesignReviewLight -only-testing:NativeMusicUITests/NativeMusicUITests/testDesignReviewDark test)
  if [[ -n "${TEST_RESULT_PATH:-}" ]]; then args+=(-resultBundlePath "$TEST_RESULT_PATH"); fi
  counted_ui_test testDesignReviewLight testDesignReviewDark -- python3 scripts/test-native-latin.py xcodebuild "${args[@]}"
  exit 0
fi
if [[ "$2" == T52 ]]; then
  # V02: design tokens, the source guard (no literal radius/material/animation/spacing outside DesignSystem), the audit-rule unit tests, and the
  # headless layout audit + snapshots of every primary surface. No UI session is needed: windows are hosted offscreen and nothing is shown or keyed.
  discovery=$(swift test --package-path Packages/NativeMusic list)
  [[ "$discovery" == *GlassPolishTests.* ]] || { echo 'T52 discovery is empty' >&2; exit 1; }
  t52_failed=0
  counted_swift_test 'DesignTokenTests|CornerCapTests|AccentOrderTests|StackedWashTests|LayoutAuditRuleTests|SourceGuardTests' || t52_failed=1
  # Isolated synthetic content only (the app's own development catalog and library); QA isolation is decided before any store opens.
  export YTMUSE_NATIVE_DESIGN_TEST=1 YTMUSE_UI_DEVELOPMENT_DATA=1 YTMUSE_UI_DEVELOPMENT_LIBRARY=1 YTMUSE_UI_DEVELOPMENT_PLAYLISTS=1
  # HistoryVirtualizationTests hosts the History page with 1,500 rows and counts the rows it builds (only those on screen) and the pages it reads.
  for audit_style in ytmuse standard; do
    export YTMUSE_AUDIT_STYLE="$audit_style"
    counted_swift_test 'SurfaceAuditTests|SheetAuditTests|PolicyAuditTests|PlayerMorphStageTests|CapsuleHoverAuditTests|RootRegionLayoutTests|SettleHelperTests|ShutdownIsolationTests|HistoryVirtualizationTests' || t52_failed=1
  done
  unset YTMUSE_AUDIT_STYLE
  # The window-root layout contract and scroll restoration also run against the generic collection page (development data, no development
  # Library), which is the page ScrollViewIntegrationTests measures; W12's Library replaced it when the library flag is set.
  unset YTMUSE_UI_DEVELOPMENT_LIBRARY YTMUSE_UI_DEVELOPMENT_PLAYLISTS
  for audit_style in ytmuse standard; do
    export YTMUSE_AUDIT_STYLE="$audit_style"
    counted_swift_test 'RootRegionLayoutTests|ScrollViewIntegrationTests' || t52_failed=1
  done
  unset YTMUSE_AUDIT_STYLE
  exit "$t52_failed"
fi
if [[ "$2" == T44P ]]; then
  # W44-prep: the synthetic PERF04 dataset (shape, determinism, gating), the library-model equivalence tests, the indicative headless model measurements on an
  # OPTIMIZED Debug build (its own scratch path, so the ordinary Debug build is not disturbed), and (below) the isolated native performance UI tests.
  # These are indicative numbers, never W44 results (W44 needs Release builds, which lanes never make). Use scripts/perf-run.sh for the full gated run.
  # The harness's own self-tests (report, sampler, and the real-state-snapshot verdict that plants a changed snapshot plus a failing test step).
  python3 scripts/perf-report.py --self-test && python3 scripts/perf-sample.py --self-test && bash scripts/perf-run.sh --self-test && python3 scripts/check-no-event-posting.py --self-test && python3 scripts/check-no-event-posting.py || { echo 'T44P harness self-test or the no-event-posting sweep failed' >&2; exit 1; }
  discovery=$(swift test --package-path Packages/NativeMusic list)
  for required in DatasetTests ModelBenchmarkTests LibraryModelEquivalenceTests StagedLoadAllAdversarialTests SearchKeyAndIdentityTests; do
    [[ "$discovery" == *"$required"* ]] || { echo "T44P missing active class: $required" >&2; exit 1; }
  done
  # perf-run.sh ui runs the headless part separately (outside the UI lock) and sets T44P_UI_ONLY=1 for the gated UI job.
  [[ "${T44P_UI_ONLY:-0}" == 1 ]] || counted_swift_test 'PerformanceTests\.' --scratch-path "$PWD/.build/perf-o" -Xswiftc -O
  if [[ "${T44P_HEADLESS:-0}" == 1 ]]; then
    echo 'T44P headless only; native UI explicitly not run'
    exit 0
  fi
  [[ -n "${YTMUSE_PERF_DIR:-}" ]] || { echo 'T44P UI part runs only through scripts/perf-run.sh ui (it makes YTMUSE_PERF_DIR); set T44P_HEADLESS=1 for the headless part alone' >&2; exit 64; }
  if ioreg -n Root -d1 | python3 -c 'import sys; sys.exit(0 if chr(34)+"CGSSessionScreenIsLocked"+chr(34)+"=Yes" in sys.stdin.read() else 1)'; then
    echo 'T44P UI ENVIRONMENT BLOCKED: console locked' >&2
    exit 75
  fi
  export TEST_RUNNER_YTMUSE_PERF_DIR="$YTMUSE_PERF_DIR"
  [[ -z "${YTMUSE_PERF_LAUNCHES:-}" ]] || export TEST_RUNNER_YTMUSE_PERF_LAUNCHES="$YTMUSE_PERF_LAUNCHES"
  [[ -z "${YTMUSE_PERF_ITERATIONS:-}" ]] || export TEST_RUNNER_YTMUSE_PERF_ITERATIONS="$YTMUSE_PERF_ITERATIONS"
  perf_tests=(testW44PLaunch testW44PNavigation testW44PLibraryScroll testW44PPlaylistGrid testW44PBigPlaylist testW44PQueue)
  [[ -z "${T44P_ONLY:-}" ]] || perf_tests=($T44P_ONLY)     # optional subset of the scripted UI tests (perf-run.sh ui runs them all in one gated job)
  args=(-project App/NativeMusic.xcodeproj -scheme NativeMusic -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath "${BUILD_DIR:-$PWD/.build/perf-xcode}" -disableAutomaticPackageResolution)
  for name in "${perf_tests[@]}"; do args+=(-only-testing:NativeMusicUITests/NativeMusicUITests/$name); done
  args+=(SWIFT_OPTIMIZATION_LEVEL=-O test)
  if [[ -n "${TEST_RESULT_PATH:-}" ]]; then args+=(-resultBundlePath "$TEST_RESULT_PATH"); fi
  counted_ui_test "${perf_tests[@]}" -- python3 scripts/test-native-latin.py xcodebuild "${args[@]}"
  exit 0
fi
if [[ "$2" == T50 ]]; then
  python3 scripts/validate-glass-assets.py
  discovery=$(swift test --package-path Packages/NativeMusic list)
  [[ "$discovery" == *DesignSystemTests.GlassPolicyTests* ]] || { echo 'T50 discovery is empty' >&2; exit 1; }
  ./Tests/Persistence/build-crash-worker.sh
  export PERSISTENCE_CRASH_WORKER="$PWD/.build/w03/crash-worker"
  ./Tests/Queue/build-crash-worker.sh
  export QUEUE_CRASH_WORKER="$PWD/.build/w05/crash-worker"
  # W21 rework (F6): the quit-timing classes also run first, in their own invocation. They are included again in the whole-package run below, so what keeps
  # the 80 ms case green there is the test's own measure (its deadline is judged from when the shutdown started), not the separate invocation.
  counted_swift_test 'QuitDeadlineTests|QuitSheetAndDeadlineLogTests|WebKitStoreProcessTests'
  counted_whole_package
  if [[ "${T50_HEADLESS:-0}" == 1 ]]; then
    echo 'T50 headless only (the whole package); native UI explicitly not run'
    exit 0
  fi
  if ioreg -n Root -d1 | python3 -c 'import sys; sys.exit(0 if chr(34)+"CGSSessionScreenIsLocked"+chr(34)+"=Yes" in sys.stdin.read() else 1)'; then
    echo 'T50 ENVIRONMENT BLOCKED: console session locked; native window validation requires unlock.' >&2
    exit 75
  fi
  args=(-project App/NativeMusic.xcodeproj -scheme NativeMusic -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath "${BUILD_DIR:-$PWD/.build/xcode}" -disableAutomaticPackageResolution test)
  if [[ -n "${TEST_RESULT_PATH:-}" ]]; then args+=(-resultBundlePath "$TEST_RESULT_PATH"); fi
  counted_ui_test --all-in Tests/NativeMusicUITests/NativeMusicUITests.swift -- python3 scripts/test-native-latin.py xcodebuild "${args[@]}"
  exit 0
fi
if [[ "$2" == T05 ]]; then
  ./Tests/Queue/build-crash-worker.sh
  export QUEUE_CRASH_WORKER="$PWD/.build/w05/crash-worker"
  discovery=$(swift test --package-path Packages/NativeMusic list)
  [[ "$discovery" == *QueueTests.* ]] || { echo 'T05 discovery is empty' >&2; exit 1; }
  printf '%s\n' "$discovery"
  counted_swift_test QueueTests
  exit 0
fi
if [[ "$2" == T04 ]]; then
  discovery=$(swift test --package-path Packages/NativeMusic list)
  printf '%s\n' "$discovery"
  if ! [[ "$discovery" == *AccountSessionTests.* ]]; then
    echo 'T04 discovery is empty' >&2
    exit 1
  fi
  counted_swift_test AccountSessionTests
  args=(-project App/NativeMusic.xcodeproj -scheme NativeMusic -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath "${BUILD_DIR:-$PWD/.build/xcode}" -disableAutomaticPackageResolution -only-testing:NativeMusicUITests/NativeMusicUITests/testYTMuseWelcomeAndNativeAccounts test)
  if [[ -n "${TEST_RESULT_PATH:-}" ]]; then args+=(-resultBundlePath "$TEST_RESULT_PATH"); fi
  counted_ui_test testYTMuseWelcomeAndNativeAccounts -- python3 scripts/test-native-latin.py xcodebuild "${args[@]}"
  exit 0
fi
if [[ "$2" == T03 ]]; then
  swift build --package-path Packages/NativeMusic
  ./Tests/Persistence/build-crash-worker.sh
  export PERSISTENCE_CRASH_WORKER="$PWD/.build/w03/crash-worker"
  discovery=$(swift test --package-path Packages/NativeMusic list)
  printf '%s\n' "$discovery"
  if ! [[ "$discovery" == *PersistenceTests.* ]]; then
    echo 'T03 discovery is empty' >&2
    exit 1
  fi
  counted_swift_test PersistenceTests
  exit 0
fi
if [[ "$2" == T02 ]]; then
  discovery=$(swift test --package-path Packages/NativeMusic list)
  printf '%s\n' "$discovery"
  if ! [[ "$discovery" == *DomainContractTests.* ]]; then
    echo 'T02 discovery is empty' >&2
    exit 1
  fi
  counted_swift_test DomainContractTests
  exit 0
fi
swift build --package-path Extensions
swift test --package-path Packages/NativeMusic list
./Tests/Persistence/build-crash-worker.sh
export PERSISTENCE_CRASH_WORKER="$PWD/.build/w03/crash-worker"
./Tests/Queue/build-crash-worker.sh
export QUEUE_CRASH_WORKER="$PWD/.build/w05/crash-worker"
counted_whole_package
args=(-project App/NativeMusic.xcodeproj -scheme NativeMusic -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath "${BUILD_DIR:-$PWD/.build/xcode}" -disableAutomaticPackageResolution test)
if [[ -n "${TEST_RESULT_PATH:-}" ]]; then args+=(-resultBundlePath "$TEST_RESULT_PATH"); fi
counted_ui_test --all-in Tests/NativeMusicUITests/NativeMusicUITests.swift -- python3 scripts/test-native-latin.py xcodebuild "${args[@]}"
