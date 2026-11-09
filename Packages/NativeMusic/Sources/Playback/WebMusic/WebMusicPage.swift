import AppKit
import Foundation
import WebKit

/// Which native generation the main-frame navigation in flight carries, from its
/// request URL at policy time (the bootstrap later strips it from the visible URL).
/// A server redirect of that navigation keeps it; a page-initiated navigation, or
/// one that follows a cancelled/failed provisional navigation, has none.
public struct WebMusicNavigationTracker: Sendable, Equatable {
    public private(set) var pending: UInt64?
    public private(set) var provisional = false
    public init() {}
    public mutating func policy(_ url: URL?) { pending = WebKitMusicPage.track(url, pending: pending, provisional: provisional); provisional = true }
    public mutating func commit() -> UInt64? { defer { pending = nil; provisional = false }; return pending }
    public mutating func provisionalEnded() { pending = nil; provisional = false }
}

/// Monotonic ordering for cookie-store snapshots: each read takes the next number,
/// and a reply is applied only if it is newer than every reply already applied.
public struct WebMusicSnapshotSequence: Sendable, Equatable {
    public private(set) var issued: UInt64 = 0
    public private(set) var applied: UInt64 = 0
    public init() {}
    public mutating func begin() -> UInt64 { issued += 1; return issued }
    public mutating func accept(_ sequence: UInt64) -> Bool {
        guard sequence > applied, sequence <= issued else { return false }
        applied = sequence; return true
    }
}

public struct WebMusicPageDiagnostics: Sendable, Equatable {
    public let persistent: Bool
    public let requiresUserAction: Bool
    public let canOpenWindows: Bool
    public let mainFrameOnlyScripts: Int
    public let scripts: Int
    public let windowVisible: Bool
    public let cookieNames: [String]
    /// The application name appended to WebKit's user agent (PL1).
    public let applicationName: String?
    /// True when WebKit may not throttle or suspend the page while it is not visible (PL2).
    public let neverSuspendedWhenInactive: Bool
    /// The page's current inactive scheduling policy as WebKit reports it (`none`, `throttle`, `suspend`).
    public let inactiveSchedulingPolicy: String
}

/// Supplies the player's signed-in session and receives cookie rotation. The
/// app composes this from the active account's exact Keychain record; it is
/// bound to one account generation and refuses work for any other.
public protocol WebMusicCookieSource: Sendable {
    /// The allowlisted `.youtube.com` cookies to load before the first document.
    func playerCookies() async throws -> [HTTPCookie]
    /// Cookies the player's store now holds for `youtube.com` (after a change).
    func recordRotation(_ cookies: [HTTPCookie]) async
}

/// Events from the hidden page into the player. Everything arrives on the main actor.
@MainActor public protocol WebMusicPageDelegate: AnyObject {
    func page(received body: Any, from frame: WebMusicFrame)
    /// A main-frame document committed; `document` is the generation in its URL, if any.
    func pageCommitted(document: UInt64?)
    func pageFailed(_ failure: WebMusicFailure)
    func pageCookiesChanged(_ cookies: [HTTPCookie])
}

/// The hidden player surface. The real one is `WebKitMusicPage`; tests use a fake.
@MainActor public protocol WebMusicPage: AnyObject {
    func install(cookies: [HTTPCookie]) async
    func load(_ url: URL)
    func run(_ invocation: WebMusicCommand.Invocation) async -> WebMusicCommandReply
    /// P5-1: while nothing plays, WebKit may throttle the hidden page's timers when it is not visible
    /// (`.throttle`, never `.suspend`); before anything plays again the player turns it back to `.none`.
    func setThrottled(_ throttled: Bool)
    /// Stops media, removes handlers/observers and releases the web view and its
    /// non-persistent store. Idempotent.
    func teardown() async
    /// W17: moves the SAME web view (and so the same playing media, with no reload) into a native surface's view, or back into the
    /// hidden host window when `host` is nil. Only the view moves; nothing is paused, loaded or restarted.
    func attachVideo(to host: NSView?)
    /// W17: a one-off read of the `<video>` element (picture size, frames, geometry). Nil when the page has none or does not answer.
    func measureVideo() async -> WebMusicVideoMeasurement?
    /// Rework F2: real AppKit answers about input reaching the page. Nil for a fake page.
    func inputFacts() -> WebMusicInputFacts?
}
public extension WebMusicPage {
    func attachVideo(to host: NSView?) {}
    func measureVideo() async -> WebMusicVideoMeasurement? { nil }
    func inputFacts() -> WebMusicInputFacts? { nil }
}

/// The hidden player's web view. It is never interactive (rework F2): wherever it lives, in the hidden host or on a native surface, it
/// answers no hit test, never becomes first responder, ignores key and mouse events and offers no context menu, so YouTube's page controls,
/// keyboard shortcuts and WebKit's media menu can never bypass the native command layer. Script injection (`callAsyncJavaScript`) is not input.
final class NonInteractiveWebView: WKWebView {
    override var acceptsFirstResponder: Bool { false }
    override func becomeFirstResponder() -> Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func menu(for event: NSEvent) -> NSMenu? { nil }
    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) { menu.removeAllItems() }
    override func performKeyEquivalent(with event: NSEvent) -> Bool { false }
    override func keyDown(with event: NSEvent) {}
    override func keyUp(with event: NSEvent) {}
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {}
    override func rightMouseDown(with event: NSEvent) {}
    override func otherMouseDown(with event: NSEvent) {}
    override func scrollWheel(with event: NSEvent) {}

    /// The narrowest page YouTube Music is laid out at, in CSS pixels. Below 616 px the signed-in page swaps its player for a compact one
    /// with no Shuffle or Repeat toggle and no Like/Dislike group (`matchMedia("(max-width: 615px)")` in its own player code, seen live on
    /// 2026-11-09: a 574 px page had neither, a 1663 px one both), and the app reads all four from those controls. The hidden page and every
    /// video surface (an inline picture can be a few hundred points wide) are therefore zoomed out until the page is at least this wide, so
    /// the controls exist whatever the frame; the picture still fills the frame.
    static let minimumLayoutWidth: CGFloat = 800
    /// The page zoom that lays a frame `width` points wide out at least `minimumLayoutWidth` CSS pixels wide: 1 when it already is.
    static func pageZoom(forWidth width: CGFloat) -> CGFloat {
        guard width.isFinite, width > 0 else { return 1 }
        return max(min(width / minimumLayoutWidth, 1), 0.1)
    }
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        let zoom = Self.pageZoom(forWidth: newSize.width)
        if pageZoom != zoom { pageZoom = zoom }
    }
}

/// What the web view answers to input, measured with real AppKit (probe and tests).
public struct WebMusicInputFacts: Sendable, Equatable {
    public let acceptsFirstResponder: Bool
    public let hitTestReturnsView: Bool
    public let becameFirstResponder: Bool
    public let hasContextMenu: Bool
}

/// One hidden `WKWebView` running `music.youtube.com`'s own player, never shown
/// as UI. Its website data store is non-persistent, so Google's full web session
/// exists only in memory while the app runs. It lives in its own never-ordered-in
/// window, so closing the main window does not stop audio.
@MainActor public final class WebKitMusicPage: NSObject, WebMusicPage {
    private weak var delegate: (any WebMusicPageDelegate)?
    private var webView: WKWebView?
    private var window: NSWindow?
    private var store: WKWebsiteDataStore?
    private var cookieObserver: CookieRelay?
    private var handler: MessageRelay?
    private var navigator: NavigationRelay?
    /// Generation of the main-frame navigation in flight, taken from its request URL
    /// at policy time (the bootstrap later strips it from the visible URL). A server
    /// redirect of that navigation keeps it; a page-initiated navigation has none.
    private var tracker = WebMusicNavigationTracker()
    private var cookieSnapshots = WebMusicSnapshotSequence()
    /// W17: the native surface view currently showing the web view's video picture, if any (otherwise the hidden host window holds it).
    private weak var videoHost: NSView?
    public var isShowingInVideoSurface: Bool { videoHost != nil && webView?.superview === videoHost }

    /// Live-check fallback, off by default: if WebKit refuses to start media in a
    /// never-ordered-in window on this OS, the operator can set this default to
    /// order the host window in fully transparent, click-through and 1×1 (still
    /// never visible). `defaults write local.native-music.development YTMusePlayerHostOrderedIn -bool YES`
    public static let orderedInKey = "YTMusePlayerHostOrderedIn"
    /// The size, in CSS pixels, a page shown in a frame of `size` points is laid out at (the hidden page and every video surface: see
    /// `NonInteractiveWebView.minimumLayoutWidth`). A video that fills the surface measures this size from inside the page.
    public static func layoutSize(for size: CGSize) -> CGSize {
        let zoom = NonInteractiveWebView.pageZoom(forWidth: size.width)
        return CGSize(width: size.width / zoom, height: size.height / zoom)
    }
    private let orderHostWindowIn: Bool
    public init(delegate: any WebMusicPageDelegate, orderHostWindowIn: Bool = false) {
        self.delegate = delegate; self.orderHostWindowIn = orderHostWindowIn
        super.init()
    }

    /// Configuration only; nothing is loaded and no network is used here.
    /// PL1 (observed live 2026-10-29): with WebKit's default user agent YouTube Music
    /// serves a 2 KB "not optimized for your browser" page instead of the app. The
    /// engine IS Safari's WebKit, so the player presents Safari's application name,
    /// as Safari itself and Kaset do. Safari's major version has matched the macOS
    /// major version since macOS 26; one rule, derived from the running OS.
    public nonisolated static func safariApplicationName(osMajor: Int = ProcessInfo.processInfo.operatingSystemVersion.majorVersion) -> String {
        "Version/\(osMajor >= 26 ? osMajor : 26).0 Safari/605.1.15"
    }
    static func configuration(store: WKWebsiteDataStore) -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = store
        configuration.applicationNameForUserAgent = safariApplicationName()
        // PL2 (observed live): the never-visible player was suspended ~3 s after
        // load (viewIsBecomingInvisible -> PrepareToSuspend -> Suspended) before any
        // media started. A hidden audio player must keep running while not visible.
        configuration.preferences.inactiveSchedulingPolicy = .none
        // A native Play press starts audio without a web gesture; the document-start
        // script still blocks any start without native intent.
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.allowsAirPlayForMediaPlayback = false
        let content = configuration.userContentController
        content.addUserScript(WKUserScript(source: WebMusicScripts.bootstrap, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        content.addUserScript(WKUserScript(source: WebMusicScripts.observer, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        return configuration
    }

    /// W21: the hidden player's host window is never a document window. It stays out of the Windows menu, Command-` cycling and Mission
    /// Control, takes no mouse input and never becomes key; the shell never counts it as a window (one rule, tested).
    public static func applyHostWindowRules(_ window: NSWindow) {
        window.isReleasedWhenClosed = false
        window.isExcludedFromWindowsMenu = true
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.transient, .ignoresCycle, .stationary]
        window.setAccessibilityElement(false)
    }

    private func ensureView() -> WKWebView {
        if let webView { return webView }
        // WebKit is initialised here, on the main actor, before any store class method.
        let store = WKWebsiteDataStore.nonPersistent()
        let configuration = Self.configuration(store: store)
        let handler = MessageRelay(owner: self)
        configuration.userContentController.add(handler, name: WebMusicBridge.handlerName)
        let view = NonInteractiveWebView(frame: NSRect(x: 0, y: 0, width: 480, height: 360), configuration: configuration)
        view.pageZoom = NonInteractiveWebView.pageZoom(forWidth: view.frame.width)   // init(frame:) need not go through setFrameSize
        let navigator = NavigationRelay(owner: self)
        view.navigationDelegate = navigator; view.uiDelegate = navigator
        view.setAccessibilityElement(false)
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: true)
        Self.applyHostWindowRules(window)
        window.contentView = view
        window.setAccessibilityElement(false)
        if orderHostWindowIn {
            window.alphaValue = 0; window.hasShadow = false
            window.setContentSize(NSSize(width: 1, height: 1))
            window.orderBack(nil)
        }
        let observer = CookieRelay(owner: self)
        store.httpCookieStore.add(observer)
        self.store = store; self.webView = view; self.window = window
        self.handler = handler; self.navigator = navigator; self.cookieObserver = observer
        return view
    }

    public func install(cookies: [HTTPCookie]) async {
        _ = ensureView()
        guard let store else { return }
        // Change notifications for these arrive too; the player treats the
        // installed set as its baseline, so they never count as rotation.
        for cookie in cookies { await store.httpCookieStore.setCookie(cookie) }
    }
    /// Fresh-process probe only (nil in the app): serve this HTML as the response to
    /// every player load via `loadSimulatedRequest`, so the real scripts, bridge and
    /// navigation policy run against a fixture without any network.
    public var simulatedDocument: String?
    public func load(_ url: URL) {
        guard WebMusicNavigation.allowsMainFrame(url) else { return }
        let view = ensureView()
        if let simulatedDocument { view.loadSimulatedRequest(URLRequest(url: url), responseHTML: simulatedDocument); return }
        // `replace` keeps WebKit's history from growing across playlist loads
        // (Kaset ADR-0034); the first document uses an ordinary load.
        if view.url != nil, WebMusicNavigation.isPlayerDocument(view.url!) {
            // An awaited call inside a MainActor Task: no completion closure whose
            // isolation depends on which thread WebKit delivers it on (NP1 audit).
            Task { @MainActor [weak self, weak view] in
                guard let view else { return }
                do { _ = try await view.callAsyncJavaScript("window.location.replace(target); return true;",
                                                            arguments: ["target": url.absoluteString], in: nil, contentWorld: .page) }
                catch { if self?.webView === view { view.load(URLRequest(url: url)) } }
            }
        } else {
            view.load(URLRequest(url: url))
        }
    }
    /// `WKWebView.configuration` is a copy, but the `WKPreferences` inside it is shared with the live view, so
    /// writing the policy there reaches the running page (a probe of this, with a non-persistent store and
    /// no network, is in `WebMusicPlayerProbe`). Whether WebKit then really throttles the page's
    /// WebContent process cannot be observed offline.
    public func setThrottled(_ throttled: Bool) {
        webView?.configuration.preferences.inactiveSchedulingPolicy = throttled ? .throttle : .none
    }
    public func attachVideo(to host: NSView?) {
        guard let webView else { return }
        if let host {
            if webView.superview === host { videoHost = host; return }
            // The hidden window keeps an empty placeholder while the view is on a native surface; the view itself is the same object,
            // so its page, media and decoder are untouched.
            webView.removeFromSuperview()
            window?.contentView = NSView(frame: .zero)
            webView.frame = host.bounds; webView.autoresizingMask = [.width, .height]
            host.addSubview(webView)
            videoHost = host
        } else if videoHost != nil || webView.superview !== window?.contentView {
            videoHost = nil
            webView.removeFromSuperview()
            window?.contentView = webView
        }
    }
    /// Real AppKit answers for the web view's input (never a page-script question).
    public func inputFacts() -> WebMusicInputFacts? {
        guard let webView else { return nil }
        let centre = NSPoint(x: webView.bounds.midX, y: webView.bounds.midY)
        let inSuperview = webView.superview.map { webView.convert(centre, to: $0) } ?? centre
        // Both layers: the web view itself, and whatever contains it (the native surface), must answer no hit test.
        let own = webView.hitTest(inSuperview)
        let container = webView.superview?.hitTest(inSuperview)
        let hit = own ?? container
        let event = NSEvent.mouseEvent(with: .rightMouseDown, location: centre, modifierFlags: [], timestamp: 0, windowNumber: webView.window?.windowNumber ?? 0,
                                       context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
        let menu = event.flatMap { webView.menu(for: $0) }
        let became = webView.window?.makeFirstResponder(webView) ?? false
        return .init(acceptsFirstResponder: webView.acceptsFirstResponder, hitTestReturnsView: hit.map { $0 === webView || $0.isDescendant(of: webView) } ?? false,
                     becameFirstResponder: became && webView.window?.firstResponder === webView, hasContextMenu: menu != nil)
    }
    public func measureVideo() async -> WebMusicVideoMeasurement? {
        guard let webView else { return nil }
        let value = try? await webView.callAsyncJavaScript(WebMusicScripts.measureVideo, arguments: [:], in: nil, contentWorld: .page)
        return WebMusicVideoMeasurement(value)
    }
    public func run(_ invocation: WebMusicCommand.Invocation) async -> WebMusicCommandReply {
        guard let webView else { return .unavailable }
        do {
            let value = try await webView.callAsyncJavaScript(invocation.body, arguments: invocation.arguments, in: nil, contentWorld: .page)
            return WebMusicCommandReply(value)
        } catch { return .unavailable }
    }
    public func teardown() async {
        guard let webView else { return }
        let store = self.store
        webView.stopLoading()
        await webView.pauseAllMediaPlayback()
        await webView.closeAllMediaPresentations()
        webView.configuration.userContentController.removeScriptMessageHandler(forName: WebMusicBridge.handlerName)
        webView.configuration.userContentController.removeAllUserScripts()
        if let cookieObserver { store?.httpCookieStore.remove(cookieObserver) }
        webView.navigationDelegate = nil; webView.uiDelegate = nil
        // A native surface that was showing the picture lets go of it with the page.
        webView.removeFromSuperview(); videoHost = nil
        window?.orderOut(nil); window?.contentView = nil
        self.webView = nil; window = nil; handler = nil; navigator = nil; cookieObserver = nil; self.store = nil
        // The store is non-persistent; clearing it as well leaves nothing behind
        // even while WebKit finishes releasing the view.
        await store?.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
    }

    /// Configuration facts and cookie NAMES only (never values), for the
    /// fresh-process probe and diagnostics. Nil once torn down.
    public func diagnostics() async -> WebMusicPageDiagnostics? {
        guard let webView, let store, let window else { return nil }
        let configuration = webView.configuration
        let names = await store.httpCookieStore.allCookies().map(\.name).sorted()
        return .init(persistent: store.isPersistent, requiresUserAction: !configuration.mediaTypesRequiringUserActionForPlayback.isEmpty,
                     canOpenWindows: configuration.preferences.javaScriptCanOpenWindowsAutomatically,
                     mainFrameOnlyScripts: configuration.userContentController.userScripts.filter(\.isForMainFrameOnly).count,
                     scripts: configuration.userContentController.userScripts.count, windowVisible: window.isVisible, cookieNames: names,
                     applicationName: configuration.applicationNameForUserAgent,
                     neverSuspendedWhenInactive: configuration.preferences.inactiveSchedulingPolicy == .none,
                     inactiveSchedulingPolicy: { switch configuration.preferences.inactiveSchedulingPolicy { case .none: "none"; case .throttle: "throttle"; case .suspend: "suspend"; @unknown default: "unknown" } }())
    }

    // MARK: Relays (weak, so WebKit never retains the page owner)
    fileprivate func received(_ message: WKScriptMessage) {
        guard let webView, message.webView === webView else { return }
        let origin = message.frameInfo.securityOrigin
        delegate?.page(received: message.body, from: WebMusicFrame(isMainFrame: message.frameInfo.isMainFrame,
                                                                    scheme: origin.protocol, host: origin.host, port: origin.port))
    }
    fileprivate func committed(_ view: WKWebView) {
        guard view === webView else { return }
        delegate?.pageCommitted(document: tracker.commit())
    }
    /// A provisional main-frame navigation failed or was cancelled before commit:
    /// its generation must not pass to whatever navigation comes next.
    fileprivate func provisionalEnded(_ view: WKWebView) {
        guard view === webView else { return }
        tracker.provisionalEnded()
    }
    /// Pure bookkeeping for one allowed main-frame navigation (unit-tested).
    nonisolated static func track(_ url: URL?, pending: UInt64?, provisional: Bool) -> UInt64? {
        if let token = WebMusicNavigation.document(of: url) { return token }
        return provisional ? pending : nil
    }
    fileprivate func failed(_ view: WKWebView, _ failure: WebMusicFailure) {
        guard view === webView else { return }
        delegate?.pageFailed(failure)
    }
    fileprivate func cookiesChanged(_ store: WKHTTPCookieStore) {
        guard let current = self.store, current.httpCookieStore === store else { return }
        let sequence = cookieSnapshots.begin()
        Task { @MainActor [weak self] in
            let cookies = await store.allCookies()
            // C1: an older snapshot can never be applied after a newer one.
            guard let self, self.store === current, self.cookieSnapshots.accept(sequence) else { return }
            let youtube = cookies.filter {
                let domain = $0.domain.lowercased()
                return domain == "youtube.com" || domain == ".youtube.com"
            }
            self.delegate?.pageCookiesChanged(youtube)
        }
    }
    fileprivate func decide(_ action: WKNavigationAction, in view: WKWebView) -> WKNavigationActionPolicy {
        guard view === webView else { return .cancel }
        let url = action.request.url
        // A new-window request (no target frame) is refused and never tracked.
        guard let target = action.targetFrame else { return .cancel }
        if target.isMainFrame {
            if WebMusicNavigation.allowsMainFrame(url) {
                tracker.policy(url)
                return .allow
            }
            let host = url?.host?.lowercased() ?? ""
            let signIn = host.hasPrefix("accounts.") || host.hasPrefix("consent.")
            delegate?.pageFailed(signIn ? .signInRequired : .navigationRefused)
            return .cancel
        }
        return WebMusicNavigation.allowsSubframe(url) ? .allow : .cancel
    }
}

/// Runs framework callbacks on the main actor without assuming the delivery thread:
/// synchronously on the main thread, otherwise by hopping (NP1 audit).
public enum WebMusicMainActor {
    public static func run(_ body: @escaping @MainActor @Sendable () -> Void) {
        if Thread.isMainThread { MainActor.assumeIsolated { body() } }
        else { Task { @MainActor in body() } }
    }
}

private final class MessageRelay: NSObject, WKScriptMessageHandler {
    weak var owner: WebKitMusicPage?
    init(owner: WebKitMusicPage) { self.owner = owner }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        // WebKit delivers script messages on the main thread; if that ever changes this
        // hops instead of trapping (NP1 audit). The message object is only read there.
        nonisolated(unsafe) let message = message
        WebMusicMainActor.run { [weak owner] in owner?.received(message) }
    }
}
private final class CookieRelay: NSObject, WKHTTPCookieStoreObserver {
    weak var owner: WebKitMusicPage?
    init(owner: WebKitMusicPage) { self.owner = owner }
    func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
        Task { @MainActor [weak self] in self?.owner?.cookiesChanged(cookieStore) }
    }
}
private final class NavigationRelay: NSObject, WKNavigationDelegate, WKUIDelegate {
    weak var owner: WebKitMusicPage?
    init(owner: WebKitMusicPage) { self.owner = owner }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        owner?.decide(navigationAction, in: webView) ?? .cancel
    }
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) { owner?.committed(webView) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        // Including cancellations, which `failed` otherwise ignores.
        owner?.provisionalEnded(webView)
        failed(webView, error)
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) { failed(webView, error) }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { owner?.failed(webView, .playerStopped) }
    /// New windows are refused outright.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? { nil }
    private func failed(_ webView: WKWebView, _ error: any Error) {
        let error = error as NSError
        // Policy cancellations and replaced navigations are not load failures.
        if error.domain == NSURLErrorDomain, error.code == NSURLErrorCancelled { return }
        if error.domain == "WebKitErrorDomain", error.code == 102 { return }
        owner?.failed(webView, .loadFailed)
    }
}
