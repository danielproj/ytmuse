# YTMuse

The user confirmed **YTMuse** as the app name during W04 (“ok, sounds good, name it like that”). The built public app product is `YTMuse.app`.

Tagline: “YouTube Music, native on Mac.”

Descriptor: “An independent native YouTube Music client for Mac.”

This names an independent client and does not imply endorsement by Google or Apple. Browser Music authentication and all live-service gates remain unverified. Development welcome/account screens state that browser sign-in is not connected.

This is a display-brand decision only. Package, project, source type names, development bundle identifiers and Keychain namespaces remain unchanged. Public brand/bundle ownership and distribution checks remain with their assigned release nodes. The original product specification and pinned harness inputs are unchanged.

The user also requested generated icons. The parent supplied the original app-icon master and matching monochrome template mark under `Resources/Brand/`, including prompts, reproducible conversion script, validation and hashes. The app embeds only `YTMuse.icns` and the 18/36px menu template resources; master artwork/provenance/scripts stay in source. `CFBundleIconFile` resolves `YTMuse.icns`; the welcome view uses the actual application icon. `BrandAssets.menuBarTemplate()` explicitly enables template rendering for W21, without creating a status item during W04.

The [glass visual addendum](Visual-Direction.md) supersedes the original icon integration above. V01 compiles `Resources/Brand/Glass-v2/YTMuse.icon` with Xcode into the bundle's adaptive asset catalog and generated `YTMuse.icns`, referenced by `CFBundleIconName=YTMuse`. The separate `YTMuseGlass.icns` is a flattened compatibility resource. Startup leaves native icon selection in control. Prior v1 sources and provenance remain unchanged. The menu mark is unchanged and remains a native template.
