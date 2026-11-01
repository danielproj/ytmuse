#!/bin/bash
# W30 (T30.1): the CI steps. .github/workflows/ci.yml runs exactly this, and scripts/clean-checkout.sh runs exactly this in a clean clone, so a local pass and a
# CI pass mean the same thing. It needs NO secret and refuses to see one: no Google client or account, no signing identity, no notarization or feed key. Pull-request
# tests use sanitized fixtures and owned or generated media only (BUILD02).
#
# What runs (scripts/test.sh --suite T30, headless): the toolchain pin; module boundaries; the dependency, licence and SBOM checks; the repository scan for secrets
# and personal data; the workflow and documentation checks (documented examples execute); the signed-package script over shimmed tools; the updater's tests; EVERY
# headless package test, counted (discovered against executed); a Debug build of the app and the inspection of that binary for any browser, Python or Node runtime.
# Native UI tests need a logged-in desktop and are not part of CI; they run locally under scripts/test.sh with their own gates.
set -euo pipefail
cd "$(dirname "$0")/.."
unset YTMUSE_CODESIGN_IDENTITY YTMUSE_DEVELOPER_ID YTMUSE_NOTARY_PROFILE YTMUSE_FEED_KEY YTMUSE_FEED_KEY_CONTENTS YTMUSE_FEED_PUBLIC_KEY YTMUSE_UPDATE_REPOSITORY \
      YTMUSE_GOOGLE_DESKTOP_CLIENT_ID YTMUSE_USE_REAL_STORES
export YTMUSE_CI=1 T30_HEADLESS=1 T30_WHOLE_PACKAGE=1
./scripts/check-toolchain.sh
./scripts/test.sh --suite T30
echo 'ci: ok'
