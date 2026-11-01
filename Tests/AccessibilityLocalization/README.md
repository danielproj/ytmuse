# Accessibility and localization tests (W28, suite T28)

Run with `scripts/test.sh --suite T28` (`T28_HEADLESS=1` skips the native UI part). One suite, three layers:

| Layer | Where | What it proves |
| - | - | - |
| Static guards | `scripts/l10n/build-catalog.py --check`, `scripts/check-localization.py` (+ `--self-test`), `scripts/check-test-preferences.py` | the catalog and `Resources/LocalizationManifest.json` are exactly what the tool writes; only the specification's 47 base locales and 6 variants exist; core keys, plural categories, placeholders and product names hold in every locale; no sentence is assembled from fragments; no test or script writes a persistent preferences domain |
| In-process | `Packages/NativeMusic/Tests/AccessibilityLocalizationTests` | locale resolution and fallback, independence of interface language / content language / content region, catalog completeness (Swift side), natural sort and locale-aware search, pseudolocalization, the contrast model over every palette, appearance and mode, announcements, motion, non-drag alternatives |
| Layout audit | `Packages/NativeMusic/Tests/GlassPolishTests/LocaleAccessibilityAuditTests.swift` | the T52 layout audit under double-length pseudolanguage and right-to-left on eight surfaces at the minimum and default window size |
| Native UI | `testW28KeyboardAndAccessibilityTraversal` in `Tests/NativeMusicUITests` | a Tab ring without traps, the command palette as the keyboard route to every destination, Escape closing sheets, an accessibility-tree traversal in which every operable element is named, and independent language choices in Settings |

Raw traces for the last run are written when `W28_TRACE_DIR` is set (`artifacts/harness/nodes/W28/traces/`): `contrast-samples.csv`, `contrast-worst-by-role.txt`, `pseudolocalization.txt`, `mixed-scripts.txt`, `locale-coverage.csv`.

## What this suite does not prove

* **Real VoiceOver.** The traversal reads the accessibility tree that XCUITest sees. Spoken output, rotor order and the actions rotor need a person with VoiceOver on a Mac (W42 live list).
* **Translation quality.** Every non-English string is a machine seed marked `needs_review`. The manifest says `releaseQualityClaim: false`. Review packets for every locale are in `artifacts/harness/nodes/W28/review-packets/`.
* **Large text.** This macOS does not scale third-party SwiftUI text with Dynamic Type (measured: identical widths), so a large-text layout run would audit unchanged type; the audit skips that mode and starts running it when the platform honours it (the control test fails if it starts to, and must then be updated). Fixed-height text is excluded by a source guard instead.
* **Increase Contrast on a real display.** The model covers it as numbers (Increased Contrast colours in `MusicPalette`); a headless process cannot switch the system setting, so the appearance-to-colour mapping is tested by name.
