# GitHub source and installable releases

The cleaned source repository is public. Its owner/name is selected by the maintainer and supplied to the packaging configuration; the source remains portable across repositories. No installer release has been published. Version 0.1.0 is tagged, and its production app has built, signed with Developer ID and been submitted to Apple for notarization. That submission is still processing. The local installed app remains the earlier Apple Development build.

Release packaging uses a dedicated production app/widget identity, derived by default as `com.github.<owner>.<repository>` with a `.widget` companion. `YTMUSE_RELEASE_BUNDLE_ID` can override it with a valid reverse-DNS identifier. The app group uses the signing Team ID followed by that production identifier, separating releases from local development stores. Ordinary source builds retain the development identifiers.

The current build targets Apple Silicon and macOS 27 or later. Building requires the exact Xcode/Swift versions in `toolchain.json`. Intel Macs and earlier macOS versions are not supported by this build.

## Source synchronization

The working development repository contains internal harness evidence and has a different history from GitHub's cleaned snapshot. Commit product source, tests, resources and public documentation locally, then generate the publishable tree with `scripts/make-public-snapshot.sh` into a new directory outside the working repository. Review and scan the snapshot before synchronizing it onto GitHub's existing history. Do not force-push the internal development history or upload live-account logs, screenshots, local paths or signing files.

## Installer and updater path

The existing `.github/workflows/release.yml` creates a **draft** release from a version tag after verification and packaging. `scripts/package-release.sh` builds the app and widget, signs them with Developer ID, notarizes and staples the app and DMG, writes checksums and an SBOM, and signs the update feed. It refuses development identities. Packaging and publishing are separate actions.

The following prerequisites remain:

- A Developer ID Application identity has been installed on the maintainer Mac and an actual signing/timestamp check passed. Notarization credentials were validated and stored in its local Keychain. No private material was uploaded to GitHub. An identity/profile name stored in GitHub Secrets alone would not install those credentials on a runner.
- The production app/widget identifiers and application group are configured independently of development stores. The tagged production build and signing passed. Final packaged-bundle and entitlement verification remain pending; this is not distribution acceptance.
- A local Ed25519 update-feed key pair has been prepared outside Git with owner-only permissions. Its private key has not been uploaded. The package pins the matching public key, release repository and feed URL; publication and final feed verification remain pending. Source builds leave update networking disabled.
- A compatible clean packaging runner. GitHub currently has no repository runner or `YTMUSE_RUNNER` variable configured for this project. The workflows' exact toolchain check will refuse an incompatible hosted image. Local packaging on an appropriately configured Mac is also possible.
- If GitHub Actions is used, a protected `release` environment and its documented secrets, and a successful verification run. Checkout actions are pinned to an immutable revision, and release jobs select the pinned Xcode. The `release` environment now requires maintainer review. No private signing secrets have been uploaded. Repository Actions are currently disabled; local packaging remains possible without uploading keys to GitHub.
- A clean-Mac install/Gatekeeper check and an update/rollback rehearsal. Passing a local development build does not replace these checks.

Once those prerequisites pass, build from the reviewed version tag and attach the DMG, checksum, SBOM, release notes and signed `feed.json` to a draft GitHub release. Inspect that concrete draft before publication. Keep the release labeled as a development preview while known feature and acceptance gaps remain.

## Who can download

Public source and public downloads have been selected. Anyone can read and build the published source. Once a signed/notarized installer release is published, it will be downloadable without repository invitations. The update-feed trust and first installer remain pending; making the source public alone does not publish a binary.

References: [GitHub releases](https://docs.github.com/en/repositories/releasing-projects-on-github/about-releases), [Apple Developer ID](https://developer.apple.com/developer-id/), [packaging and updater design](Distribution.md), and [publishing checks](Publishing-Checklist.md).
