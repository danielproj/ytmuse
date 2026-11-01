# YTMuse — glass visual direction

The user confirmed the YTMuse name and then requested: “icon should be glass friendly, same for design, it should have glass effects, fully”. This is an authoritative visual addendum to the frozen original specification. The original specification and planning inputs remain intact for audit. Their earlier restrained/selective-material preference is superseded by this app-wide glass direction; functional, privacy, accessibility and performance requirements remain mandatory.

## Required appearance

- GLASS01: Make glass the coherent visual language across the app: welcome, account management, navigation/sidebar, browser/content panels, bottom player, queue/lyrics, Settings, sheets, menu-bar popover, mini-player and Now Playing. Use depth, translucency, layered surfaces, restrained red artwork accents and fine highlights with a clear hierarchy.
- GLASS02: Use actual native SwiftUI/AppKit materials and Liquid Glass controls. Create shared design tokens/components and grouped effects. Preserve native window chrome and interaction behavior. A screenshot or raster effect is not implementation of an interactive material.
- GLASS03: Use an original glass-compatible YTMuse icon with a recognizable musical M/play detail. Keep a layered source for Apple's icon workflow, verify actual compiled rendering and appearance modes, and retain the native size set. Keep the template menu-bar mark adaptable to the system appearance.
- GLASS04: Keep text, icons, focus, selection, pending/error and disabled states legible across light/dark and varied backgrounds. Album art does not determine whether essential information can be read.
- GLASS05: Honor Reduce Transparency, Increase Contrast, Reduce Motion and power/visibility conditions with appropriate native fallbacks. Hidden windows stop decorative work; the original resource budgets still apply.
- GLASS06: The public product remains YTMuse.app. Package actual icon resources and verify their resolution in the built app. Preserve generated asset provenance and the previous accepted icon files as versioned evidence.
- GLASS07: Styling must preserve account/command/player ownership and actual controls. Do not invent connected accounts, catalog content or playback to decorate a screenshot.

## Assets and platform references

Glass sources and a flattened compatibility icon are in `Resources/Brand/Glass-v2/`. The separate foreground PNG is intended for a layered native icon source. The v1 assets remain unchanged until the glass task integrates and verifies its replacement. Generation used the built-in image_gen tool; exact prompts are stored beside the assets.

Apple documents native [Liquid Glass custom views](https://developer.apple.com/documentation/swiftui/applying-liquid-glass-to-custom-views), [`glassEffect`](https://developer.apple.com/documentation/swiftui/view/glasseffect(_:in:)), [`GlassEffectContainer`](https://developer.apple.com/documentation/swiftui/glasseffectcontainer), and the [layered Icon Composer workflow](https://developer.apple.com/icon-composer/). The selected macOS 27 SDK exposes glass button styles, and Icon Composer is installed within the selected Xcode. These observations establish candidate tools, not a runtime visual pass.

## Ownership and acceptance

V01 implements the shared native glass foundation, styles the current working app surfaces and integrates the glass icon. W09 extends it to browser/design components; W21 applies it to windows/menu/mini-player, W27 to complete Settings, and W28/W44 verify accessibility/localization/resource behavior. W47 and the final Critic include this addendum in the complete release audit. No live service gate is closed by visual work.

The operator prioritizes W08's service-connection investigation first, then V01. The full original feature inventory remains in scope.

## Polish direction — 2026-10-30 (account holder)

The account holder asked for: no UI overlaps anywhere, everything perfectly aligned, proper rounded corners, proper Liquid Glass, and light, tasteful animation used generously but never distracting. The player should be the most refined and enjoyable surface in the app. Their words: "Make sure that there is no UI overlaps … perfectly aligned. And we have proper rounds. and proper light animation … Proper liquid glass … the player is … most and interesting to use."

- GLASS07 — Alignment: no element overlaps another unless the overlap is a deliberate layer (glass over content). Edges, baselines and spacing follow one layout grid of 4/8 pt tokens. Margins stay consistent per surface at every supported window size.
- GLASS08 — Corners: one radius scale from design tokens. Nested shapes are concentric (inner radius = outer radius − inset), with no ad-hoc literal radii outside the design system.
- GLASS09 — Native Liquid Glass: use the system Liquid Glass APIs (glass effects, glass containers with morphing identities, glass button styles, interactive glass where it aids touch-like feedback), not imitation blur. Group neighbouring glass in containers so it refracts and merges correctly.
- GLASS10 — Motion: light, physical motion (springs, glass morphs, gentle highlight and tint transitions) on state changes and navigation, more than today but never decorative loops. It honours Reduce Motion, Reduce Transparency, Increase Contrast and Low Power Mode, and stops while windows are hidden (MOTION01–05, WIN10).
- GLASS11 — Player showcase: the bottom player and Now Playing are the most polished surfaces. The glass mini-player expands into Now Playing with a continuous morph, artwork-derived light and tint stay legible, progress and controls respond fluidly, and hover and press states give tactile feedback, without hiding ads (Playback addendum) and without overlapping content.
