import Testing
import Foundation
import DesignSystem
import SwiftUI
@testable import AppShell

/// N8: on a rapid skip (A then B) A's decode can finish after B's; only the artwork still current may publish its light.
@Suite @MainActor struct AccentOrderTests {
    private let a = Data([1]), b = Data([2])
    private let tintA = MusicTint(red: 1, green: 0, blue: 0), tintB = MusicTint(red: 0, green: 0, blue: 1)

    @Test func aSlowEarlierDecodeNeverOverwritesALaterOne() async throws {
        let sequencer = AccentSequencer()
        var published: [MusicTint?] = []
        let a = self.a, b = self.b, tintA = self.tintA, tintB = self.tintB
        // A starts first and finishes LAST; B starts second and finishes first.
        sequencer.publish(a, decode: { _ in try? await Task.sleep(for: .milliseconds(200)); return tintA }) { published.append($0) }
        sequencer.publish(b, decode: { _ in try? await Task.sleep(for: .milliseconds(20)); return tintB }) { published.append($0) }
        try await Task.sleep(for: .milliseconds(500))
        #expect(published == [tintB], "only B's light was published; A's late result was dropped (\(published))")
    }
    @Test func inOrderResultsAllPublish() async throws {
        let sequencer = AccentSequencer()
        var published: [MusicTint?] = []
        let tintA = self.tintA, tintB = self.tintB
        sequencer.publish(a, decode: { _ in tintA }) { published.append($0) }
        try await Task.sleep(for: .milliseconds(80))
        sequencer.publish(b, decode: { _ in tintB }) { published.append($0) }
        try await Task.sleep(for: .milliseconds(80))
        #expect(published == [tintA, tintB], "control: results that arrive in order are all published")
    }
    @Test func noArtworkClearsAndSupersedesAnInFlightDecode() async throws {
        let sequencer = AccentSequencer()
        var published: [MusicTint?] = []
        let tintA = self.tintA
        sequencer.publish(a, decode: { _ in try? await Task.sleep(for: .milliseconds(100)); return tintA }) { published.append($0) }
        sequencer.publish(nil) { published.append($0) }
        try await Task.sleep(for: .milliseconds(300))
        #expect(published == [nil], "the cleared state stands; the earlier decode is dropped")
    }
}

@Suite struct StackedWashTests {
    private func linear(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
    private func encoded(_ l: Double) -> Double { l <= 0.0031308 ? l * 12.92 : 1.055 * pow(l, 1 / 2.4) - 0.055 }
    /// Alpha-composites `layers` washes of the tint, one after the other, over a gray backdrop (sRGB blend), then WCAG contrast against the secondary gray.
    private func contrast(_ tint: MusicTint, opacities: [Double], backdrop: Double, scheme: ColorScheme) -> Double {
        var c = [encoded(backdrop), encoded(backdrop), encoded(backdrop)]
        let t = [tint.red, tint.green, tint.blue]
        for a in opacities { for i in 0..<3 { c[i] = (1 - a) * c[i] + a * t[i] } }
        let background = 0.2126 * linear(c[0]) + 0.7152 * linear(c[1]) + 0.0722 * linear(c[2])
        let g = MusicStyle.secondaryGray(scheme), text = 0.2126 * linear(g) + 0.7152 * linear(g) + 0.0722 * linear(g)
        return (max(background, text) + 0.05) / (min(background, text) + 0.05)
    }
    @Test(arguments: [ColorScheme.light, ColorScheme.dark])
    func theExpandedPlayersTwoLayersTogetherKeepTheSolvedContrast(scheme: ColorScheme) {
        let range = MusicTint.backdropRange(scheme)
        for (name, tint) in DesignTokenTests.hostileTints {
            let half = tint.glassOpacity(scheme: scheme) * ExpandedLight.share
            for backdrop in [range.lowerBound, range.upperBound] {
                let combined = contrast(tint, opacities: [half, half], backdrop: backdrop, scheme: scheme)
                #expect(combined >= MusicTint.minimumContrast, "\(name) \(scheme) backdrop \(backdrop): two half-washes give \(combined):1")
            }
        }
    }
    /// Control: two FULL washes (the glass tint plus a second light at the solved opacity, as before rework 3) do break the model for a saturated cover.
    @Test func twoFullWashesWouldBreakTheLightModeContrast() {
        let red = MusicTint(red: 0.9, green: 0.1, blue: 0.1)
        let full = red.glassOpacity(scheme: .light)
        let low = MusicTint.backdropRange(.light).lowerBound
        #expect(contrast(red, opacities: [full, full], backdrop: low, scheme: .light) < contrast(red, opacities: [full], backdrop: low, scheme: .light), "stacking lowers the contrast")
        #expect(contrast(red, opacities: [full, full, full], backdrop: low, scheme: .light) < MusicTint.minimumContrast, "three layers (hero + surface + glass) fall below the floor")
    }
}
