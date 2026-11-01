import Features
import Foundation
import Observation
import SwiftUI

// W24 rework 1 (finding 4). A Search asked for by an App Intent is a REQUEST that waits for a window, not a notification a window may miss.
//
// The intent posts the words; the first window that is visible and frontmost performs them (types the query and presses Return, the same use case
// the search field's Return runs) and marks the request performed; the intent waits for that, and answers "searched" only if it happened. A request
// no window took within the timeout is withdrawn and reported as not done. A window that appears AFTER the post (a cold launch, a restored window)
// takes it when it becomes visible, and two windows never both take it.

@MainActor @Observable final class SearchRequestInbox {
    struct Request: Equatable, Sendable { let serial: Int; let text: String }
    private(set) var pending: Request?
    private(set) var performedSerial = 0
    @ObservationIgnored private var serial = 0
    /// The serials windows performed (recent ones only).
    @ObservationIgnored private var performed: Set<Int> = []

    /// Posts a request (a newer one replaces an unclaimed older one) and returns its serial.
    func post(_ text: String) -> Int {
        serial += 1
        pending = Request(serial: serial, text: text)
        return serial
    }
    /// An eligible window takes the pending request and performs it, exactly once. False when nothing is pending or the window is not eligible.
    @discardableResult func claim(eligible: Bool, perform: (String) -> Void) -> Bool {
        guard eligible, let request = pending else { return false }
        pending = nil
        perform(request.text)
        performedSerial = request.serial
        performed.insert(request.serial)
        if performed.count > 64 { performed = performed.filter { $0 > request.serial - 32 } }
        return true
    }
    /// Posts the request, brings a window forward with `show`, and waits for a window to perform it. True only if one did; otherwise the request is
    /// withdrawn, so a window that appears later never runs a search the person was told did not happen.
    func request(_ text: String, show: () -> Void, timeout: Duration) async -> Bool {
        let serial = post(text)
        show()
        if await waitUntilPerformed(serial, timeout: timeout) { return true }
        withdraw(serial)
        return false
    }
    /// Withdraws whatever is pending (an account barrier). Intents waiting on it are told, at once, that their request was not performed.
    func clear() { pending = nil }
    func withdraw(_ serial: Int) { if pending?.serial == serial { pending = nil } }
    /// True only if a window performed THIS request. A request that a newer one replaced, that was withdrawn, or that no window took within `timeout` was not
    /// performed, and is reported so at once (a replaced request does not wait out its timeout: its words will never be searched).
    func waitUntilPerformed(_ serial: Int, timeout: Duration) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while !performed.contains(serial), pending?.serial == serial, ContinuousClock.now < deadline, !Task.isCancelled { try? await Task.sleep(for: .milliseconds(25)) }
        return performed.contains(serial)
    }
}

/// The window side. It claims the pending request when the window appears, when the window becomes visible, and when a request arrives; `eligible`
/// says whether THIS window may take it (visible, and frontmost or no other main window).
struct SearchRequestReceiver: ViewModifier {
    let inbox: SearchRequestInbox
    let search: SearchModel
    let visible: Bool
    let isFrontmost: @MainActor () -> Bool
    let open: @MainActor () -> Void
    func body(content: Content) -> some View {
        content
            .onAppear { consume() }
            .onChange(of: visible) { _, _ in consume() }
            .onChange(of: inbox.pending) { _, _ in consume() }
    }
    @MainActor private func consume() {
        inbox.claim(eligible: visible && isFrontmost()) { text in
            open()
            search.query = text
            search.submit()
        }
    }
}
