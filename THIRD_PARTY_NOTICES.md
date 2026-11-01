# Third-party notices

## Dependencies and what ships

YTMuse has **no third-party package dependency**: `Packages/NativeMusic/Package.resolved` records no pins and `toolchain.json` lists no external dependency. The app links only Apple's system frameworks (listed in the [SBOM](Docs/sbom.cdx.json)); the hidden YouTube Music player is the system WebKit, which is part of macOS and is not shipped. Nothing below is linked into, or shipped in, the app. The material below is *referenced, adapted or copied for tests*:

## ytmusicapi

- Source: https://github.com/sigma67/ytmusicapi at commit `4da34b68e68d33356860fbf5d4f0245655969b08`, licensed under the MIT licence.
- Two upstream files (the uploads mixin and the uploads parser) are kept as a pinned reference copy in `artifacts/harness/nodes/W19/reference/` (their hashes are in its `manifest.json`). They are read only by a test (`UploadsTests`) that compares the wire shapes of the native upload code with the reference. Nothing is linked, shipped or copied into product code.
- Upstream licence (captured from the same repository, `LICENSE`):

```
MIT License

Copyright (c) 2026 sigma67

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## Kaset

- Source: https://github.com/sozercan/kaset, inspected read-only at commit `4c59ff259d853f1cc328597f5adccf2a291c2fa7`. Nothing from Kaset was built, run, vendored or linked.
- Adapted into original YTMuse code (E01 lane M2):
  - `Packages/NativeMusic/Sources/AccountSession/WebSession/WebMusicSignIn.swift`:
    - `MusicSignInNavigation.passkeySuppressionSource` adapts the WebAuthn-removal user script from Kaset `Sources/Kaset/Services/WebKit/LoginPasskeySuppression.swift` (ADR-0033 in `docs/adr/0033-login-passkey-suppression.md`). Here it is narrowed to return unless the host is `accounts.google.com`, and it is off by default.
    - `MusicSignInNavigation.signInURL` follows the sign-in URL in Kaset `Sources/Kaset/Views/LoginWebView.swift`.
  - `Packages/NativeMusic/Sources/AccountSession/WebSession/MusicCookieSession.swift`:
    - `MusicCookieSession.allowedNames` reproduces the auth-cookie allowlist `authCookieNames` from Kaset `Sources/Kaset/Services/WebKit/WebKitManager+Cookies.swift`. YTMuse adds `PREF`, `SOCS`, `CONSENT`, `VISITOR_INFO1_LIVE` and `VISITOR_PRIVACY_METADATA`.
    - `SAPISIDHash`, and the preference for `__Secure-3PAPISID` over `SAPISID`, follow Kaset `Sources/Kaset/Services/API/InnerTubeSupport.swift` and `Sources/Kaset/Services/WebKit/WebKitManager+AuthMaterial.swift`.
  - `Packages/NativeMusic/Sources/YouTubeMusicAdapter/SignedMusic.swift`:
    - The `account/account_menu` header path (`actions[0].openPopupAction.popup.multiPageMenuRenderer.header.activeAccountHeaderRenderer`) follows Kaset `Sources/APIExplorer/main.swift`.
    - The `channelHandle.runs` and `accountPhoto.thumbnails` shapes match Kaset `Sources/Kaset/Services/API/Parsers/AccountsListParser.swift`, which parses `account/accounts_list`, not `account_menu`.
    - The library grid/shelf renderer names follow Kaset `Sources/Kaset/Services/API/Parsers/LibraryContentParser.swift`.
  - These parsers and the request code were re-implemented, not copied.
- Adapted into original YTMuse code (E01 lane P1, hidden YouTube Music player, approved in `Docs/Playback-Addendum.md`):
  - `Packages/NativeMusic/Sources/Playback/WebMusic/WebMusicScripts.swift`:
    - `WebMusicScripts.adDetection` adapts `hasAdPlayerSignal`/`adPlayerAPIs` from Kaset `Sources/Kaset/Services/WebKit/PlaybackAdDetectionScript.swift`: player type 2 from `getPresentingPlayerType(true)` on `#movie_player` and `ytmusic-player.playerApi`, with the `ad-showing`/`ad-interrupting` classes as fallback. Detection only. Rework 1 also adapts Kaset's `isAdShowing` ad-pod continuity (`awaitingContent`: the ad creative's video ID, recorded while ad signals are present, holds the ad state until the requested content's `v` video returns) as `ytmuseAdShowing`, without Kaset's physical media-binding check.
    - The `navigator.mediaSession.setActionHandler` wrapper in `WebMusicScripts.bootstrap` follows the idea of Kaset's media-control bootstrap in `Sources/Kaset/Views/SingletonPlayerWebView+PlaybackPreferences.swift`; YTMuse refuses every page handler and also withholds the page's metadata from WebKit.
    - The play-event suppression in the bootstrap follows Kaset's `pageBootstrapScript` playback suppression in `Sources/Kaset/Views/MiniPlayerWebView.swift`.
    - `WebMusicScripts.loadPlaylist` uses the in-page router call shape `app.resolveCommand({ watchEndpoint: … })` from Kaset `Sources/Kaset/Views/SingletonPlayerWebView+RouterNavigation.swift`.
  - `Packages/NativeMusic/Sources/Playback/WebMusic/WebMusicCommand.swift`, `WebMusicPage.swift`, `WebMusicPlayer.swift`, `WebMusicTransport.swift`, `WebMusicBridge.swift`:
    - The document-generation token carried in the playback URL and the main-frame/origin/current-document bridge gate follow Kaset ADR-0026 (`docs/adr/0026-generation-scoped-web-playback-bridge.md`); `window.location.replace` for later documents follows ADR-0034. The code is original.

  - W12 rework 1 (copied data, not code): `Fixtures/W12-kaset-real/artist_lofi_girl_episodes_more.json` is Kaset's `Tests/KasetTests/Fixtures/artist_lofi_girl_episodes_more.json` (a real signed YouTube Music browse response), copied byte-for-byte at commit `4c59ff259d853f1cc328597f5adccf2a291c2fa7` with its sha256 recorded in `Fixtures/W12-kaset-real/manifest.json`. It is used only by tests, to read real signed menu toggles ("Mark as played", "Pin to Listen again"). The icon-based recognition of library toggles in `MusicBrowseParser` (a `LIBRARY_ADD`/`BOOKMARK_BORDER` icon names an add action, a `LIBRARY_REMOVE`/`BOOKMARK` icon a remove action, whichever side is the default) follows the convention in Kaset `Sources/Kaset/Services/API/Parsers/SongMetadataParser.swift` (`parseToggleMenuItem`), which agrees with ytmusicapi; the code is original. The licence text below applies to the copied file.
  - W13 (copied data, and request shapes read, not code): `Fixtures/W13-real/kaset-playlist_detail.json` is Kaset's `Tests/KasetTests/Fixtures/playlist_detail.json`, copied byte-for-byte at commit `4c59ff259d853f1cc328597f5adccf2a291c2fa7` with its sha256 in `Fixtures/W13-real/manifest.json`. It is a hand-written test fixture of Kaset's (not a signed capture) and is used only by tests, to show a header-only layout is not read as editable. `Fixtures/W13-real/browse-playlist.json` is this project's own real anonymous capture (`Fixtures/W11-real`). The playlist requests in `SignedPlaylistWrites.swift` were compared with Kaset's `Sources/Kaset/Services/API/YTMusicClient.swift` (`createPlaylist`, `addSongToPlaylist`, `removeSongFromPlaylist`, `deletePlaylist`); the code is original. The licence text below applies to the copied file.
```
MIT License

Copyright (c) 2025 sozercan

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```
