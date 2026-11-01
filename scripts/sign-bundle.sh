#!/bin/bash
# W25 (F2): signs a built YTMuse.app that embeds the widget extension, INNER TO OUTER, with one identity.
#   scripts/sign-bundle.sh <YTMuse.app> <identity>
# Order: the extension first, then the app (the app's seal covers the extension's signature). Both use the same identity, so both carry the same Team ID.
# The entitlement files say `$(TeamIdentifierPrefix)local.native-music.development`; the prefix is the identity's Team ID, learned here from a throwaway signature of a COPY
# of the extension, expanded into private temporary files, and written into both Info.plists (`YTMuseAppGroup`, which is how the code learns its group id). The Team ID
# is never written into the repository, never printed, and the temporary files are removed on exit.
# ANY failure after the bundle starts to change (an Info.plist write, either signature, the verification, a refused identity or mismatched teams) runs a restore from an EXIT
# trap: the embedded extension is REMOVED (an ad-hoc build embeds none; check-intents.py rejects one), the app's Info.plist group key goes back to the build variable, and the
# app is signed ad hoc with the ad-hoc entitlements (no App Group). The result is exactly what an ad-hoc build is, and the script's own exit status is kept.
set -euo pipefail
cd "$(dirname "$0")/.."
app="${1:?usage: sign-bundle.sh <YTMuse.app> <identity>}"; identity="${2:?usage: sign-bundle.sh <YTMuse.app> <identity>}"
appex="$app/Contents/PlugIns/NativeMusicWidget.appex"
[[ -d "$appex" ]] || { echo 'sign-bundle: the app has no widget extension to sign (build with YTMUSE_EMBED_WIDGET=YES)' >&2; exit 66; }
scratch="$(mktemp -d "${TMPDIR:-/tmp}/ytmuse-sign-XXXXXX")"
armed=""; finished=""
restore() {
  local status=$?
  if [[ -n "$armed" && -z "$finished" ]]; then
    set +e
    /usr/libexec/PlistBuddy -c "Set :YTMuseAppGroup \$(TeamIdentifierPrefix)local.native-music.development" "$app/Contents/Info.plist" 2>/dev/null
    rm -rf "$appex"; rmdir "$app/Contents/PlugIns" 2>/dev/null
    codesign --force --sign - --entitlements App/NativeMusic-adhoc.entitlements "$app" >/dev/null 2>&1
    echo 'sign-bundle: signing did not complete; restored the bundle to ad hoc with no widget extension and no App Group' >&2
    [[ $status -ne 0 ]] || status=65
  fi
  rm -rf "$scratch"
  exit $status
}
trap restore EXIT
# 1. The identity's team, from a signature of a copy (the real extension is signed once, with its final entitlements).
cp -R "$appex" "$scratch/probe.appex"
codesign --force --options runtime --timestamp=none --sign "$identity" "$scratch/probe.appex" >/dev/null 2>&1 || { echo 'sign-bundle: the identity could not sign' >&2; exit 65; }
team="$(codesign -dvv "$scratch/probe.appex" 2>&1 | sed -n 's/^TeamIdentifier=//p' | head -1)"
[[ "$team" =~ ^[A-Z0-9]{10}$ ]] || { echo 'sign-bundle: the identity carries no Team ID, so no App Group can be used' >&2; exit 65; }
# 2. The entitlements and Info.plists with the prefix filled in.
prefix="$team."
expand() { sed "s/\$(TeamIdentifierPrefix)/$prefix/g" "$1" > "$2"; }
expand App/NativeMusic.entitlements "$scratch/app.entitlements"
expand Extensions/NativeMusicWidget.entitlements "$scratch/widget.entitlements"
group="${prefix}local.native-music.development"
armed=1
for plist in "$app/Contents/Info.plist" "$appex/Contents/Info.plist"; do
  /usr/libexec/PlistBuddy -c "Set :YTMuseAppGroup $group" "$plist" 2>/dev/null || /usr/libexec/PlistBuddy -c "Add :YTMuseAppGroup string $group" "$plist"
done
# 3. Inner to outer.
sign() { codesign --force --options runtime --timestamp=none --entitlements "$1" --sign "$identity" "$2"; }
sign "$scratch/widget.entitlements" "$appex"
sign "$scratch/app.entitlements" "$app"
codesign --verify --deep --strict "$app"
authority() { codesign -dvv "$1" 2>&1 | /usr/bin/grep -m1 '^Authority=' || true; }
team_of() { codesign -dvv "$1" 2>&1 | sed -n 's/^TeamIdentifier=//p' | head -1; }
if [[ "$(authority "$app")" != "Authority=Apple Development: "* || "$(team_of "$app")" != "$team" || "$(team_of "$appex")" != "$team" ]]; then
  # Never leave the bundle signed with a refused identity or with two different teams: the EXIT trap restores it.
  echo 'sign-bundle: signed with an identity that is not Apple Development, or the app and the extension did not get the same team; refused' >&2
  exit 65
fi
finished=1
# Fixed text only: never print the identity name or team ID.
echo 'YTMuse.app and its widget extension signed with the configured identity (extension first)'
