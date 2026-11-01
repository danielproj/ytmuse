# YTMuse icon assets

Original app icon and matching menu-bar template generated for YTMuse using the built-in `image_gen` tool. The template was generated from this project's own app-icon master. No external reference artwork was supplied.

- `YTMuse-AppIcon-master-v1.png`: transparent 1254 × 1254 app-icon master.
- `YTMuse.iconset/`: ten native macOS PNG representations, 16 through 1024 pixels.
- `YTMuse.icns`: compiled application icon for the app bundle.
- `YTMuse-MenuTemplate-master-v1.png`: transparent monochrome master.
- `YTMuseMenuTemplate.png` and `YTMuseMenuTemplate@2x.png`: 18-point menu-bar template representations. Mark the loaded image as a template so macOS supplies its appearance.
- `generation-prompts.json`: exact generation/edit prompts and production method.
- `icon-validation.txt` and `asset-manifest.json`: packaging, transparency and source-integrity evidence.

Regenerate only the mechanical size/package outputs with `bash Resources/Brand/build-icons.sh` from the repository root. Masters are preserved. Apple `sips` performs resampling and `iconutil` produces the native icon file; these build tools are not shipped as application runtimes.

Embed only the icon files required by the app. The source masters, prompts, validation records and build script belong to the source repository. The actual menu-bar control remains owned by the window-lifecycle node.
