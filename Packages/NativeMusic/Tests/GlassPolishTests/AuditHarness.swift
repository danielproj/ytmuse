import AppKit
import SwiftUI
import DesignSystem
import Domain
import Observation
@testable import AppShell

/// The scene phase the hosted surface sees. The audit runs under `.active` (the native glass path); snapshots switch to
/// `.background` first, because an offscreen bitmap cannot rasterise native glass (it comes out blank) while the simplified
/// material path draws. Layout is identical in both.
@MainActor @Observable final class AuditPhase { var value: ScenePhase = .active }

/// Accessibility conditions the hosted surface sees (GLASS05). Test-only: the underscored setters are the only way to impose them on a hosted view.
enum AuditPolicyMode: String, CaseIterable, Sendable { case standard, reduceTransparency, increaseContrast }
/// W28 (L10N04, A11Y02): how the hosted surface reads. Double-length doubles every localized string (Foundation's pseudolanguage; the test process must
/// set `NSDoubleLocalizedStrings` before it renders anything, see `PseudoLocale.enableDoubleLength`), right-to-left flips the layout direction, and
/// large text sets the app's own text-size setting to 150% (`musicContentScale`; the platform does not scale third-party text).
enum AuditLocaleMode: String, CaseIterable, Sendable { case standard, doubleLength, rightToLeft, largeText }
private struct PhasedRoot<Content: View>: View {
    @Bindable var phase: AuditPhase
    let mode: AuditPolicyMode
    var localeMode: AuditLocaleMode = .standard
    let content: Content
    var body: some View {
        content.environment(\.scenePhase, phase.value)
            .environment(\.layoutDirection, localeMode == .rightToLeft ? .rightToLeft : .leftToRight)
            .environment(\.musicContentScale, localeMode == .largeText ? 1.5 : 1.0)
            .environment(\._accessibilityReduceTransparency, mode == .reduceTransparency)
            .environment(\._colorSchemeContrast, mode == .increaseContrast ? .increased : .standard)
    }
}

/// Frames reported by `auditRoot`, kept outside the view so a test can read the latest settled set.
@MainActor final class FrameBox { var frames: [AuditFrame] = [] }

final class OffscreenAuditWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

struct AuditSize: Hashable, Sendable, CustomStringConvertible {
    let name: String; let width: Double; let height: Double
    var description: String { name }
    static let minimum = AuditSize(name: "minimum", width: 840, height: 560)
    static let standard = AuditSize(name: "default", width: 1240, height: 820)
    static let large = AuditSize(name: "large", width: 1680, height: 1050)
    /// The narrowest width at which the queue panel is inline (BrowserLayout.showsTrailing): where the expanded player's accessories wrap.
    static let queueInline = AuditSize(name: "queueInline", width: 1120, height: 780)
    static let all = [minimum, standard, large]
}

enum AuditScheme: String, CaseIterable, Sendable { case light, dark
    var appearance: NSAppearance? { NSAppearance(named: self == .dark ? .darkAqua : .aqua) }
}

/// An offscreen window hosting one SwiftUI surface, never ordered where a person sees it and never key.
@MainActor final class AuditHost {
    /// The style every audit host renders in (see the hosting line below).
    static let style = AppStyle.ytmuse
    let window: OffscreenAuditWindow
    let controller: NSHostingController<AnyView>
    let box = FrameBox()
    let phase = AuditPhase()
    var size: AuditSize
    /// `shell` hosts the surface the way the app's window does (unified toolbar, scene-bridged title, the main-window contract), so the minimum size
    /// is the real minimum and a layout that needs more room than the window has overflows here exactly as it would in the app.
    init<Content: View>(_ content: Content, size: AuditSize, scheme: AuditScheme, title: Bool = true, mode: AuditPolicyMode = .standard, shell: Bool = false, localeMode: AuditLocaleMode = .standard, intrinsicHeight: Bool = false) {
        self.size = size
        let box = self.box
        let hosted = shell ? AnyView(content.modifier(MainWindowContract(state: MainWindowContractState()))) : AnyView(content)
        let mirrored = localeMode == .rightToLeft
        // These audits pin the YTMuse style's geometry (its padded glass sidebar panel, its panels); Standard is the default since APPEARANCE-STYLE,
        // so the style is stated rather than inherited.
        controller = NSHostingController(rootView: AnyView(PhasedRoot(phase: phase, mode: mode, localeMode: localeMode, content: hosted.auditRoot { box.frames = mirrored ? AuditHost.mirrorHorizontally($0) : $0 }).environment(\.musicAppStyle, AuditHost.style)))
        controller.sizingOptions = shell ? [.minSize] : []
        if shell { controller.sceneBridgingOptions = [.toolbars, .title] }
        // NSPopover receives no fixed height in production. Measure the same single
        // hosting controller instead of auditing unused space in an invented window.
        if intrinsicHeight {
            let fitted = controller.sizeThatFits(in: CGSize(width: size.width, height: CGFloat.greatestFiniteMagnitude))
            self.size = AuditSize(name: size.name, width: size.width, height: ceil(fitted.height))
        }
        let hostSize = self.size
        window = OffscreenAuditWindow(contentRect: CGRect(x: -20000, y: -20000, width: hostSize.width, height: hostSize.height),
                                      styleMask: title ? [.titled, .resizable, .closable, .miniaturizable, .fullSizeContentView] : [.borderless], backing: .buffered, defer: false)
        window.appearance = scheme.appearance
        if shell { window.title = "YTMuse"; window.toolbarStyle = .unified }
        window.contentViewController = controller
        window.ignoresMouseEvents = true; window.alphaValue = 0
        window.orderFrontRegardless()
        window.setFrame(CGRect(x: -20000, y: -20000, width: hostSize.width, height: hostSize.height), display: true)
    }
    /// W28: the audit rules are stated in leading/trailing terms but measured from the left edge. In a right-to-left layout every frame is reflected about
    /// the window's vertical axis first, so "the sidebar is on the leading side" and "offsets from the container's origin" keep their meaning.
    static func mirrorHorizontally(_ frames: [AuditFrame]) -> [AuditFrame] {
        guard let width = frames.first(where: { $0.tag.name == LayoutAudit.windowName })?.rect.width else { return frames }
        return frames.map { AuditFrame(tag: $0.tag, rect: CGRect(x: width - $0.rect.maxX, y: $0.rect.minY, width: $0.rect.width, height: $0.rect.height)) }
    }
    func settle(until condition: (() -> Bool)? = nil, milliseconds: Int = 1200) async {
        let steps = max(1, milliseconds / 25)
        for step in 0..<steps {
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            try? await Task.sleep(for: .milliseconds(25))
            if let condition, step > 4, condition() { break }
        }
        for _ in 0..<6 { window.contentView?.layoutSubtreeIfNeeded(); window.displayIfNeeded(); try? await Task.sleep(for: .milliseconds(25)) }
    }
    /// Waits, bounded, until every `required` tag has been reported AND the reported frames have stopped changing for `stableFor` consecutive polls.
    /// Nothing is dropped or relaxed: a tag that is never reported is still absent when the bound ends, and `violations(expecting:)` then fails it as missing.
    /// The wait only exists because the preference that carries the frames lags layout on a loaded machine (the suites of a test run render in parallel).
    @discardableResult
    func settleUntilReported(_ required: [String], milliseconds: Int = AuditHost.reportBoundMilliseconds, stableFor: Int = 4) async -> Bool {
        let steps = max(1, milliseconds / 25)
        var previous: [AuditFrame] = [], stable = 0, complete = false
        for _ in 0..<steps {
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            try? await Task.sleep(for: .milliseconds(25))
            let names = Set(box.frames.map(\.tag.name))
            complete = required.allSatisfy(names.contains)
            stable = complete && box.frames == previous ? stable + 1 : 0
            previous = box.frames
            if stable >= stableFor { break }
        }
        for _ in 0..<2 { window.contentView?.layoutSubtreeIfNeeded(); window.displayIfNeeded(); try? await Task.sleep(for: .milliseconds(25)) }
        return complete
    }
    /// The longest a surface may take to report its tags once it is hosted: ten times what an idle machine needs.
    static let reportBoundMilliseconds = 6000
    var bounds: CGRect { box.frames.first { $0.tag.name == LayoutAudit.windowName }?.rect ?? CGRect(x: 0, y: 0, width: size.width, height: size.height) }
    func violations(expecting required: [String] = []) -> [AuditViolation] { LayoutAudit.evaluate(box.frames, bounds: bounds, expecting: required) }
    /// A PNG of the hosted surface at 1x. Offscreen rendering draws the SwiftUI layers; the native glass effect itself may rasterise
    /// as its fallback, so the PNG shows geometry, corners, alignment and content, and is not a Liquid Glass fidelity check.
    func snapshot(to url: URL) async throws {
        phase.value = .background
        await settle(milliseconds: 400)
        guard let view = window.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw CocoaError(.fileWriteUnknown) }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }
    func close() { window.orderOut(nil); window.contentViewController = nil }
}

/// Where a run writes its snapshots and audit report (unset in an ordinary test run).
enum AuditOutput {
    static var directory: URL? { ProcessInfo.processInfo.environment["V02_SNAPSHOT_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) } }
    static var report: URL? { ProcessInfo.processInfo.environment["V02_AUDIT_REPORT"].map { URL(fileURLWithPath: $0) } }
}
