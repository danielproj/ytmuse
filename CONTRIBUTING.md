# Contributing

Thanks for helping. YTMuse is an independent native macOS client (see the [README](README.md) for what exists today). The specification in [Docs/Product-Specification.md](Docs/Product-Specification.md) is the contract; read the section you touch.

## Set up

Apple Silicon, macOS 27 or later, Xcode 27.2 (27B52). Nothing else: no Google account, signing identity or secret. `./scripts/check-toolchain.sh` fails on any other Xcode, Swift or SDK.

```sh
./scripts/test.sh --suite T02    # the domain contracts; every suite is named T<number> in Docs/Build.md
swift test --package-path Packages/NativeMusic list    # every test, discovered
```

`scripts/test.sh` caps compiler parallelism (`YTMUSE_BUILD_JOBS`, default 6) and compares the tests discovered with the tests executed, failing when fewer ran. Use it rather than a bare `swift test` for a suite run.

## Rules that every change must keep

* **Native only.** No Python, Node, browser engine, Electron or remote executable code ships in the app; no dependency that requires one. `python3 scripts/check-distribution.py --source-only` enforces the dependency, licence and SBOM rules, and `--app` inspects a built bundle. Adding any external package needs a stated reason, a compatible licence, an exact pin, an entry in `toolchain.json`, the SBOM and `THIRD_PARTY_NOTICES.md`, in the same change.
* **Tests use sanitized fixtures and owned or generated media only.** Pull-request tests run without a Google account. Live-service checks use separately provisioned accounts and never touch a personal playlist without a deliberate test action. Never put a cookie, token, session, e-mail address, Team ID or absolute home path in a fixture, a log, a screenshot or a commit. `python3 scripts/scan-repository.py --tree --fail-on high` and `--images` check this.
* **Tests never touch the real stores** (Keychain items, the account database, preferences, WebKit data, the Spotlight index, the App Group). Suites run isolated by default; a test that needs a store builds one in a temporary folder and deletes it.
* **Be honest about gates.** A feature that depends on a live service, hardware or a release step is "built, live unverified" until that evidence exists. Do not describe an unfinished feature as complete in the README, the capability matrix or the app.
* **Module boundaries** are in `scripts/module-dependencies.json`; `scripts/check-boundaries.py` fails on an unreviewed edge.

## Pull requests

* Keep a change to one concern. State which specification clause it implements and which test proves it; include a test that can fail.
* CI runs `scripts/ci.sh`: toolchain, boundaries, distribution and licence checks, a Debug build and the headless suites. It has no secrets and runs only on pull requests from forks with read-only permissions. Run the same steps locally, in a clean clone, with `./scripts/clean-checkout.sh`.
* Signing, notarization and the update feed key are the maintainer's. You never need them to contribute, and no pull request may add one.

## Reporting a vulnerability

Not through an issue: see [SECURITY.md](SECURITY.md).

## Licence

By contributing you agree your work is released under the [MIT licence](LICENSE).
