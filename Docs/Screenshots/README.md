# Screenshots

These are **headless renders of the app's own labelled development data**: a built-in synthetic catalog, a generated gradient in place of cover art, no signed-in account, no network and no personal data (DESIGN07, BUILD03). They were produced by the design-audit tests (`GlassPolishTests`) from offscreen windows and downscaled to 760 px on the long edge.

Two things they are not: they are not screenshots of YouTube Music (the service's own content appears nowhere), and an offscreen bitmap cannot draw native Liquid Glass, so the render uses the simplified material path. Geometry, spacing and content are the app's; the glass itself is not shown.

| File | Shows |
| --- | --- |
| `home-default-light.png`, `home-default-dark.png` | Home with the not-signed-in welcome, in light and dark |
| `explore-default-light.png` | Explore |
| `detail-default-dark.png` | A detail page |

`scripts/scan-repository.py --images` reads each screenshot's metadata and its on-screen text (through macOS Vision) for e-mail addresses, names, sessions and tokens; it must report nothing for this folder.
