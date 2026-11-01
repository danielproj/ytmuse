// The in-repository native updater (W30). See Docs/Distribution.md. Files: AppVersion (strict version ordering), UpdateFeed (the signed feed's shape),
// FeedVerifier (Ed25519 verification, pinned trust, provenance, rollback), UpdateRequests (the one request builder and the network seam),
// UpdateStaging (hash, extraction, code signature), UpdateInstaller (explicit restart, playback gate, atomic exchange), UpdateController (consent and flow).
