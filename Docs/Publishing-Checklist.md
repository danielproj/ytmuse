# Publishing checklist

The cleaned-source repository and [0.1.17 development preview](https://github.com/danielproj/ytmuse/releases/tag/v0.1.17) are public. The source tree and screenshots were scanned, and commit metadata was reviewed to confirm that it contains only the public maintainer identity and GitHub noreply addresses. Internal development history remains local. The app and DMG passed Developer ID signing, Apple notarization, stapling and local Gatekeeper checks; the signed feed matches the final installer. By hand, on the 0.1.3 preview, the maintainer checked a clean install and a real signed update; that update crashed the old app as it quit, which 0.1.4 fixes. On 2026-11-05 the account holder confirmed the remaining core checks work, including update restart after the fix. Wider G09 distribution checks remain deferred; see the [backlog](Backlog.md). [GitHub-Releases.md](GitHub-Releases.md) records current configuration. Historical findings below explain why the internal development history is not synchronized to the release repository. BUILD08: the account holder selected public source and downloads; App Store submission is outside that decision.

## 1. Decide what is published (account holder)

The working repository carries the build harness's evidence under `artifacts/` (about 23,000 files). A history scan (`python3 scripts/scan-repository.py --history`) found, and these cannot be fixed by editing the working tree:

| Finding | Where | Why it matters |
| --- | --- | --- |
| The macOS account name appears in absolute paths, hundreds of thousands of times | about 1,800 files under `artifacts/harness` (build and test logs) | names the account holder's local account |
| The account holder's personal e-mail address is the author and committer of all 1,191 commits | commit metadata | public the moment history is pushed |
| Copies of third-party reference code and specifications under other licences (GPL-class and others) | `artifacts/harness/nodes/W08/reference-code`, `E01/stage-auth/oidc-core.md` | cannot be republished under this project's MIT licence |
| A third-party sample project's Team ID and public API keys of other projects' clients | `artifacts/harness/nodes/V01/raw`, `W08/reference-code` | not secrets of this project, but not ours to publish |
| About 560 live-run screenshots and captures | `artifacts/harness` | may show a desktop or an account holder's data; the OCR and metadata scan (`--images`) found no e-mail address, name or session in any of them, but they were not reviewed by eye |

**Recommended:** publish the snapshot, not this history. `scripts/make-public-snapshot.sh /absolute/path/to/new-dir` writes the committed tree without `artifacts/`, `plans/` and the harness documents (`Docs/public-snapshot-excludes.txt`), puts back the ten harness files that the repository's own tests and scripts read (`Docs/public-snapshot-keep.txt`), scans the result, and stops on any medium or high finding. `scripts/clean-checkout.sh --snapshot` then builds that snapshot (no `.git`, no secret) and runs every headless test in it, so the published tree is proved self-sufficient. Make the first public commit from that directory with a `noreply` author. Then no shared history is rewritten and none of the findings above is published. The Docs refer to the harness evidence in places; those links dangle in the snapshot and should be reworded or the evidence summarized before publication.

Done 2026-11-01: the account holder chose to remove their first name and Mac model from `Docs/Product-Specification.md` line 1.

Before publishing the snapshot: the kept reference copy of two ytmusicapi files (MIT) needs the upstream licence text and copyright line in `THIRD_PARTY_NOTICES.md` (they were not captured with the copy), or the copy and its test must go.

If the account holder prefers to publish the full history instead, every item above must be resolved first, and a history rewrite (a decision of the operator, never of a worker) is required.

## 2. Configure the repository (public preview exists; Actions setup pending)

1. Choose the owner and name. They go into the app only at packaging time (`YTMUSE_UPDATE_REPOSITORY`); the source carries none.
2. Create the repository and push the snapshot. Enable private vulnerability reporting, branch protection on the default branch and required status checks `ci` and `license`.
3. Create a GitHub **environment** named `release` with required reviewers and these secrets: `YTMUSE_DEVELOPER_ID` (identity name), `YTMUSE_NOTARY_PROFILE` (notarytool keychain profile name or its credentials), `YTMUSE_FEED_KEY` (the feed signing key file contents), `YTMUSE_FEED_PUBLIC_KEY`. Pull-request workflows never see them.
4. Replace the first-party action tags in `.github/workflows` with commit SHAs (`scripts/check-workflows.py` lists which are tag-pinned), set the runner label variable `YTMUSE_RUNNER` to a macOS 27 runner that has Xcode 27.2 (27B52), and run the CI workflow on a pull request. **The workflows have never run**; they are checked only by `scripts/check-workflows.py` and by running their steps locally.

## 3. Keys and identities (local packaging configured)

* The feed key was created **once**, outside Git with owner-only permissions, using `ytmuse-feed keygen --private-out <path outside any repository> --public-out <path>` (see [Distribution.md](Distribution.md)). Its backup and rotation rehearsal remain maintainer responsibilities. The private key is never committed, never logged and never placed in a pull-request workflow.
* A usable Developer ID Application identity is installed on the packaging Mac and passed actual hardened-runtime signing with a secure timestamp. The notarization credential was validated and stored in its Keychain. None is in the repository; the packaging script receives only the identity selector, profile name and feed-key path. No private signing material was uploaded to GitHub.

## 4. Before distribution acceptance

The normal update/restart flow is accepted by the account holder as of 2026-11-05. Fresh-checkout, clean-second-Mac, tampered/downgraded-feed refusal and rollback requirements below remain deferred; G09 is still open for that broader scope.

1. Source: a clean clone passes `scripts/clean-checkout.sh`; `scripts/scan-repository.py --tree --history --images --fail-on high` reports nothing outstanding; `scripts/check-distribution.py --source-only` passes; `Docs/sbom.cdx.json` is current.
2. Build: `scripts/package-release.sh` on a clean checkout of the release tag (`--dry-run` first). It builds Release arm64 with the version and build number, signs with hardened runtime (inner code first), makes the DMG, notarizes and staples, writes the checksum, regenerates the SBOM, runs `check-distribution.py --app`, writes the feed payload and signs it.
3. Verify what was built, on a second Mac that has never run YTMuse: install from the DMG, launch, confirm Gatekeeper accepts it, and run the update path: an older signed build must offer, download, verify and, on **Restart to Update** with nothing playing, replace itself; a tampered or downgraded feed must be refused. This is the W46 rehearsal and gate G09; unit tests do not replace it.
4. Do not call it 1.0. The service gates G01–G08 are open ([README](../README.md)); label the release honestly with the [capability matrix](Capability-Matrix.md).

## 5. After publishing

* Rotate nothing by hand; if the feed key may have leaked, ship an app that pins the successor key and stop signing with the old one.
* Re-run the history scan on the published repository.
