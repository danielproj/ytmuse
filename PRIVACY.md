# Privacy

YTMuse keeps its state on your Mac. There is no cloud state store, account proxy or developer media relay (ARCH10), and **no analytics, telemetry or remote crash reporting**: the app contains no analytics SDK and sends no diagnostics anywhere. This describes the code in this repository; no release exists yet.

## What is stored, locally

Your signed-in session (in the macOS Keychain, under the app's own service names), your account list, a local copy of your library and playback state, the queue, settings, cached artwork, files you add to the owned-music store. Removing an account deletes its credentials and everything derived from it.

## What is sent, and to whom

* **YouTube Music and Google** receive the requests needed to sign you in and show and play your music, as the service's own web player would. Your password is entered on Google's page, never in YTMuse. The hidden player is the system's WebKit.
* **Artwork hosts** serve cover images.
* **GitHub** receives an update check **only if you allow it**. By default no update check is made. You are asked once; if you opt in, the app asks at most once a day while it is running. A check is one plain request for one small signed file, carrying no account, listening, device or version information, no cookie and no identifier (`Docs/Distribution.md` lists the exact headers). Building from source includes no update feed, so a source build checks nothing.
* **Nobody else.** There are no third-party SDKs, advertising identifiers or tracking.

## What stays private

Notifications show title and artist only and are off until you turn them on. Spotlight indexing and the global shortcuts are off until you turn them on; private playlists, uploads and history are indexed only on a second, separate choice, and are removed when you sign out. The widget receives a minimal snapshot and no credentials.

## Controls

The update choices are under Settings > Updates. A complete local-data reset, per-category restore defaults and account-local cache clearing are specified (section 16) and belong to the Settings work; the [capability matrix](Docs/Capability-Matrix.md) states how far that has come.

## Screenshots and fixtures in this repository

They are generated from the app's own synthetic development data or sanitized captures of public pages. No session, cookie, token or account detail belongs in either; `scripts/scan-repository.py` checks.
