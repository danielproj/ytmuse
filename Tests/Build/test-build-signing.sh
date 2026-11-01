#!/bin/bash
# Exercises scripts/build.sh's opt-in signing logic with shimmed xcodebuild,
# codesign and security (no real keychain, identity or build). L4/K1a/N3. W25: build.sh now signs through scripts/sign-bundle.sh (extension first, then the app, the
# Team ID prefix filled in from the identity's team) and embeds the widget extension only for a build that is given an identity.
set -euo pipefail
repo="$(cd "$(dirname "$0")/../.." && pwd)"
fail() { echo "FAIL $*"; exit 1; }
# TH1: this script's scratch folders are named with its own prefix AND the creating process id (`ytmuse-build-signing.<pid>.XXXXXX`) and removed when it
# ends, however it ends. (Before, `mktemp -d` left one generic `tmp.XXXXXXXXXX` folder per case in $TMPDIR on every run: 71 were counted by the W25 critic.)
# Rework 2: a leftover is deleted only when the process that created it is gone (never by age: other runs of this script, in other lanes, share the prefix).
tmp_root="${TMPDIR:-/tmp}"; tmp_root="${tmp_root%/}"
base_prefix="ytmuse-build-signing."
prefix="${base_prefix}$$."
made=()
session_marker="$(mktemp "$tmp_root/${prefix}marker.XXXXXX")"
cleanup() {
  local d
  for d in ${made[@]+"${made[@]}"} "$session_marker"; do
    # Only what this run created: under the temp root, carrying this run's own prefix (with its process id), not a symlink.
    [[ -n "$d" && "$d" == "$tmp_root/$prefix"* && ! -L "$d" ]] && rm -rf "$d"
  done
}
trap cleanup EXIT
# Legacy folders (generic `tmp.*` names, left by runs before the trap existed): only ones that are provably this script's own, owned by this user, older than
# ten minutes AND older than this session. A legacy folder has exactly this script's layout and its synthetic shims; nothing else is touched.
is_ours_legacy() {
  local d=$1 entry
  [[ -d "$d" && ! -L "$d" && -O "$d" ]] || return 1
  for entry in "$d"/* "$d"/.[!.]*; do
    [[ -e "$entry" ]] || continue
    case "${entry##*/}" in bin|repo|derived|codesign.log|codesign.log.xcodebuild|out.log) ;; *) return 1 ;; esac
  done
  [[ -f "$d/bin/security" && -f "$d/bin/codesign" && -f "$d/bin/xcodebuild" && -f "$d/repo/scripts/build.sh" && -f "$d/repo/scripts/check-toolchain.sh" ]] || return 1
  grep -q "SYNTH67890" "$d/bin/security" && [[ "$(cat "$d/repo/scripts/check-toolchain.sh")" == $'#!/bin/bash\nexit 0' ]]
}
sweep_old() {
  local d name rest pid
  for d in "$tmp_root"/tmp.* "$tmp_root"/"$base_prefix"*; do
    name="${d##*/}"
    if [[ "$name" == "$base_prefix"* ]]; then
      # Named by this script's scheme: `ytmuse-build-signing.<pid>.<random>`. Anything else under the prefix is not ours to judge: left alone.
      rest="${name#"$base_prefix"}"; pid="${rest%%.*}"
      [[ "$rest" == *.* && "$pid" =~ ^[0-9]+$ && "$pid" != "$$" ]] || continue
      ps -p "$pid" > /dev/null 2>&1 && continue          # the creating process is still running (or the pid is reused by a live one): leave it
      [[ ! -L "$d" && -O "$d" ]] && rm -rf "$d"
    else
      [[ -d "$d" && "$d" -ot "$session_marker" ]] || continue
      [[ -z "$(find "$d" -maxdepth 0 -mmin -10 2>/dev/null)" ]] || continue
      if is_ours_legacy "$d"; then rm -rf "$d"; fi
    fi
  done
}
sweep_old
setup() {
  work="$(mktemp -d "$tmp_root/${prefix}XXXXXX")"; made+=("$work"); mkdir -p "$work/repo/scripts" "$work/repo/App" "$work/bin"
  cp "$repo/scripts/build.sh" "$work/repo/scripts/build.sh"; cp "$repo/scripts/sign-bundle.sh" "$work/repo/scripts/sign-bundle.sh"
  mkdir -p "$work/repo/Extensions"
  cp "$repo/App/NativeMusic.entitlements" "$repo/App/NativeMusic-adhoc.entitlements" "$work/repo/App/"
  cp "$repo/Extensions/NativeMusicWidget.entitlements" "$repo/Extensions/NativeMusicWidget-adhoc.entitlements" "$work/repo/Extensions/"
  printf '#!/bin/bash\nexit 0\n' > "$work/repo/scripts/check-toolchain.sh"; chmod +x "$work/repo/scripts/check-toolchain.sh"
  cat > "$work/bin/xcodebuild" <<'X'
#!/bin/bash
echo "xcodebuild embed=${YTMUSE_EMBED_WIDGET:-unset} $*" >> "$SHIM_LOG.xcodebuild"
for ((i=1;i<=$#;i++)); do [[ "${!i}" == -derivedDataPath ]] && { j=$((i+1)); app="${!j}/Build/Products/Release/YTMuse.app"; mkdir -p "$app/Contents"
  printf '<?xml version="1.0"?><plist version="1.0"><dict><key>YTMuseAppGroup</key><string>local.native-music.development</string></dict></plist>' > "$app/Contents/Info.plist"
  if [[ "${YTMUSE_EMBED_WIDGET:-NO}" == YES ]]; then mkdir -p "$app/Contents/PlugIns/NativeMusicWidget.appex/Contents"; cp "$app/Contents/Info.plist" "$app/Contents/PlugIns/NativeMusicWidget.appex/Contents/Info.plist"; fi; }; done
echo "** BUILD SUCCEEDED **"
X
  # security: one Apple Development identity and one Developer ID identity.
  cat > "$work/bin/security" <<'X'
#!/bin/bash
echo '  1) 1111111111111111111111111111111111111111 "Apple Development: Synthetic Person (SYNTH12345)"'
echo '  2) 2222222222222222222222222222222222222222 "Developer ID Application: Synthetic Org (SYNTH67890)"'
echo '     2 valid identities found'
X
  # codesign: records calls; reports whatever authority SHIM_AUTHORITY says.
  cat > "$work/bin/codesign" <<'X'
#!/bin/bash
echo "codesign $*" >> "$SHIM_LOG"
if [[ " $* " == *" -dvv "* ]]; then echo "Authority=${SHIM_AUTHORITY}" >&2; echo "TeamIdentifier=SYNTH12345" >&2; fi
exit 0
X
  chmod +x "$work/bin/"*
  export SHIM_LOG="$work/codesign.log"; : > "$SHIM_LOG"
}
run() { (cd "$work/repo" && PATH="$work/bin:/usr/bin:/bin" BUILD_DIR="$work/derived" YTMUSE_CODESIGN_IDENTITY="$1" bash scripts/build.sh) > "$work/out.log" 2>&1; }

# 1. A Developer ID SHA-1 is refused before any signing.
setup; set +e; run 2222222222222222222222222222222222222222; status=$?; set -e
[[ $status == 65 ]] || fail "developer-id sha1 exit $status"
! grep -q -- "--sign" "$SHIM_LOG" || fail "bundle was signed with a refused identity"
echo "ok refused Developer ID SHA-1 before signing (exit 65, no codesign --sign)"

# 2. An unknown SHA-1 is refused before signing.
setup; set +e; run 3333333333333333333333333333333333333333; status=$?; set -e
[[ $status == 65 ]] && ! grep -q -- "--sign" "$SHIM_LOG" || fail "unknown sha1"
echo "ok refused unknown SHA-1 before signing"

# 3. A non-Development name is refused by pattern (exit 64), before building.
setup; set +e; run "Developer ID Application: Synthetic Org (SYNTH67890)"; status=$?; set -e
[[ $status == 64 ]] || fail "name pattern exit $status"
echo "ok refused non-Development name by pattern (exit 64)"

# 4. If the signed result is not Apple Development anyway, ad-hoc is restored.
setup; export SHIM_AUTHORITY="Developer ID Application: Synthetic Org (SYNTH67890)"; set +e; run 1111111111111111111111111111111111111111; status=$?; set -e
[[ $status == 65 ]] || fail "post-check exit $status"
tail -n 2 "$SHIM_LOG" | grep -q -- "--sign - " || fail "ad-hoc not restored: $(cat "$SHIM_LOG")"
echo "ok restored ad-hoc signing after a refused authority (exit 65)"

# 5. A valid Apple Development SHA-1 signs; output never names the identity or team.
setup; export SHIM_AUTHORITY="Apple Development: Synthetic Person (SYNTH12345)"; set +e; run 1111111111111111111111111111111111111111; status=$?; set -e
[[ $status == 0 ]] || fail "valid identity exit $status: $(cat "$work/out.log")"
grep -q "signed with the configured identity (extension first)" "$work/out.log" || fail "fixed message missing"
grep -q "embed=YES" "$SHIM_LOG.xcodebuild" || fail "a build with an identity must embed the widget extension"
# inner to outer: the extension is signed before the app
ext_line="$(grep -n -- "--entitlements" "$SHIM_LOG" | grep -n "NativeMusicWidget.appex" | head -1 | cut -d: -f1)"; app_line="$(grep -n -- "--entitlements" "$SHIM_LOG" | grep -n "YTMuse.app$" | head -1 | cut -d: -f1)"
[[ -n "$ext_line" && -n "$app_line" && "$ext_line" -lt "$app_line" ]] || fail "extension not signed before the app: $(cat "$SHIM_LOG")"
! grep -Eq "SYNTH12345|Synthetic Person|1111111111" "$work/out.log" || fail "identity or team printed"
echo "ok signed with a valid Apple Development identity; printed neither identity nor team"
# 6. Without an identity nothing is embedded and nothing is signed (an ad-hoc build never touches the App Group).
setup; set +e; (cd "$work/repo" && PATH="$work/bin:/usr/bin:/bin" BUILD_DIR="$work/derived" bash scripts/build.sh) > "$work/out.log" 2>&1; status=$?; set -e
[[ $status == 0 ]] || fail "unsigned build exit $status: $(cat "$work/out.log")"
grep -q "embed=NO" "$SHIM_LOG.xcodebuild" && ! grep -q "embed=YES" "$SHIM_LOG.xcodebuild" || fail "an unsigned build must not embed the extension"
! grep -q -- "--sign" "$SHIM_LOG" || fail "an unsigned build must sign nothing itself"
[[ ! -e "$work/derived/Build/Products/Release/YTMuse.app/Contents/PlugIns" ]] || fail "an unsigned build embedded a plug-in"
echo "ok no identity: the extension is not embedded and nothing is signed here"
echo PASS
