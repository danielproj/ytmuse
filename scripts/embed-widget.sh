#!/bin/sh
# W25: the app target's last build phase. Puts the widget extension into Contents/PlugIns ONLY when YTMUSE_EMBED_WIDGET=YES, and takes it out otherwise.
# The default is NO: an ad-hoc, unsigned, test or worktree build never embeds an extension (so the system is never offered one from a build directory) and never
# touches the App Group. scripts/build.sh sets YES only when it is given a signing identity, and then signs the extension and the app itself (scripts/sign-bundle.sh).
# This phase does NOT sign anything: it runs before Xcode signs the app, which is what signs the nested debug dylib first (re-signing here made a clean build fail).
# Flipping the setting for one derived-data folder leaves a stale seal; use a separate BUILD_DIR when you embed.
set -eu
plugins="$TARGET_BUILD_DIR/$PLUGINS_FOLDER_PATH"
appex="$plugins/NativeMusicWidget.appex"
if [ "${YTMUSE_EMBED_WIDGET:-NO}" = YES ]; then
  mkdir -p "$plugins"
  rsync -a --delete "$BUILT_PRODUCTS_DIR/NativeMusicWidget.appex/" "$appex/"
else
  if [ -e "$appex" ]; then rm -rf "$appex"; rmdir "$plugins" 2>/dev/null || true; fi
fi
