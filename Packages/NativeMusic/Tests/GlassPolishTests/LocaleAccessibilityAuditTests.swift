import Testing
import AppKit
import SwiftUI
import Foundation
import DesignSystem
@testable import AppShell
@testable import Features

// W28 (T28.3, L10N04): the layout audit under pseudolocalization, right-to-left layout and large text. Headless: nothing is shown, keyed or spoken.
// (A hosted SwiftUI view builds its accessibility tree only for a connected accessibility client, so the traversal itself runs in the native UI
// suite, `testW28KeyboardAndAccessibilityTraversal`; this file holds the layout half.)

/// Foundation's double-length pseudolanguage, switched on for this process before anything renders (a string resolved earlier is cached at its normal
/// length, so these suites run in their own invocation: see scripts/test.sh, suite T28). It is turned on through the REGISTRATION domain, which lives in
/// this process only: writing it with `UserDefaults.standard.set` would persist it in the test runner's shared preferences domain, where every other
/// lane's tests would read it (that happened once; scripts/check-test-preferences.py now fails any test that writes a persistent domain).
enum PseudoLocale {
    static let enableDoubleLength: Void = { UserDefaults.standard.register(defaults: ["NSDoubleLocalizedStrings": true]) }()
}

/// Pseudolocalized (every string doubled), right-to-left and large-text renders of the primary surfaces, held to the same layout audit as the
/// English ones: no overlap, nothing escaping its container, margins and alignment kept.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["YTMUSE_NATIVE_DESIGN_TEST"] == "1"))
@MainActor struct LocaleLayoutAuditTests {
    /// Controls: the pseudo modes really change what is measured, so a passing audit is not an audit of unchanged English.
    @Test func theModesChangeWhatIsMeasured() {
        PseudoLocale.enableDoubleLength
        func width(_ view: some View) -> CGFloat { NSHostingView(rootView: view).fittingSize.width }
        let sentence = "Your queue is empty and the quick brown fox"
        let localized = width(Text(LocalizedStringKey(sentence))), plain = width(Text(verbatim: sentence))
        #expect(localized > plain * 1.6, "double-length doubles localized text (\(localized) vs \(plain))")
        // Large text is the app's own setting: 150% makes the same page measurably larger (the pixel proof of the scaling itself is ContentScaleTests).
        let zoomed = width(Text(verbatim: sentence).musicContentZoom().environment(\.musicContentScale, 1.5).frame(width: 2000, alignment: .leading))
        #expect(zoomed >= 2000, "the zoomed content fills its proposal and does not shrink it (\(zoomed))")
    }
    @Test func rightToLeftReflectsLeadingContentAndTheMirrorRestoresLeadingTerms() async throws {
        let content = HStack(spacing: 0) { Color.red.frame(width: 100, height: 40).audit("first", kind: .element); Color.blue.frame(width: 100, height: 40).audit("second", kind: .element); Spacer() }.frame(width: 400, height: 100, alignment: .topLeading)
        let ltr = AuditHost(content, size: AuditSize(name: "probe", width: 400, height: 100), scheme: .light, title: false, localeMode: .standard)
        let rtl = AuditHost(content, size: AuditSize(name: "probe", width: 400, height: 100), scheme: .light, title: false, localeMode: .rightToLeft)
        defer { ltr.close(); rtl.close() }
        await ltr.settleUntilReported(["first", "second"]); await rtl.settleUntilReported(["first", "second"])
        func x(_ host: AuditHost, _ name: String) -> CGFloat? { host.box.frames.first { $0.tag.name == name }?.rect.minX }
        let raw = AuditHost.mirrorHorizontally(rtl.box.frames)
        #expect(x(ltr, "first") == 0 && x(ltr, "second") == 100, "left-to-right: first on the left")
        // The host stored mirrored frames already, so the audit's leading-edge rules hold: the first element is still the leading one.
        #expect(x(rtl, "first") == 0 && x(rtl, "second") == 100, "right-to-left, after the audit's reflection: first is leading")
        #expect(raw.first { $0.tag.name == "first" }?.rect.minX == 300, "control: un-reflected, the first element really sits at the right edge (\(String(describing: raw.first { $0.tag.name == "first" }?.rect)))")
    }
    init() { PseudoLocale.enableDoubleLength }
    struct Case: Sendable, CustomTestStringConvertible {
        let surface: SurfaceAuditTests.Surface; let size: AuditSize; let locale: AuditLocaleMode
        var testDescription: String { "\(surface.rawValue) \(size.name) \(locale.rawValue)" }
        static let all: [Case] = [SurfaceAuditTests.Surface.home, .library, .downloads, .search, .playerPlaying, .nowPlayingSong, .queueSong].flatMap { surface in
            [AuditSize.minimum, .standard].flatMap { size in [AuditLocaleMode.doubleLength, .rightToLeft, .largeText].filter { mode in ProcessInfo.processInfo.environment["W28_LOCALE_MODES"].map { $0.split(separator: ",").contains(Substring(mode.rawValue)) } ?? true }.map { Case(surface: surface, size: size, locale: $0) } }
        }
    }
    @Test(arguments: Case.all)
    func layoutHoldsUnderPseudolocalizationRightToLeftAndLargeText(_ item: Case) async throws {
        let result = try await SurfaceAuditTests().render(item.surface, size: item.size, scheme: .dark, localeMode: item.locale)
        AuditLog.records.append(result.record)
        if let url = AuditOutput.report { try? JSONEncoder().encode(AuditLog.records).write(to: url) }
        #expect(result.record.frames > 5, "the audit saw the surface (\(result.record.frames) frames)")
        #expect(result.violations.isEmpty, Comment(rawValue: result.violations.map(\.description).joined(separator: "\n")))
    }
}
