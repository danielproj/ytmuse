#!/bin/bash
# W30 (BUILD04, BUILD06, SEC10): the signed-package script. Builds the arm64 Release app, signs it with a Developer ID identity (hardened runtime, inner code
# first), makes the DMG, notarizes and staples, writes the checksum, the SBOM, the binary inspection and the signed update feed, into a NEW directory.
#
#   scripts/package-release.sh --version 1.2.0 --build 120 --out /absolute/new/dir [--dry-run]
#
# Credentials come ONLY from the environment and are never printed, written or committed:
#   YTMUSE_DEVELOPER_ID        a "Developer ID Application: …" identity name, or its 40-hex SHA-1, in the caller's keychain
#   YTMUSE_NOTARY_PROFILE      the name of a notarytool keychain profile (xcrun notarytool store-credentials)
#   YTMUSE_FEED_KEY            path of the feed signing key file (ytmuse-feed keygen), mode 0600, outside any git work tree
#   YTMUSE_FEED_PUBLIC_KEY     the matching public key (base64), pinned into the app's Info.plist
#   YTMUSE_UPDATE_REPOSITORY   "owner/name" of the GitHub repository the releases are published to
#   YTMUSE_RELEASE_BUNDLE_ID   optional production id; defaults to com.github.<owner>.<repository> (lowercase, underscores become hyphens)
# Operator rule: lanes and critics never run this script for real (it accesses real signing/notarization credentials). --dry-run validates the
# arguments and the environment and prints the plan without building, signing or writing anything; Tests/Build/test-package-release.sh runs the whole flow over
# shimmed tools. Nothing here publishes, uploads or contacts a service other than Apple's notary service, and only when run for real by the account holder.
set -euo pipefail
cd "$(dirname "$0")/.."
version=""; build=""; out=""; dry=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --version) version="${2:-}"; shift 2;;
    --build) build="${2:-}"; shift 2;;
    --out) out="${2:-}"; shift 2;;
    --dry-run) dry=1; shift;;
    *) echo "unknown argument: $1" >&2; exit 64;;
  esac
done
die() { echo "package-release: $1" >&2; exit "${2:-64}"; }
[[ "$version" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-[0-9A-Za-z.-]+)?$ ]] || die '--version must be a semantic version such as 1.2.0'
[[ "$build" =~ ^[1-9][0-9]*$ ]] || die '--build must be a positive integer, larger than every earlier release build'
[[ -n "$out" && "$out" == /* ]] || die '--out must be an absolute path'
[[ ! -e "$out" ]] || die "refusing: $out already exists" 65
case "$out/" in "$PWD"/*) die 'refusing: --out must be outside the repository' 65;; esac
identity="${YTMUSE_DEVELOPER_ID:-}"; profile="${YTMUSE_NOTARY_PROFILE:-}"; feed_key="${YTMUSE_FEED_KEY:-}"; public_key="${YTMUSE_FEED_PUBLIC_KEY:-}"; repo="${YTMUSE_UPDATE_REPOSITORY:-}"
[[ -n "$identity" && -n "$profile" && -n "$feed_key" && -n "$public_key" && -n "$repo" ]] || die 'YTMUSE_DEVELOPER_ID, YTMUSE_NOTARY_PROFILE, YTMUSE_FEED_KEY, YTMUSE_FEED_PUBLIC_KEY and YTMUSE_UPDATE_REPOSITORY must all be set' 66
[[ "$identity" =~ ^Developer\ ID\ Application:\ .+$ || "$identity" =~ ^[0-9A-Fa-f]{40}$ ]] || die 'YTMUSE_DEVELOPER_ID must be a "Developer ID Application: …" identity or its SHA-1 (a development identity cannot make a release)' 65
[[ "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || die 'YTMUSE_UPDATE_REPOSITORY must look like owner/name'
bundle_id="${YTMUSE_RELEASE_BUNDLE_ID:-}"
if [[ -z "$bundle_id" ]]; then
  bundle_id="com.github.$(printf '%s' "$repo" | tr '[:upper:]' '[:lower:]' | tr '/_' '.-')"
fi
[[ "$bundle_id" =~ ^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+){2,}$ ]] || die 'YTMUSE_RELEASE_BUNDLE_ID must be a reverse-DNS bundle identifier' 65
[[ "$bundle_id" != local.* ]] || die 'release packaging refuses a local development bundle identifier' 65
widget_id="$bundle_id.widget"
[[ "$public_key" =~ ^[A-Za-z0-9+/]{43}=$ ]] || die 'YTMUSE_FEED_PUBLIC_KEY must be a base64 Ed25519 public key'
[[ -f "$feed_key" && ! -L "$feed_key" ]] || die 'YTMUSE_FEED_KEY must name a regular file' 66
[[ "$(stat -f '%Lp' "$feed_key")" =~ ^(400|600)$ ]] || die 'YTMUSE_FEED_KEY must not be readable by group or others (chmod 600)' 66
key_dir="$(cd "$(dirname "$feed_key")" && pwd -P)"
( cd "$key_dir" && git rev-parse --show-toplevel >/dev/null 2>&1 ) && die 'YTMUSE_FEED_KEY must be outside any git work tree' 65
# TH2 (W30 D-L3): read the identity list into a variable FIRST. `security find-identity | grep -q` under `pipefail` fails intermittently: grep -q exits at its first match, the
# writer can then be killed by SIGPIPE (status 141), and the pipeline reports that instead of grep's 0, so a valid identity was sometimes reported as missing.
identities="$(security find-identity -v -p codesigning)" || die 'the keychain identities could not be listed' 65
if [[ "$identity" =~ ^[0-9A-Fa-f]{40}$ ]]; then
  /usr/bin/awk -v id="$identity" '{ if (toupper($2) == toupper(id) && index($0, "Developer ID Application: ") > 0) found=1 } END { exit found ? 0 : 1 }' <<<"$identities" || die 'the SHA-1 does not name a valid Developer ID Application identity' 65
else
  grep -qF "\"$identity\"" <<<"$identities" || die 'the identity is not in the keychain' 65
fi
tag="v$version"
steps=("check the toolchain pin" "check the tree is clean and HEAD is tagged $tag" "build Release arm64 (version $version, build $build) with production app/widget identifiers" "pin the update repository and public key into the app's Info.plist"
       "sign the widget extension then the app: Developer ID, hardened runtime, secure timestamp" "inspect the bundle: no browser, Python or Node runtime" "notarize and staple the app"
       "make, sign, notarize and staple the DMG" "write the checksum, the SBOM and the release notes" "write and sign the update feed, then verify it as the app does")
if [[ $dry == 1 ]]; then
  echo "package-release (dry run): arguments and environment are valid; nothing was built, signed or written."
  n=1; for s in "${steps[@]}"; do echo "  $n. $s"; n=$((n+1)); done
  exit 0
fi
./scripts/check-toolchain.sh
git diff --quiet HEAD -- . || die 'the working tree has uncommitted changes' 66
[[ "$(git describe --exact-match --tags HEAD 2>/dev/null || true)" == "$tag" ]] || die "HEAD must be exactly the tag $tag" 66
commit="$(git rev-parse HEAD)"
mkdir -p "$out"
work="$(mktemp -d "${TMPDIR:-/tmp}/ytmuse-package-XXXXXX")"
scratch_ok=""
cleanup() { local s=$?; rm -rf "$work"; [[ -n "$scratch_ok" || $s -eq 0 ]] || echo "package-release failed; $out holds the partial output (nothing was published)" >&2; exit $s; }
trap cleanup EXIT
derived="$work/derived"
YTMUSE_EMBED_WIDGET=YES xcodebuild -project App/NativeMusic.xcodeproj -scheme NativeMusic -configuration Release -destination 'platform=macOS,arch=arm64' -derivedDataPath "$derived" \
  -disableAutomaticPackageResolution MARKETING_VERSION="$version" CURRENT_PROJECT_VERSION="$build" YTMUSE_EMBED_WIDGET=YES \
  YTMUSE_APP_BUNDLE_IDENTIFIER="$bundle_id" YTMUSE_WIDGET_BUNDLE_IDENTIFIER="$widget_id" build
app="$derived/Build/Products/Release/YTMuse.app"; appex="$app/Contents/PlugIns/NativeMusicWidget.appex"
[[ -d "$app" && -d "$appex" ]] || die 'the build did not produce the app with its widget extension' 65
plist="$app/Contents/Info.plist"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$plist")" == "$bundle_id" ]] || die 'the app build did not use the production bundle identifier' 65
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$appex/Contents/Info.plist")" == "$widget_id" ]] || die 'the widget build did not use the production bundle identifier' 65
# Debug sections contain the packaging Mac's source paths and do not belong in a download.
strip -S "$app/Contents/MacOS/YTMuse" "$appex/Contents/MacOS/NativeMusicWidget"
for key in YTMuseUpdateFeedURL YTMuseUpdatePublicKeys YTMuseUpdateRepository; do /usr/libexec/PlistBuddy -c "Delete :$key" "$plist" 2>/dev/null || true; done
/usr/libexec/PlistBuddy -c "Add :YTMuseUpdateFeedURL string https://github.com/$repo/releases/latest/download/feed.json" "$plist"
/usr/libexec/PlistBuddy -c "Add :YTMuseUpdateRepository string $repo" "$plist"
/usr/libexec/PlistBuddy -c "Add :YTMuseUpdatePublicKeys array" "$plist"
/usr/libexec/PlistBuddy -c "Add :YTMuseUpdatePublicKeys:0 string $public_key" "$plist"
# Team ID, learned from a throwaway signature of a copy (never printed or written to the repository); it fills the App Group prefix, as scripts/sign-bundle.sh does.
cp -R "$appex" "$work/probe.appex"
codesign --force --options runtime --timestamp=none --sign "$identity" "$work/probe.appex" >/dev/null 2>&1 || die 'the identity could not sign' 65
team="$(codesign -dvv "$work/probe.appex" 2>&1 | sed -n 's/^TeamIdentifier=//p' | head -1)"
[[ "$team" =~ ^[A-Z0-9]{10}$ ]] || die 'the identity carries no Team ID' 65
group="$team.$bundle_id"
expand() { sed "s/\$(TeamIdentifierPrefix)local.native-music.development/$group/g" "$1" > "$2"; }
expand App/NativeMusic.entitlements "$work/app.entitlements"; expand Extensions/NativeMusicWidget.entitlements "$work/widget.entitlements"
for p in "$plist" "$appex/Contents/Info.plist"; do
  /usr/libexec/PlistBuddy -c "Set :YTMuseAppGroup $group" "$p" 2>/dev/null || /usr/libexec/PlistBuddy -c "Add :YTMuseAppGroup string $group" "$p"
  /usr/libexec/PlistBuddy -c "Set :YTMuseAppGroupSuffix $bundle_id" "$p" 2>/dev/null || /usr/libexec/PlistBuddy -c "Add :YTMuseAppGroupSuffix string $bundle_id" "$p"
done
python3 - "$app" "$HOME" "$PWD" <<'PRIVACY'
from pathlib import Path
import sys
root = Path(sys.argv[1])
prefixes = [value.encode() for value in sys.argv[2:] if value and value != '/']
for path in root.rglob('*'):
    if path.is_file() and not path.is_symlink():
        data = path.read_bytes()
        if any(prefix in data for prefix in prefixes):
            print('package-release: private build path remains in the app bundle', file=sys.stderr)
            raise SystemExit(65)
PRIVACY
codesign --force --options runtime --timestamp --entitlements "$work/widget.entitlements" --sign "$identity" "$appex"
codesign --force --options runtime --timestamp --entitlements "$work/app.entitlements" --sign "$identity" "$app"
codesign --verify --deep --strict "$app"
[[ "$(codesign -dvv "$app" 2>&1 | /usr/bin/grep -m1 '^Authority=' || true)" == "Authority=Developer ID Application: "* ]] || die 'the app is not signed by a Developer ID Application identity' 65
python3 scripts/check-distribution.py --app "$app" --json "$out/binary-inventory.json"
# Notarize and staple the app (an app dragged out of the image keeps its ticket), then the DMG.
ditto -c -k --keepParent "$app" "$work/YTMuse-app.zip"
xcrun notarytool submit "$work/YTMuse-app.zip" --keychain-profile "$profile" --wait
xcrun stapler staple "$app"
stage="$work/dmg"; mkdir -p "$stage"; cp -R "$app" "$stage/YTMuse.app"; ln -s /Applications "$stage/Applications"
dmg="$out/YTMuse-$version.dmg"
hdiutil create -quiet -volname YTMuse -srcfolder "$stage" -format UDZO -fs APFS "$dmg"
codesign --force --timestamp --sign "$identity" "$dmg"
xcrun notarytool submit "$dmg" --keychain-profile "$profile" --wait
xcrun stapler staple "$dmg"
spctl -a -t open --context context:primary-signature "$dmg"
# From here the DMG is final: its hash is what the feed will promise.
( cd "$out" && shasum -a 256 "YTMuse-$version.dmg" > "YTMuse-$version.dmg.sha256" )
python3 scripts/make-sbom.py --out "$out/sbom.cdx.json"
cat > "$out/release-notes.md" <<NOTES
# YTMuse $version

Source tag \`$tag\`, commit \`$commit\`. arm64, macOS 27 or later, Developer ID signed and notarized.

The SHA-256 of the disk image is in \`YTMuse-$version.dmg.sha256\`. The software bill of materials is \`sbom.cdx.json\`. \`feed.json\` is the signed update feed.

This release is not a finished product: the service gates in the README (G01 to G09) are open. See the capability matrix for what works and what is not built.
NOTES
tool="${YTMUSE_FEED_TOOL:-scripts/bin/swift run --package-path Packages/NativeMusic --quiet FeedTool}"
now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"; expires="$(date -u -v+90d +%Y-%m-%dT%H:%M:%SZ)"
$tool make-payload --repository "$repo" --version "$version" --build "$build" --asset "$dmg" --sbom "$out/sbom.cdx.json" --commit "$commit" --sequence "$build" \
  --issued "$now" --published "$now" --expires "$expires" --out "$work/payload.json"
$tool sign --key "$feed_key" --payload "$work/payload.json" --out "$out/feed.json"
printf '%s\n' "$public_key" > "$work/feed.pub"
$tool verify --feed "$out/feed.json" --public-key "$work/feed.pub" --repository "$repo" --current-version 0.0.1 --current-build 1
scratch_ok=1
echo "package-release: wrote $(ls "$out" | wc -l | tr -d ' ') files to $out. Nothing was published; creating the GitHub release is a separate, manual step."
