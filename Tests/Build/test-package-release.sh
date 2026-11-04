#!/bin/bash
# W30 (T30.4, SEC10, BUILD04): scripts/package-release.sh over SHIMMED tools. Nothing here builds Release, signs anything, notarizes or reaches a keychain: xcodebuild,
# codesign, security, xcrun, hdiutil, ditto, spctl and git are stand-ins that record their calls and make a fake bundle. The feed tool and the checks are the real ones, on a
# throwaway key made in this run's own temporary folder. Like W25's signing test, the scratch folder carries this run's pid and is removed when the run ends.
set -euo pipefail
repo="$(cd "$(dirname "$0")/../.." && pwd)"
fail() { echo "FAIL $*"; exit 1; }
tmp_root="${TMPDIR:-/tmp}"; tmp_root="${tmp_root%/}"
base="$(mktemp -d "$tmp_root/ytmuse-package-release.$$.XXXXXX")"
trap 'rm -rf "$base"' EXIT
mkdir -p "$base/bin" "$base/keys"
export SHIM_LOG="$base/calls.log"; : > "$SHIM_LOG"
cat > "$base/bin/git" <<'X'
#!/bin/bash
case "$1" in
  diff) exit "${SHIM_GIT_DIRTY:-0}";;
  describe) echo "${SHIM_GIT_TAG:-v1.2.0}";;
  rev-parse) if [[ "$2" == HEAD ]]; then echo 0123456789abcdef0123456789abcdef01234567; else exec /usr/bin/git "$@"; fi;;
  *) exec /usr/bin/git "$@";;
esac
X
cat > "$base/bin/security" <<'X'
#!/bin/bash
echo '  1) 1111111111111111111111111111111111111111 "Apple Development: Synthetic Person (SYNTH12345)"'
echo '  2) 2222222222222222222222222222222222222222 "Developer ID Application: Synthetic Org (SYNTH67890)"'
echo '     2 valid identities found'
# TH2: a long listing after the matching line (a Mac with many identities). A reader that stops at the first match (`grep -q`) closes the pipe while this is still writing.
if [[ -n "${SHIM_SECURITY_PAD:-}" ]]; then for ((i = 1; i <= 4000; i++)); do echo "     padding line $i of a long identity listing, written after the match so an early-exiting reader closes the pipe"; done; fi
X
cat > "$base/bin/xcodebuild" <<'X'
#!/bin/bash
echo "xcodebuild $*" >> "$SHIM_LOG"
for ((i=1;i<=$#;i++)); do [[ "${!i}" == -derivedDataPath ]] && { j=$((i+1)); d="${!j}"; }; done
app_id=unset.app; widget_id=unset.widget
for arg in "$@"; do
  case "$arg" in
    YTMUSE_APP_BUNDLE_IDENTIFIER=*) app_id="${arg#*=}";;
    YTMUSE_WIDGET_BUNDLE_IDENTIFIER=*) widget_id="${arg#*=}";;
  esac
done
app="$d/Build/Products/Release/YTMuse.app"; mkdir -p "$app/Contents/MacOS" "$app/Contents/PlugIns/NativeMusicWidget.appex/Contents/MacOS"
plist='<?xml version="1.0"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>%s</string><key>CFBundleShortVersionString</key><string>1.2.0</string><key>YTMuseAppGroup</key><string>x</string></dict></plist>'
printf "$plist" "${SHIM_BAD_APP_ID:-$app_id}" > "$app/Contents/Info.plist"; printf "$plist" "${SHIM_BAD_WIDGET_ID:-$widget_id}" > "$app/Contents/PlugIns/NativeMusicWidget.appex/Contents/Info.plist"
printf '#!/bin/bash\nexit 0\n' > "$app/Contents/MacOS/YTMuse"
printf '#!/bin/bash\nexit 0\n' > "$app/Contents/PlugIns/NativeMusicWidget.appex/Contents/MacOS/NativeMusicWidget"
if [[ -n "${SHIM_LEAK_BUILD_PATH:-}" ]]; then printf '# %s\n' "$HOME" >> "$app/Contents/MacOS/YTMuse"; fi
echo "** BUILD SUCCEEDED **"
X
cat > "$base/bin/strip" <<'X'
#!/bin/bash
echo "strip $*" >> "$SHIM_LOG"
X
cat > "$base/bin/codesign" <<'X'
#!/bin/bash
echo "codesign $*" >> "$SHIM_LOG"
if [[ " $* " == *" -dvv "* ]]; then echo "Authority=${SHIM_AUTHORITY:-Developer ID Application: Synthetic Org (SYNTH67890)}" >&2; echo "TeamIdentifier=SYNTH67890" >&2; fi
if [[ " $* " == *" --entitlements "* ]]; then
  for ((i=1;i<=$#;i++)); do [[ "${!i}" == --entitlements ]] && { j=$((i+1)); entitlements="${!j}"; }; done
  kind=widget; [[ "${*: -1}" == *YTMuse.app ]] && kind=app
  cp "${*: -1}/Contents/Info.plist" "$SHIM_LOG.$kind-info.plist"
  cp "$entitlements" "$SHIM_LOG.$kind.entitlements"
fi
exit 0
X
cat > "$base/bin/xcrun" <<'X'
#!/bin/bash
echo "xcrun $*" >> "$SHIM_LOG"
[[ "$1" == --sdk ]] && { /usr/bin/xcrun "$@"; exit $?; }
exit 0
X
cat > "$base/bin/hdiutil" <<'X'
#!/bin/bash
echo "hdiutil $*" >> "$SHIM_LOG"
out="${*: -1}"; src=""; for ((i=1;i<=$#;i++)); do [[ "${!i}" == -srcfolder ]] && { j=$((i+1)); src="${!j}"; }; done
/usr/bin/tar -cf "$out" -C "$src" .
X
cat > "$base/bin/ditto" <<'X'
#!/bin/bash
echo "ditto $*" >> "$SHIM_LOG"; printf 'zip' > "${*: -1}"
X
cat > "$base/bin/spctl" <<'X'
#!/bin/bash
echo "spctl $*" >> "$SHIM_LOG"
X
chmod +x "$base/bin/"*
# A throwaway feed key, outside the repository (this run's temp folder).
tool="$repo/scripts/bin/swift run --package-path $repo/Packages/NativeMusic --quiet FeedTool"
$tool keygen --private-out "$base/keys/feed.key" --public-out "$base/keys/feed.pub" > /dev/null
pub="$(tr -d '\n' < "$base/keys/feed.pub")"
env_ok() { export YTMUSE_DEVELOPER_ID="Developer ID Application: Synthetic Org (SYNTH67890)" YTMUSE_NOTARY_PROFILE=synthetic-profile YTMUSE_FEED_KEY="$base/keys/feed.key" YTMUSE_FEED_PUBLIC_KEY="$pub" YTMUSE_UPDATE_REPOSITORY=example-owner/example-repo; }
run() { local out="$1"; shift; (cd "$repo" && PATH="$base/bin:$PATH" bash scripts/package-release.sh "$@" --out "$out") > "$base/out.log" 2>&1; }
expect_status() { local want=$1; shift; set +e; run "$@"; local s=$?; set -e; [[ $s == "$want" ]] || fail "expected exit $want, got $s for: $* -- $(tail -3 "$base/out.log")"; }
fresh() { : > "$SHIM_LOG"; rm -rf "$base/release"; }

# 1. Arguments and environment are refused before anything happens. Every refusal case runs with --dry-run: even if one of these guards were broken, the run could only print the plan,
# never build, sign or write anything (operator rule: a test of a guard must not be able to perform the protected action).
env_ok; fresh
expect_status 64 "$base/release" --version 1.2 --build 120 --dry-run; echo "ok bad version refused"
expect_status 64 "$base/release" --version 1.2.0 --build 0 --dry-run; echo "ok bad build refused"
set +e; (cd "$repo" && PATH="$base/bin:$PATH" bash scripts/package-release.sh --version 1.2.0 --build 120 --dry-run --out relative/dir) > "$base/out.log" 2>&1; s=$?; set -e; [[ $s == 64 ]] || fail "relative out"; echo "ok relative --out refused"
(unset YTMUSE_FEED_KEY; expect_status 66 "$base/release" --version 1.2.0 --build 120 --dry-run); echo "ok missing credentials refused (exit 66)"
(export YTMUSE_DEVELOPER_ID="Apple Development: Synthetic Person (SYNTH12345)"; expect_status 65 "$base/release" --version 1.2.0 --build 120 --dry-run); echo "ok a development identity cannot make a release"
(export YTMUSE_DEVELOPER_ID=1111111111111111111111111111111111111111; expect_status 65 "$base/release" --version 1.2.0 --build 120 --dry-run); echo "ok a development SHA-1 refused"
for bad in local.native-music.development 'not a bundle' 'com..example' 'com.example/bad'; do
  (export YTMUSE_RELEASE_BUNDLE_ID="$bad"; expect_status 65 "$base/release" --version 1.2.0 --build 120 --dry-run)
done
echo "ok development and malformed release bundle identifiers refused"
chmod 644 "$base/keys/feed.key"; expect_status 66 "$base/release" --version 1.2.0 --build 120 --dry-run; chmod 600 "$base/keys/feed.key"; echo "ok a group-readable feed key refused"
mkdir -p "$base/gitkey" && (cd "$base/gitkey" && /usr/bin/git init -q) && cp "$base/keys/feed.key" "$base/gitkey/feed.key"; chmod 600 "$base/gitkey/feed.key"
(export YTMUSE_FEED_KEY="$base/gitkey/feed.key"; expect_status 65 "$base/release" --version 1.2.0 --build 120 --dry-run); echo "ok a feed key inside a git work tree refused"
mkdir -p "$base/exists"; expect_status 65 "$base/exists" --version 1.2.0 --build 120 --dry-run; echo "ok an existing --out refused"
expect_status 65 "$repo/should-not-be-created" --version 1.2.0 --build 120 --dry-run; [[ ! -e "$repo/should-not-be-created" ]] || fail "created a directory inside the repository"; echo "ok an --out inside the repository refused"
[[ ! -s "$SHIM_LOG" ]] || fail "a refusal still called a tool: $(cat "$SHIM_LOG")"

# 2. A dry run validates and prints the plan, builds, signs and writes nothing, and names no identity.
fresh; expect_status 0 "$base/release" --version 1.2.0 --build 120 --dry-run
[[ ! -e "$base/release" ]] || fail "dry run created the output directory"
! grep -Eq "^(xcodebuild|codesign|hdiutil|xcrun)" "$SHIM_LOG" || fail "dry run called a build or signing tool"
grep -q "dry run" "$base/out.log" && ! grep -Eq "Synthetic|SYNTH|synthetic-profile|feed.key" "$base/out.log" || fail "dry run printed a credential name"
echo "ok dry run builds, signs and writes nothing, and prints no credential"

# 2b. TH2 (W30 D-L3): the identity check must not depend on how much the keychain tool writes after the match. `security ... | grep -q` under pipefail failed intermittently (the
# writer is killed by SIGPIPE when grep -q exits at its first match, and the pipeline reports 141). The listing here is ~400 KB, far more than a pipe holds, so the old form fails
# EVERY time; the repeat count also covers the SHA-1 branch and a listing that fails.
for n in $(seq 1 25); do (export SHIM_SECURITY_PAD=1; expect_status 0 "$base/release" --version 1.2.0 --build 120 --dry-run) || fail "named identity, long listing, run $n"; done
for n in $(seq 1 10); do (export SHIM_SECURITY_PAD=1 YTMUSE_DEVELOPER_ID=2222222222222222222222222222222222222222; expect_status 0 "$base/release" --version 1.2.0 --build 120 --dry-run) || fail "SHA-1 identity, long listing, run $n"; done
(export SHIM_SECURITY_PAD=1 YTMUSE_DEVELOPER_ID="Developer ID Application: Someone Else (SYNTH99999)"; expect_status 65 "$base/release" --version 1.2.0 --build 120 --dry-run); echo "ok an identity that is not in a long listing is still refused"
echo "ok the identity check is the same on every one of 35 runs over a long keychain listing"

# 3. The tree must be clean and HEAD must be exactly the tag.
fresh; (export SHIM_GIT_DIRTY=1; expect_status 66 "$base/release" --version 1.2.0 --build 120); echo "ok an unclean tree refused"
fresh; (export SHIM_GIT_TAG=v9.9.9; expect_status 66 "$base/release" --version 1.2.0 --build 120); echo "ok a HEAD that is not the tag refused"

# 4. The whole flow over shims.
fresh; expect_status 0 "$base/release" --version 1.2.0 --build 120
out="$base/release"
for f in YTMuse-1.2.0.dmg YTMuse-1.2.0.dmg.sha256 sbom.cdx.json release-notes.md feed.json binary-inventory.json; do [[ -s "$out/$f" ]] || fail "missing output $f"; done
grep -q "MARKETING_VERSION=1.2.0" "$SHIM_LOG" && grep -q "CURRENT_PROJECT_VERSION=120" "$SHIM_LOG" && grep -q "YTMUSE_EMBED_WIDGET=YES" "$SHIM_LOG" || fail "version, build or embed not passed to xcodebuild"
grep -q -- "-configuration Release" "$SHIM_LOG" && grep -q "arch=arm64" "$SHIM_LOG" || fail "not a Release arm64 build"
ext=$(grep -n -- "--entitlements" "$SHIM_LOG" | grep "appex$" | head -1 | cut -d: -f1); app=$(grep -n -- "--entitlements" "$SHIM_LOG" | grep "YTMuse.app$" | head -1 | cut -d: -f1)
[[ -n "$ext" && -n "$app" && "$ext" -lt "$app" ]] || fail "the extension was not signed before the app"
stripped=$(grep -n '^strip -S ' "$SHIM_LOG" | head -1 | cut -d: -f1)
[[ -n "$stripped" && "$stripped" -lt "$ext" ]] || fail "debug information must be stripped before signing"
grep -- "--entitlements" "$SHIM_LOG" | grep -q -- "--options runtime" && grep -- "--entitlements" "$SHIM_LOG" | grep -q -- "--timestamp " || fail "hardened runtime and a secure timestamp are required"
! grep -q -- "--timestamp=none" <(grep -v "probe.appex" "$SHIM_LOG") || fail "a release signature without a secure timestamp"
[[ "$(grep -c '^xcrun notarytool submit' "$SHIM_LOG")" == 2 && "$(grep -c '^xcrun stapler staple' "$SHIM_LOG")" == 2 ]] || fail "app and DMG must each be notarized and stapled"
grep '^xcrun notarytool' "$SHIM_LOG" | grep -q -- "--keychain-profile synthetic-profile --wait" || fail "notarytool must use the keychain profile and wait"
grep -q '^spctl -a -t open' "$SHIM_LOG" || fail "the DMG was not assessed by Gatekeeper"
grep -q 'YTMUSE_APP_BUNDLE_IDENTIFIER=com.github.example-owner.example-repo' "$SHIM_LOG" || fail "production app id not passed"
grep -q 'YTMUSE_WIDGET_BUNDLE_IDENTIFIER=com.github.example-owner.example-repo.widget' "$SHIM_LOG" || fail "production widget id not passed"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$SHIM_LOG.app-info.plist")" == com.github.example-owner.example-repo ]] || fail "wrong app id"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$SHIM_LOG.widget-info.plist")" == com.github.example-owner.example-repo.widget ]] || fail "wrong widget id"
for kind in app widget; do
  [[ "$(/usr/libexec/PlistBuddy -c 'Print :YTMuseAppGroupSuffix' "$SHIM_LOG.$kind-info.plist")" == com.github.example-owner.example-repo ]] || fail "production suffix not pinned"
  [[ "$(/usr/libexec/PlistBuddy -c 'Print :YTMuseAppGroup' "$SHIM_LOG.$kind-info.plist")" == SYNTH67890.com.github.example-owner.example-repo ]] || fail "wrong production group"
  [[ "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.application-groups:0' "$SHIM_LOG.$kind.entitlements")" == SYNTH67890.com.github.example-owner.example-repo ]] || fail "wrong group entitlement"
done
# the pinned update configuration reached the app's Info.plist before signing
info="$SHIM_LOG.app-info.plist"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :YTMuseUpdateRepository' "$info")" == example-owner/example-repo ]] || fail "repository not pinned"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :YTMuseUpdateFeedURL' "$info")" == "https://github.com/example-owner/example-repo/releases/latest/download/feed.json" ]] || fail "feed URL not pinned"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :YTMuseUpdatePublicKeys:0' "$info")" == "$pub" ]] || fail "public key not pinned"
! /usr/bin/grep -q "BEGIN\|feed.key" "$info" || fail "private key material in the app"
# the checksum and the feed promise the final DMG's bytes
[[ "$(cd "$out" && shasum -a 256 -c YTMuse-1.2.0.dmg.sha256 2>&1)" == "YTMuse-1.2.0.dmg: OK" ]] || fail "checksum does not verify"
python3 - "$out" <<'PY' || fail "the feed does not describe the final DMG"
import base64, hashlib, json, sys
out = sys.argv[1]
feed = json.load(open(out + "/feed.json")); payload = json.loads(base64.b64decode(feed["payload"]))
release = payload["releases"][0]
dmg = open(out + "/YTMuse-1.2.0.dmg", "rb").read()
assert release["asset"]["sha256"] == hashlib.sha256(dmg).hexdigest() and release["asset"]["length"] == len(dmg)
assert release["version"] == "1.2.0" and release["build"] == 120 and payload["sequence"] == 120
assert release["provenance"]["commit"] == "0123456789abcdef0123456789abcdef01234567" and release["provenance"]["tag"] == "v1.2.0"
assert release["provenance"]["sbomSHA256"] == hashlib.sha256(open(out + "/sbom.cdx.json", "rb").read()).hexdigest()
PY
! grep -Eq "Synthetic|SYNTH67890|synthetic-profile" "$base/out.log" || fail "an identity, team or profile name was printed"
! grep -q "$(head -c 20 "$base/keys/feed.key")" "$base/out.log" "$out"/* 2>/dev/null || fail "the feed private key was written or printed"
echo "ok whole flow: Release arm64, extension before app, hardened runtime, secure timestamp, notarize and staple both, pins in Info.plist, feed describes the final DMG"

# 5. A signature that does not end up Developer ID is refused before the DMG.
fresh; (export SHIM_AUTHORITY="Apple Development: Synthetic Person (SYNTH12345)"; expect_status 65 "$base/release" --version 1.2.0 --build 120)
! grep -q '^hdiutil' "$SHIM_LOG" && [[ ! -e "$base/release/YTMuse-1.2.0.dmg" ]] || fail "a DMG was made from a wrongly signed app"
echo "ok a wrongly signed app stops before the DMG"
fresh; (export SHIM_BAD_APP_ID=local.native-music.development; expect_status 65 "$base/release" --version 1.2.0 --build 120)
! grep -q '^hdiutil\|^xcrun notarytool' "$SHIM_LOG" || fail "a mismatched app identity reached distribution"
fresh; (export SHIM_BAD_WIDGET_ID=local.native-music.development.widget; expect_status 65 "$base/release" --version 1.2.0 --build 120)
! grep -q '^hdiutil\|^xcrun notarytool' "$SHIM_LOG" || fail "a mismatched widget identity reached distribution"
echo "ok mismatched production app/widget identities stop before signing and notarization"
fresh; (export SHIM_LEAK_BUILD_PATH=1; expect_status 65 "$base/release" --version 1.2.0 --build 120)
! grep -q '^hdiutil\|^xcrun notarytool' "$SHIM_LOG" || fail "private build paths reached distribution"
echo "ok private build paths stop before notarization and packaging"
echo PASS
