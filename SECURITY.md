# Security

## Reporting a vulnerability

Please report privately, not in a public issue or pull request. Use GitHub's private vulnerability reporting on the repository (Security tab → Report a vulnerability) once the repository is public; until then, report to the maintainer directly. Include the version or commit, what you did and what you saw. Do not include a real cookie, token or account in the report; describe the shape instead.

You will get an acknowledgement and a plan. The project has no bounty. There is no released version yet, so there is no supported-versions table; the latest commit on the default branch is the only supported state.

## What the project protects

* **Sessions and credentials.** A signed-in session is stored in the macOS Keychain under the app's own service names and is never written to a fixture, a log, a screenshot, a diagnostics export or the repository. The app never asks you to copy cookies from a browser. Removing an account deletes its credentials, keys, snapshots, indexes and queued writes.
* **Updates.** An update is installed only if a signed feed (Ed25519, key pinned in the app), the release provenance, the asset's SHA-256, the app's code signature (the same identity as the running app) and version ordering (no downgrade, no replayed feed) all check out, never while music is playing and never without the person's explicit restart. See [Docs/Distribution.md](Docs/Distribution.md).
* **Release signing credentials and CI secrets.** The Developer ID identity, the notarization credentials and the feed signing key are never in the repository. CI for pull requests has no secrets; releases are signed only from a protected environment. Throwaway keys are used by every test.
* **The repository itself.** `scripts/scan-repository.py` looks for sessions, cookies, tokens, private keys, e-mail addresses, Team IDs and personal paths in the tree, the history and the screenshots before anything is published.

## What it does not claim

The service gates in the [README](README.md) are open: authentication, native media access and the other live-service behaviour have not been verified against real accounts, so security claims about them are claims about the code and its fixture tests only. The hidden YouTube Music player is the system WebKit; its security is the operating system's.
