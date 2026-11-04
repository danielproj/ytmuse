# GitHub source and installable releases

The cleaned source repository and [0.1.0 development preview](https://github.com/danielproj/ytmuse/releases/tag/v0.1.0) are public. Anyone can download the Developer ID-signed, notarized DMG without a repository invitation. This is an early preview; G01–G09 remain open. The release notes and [capability matrix](Capability-Matrix.md) describe the implementation and validation limits.

The preview targets **Apple Silicon and macOS 27 or later**. Intel Macs and earlier macOS versions are not supported. Building from source requires the exact Xcode/Swift versions in `toolchain.json`.

## Install

Download `YTMuse-0.1.0.dmg` from the release page, open it, and drag **YTMuse.app** into **Applications**. The app and image both carry stapled Apple notarization tickets. The release also provides a SHA-256 checksum, the SBOM, release notes and signed `feed.json`.

Release packaging uses a dedicated production app/widget identity, derived by default as `com.github.<owner>.<repository>` with a `.widget` companion. `YTMUSE_RELEASE_BUNDLE_ID` can override it with a valid reverse-DNS identifier. The app group uses the signing Team ID followed by that production identifier. Ordinary source builds retain development identifiers; no migration from development stores is included.

The public app pins its update repository, feed URL and Ed25519 public key. Automatic checks require opt-in, and installation requires an explicit restart. Source builds have no feed or pinned key and leave update networking disabled.

## What was verified

The preview was built from source tag `v0.1.0`. The production app/widget identifiers and group, hardened runtime, secure timestamps, strict signatures, app and DMG notarization tickets, local Gatekeeper acceptance, bundle inventory, private-build-path removal, checksum and signed feed were checked. The uploaded assets were downloaded again and compared with the verified local files.

No clean-second-Mac installation or real signed update/rollback rehearsal was performed. Earlier bounded core-account and visual checks used the development build. They do not establish acceptance of the public production identity. Broader account, audio, accessibility, localization and device checks remain open.

## Source synchronization

The working development repository contains internal harness evidence and has a different history from GitHub's cleaned snapshot. Commit product source, tests, resources and public documentation locally, then generate the publishable tree with `scripts/make-public-snapshot.sh` into a new directory outside the working repository. Review and scan the snapshot before synchronizing it onto GitHub's existing history. Do not force-push the internal development history or upload live-account logs, screenshots, local paths or signing files.

## Future packaging and automation

`scripts/package-release.sh` builds the app and widget from a clean version tag, signs them with Developer ID, notarizes and staples the app and DMG, writes checksums and an SBOM, and signs the update feed. It refuses development identities. Packaging and publishing are separate actions; inspect the concrete draft assets before publication. Version and build numbers must increase over prior releases.

Signing credentials and the feed private key remain local with owner-only protection; the notarization profile is held in Keychain. No private signing material has been uploaded to GitHub. An identity/profile name in GitHub Secrets alone would not install those credentials on a runner.

The existing `.github/workflows/release.yml` creates a **draft** release from a version tag after verification and packaging. Repository Actions remain disabled. A protected `release` environment requires maintainer review, but no compatible repository runner, `YTMUSE_RUNNER` variable or private signing secrets are configured. Enabling future Actions packaging requires those prerequisites and a successful verification run. The workflow's exact toolchain check refuses incompatible hosted images; local packaging on the pinned Mac remains supported.

References: [GitHub releases](https://docs.github.com/en/repositories/releasing-projects-on-github/about-releases), [Apple Developer ID](https://developer.apple.com/developer-id/), [packaging and updater design](Distribution.md), and [publishing checks](Publishing-Checklist.md).
