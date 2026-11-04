# YTMuse for macOS

*YouTube Music, native on Mac.* An independent, native SwiftUI/AppKit music client, **under development and not released**. It is not endorsed by, affiliated with or sponsored by Google, YouTube or Apple; "YouTube" and "YouTube Music" belong to Google, and this project uses neither company's logos. Original code is MIT licensed ([LICENSE](LICENSE)); third-party material is listed in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

![Home, light and dark, rendered from the app's own development data](Docs/Screenshots/home-default-dark.png)

## Status, honestly

There is **no release or published installer yet**. The current app has been built and installed locally with development signing. That is separate from a Developer ID-signed, notarized release that other people can download. The source repository is public. A downloadable installer has not been published yet. [GitHub release setup](Docs/GitHub-Releases.md) records what remains before downloads are available.

The core page/sidebar/player redesign has passed bounded visual checks. Native-account smoke checks cover sign-in restoration, Search, playlist creation/editing/addition/removal, mix/radio startup and upcoming-item selection. Radio tuning filters still fail to load. These checks do not close the full account matrix, audible-output, accessibility, hardware or distribution gates below:

| Gate | State |
| --- | --- |
| G01 Authentication (real free and Premium sessions) | **open** — a signed-in session and restoration passed a bounded native-account check; the complete free/Premium and fresh-sign-in matrix remains unverified |
| G02 Native media access, G03 free-account playback, G04 Premium quality | **open** — playback of YouTube Music goes through the user-approved hidden system-WebKit player; native media access is not established |
| G05 Offline | **open** — YouTube Music offers no downloads to this app; only music from files on this Mac can be stored |
| G06 Service parity, G07 Casting, G08 System integration, G09 Distribution | **open** — see the [capability matrix](Docs/Capability-Matrix.md) |

Automated tests use **sanitized fixtures and owned synthetic audio**, isolated from real account stores. Separate, bounded manual checks use the installed app's normal interface. [Docs/Capability-Matrix.md](Docs/Capability-Matrix.md) records the wider implementation and acceptance limits. Upload functionality has been removed. The full contract is [the specification](Docs/Product-Specification.md).

## Build from source

You need an Apple Silicon Mac on macOS 27 or later with Xcode 27.2 (build 27B52) selected. No account, signing identity, certificate, private file or secret is needed. The toolchain is pinned in [toolchain.json](toolchain.json) and checked by this command, which fails on any other version:

```sh run
./scripts/check-toolchain.sh
```

Build and run the app locally, then run a test suite (details and the other suites in [Docs/Build.md](Docs/Build.md)):

```sh
./scripts/build.sh
open .build/xcode/Build/Products/Release/YTMuse.app
./scripts/test.sh --suite T02
```

A source build is signed ad hoc, so it has **no update feed and never contacts an update server**. To check the module boundaries and the dependency, licence and SBOM rules without building the app:

```sh run
python3 scripts/check-boundaries.py
python3 scripts/check-distribution.py --source-only
```

To prove a fresh clone builds and tests with no secrets (it clones under `~/Projects`, runs the same steps as CI and deletes the clone): `./scripts/clean-checkout.sh`.

## Documentation

| | |
| --- | --- |
| [CONTRIBUTING.md](CONTRIBUTING.md) | how to build, test and propose changes |
| [SECURITY.md](SECURITY.md) | reporting a vulnerability, and what is protected |
| [PRIVACY.md](PRIVACY.md) | what the app stores and sends |
| [Docs/Distribution.md](Docs/Distribution.md) | releases, the updater, signing, the App Store question |
| [Docs/Capability-Matrix.md](Docs/Capability-Matrix.md) | what works, what is fixture-tested, what is not built |
| [Docs/Publishing-Checklist.md](Docs/Publishing-Checklist.md) | what must happen before this is published |
| [Docs/Architecture.md](Docs/Architecture.md), [Docs/Build.md](Docs/Build.md) | structure, modules and the local toolchain |

## Independence

YTMuse is a client written by its contributors for people who already use YouTube Music. It does not proxy, resell or relay any media, keeps all state on the Mac, and never asks you to copy cookies out of a browser. Subscriptions and content remain YouTube's. Anything the service does not allow a third-party client to do is reported as such in the app rather than imitated.
