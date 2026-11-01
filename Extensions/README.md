# Extension boundaries

**W25 widget.** `Extensions/Sources/NativeMusicWidget` is the one app extension: a WidgetKit widget (small and medium) built as the Xcode target `NativeMusicWidget` and embedded in `Contents/PlugIns/` by the app target. Its code is almost entirely the `WidgetShared` library of `Packages/NativeMusic` (the snapshot schema and store, the timeline provider, the views, the button intent), so the same code is exercised by `scripts/test.sh --suite T25`. The extension is sandboxed and holds exactly one entitlement besides the sandbox: the App Group `group.local.native-music.development`. It has no network client entitlement, no Keychain access group and no file access of its own, and it contains no player. Contract and limits: `Docs/Widgets-Spotlight.md`. `scripts/check-widget.py` reads the built bundle's entitlements and linkage.

**W24 intents** run in the app process (`Docs/Intents.md`); `NativeMusicIntentSupport` stays an empty scaffold that registers nothing.

Embedding is switchable: `YTMUSE_EMBED_WIDGET=NO` (a build setting) leaves the extension out of the app bundle, which the UI-test runs use so a worktree build never offers a widget to the system. The default embeds it.
