import SwiftUI
import AppKit
import Observation

/// One instance per main window. Chrome is measured from public AppKit layout, never guessed.
@MainActor @Observable final class MainWindowContractState {
    var chrome = CGSize.zero
    @ObservationIgnored var snapshot: [String: String] = [:]
}
struct MainWindowContract: ViewModifier {
    @State private var state: MainWindowContractState
    init(state: MainWindowContractState = .init()) { _state = State(initialValue: state) }
    func body(content: Content) -> some View {
        content.frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(MainWindowConfiguration(state: state).frame(width: 0, height: 0))
    }
}
/// Lifecycle/configuration adapter, not an accessibility element or hit-test surface.
private struct MainWindowConfiguration: NSViewRepresentable {
    let state: MainWindowContractState
    func makeNSView(context: Context) -> ConfigurationView { .init(state: state) }
    func updateNSView(_ view: ConfigurationView, context: Context) { view.state = state; view.schedule() }
    static func dismantleNSView(_ view: ConfigurationView, coordinator: ()) { view.detach() }
    final class ConfigurationView: NSView {
        var state: MainWindowContractState
        private var observers: [NSObjectProtocol] = []
        private var layoutObservation: NSKeyValueObservation?
        private var minimumObservation: NSKeyValueObservation?
        private var scheduled = false
        private weak var constrainedView: NSView?
        private var sizeConstraints: [NSLayoutConstraint] = []
        private let debug = ProcessInfo.processInfo.environment["YTMUSE_NATIVE_DESIGN_TEST"] == "1"
        init(state: MainWindowContractState) { self.state = state; super.init(frame: .zero); setAccessibilityElement(false) }
        required init?(coder: NSCoder) { nil }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow(); detach()
            guard let window else { return }
            let center = NotificationCenter.default
            for name in [NSWindow.didResizeNotification, NSWindow.didUpdateNotification, NSWindow.didChangeScreenNotification] {
                observers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.schedule() } })
            }
            layoutObservation = window.observe(\.contentLayoutRect, options: [.new]) { [weak self] _, _ in
                DispatchQueue.main.async { [weak self] in self?.schedule() }
            }
            minimumObservation = window.observe(\.contentMinSize, options: [.new]) { [weak self] _, _ in
                DispatchQueue.main.async { [weak self] in self?.schedule() }
            }
            schedule()
        }
        func detach() {
            for token in observers { NotificationCenter.default.removeObserver(token) }; observers.removeAll(); layoutObservation = nil; minimumObservation = nil
            NSLayoutConstraint.deactivate(sizeConstraints); sizeConstraints.removeAll(); constrainedView = nil
        }
        func schedule() {
            guard !scheduled else { return }; scheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }; self.scheduled = false
                guard let window = self.window else { return }
                let chrome = CGSize(width: max(0, window.frame.width - window.contentLayoutRect.width), height: max(0, window.frame.height - window.contentLayoutRect.height))
                if self.state.chrome != chrome { self.state.chrome = chrome }
                guard let content = window.contentView else { return }
                // NSWindow ignores minSize under Auto Layout. Constrain the public content view,
                // converting the OUTER contract using its actual frame-to-content difference.
                let minimum = CGSize(width: max(0, 840 - (window.frame.width - content.frame.width)), height: max(0, 560 - (window.frame.height - content.frame.height)))
                if window.contentMinSize != minimum { window.contentMinSize = minimum }
                if self.constrainedView !== content {
                    NSLayoutConstraint.deactivate(self.sizeConstraints)
                    self.constrainedView = content
                    self.sizeConstraints = [content.widthAnchor.constraint(greaterThanOrEqualToConstant: minimum.width), content.heightAnchor.constraint(greaterThanOrEqualToConstant: minimum.height)]
                    NSLayoutConstraint.activate(self.sizeConstraints)
                } else {
                    self.sizeConstraints[0].constant = minimum.width; self.sizeConstraints[1].constant = minimum.height
                }
                let values = ["pid": "\(ProcessInfo.processInfo.processIdentifier)", "window": "\(window.windowNumber)", "frame": "\(window.frame)", "contentLayoutRect": "\(window.contentLayoutRect)", "contentMinSize": "\(window.contentMinSize)", "outerMinSize": "\(window.minSize)", "measuredChrome": "\(chrome)", "toolbarVisible": "\(window.toolbar?.isVisible ?? false)"]
                if self.state.snapshot != values {
                    self.state.snapshot = values
                    #if DEBUG
                    if self.debug { print("W09_WINDOW_PUBLIC \(values)") }
                    #endif
                }
            }
        }
    }
}
