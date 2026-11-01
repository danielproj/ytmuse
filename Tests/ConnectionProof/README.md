# Headless connection proof

- Deterministic checks: `scripts/test.sh --suite T51` (live case explicitly skipped).
- Optional public network: `Tests/ConnectionProof/run-public-observation.sh` (homepage, Music search, selected-item player metadata; no login/playback).
- Headless affected checks and app build: `python3 artifacts/harness/nodes/E01/validate.py`. Add `--live` only for a separate public observation.

Swift tests are under `Packages/NativeMusic/Tests/ConnectionTests`. Pinned deterministic projections remain in `artifacts/harness/nodes/E01/capture-0.json` and `capture-1.json`. Each optional live run writes a new UUID directory under `observations/` with projection hashes and sanitized error categories. Historical receipts and fixtures are never refreshed by live runs. Rework validation writes under `rework-1/`; original evidence remains in `rework-1/prior/`.

Builds use this checkout's `.build/e01` and `.build/e01-app`. No foreground UI/browser consent is run. See `Docs/Connection-Proof.md` for the scope and unresolved authorization/production integration boundaries. All G01–G09 remain open.

The service-first production Google candidate is documented in
`Docs/Google-Auth-Implementation.md`. `GoogleConnectionCoordinator` composes the
one-attempt native loopback/browser flow, cryptographic ID-token verifier,
protected Google-grant rotation and lifecycle cancellation. Focused tests use
ephemeral signing keys, synthetic tokens, actual local HTTP and isolated app-owned
test Keychains; no real consent/browser/media is invoked. Production has no
accept-all verifier. The app-owned registration remains unconfirmed and Music
session/native media/event/ad access is still unavailable. Profile verification
never installs a Music account through the default bridge. The stage-auth
validation runner records exact command/environment/source/log/binary bindings.
