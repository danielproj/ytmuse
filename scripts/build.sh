#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
./scripts/check-toolchain.sh
# Optional stable local signing (see Docs/Build.md). Ad-hoc stays the default.
# YTMUSE_CODESIGN_IDENTITY names an "Apple Development: …" certificate in the
# caller's own keychain (or its 40-hex SHA-1). Nothing personal lives in the repo.
identity="${YTMUSE_CODESIGN_IDENTITY:-}"
if [[ -n "$identity" ]]; then
  if [[ ! "$identity" =~ ^Apple\ Development:\ .+$ && ! "$identity" =~ ^[0-9A-Fa-f]{40}$ ]]; then
    echo 'YTMUSE_CODESIGN_IDENTITY must be an "Apple Development: …" identity name or its SHA-1 hash' >&2
    exit 64
  fi
fi
if [[ -n "$identity" ]]; then
  # L4: resolve the identity BEFORE signing. A SHA-1 (or name) must name a valid
  # code-signing identity whose certificate is "Apple Development: …"; anything
  # else is refused without ever signing the bundle with it.
  if ! security find-identity -v -p codesigning | /usr/bin/awk -v id="$identity" '
      { hash=$2; name=$0; sub(/^[^"]*"/, "", name); sub(/".*$/, "", name)
        if ((toupper(hash) == toupper(id) || name == id) && index(name, "Apple Development: ") == 1) found=1 }
      END { exit found ? 0 : 1 }'; then
    echo 'YTMUSE_CODESIGN_IDENTITY does not name a valid Apple Development code-signing identity' >&2
    exit 65
  fi
fi
derived="${BUILD_DIR:-$PWD/.build/xcode}"
# W25: the widget extension is embedded ONLY for a build that is going to be signed with an identity (it needs a Team-ID-prefixed App Group, which an ad-hoc build
# cannot have). Without an identity nothing is embedded and the app never touches the App Group.
embed=NO; [[ -n "$identity" ]] && embed=YES
YTMUSE_EMBED_WIDGET="$embed" xcodebuild -project App/NativeMusic.xcodeproj -scheme NativeMusic -configuration Release -destination 'platform=macOS,arch=arm64' -derivedDataPath "$derived" -disableAutomaticPackageResolution YTMUSE_EMBED_WIDGET="$embed" build "$@"
if [[ -n "$identity" ]]; then
  app="$derived/Build/Products/Release/YTMuse.app"
  # Sign inner to outer with the one identity (extension, then app), hardened runtime, the entitlements with the Team ID prefix filled in from the identity's team
  # (scripts/sign-bundle.sh). A stable designated requirement lets the login keychain keep trusting the app across rebuilds, so restoring the session at launch
  # needs no prompt. It refuses and restores ad-hoc signing for a non-Apple-Development identity or mismatched teams.
  ./scripts/sign-bundle.sh "$app" "$identity"
  codesign --verify --strict --verbose=2 "$app"
fi
