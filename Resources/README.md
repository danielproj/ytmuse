# Resources

W01 uses only native typography and an SF Symbol rendered by the system. No third-party artwork, media or logos are bundled. String catalogs, icons and licensed fixtures are added by their assigned nodes.

## Localization (W28)

* `Localizable.xcstrings` is the one String Catalog. English is the source language. The 47 base and script locales and the six formatting variants of the specification (section 15) are the only locales it may carry; `de-CH` and `pt-PT` have entries of their own, `en-GB`, `en-US`, `fr-CH` and `it-CH` inherit their base language.
* `L10N/core-en.txt` is the **core set**: navigation, transport, sign-in, error, privacy and language-setting wording (63 sentences and 3 plural families). `L10N/seeds/<locale>.txt` holds the machine seed for each locale, one line per core id (`N|text`, plural families as `Pn|category:text<TAB>category:text`). `L10N/plural-categories.json` lists the CLDR plural categories each language needs; `L10N/extra-keys.txt` lists interpolated source keys that exist in English only.
* `python3 scripts/l10n/build-catalog.py` writes the localizations and `LocalizationManifest.json` from those files (it refuses a seed that drops a placeholder or a plural category); `--check` verifies the committed files are what it would write. `python3 scripts/check-localization.py` audits the result against the specification and the sources.
* **Every non-English value is a machine seed pending human review (W42).** Core strings carry that in their catalog comment and `needs_review` state; the manifest says `releaseQualityClaim: false`. "Complete" in the manifest means the core set, with plural categories; strings outside it fall back to English for that locale and `catalogCoverage` states how much of the whole catalog that is. Product and artist names are never translated. Review packets for every locale: `artifacts/harness/nodes/W28/review-packets/`.
