import Testing
import SwiftUI
@testable import DesignSystem

@Suite struct DesignTokenTests {
    @Test func radiusScaleIsOrderedAndOnTheGrid() {
        let scale = MusicRadius.scale
        #expect(scale == scale.sorted() && Set(scale).count == scale.count)
        for radius in scale { #expect(MusicSpace.isOnGrid(radius, tolerance: 0), "radius \(radius) is a multiple of the 4 pt grid") }
        for corner in MusicCorner.allCases where corner != .playerInset && corner != .panelInset { #expect(scale.contains(corner.radius), "\(corner) maps to a scale step") }
        // The two derived roles are concentric by construction, never literals.
        #expect(MusicCorner.playerInset.radius == MusicCorner.player.radius - MusicSpace.sm && MusicCorner.panelInset.radius == MusicCorner.panel.radius - MusicSpace.md)
    }
    @Test func nestedShapesAreConcentric() {
        #expect(MusicRadius.inner(of: MusicRadius.xl, inset: MusicSpace.md) == 8)
        #expect(MusicRadius.inner(of: MusicRadius.xl, inset: MusicSpace.xs) == 16)
        #expect(MusicRadius.inner(of: MusicRadius.xs, inset: MusicSpace.lg) == 0, "never negative")
        #expect(MusicCorner.player.inner(inset: MusicSpace.sm) == MusicCorner.player.radius - MusicSpace.sm)
        // The artwork inside a 12 pt inset of the player is not rounder than the player around it.
        #expect(MusicCorner.thumbnail.radius <= MusicCorner.player.radius - MusicSpace.xxs)
    }
    @Test func spacingScaleSitsOnTheFourPointGrid() {
        for step in MusicSpace.scale { #expect(MusicSpace.isOnGrid(step, tolerance: 0)) }
        #expect(MusicSpace.isOnGrid(7.9) && MusicSpace.isOnGrid(8.4) && !MusicSpace.isOnGrid(10) && !MusicSpace.isOnGrid(6))
        #expect(MusicStyle.radius == MusicRadius.xl && MusicStyle.compact == MusicSpace.xs && MusicStyle.spacing == MusicSpace.md && MusicStyle.inset == MusicSpace.lg,
                "the pre-V02 constants are aliases of the scale, so existing call sites cannot drift")
    }
    @Test func nestedContentIsSetInOneStepPerLevelUpToTheCap() {
        #expect(MusicSpace.nestedIndent(level: 1) == MusicSpace.lg && MusicSpace.nestedIndent(level: 2) == MusicSpace.lg * 2 && MusicSpace.nestedIndent(level: 3) == MusicSpace.lg * 3)
        #expect(MusicSpace.nestedIndent(level: 0) == MusicSpace.lg && MusicSpace.nestedIndent(level: -2) == MusicSpace.lg, "nested content is always set in")
        #expect(MusicSpace.nestedIndent(level: 12) == MusicSpace.nestedIndent(level: MusicSpace.maximumNesting), "a deep thread stops at the cap")
        for level in -1...8 { #expect(MusicSpace.isOnGrid(MusicSpace.nestedIndent(level: level), tolerance: 0)) }
    }
    @Test func elevationGrowsWithLevel() {
        let levels = MusicElevation.allCases
        for (lower, higher) in zip(levels, levels.dropFirst()) {
            #expect(higher.radius > lower.radius && higher.opacity > lower.opacity && higher.offset > lower.offset)
        }
        #expect(MusicElevation.flat.radius == 0 && MusicElevation.flat.opacity == 0)
    }
    @Test func motionBudgetsStillHoldAndReduceMotionKeepsOnlyCrossfades() {
        for motion in MusicMotion.allCases {
            #expect(motion.duration(reduceMotion: false, lowPower: false, visible: false) == 0, "\(motion): a hidden window animates nothing")
            if motion != .hoverPress && motion != .loading && motion != .reveal && motion != .playerMorph {
                #expect(motion.duration(reduceMotion: true, lowPower: false, visible: true) == 0, "\(motion): Reduce Motion is instant")
            } else {
                #expect(motion.duration(reduceMotion: true, lowPower: false, visible: true) <= 0.1, "\(motion): a short crossfade")
            }
            #expect(motion.animation(reduceMotion: false, lowPower: false, visible: false) == nil)
        }
        for motion in [MusicMotion.artworkColor, .artworkExpansion, .playerMorph] where motion != .playerMorph { #expect(motion.duration(reduceMotion: false, lowPower: true, visible: true) == 0) }
        #expect(MusicMotion.playerMorph.duration(reduceMotion: false, lowPower: true, visible: true) == 0, "Low Power: instant")
        #expect(MusicMotion.playerMorph.duration(reduceMotion: true, lowPower: false, visible: true) == 0.1, "Reduce Motion: a 0.1 s crossfade")
        #expect((0.14...0.2).contains(MusicMotion.selection.seconds) && (0.22...0.3).contains(MusicMotion.reveal.seconds) && (0.3...0.36).contains(MusicMotion.playerMorph.seconds))
        #expect(MusicMotion.allCases.map(\.seconds).max()! <= 0.75, "no token exceeds the colour-transition ceiling")
    }
    // MARK: Tint contrast, checked independently of the solver
    /// sRGB-encoded gray whose relative luminance is `luminance`.
    private func gray(forLuminance luminance: Double) -> Double { luminance <= 0.0031308 ? luminance * 12.92 : 1.055 * pow(luminance, 1 / 2.4) - 0.055 }
    private func linear(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
    private func luminance(_ r: Double, _ g: Double, _ b: Double) -> Double { 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b) }
    /// What a viewer gets: the backdrop gray alpha-composited with the tint in sRGB space (the usual blend), then WCAG contrast against the real secondary gray.
    private func composedContrast(_ tint: MusicTint, opacity: Double, backdropLuminance: Double, scheme: ColorScheme) -> Double {
        let backdrop = gray(forLuminance: backdropLuminance)
        let blend = { (t: Double) in (1 - opacity) * backdrop + opacity * t }
        let background = luminance(blend(tint.red), blend(tint.green), blend(tint.blue))
        let text = luminance(MusicStyle.secondaryGray(scheme), MusicStyle.secondaryGray(scheme), MusicStyle.secondaryGray(scheme))
        return (max(background, text) + 0.05) / (min(background, text) + 0.05)
    }
    static let hostileTints: [(String, MusicTint)] = [("red", .init(red: 0.9, green: 0.1, blue: 0.1)), ("yellow", .init(red: 1, green: 0.9, blue: 0)), ("white", .init(red: 1, green: 1, blue: 1)),
                                                      ("black", .init(red: 0, green: 0, blue: 0)), ("blue", .init(red: 0.1, green: 0.2, blue: 1)), ("grey", .init(red: 0.5, green: 0.5, blue: 0.5)),
                                                      ("cream", .init(red: 1, green: 0.97, blue: 0.85))]
    @Test(arguments: [ColorScheme.light, ColorScheme.dark])
    func theUntintedBackdropAlreadyKeepsTheSecondaryText(scheme: ColorScheme) {
        for backdrop in [MusicTint.backdropRange(scheme).lowerBound, MusicTint.backdropRange(scheme).upperBound] {
            let plain = composedContrast(MusicTint(red: 0, green: 0, blue: 0), opacity: 0, backdropLuminance: backdrop, scheme: scheme)
            #expect(plain >= MusicTint.minimumContrast, "\(scheme) backdrop \(backdrop): secondary text alone is \(plain):1")
        }
    }
    @Test(arguments: [ColorScheme.light, ColorScheme.dark])
    func noArtworkTintCostsSecondaryTextItsContrastOnAnyPlausibleBackdrop(scheme: ColorScheme) {
        let range = MusicTint.backdropRange(scheme)
        for (name, tint) in Self.hostileTints {
            let opacity = tint.glassOpacity(scheme: scheme)
            #expect(opacity <= MusicTint.maximumOpacity, "\(name)")
            // Every backdrop in the plausible range, not just its ends and not the solver's own luminance model.
            for step in 0...10 {
                let backdrop = range.lowerBound + (range.upperBound - range.lowerBound) * Double(step) / 10
                let result = composedContrast(tint, opacity: opacity, backdropLuminance: backdrop, scheme: scheme)
                #expect(result >= MusicTint.minimumContrast, "\(name) \(scheme) backdrop \(backdrop): \(result):1 at opacity \(opacity)")
            }
        }
    }
    /// Control: the check above is load-bearing. Applying the wash at full strength (as the old solver's optimistic backdrop allowed) fails it.
    @Test func theCheckFailsForAWashThatIgnoresTheRealBackdrop() {
        let white = MusicTint(red: 1, green: 1, blue: 1), yellow = MusicTint(red: 1, green: 0.9, blue: 0)
        #expect(composedContrast(white, opacity: 0.05, backdropLuminance: 0.10, scheme: .dark) < MusicTint.minimumContrast, "the previous model allowed 0.05 of white over a 0.10 dark glass")
        #expect(composedContrast(yellow, opacity: 0.06, backdropLuminance: 0.10, scheme: .dark) < MusicTint.minimumContrast)
        #expect(white.glassOpacity(scheme: .dark) < 0.05 && yellow.glassOpacity(scheme: .dark) < 0.06, "the solver now withholds that wash")
    }
}

@Suite struct CornerCapTests {
    @Test func aDerivedCornerNeverMakesASmallElementACircle() {
        // The 40 pt compact thumbnail at radius 20 was a circle; capped to a quarter of the edge it is not.
        #expect(MusicCorner.playerInset.radius == 20)
        #expect(MusicCorner.playerInset.radius(forEdge: 40) == 10 && MusicCorner.playerInset.radius(forEdge: 52) == 13)
        #expect(MusicCorner.playerInset.radius(forEdge: 40) < 40 / 2, "well short of a circle")
        #expect(MusicCorner.thumbnail.radius(forEdge: 160) == 8, "a large element keeps the role's own radius")
        for corner in MusicCorner.allCases { #expect(corner.radius(forEdge: 40) <= 10) }
    }
}
