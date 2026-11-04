import AppKit
import DesignSystem
import Domain
import SwiftUI

/// Manually hosted player windows use the same preference as the SwiftUI scenes.
/// The native window override keeps their chrome and SwiftUI content in agreement.
private struct AppAppearanceModifier: ViewModifier {
    @AppStorage("appearance", store: AppPreferences.store) private var stored = Appearance.system.rawValue
    @Environment(\.colorScheme) private var inheritedScheme

    func body(content: Content) -> some View {
        let appearance = Appearance(storedValue: stored)
        content.environment(\.colorScheme, appearance.colorScheme ?? inheritedScheme)
            .background(AppAppearanceWindowBridge(preference: appearance))
    }
}

extension View {
    func appAppearance() -> some View { modifier(AppAppearanceModifier()) }
}

struct AppAppearanceWindowBridge: NSViewRepresentable {
    let preference: Appearance
    func makeNSView(context: Context) -> Probe { Probe(preference: preference) }
    func updateNSView(_ view: Probe, context: Context) { view.configure(preference: preference) }

    final class Probe: NSView {
        private var preference: Appearance
        private var updatePending = false
        init(preference: Appearance) {
            self.preference = preference
            super.init(frame: .zero)
            setAccessibilityElement(false)
        }
        required init?(coder: NSCoder) { nil }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); apply() }
        func configure(preference: Appearance) {
            self.preference = preference
            guard !updatePending else { return }
            updatePending = true
            // Changing native appearance inside updateNSView can re-enter SwiftUI
            // layout. Coalesce onto the next main-loop turn, using the latest value.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.updatePending = false
                self.apply()
            }
        }
        private func apply() {
            guard let window else { return }
            let name: NSAppearance.Name? = switch preference {
            case .system: nil
            case .light: .aqua
            case .dark: .darkAqua
            }
            // Compare the resolved native name; AppKit may canonicalize appearance names.
            let resolved = name.flatMap(NSAppearance.init(named:))
            if window.appearance?.name != resolved?.name { window.appearance = resolved }
        }
    }
}
