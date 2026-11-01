# Translation brief for machine seeds (W28 rework 1)

You write **machine-seed** translations of the English UI sentences of the macOS music app YTMuse (a native YouTube Music client) into ONE language. A human reviews them later (W42); do not claim quality, but translate carefully.

## Input
`Resources/L10N/core-en.txt` has the English lines. Line kinds:
* `ID|English` — a plain sentence or label. IDs 1..1173 (1..63 and the `P` lines are already translated in `Resources/L10N/seeds/core1/<locale>.txt`; read that file first for terminology and style, and do not repeat those ids).
* `Qn|English` — an English sentence containing `%lld` (a number). Translate it into EVERY plural category your language needs (see below).

## Output (you write only files in `Resources/L10N/seeds/` named for your locale, in four parts)
* `<locale>.txt`  — plain ids 64 to 400 (inclusive; ids that exist in core-en.txt)
* `<locale>.2.txt` — plain ids 401 to 700
* `<locale>.3.txt` — plain ids 701 to 1000
* `<locale>.4.txt` — plain ids 1001 to 1173, then `Q1` to `Q40`

Line format, one line each, nothing else (no header, comment, blank line or Markdown), UTF-8:
* `ID|translated text`
* `Qn|category:text<TAB>category:text...` — categories separated by a real TAB character, each `category:` one of `zero one two few many other`, exactly these for your language: **ru** = one few many other; **de** = one other; **es** = one many other; **fr** = one many other. In every form keep `%lld` (and any `%@`). `one` is the form for 1 (and, for ru, 21, 31…); `few` for 2–4 (ru 22–24…); `many` for 5–20 (ru) or for large round numbers/millions (es "1 de millones", fr "1 de millions": write the natural "de" form); `other` for the rest/fractions. If the count is not a quantity of something (for example "Page %lld"), repeat the same text in every category.

## Rules
* Translate whole sentences naturally and keep the meaning, the plain calm tone (second person; use the formal/neutral register your language normally uses in software UI) and the recovery advice ("Try again", "Sign in again").
* **Never translate, transliterate or inflect names**: `YTMuse`, `YouTube Music`, `YouTube`, `Google`, `Mac`, `macOS`, `Keychain`, `Spotlight`, `OAuth`, `Samples` (a YouTube Music feature), `AirPlay`, `Chromecast`, `Siri`, `Shortcuts` as the app name, and any title/artist/playlist name that appears as a placeholder. In Russian, rephrase so the Latin name stays unchanged (for example "в YouTube Music", "от Google").
* Keep every `%@`, `%lld`, `%1$@`-style placeholder; you may reorder with `%1$@`/`%2$@` when your grammar needs it, never drop or add one. Keep `%%` as `%%`. Keep quotation marks around placeholders in your language's typographic style.
* Menu items, buttons and labels: short, sentence or title case as in your platform's conventions (macOS Human Interface Guidelines in your language); keep a trailing `…` where the English has one. Keep consistency with the terminology of the core1 seed (Sign in, Sign Out, Try Again, Remove, Cancel, session, library, queue, playlist, download…).
* Keep one translation per English line; do not merge, split, skip or reorder lines. If a line is a single unit/word (for example "Seconds"), translate it as a UI label.
* Use only file read and write tools. Do not run commands, builds, tests or git, do not use the network, do not write any file other than your four part files. Write each part completely, in one file write, before the next. After writing a part, re-read its first 3 and last 3 lines and check ids and format. Reply at the end with one line per file: name and line count.

## Addendum: part 5 (second round)
A fifth part file `<locale>.5.txt` holds plain ids **1174 to 1341** (168 lines), same format and rules. The first four parts are already written; do not touch them. Read `Resources/L10N/seeds/<locale>.txt` (and `.2`/`.3`/`.4`) only for terminology consistency.
