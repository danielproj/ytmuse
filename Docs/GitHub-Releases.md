# GitHub source and installable releases

The source repository is connected privately. Its owner/name is selected by the maintainer and supplied to the packaging configuration; the source remains portable across repositories. No installer release has been published. The local installed app uses Apple Development signing; it is not a notarized distribution build.

The current build targets Apple Silicon and macOS 27 or later. Building requires the exact Xcode/Swift versions in `toolchain.json`. Intel Macs and earlier macOS versions are not supported by this build.

## Source synchronization

The working development repository contains internal harness evidence and has a different history from GitHub's cleaned snapshot. Commit product source, tests, resources and public documentation locally, then generate the publishable tree with `scripts/make-public-snapshot.sh` into a new directory outside the working repository. Review and scan the snapshot before synchronizing it onto GitHub's existing history. Do not force-push the internal development history or upload live-account logs, screenshots, local paths or signing files.

## Installer and updater path

The existing `.github/workflows/release.yml` creates a **draft** release from a version tag after verification and packaging. `scripts/package-release.sh` builds the app and widget, signs them with Developer ID, notarizes and staples the app and DMG, writes checksums and an SBOM, and signs the update feed. It refuses development identities. Packaging and publishing are separate actions.

The following prerequisites remain:

- A Developer ID Application certificate and private key, plus a working notarization profile. They must be available on the packaging Mac; an identity name stored in GitHub Secrets does not install a certificate into a runner's keychain.
- A production bundle/application-group identity and the required entitlements/provisioning, verified before first distribution. The current development identity is not distribution acceptance.
- An Ed25519 update-feed signing key kept outside Git and its matching public key. The packaged app pins the release repository, feed URL and public key; source builds leave update networking disabled.
- A compatible clean packaging runner. GitHub currently has no repository runner or `YTMUSE_RUNNER` variable configured for this project. The workflows' exact toolchain check will refuse an incompatible hosted image. Local packaging on an appropriately configured Mac is also possible.
- If GitHub Actions is used, a protected `release` environment and its documented secrets, and a successful verification run. Checkout actions are pinned to an immutable revision, and release jobs select the pinned Xcode. No release environment or release secrets are currently configured.
- A clean-Mac install/Gatekeeper check and an update/rollback rehearsal. Passing a local development build does not replace these checks.

Once those prerequisites pass, build from the reviewed version tag and attach the DMG, checksum, SBOM, release notes and signed `feed.json` to a draft GitHub release. Inspect that concrete draft before publication. Keep the release labeled as a development preview while known feature and acceptance gaps remain.

## Who can download

Releases inherit repository access. A private source repository supplies downloads only to people granted access. For downloads available to everyone, choose either a public source repository or a separate public releases repository while keeping source private. Do not change repository visibility as part of routine source synchronization. A separate release repository must be pinned consistently by the packaging configuration and updater feed.

References: [GitHub releases](https://docs.github.com/en/repositories/releasing-projects-on-github/about-releases), [Apple Developer ID](https://developer.apple.com/developer-id/), [packaging and updater design](Distribution.md), and [publishing checks](Publishing-Checklist.md).
