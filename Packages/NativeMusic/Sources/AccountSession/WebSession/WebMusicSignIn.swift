import AppKit
import Foundation
import Observation
import Security
import WebKit

/// Transient, app-owned WebKit data stores: one fresh identifier per sign-in
/// attempt, unrelated to any account UUID, removed after the attempt ends. The
/// Keychain record is the only durable copy of the session.
public protocol MusicWebsiteDataStores: Sendable {
    /// Deletes every cookie and all website data the attempt store holds. Runs
    /// immediately when an attempt ends, before (and independently of) removal.
    func wipe(_ identifier: UUID) async -> Bool
    /// One removal attempt of the store directory. Returns true once removal is
    /// confirmed (a store that does not exist counts as removed). Callers retry.
    func remove(_ identifier: UUID) async -> Bool
}
public struct WebKitMusicDataStores: MusicWebsiteDataStores {
    public init() {}
    public func wipe(_ identifier: UUID) async -> Bool { await Self.wipeOnMain(identifier) }
    public func remove(_ identifier: UUID) async -> Bool { await Self.removeOnMain(identifier) }
    /// WebKit's identified-store registry crashes when a class method is its
    /// first use in the process (observed: SIGSEGV, exit 139, for a cold
    /// `remove(forIdentifier:)` and for store enumeration). Touching the default
    /// store initialises it first. Never enumerates stores; only ledger IDs.
    /// An in-use store (code 1 while a released web view is still being torn
    /// down) fails this attempt; the coordinator retries with backoff.
    @MainActor static func removeOnMain(_ identifier: UUID) async -> Bool {
        _ = WKWebsiteDataStore.default()
        do { try await WKWebsiteDataStore.remove(forIdentifier: identifier); return true } catch { return false }
    }
    @MainActor static func wipeOnMain(_ identifier: UUID) async -> Bool {
        _ = WKWebsiteDataStore.default()
        await wipe(WKWebsiteDataStore(forIdentifier: identifier))
        return true
    }
    /// Deletes all website data types and then every remaining cookie.
    @MainActor static func wipe(_ store: WKWebsiteDataStore) async {
        await store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
        for cookie in await store.httpCookieStore.allCookies() { await store.httpCookieStore.deleteCookie(cookie) }
    }
}

/// Used by isolated (Debug scratch) instances: no WebKit identified store is ever created or
/// removed, so nothing can reach the real `~/Library/WebKit` container. Pair with
/// `WebMusicSignIn(nonPersistentStores: true)`, whose web view uses an in-memory store.
public struct IsolatedMusicDataStores: MusicWebsiteDataStores {
    public init() {}
    public func wipe(_ identifier: UUID) async -> Bool { true }
    public func remove(_ identifier: UUID) async -> Bool { true }   // nothing exists on disk
}

/// IDs of sign-in attempt stores that may still exist on disk. Written before a
/// store is constructed, cleared only after its removal is confirmed. IDs only.
public protocol MusicSignInLedger: Sendable {
    func add(_ identifier: UUID) async throws
    func remove(_ identifier: UUID) async throws
    func pending() async throws -> [UUID]
}
/// Owner-only (0600 file in a 0700 directory) JSON array of UUID strings.
public actor FileMusicSignInLedger: MusicSignInLedger {
    private let url: URL
    public init(url: URL) { self.url = url }
    public func add(_ identifier: UUID) throws { var ids = try read(); if !ids.contains(identifier) { ids.append(identifier) }; try write(ids) }
    public func remove(_ identifier: UUID) throws { try write(read().filter { $0 != identifier }) }
    public func pending() throws -> [UUID] { try read() }
    private func read() throws -> [UUID] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        guard try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { throw LifecycleError.invalidDirectory }
        let data = try Data(contentsOf: url)
        guard data.count <= 65_536, let strings = try JSONSerialization.jsonObject(with: data) as? [String] else { throw LifecycleError.invalidDirectory }
        return strings.compactMap(UUID.init(uuidString:))
    }
    private func write(_ ids: [UUID]) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let data = try JSONSerialization.data(withJSONObject: ids.map(\.uuidString))
        try data.write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

public enum MusicSignInFailure: Sendable, Equatable {
    case network, timedOut, signedOut, unrecognised, differentAccount, duplicateAccount, rateLimited, server, generic
}
public enum MusicSignInPhase: Sendable, Equatable { case idle, loading, waitingForUser, verifying, failed(MusicSignInFailure) }

/// UI driver for Google's own sign-in page. `begin` loads the page in the given
/// fresh attempt store and resolves only after the web view has been released,
/// so the caller may remove that store immediately.
@MainActor public protocol MusicWebSignInPresenting: AnyObject, Sendable {
    func begin(store: UUID, account: UUID, now: @escaping @Sendable () -> Date) async throws -> MusicCookieSession
    func verifying()
    func finish(_ failure: MusicSignInFailure?)
}

/// Two narrowly documented allowances, both off unless the operator observes the
/// need on a live run (see Docs/Service-Access.md). Neither touches form fields.
public struct MusicWebSignInOptions: Sendable, Equatable {
    /// (a) Append Safari's own application name to the default WebKit user agent
    /// when Google rejects the embedded engine as an unsupported browser.
    public var safariApplicationName: Bool
    /// (b) On Google's accounts hosts only, remove the WebAuthn capability so
    /// passkey accounts fall back to Google's other methods (Kaset ADR-0033).
    /// ON by default since the first live sign-in (2026-10-28) showed Google's
    /// passkey challenge, which cannot complete in an app web view without Apple's
    /// web-browser passkey entitlement. Off by default once that entitlement is held.
    public var suppressPasskeys: Bool
    public var timeout: Duration
    public init(safariApplicationName: Bool = false, suppressPasskeys: Bool = true, timeout: Duration = .seconds(900)) {
        self.safariApplicationName = safariApplicationName; self.suppressPasskeys = suppressPasskeys; self.timeout = timeout
    }
    public static let safariApplicationNameKey = "YTMuseSignInSafariApplicationName"
    public static let suppressPasskeysKey = "YTMuseSignInSuppressPasskeys"
    /// An explicit `defaults` value always wins. Otherwise passkeys are suppressed unless this signed build holds Apple's
    /// web-browser passkey entitlement, the only thing that lets WebKit complete a google.com passkey (Touch ID, the phone,
    /// a security key) inside an app web view. With it, Google's own passkey challenge runs untouched.
    public init(defaults: UserDefaults, passkeysEntitled: Bool = PasskeyEntitlement.held) {
        self.init(safariApplicationName: defaults.bool(forKey: Self.safariApplicationNameKey),
                  suppressPasskeys: defaults.object(forKey: Self.suppressPasskeysKey) as? Bool ?? !passkeysEntitled)
    }
}

/// Whether the running process is signed with `com.apple.developer.web-browser.public-key-credential`. Apple grants it on
/// request (Account Holder, Certificates, Identifiers & Profiles); it needs a provisioning profile, so it is never in the
/// repository's entitlements. Read once from the process's own signature; no prompt, no store.
public enum PasskeyEntitlement {
    public static let key = "com.apple.developer.web-browser.public-key-credential"
    public static let held: Bool = {
        guard let task = SecTaskCreateFromSelf(nil),
              let value = SecTaskCopyValueForEntitlement(task, key as CFString, nil) else { return false }
        return (value as? Bool) ?? false
    }()
}

public enum MusicSignInNavigation {
    /// Google's sign-in for the YouTube service, continuing (via YouTube's own
    /// sign-in handler) to `music.youtube.com`.
    public static var signInURL: URL {
        var next = URLComponents(string: "https://www.youtube.com/signin")!
        next.queryItems = [.init(name: "action_handle_signin", value: "true"), .init(name: "app", value: "desktop"),
                           .init(name: "hl", value: "en"), .init(name: "next", value: MusicCookieSession.origin + "/")]
        var login = URLComponents(string: "https://accounts.google.com/ServiceLogin")!
        login.queryItems = [.init(name: "service", value: "youtube"), .init(name: "passive", value: "true"),
                            .init(name: "continue", value: next.url!.absoluteString)]
        return login.url!
    }
    /// Main frame: only the sign-in path itself. Content hosts are never top-level.
    static let mainFrameHosts: Set<String> = [
        "accounts.google.com", "accounts.youtube.com", "www.youtube.com", "music.youtube.com",
        "consent.youtube.com", "consent.google.com",
    ]
    /// Subframes and resources Google's page embeds.
    static let subframeSuffixes = ["google.com", "youtube.com", "gstatic.com", "googleusercontent.com", "googleapis.com"]
    public static func allows(_ url: URL?, mainFrame: Bool) -> Bool {
        guard let url else { return false }
        if !mainFrame, url.scheme == "about" { return url.absoluteString == "about:blank" || url.absoluteString == "about:srcdoc" }
        guard url.scheme == "https", url.user == nil, url.password == nil, url.port == nil, let host = url.host?.lowercased() else { return false }
        if mainFrame {
            return mainFrameHosts.contains(host)
                || host.range(of: #"^accounts\.google\.(?:[a-z]{2,3}|com?\.[a-z]{2})$"#, options: .regularExpression) != nil
        }
        return subframeSuffixes.contains(where: { host == $0 || host.hasSuffix("." + $0) })
    }
    public static func isMusicDestination(_ url: URL?) -> Bool {
        url?.scheme == "https" && url?.host?.lowercased() == "music.youtube.com"
    }
    static let passkeySuppressionSource = """
    (function () {
      "use strict";
      if (!/^accounts\\.google\\.(?:[a-z]{2,3}|com?\\.[a-z]{2})$/.test(window.location.hostname)) { return; }
      try { Object.defineProperty(window, "PublicKeyCredential", { value: undefined, writable: false, configurable: false }); } catch (e) {}
      try {
        var c = window.navigator && window.navigator.credentials; if (!c) { return; }
        var p = Object.getPrototypeOf(c);
        var wrap = function (f) { if (typeof f !== "function") { return f; } return function (o) {
          if (o && o.publicKey) { return Promise.reject(new DOMException("Passkeys are not available in this app.", "NotAllowedError")); }
          return f.apply(this, arguments); }; };
        p.get = wrap(p.get); p.create = wrap(p.create);
      } catch (e) {}
    })();
    """
}

/// Hosts Google's sign-in page for exactly one local account's data store. The
/// app never evaluates script against, reads, injects into or autofills Google's
/// form; the password is typed into Google's page and never reaches app code.
@MainActor @Observable public final class WebMusicSignIn: MusicWebSignInPresenting {
    public private(set) var phase: MusicSignInPhase = .idle
    public private(set) var isPresented = false
    public private(set) var progress: Double = 0
    public private(set) var host: String?
    public private(set) var contentView: NSView?
    @ObservationIgnored private let options: MusicWebSignInOptions
    @ObservationIgnored private var webView: WKWebView?
    @ObservationIgnored private var navigator: SignInNavigator?
    @ObservationIgnored private var continuation: CheckedContinuation<MusicCookieSession, any Error>?
    @ObservationIgnored private var account: UUID?
    @ObservationIgnored private var now: (@Sendable () -> Date)?
    @ObservationIgnored private var deadline: Task<Void, Never>?
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []
    @ObservationIgnored private var checking = false
    @ObservationIgnored private var recheck = false
    /// The window that asked for this sign-in (its `windowNumber`). Only that window
    /// presents the sheet: with several windows open, the one shared attempt would
    /// otherwise present in all of them and its single web view would be re-parented
    /// between their sheets, and closing any one would cancel the attempt.
    public private(set) var requestingWindow: Int?
    @ObservationIgnored private let windowProvider: @MainActor () -> Int?
    @ObservationIgnored private let nonPersistentStores: Bool
    public init(options: MusicWebSignInOptions = .init(), nonPersistentStores: Bool = false,
                windowProvider: @escaping @MainActor () -> Int? = { (NSApp.keyWindow ?? NSApp.mainWindow)?.windowNumber }) {
        self.options = options; self.nonPersistentStores = nonPersistentStores; self.windowProvider = windowProvider
    }
    /// Records the asking window: the key window when the attempt begins (the Accounts
    /// sheet counts as the window the user clicked in). Nil means nobody could be named.
    public func claimRequestingWindow() { requestingWindow = windowProvider() }
    /// Whether the presenter attached to `hostWindow` should show the sheet. With no recorded
    /// requester every enabled presenter shows (the earlier behaviour), never none.
    public nonisolated static func shouldPresent(isPresented: Bool, enabled: Bool, hostWindow: Int?, requester: Int?) -> Bool {
        guard isPresented, enabled else { return false }
        guard let requester else { return true }
        return hostWindow == requester
    }

    public func begin(store: UUID, account: UUID, now: @escaping @Sendable () -> Date) async throws -> MusicCookieSession {
        guard continuation == nil, webView == nil else { throw MusicSessionError.policy }
        try Task.checkCancellation()
        claimRequestingWindow()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (pending: CheckedContinuation<MusicCookieSession, any Error>) in
                continuation = pending; self.account = account; self.now = now
                start(store: store)
            }
        } onCancel: { Task { @MainActor [weak self] in self?.cancel() } }
    }
    private func start(store: UUID) {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = nonPersistentStores ? .nonPersistent() : WKWebsiteDataStore(forIdentifier: store)
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        if options.safariApplicationName { configuration.applicationNameForUserAgent = "Version/27.0 Safari/605.1.15" }
        if options.suppressPasskeys {
            configuration.userContentController.addUserScript(WKUserScript(
                source: MusicSignInNavigation.passkeySuppressionSource, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        }
        let view = WKWebView(frame: .init(x: 0, y: 0, width: 480, height: 640), configuration: configuration)
        let navigator = SignInNavigator(owner: self)
        view.navigationDelegate = navigator; view.uiDelegate = navigator
        configuration.websiteDataStore.httpCookieStore.add(navigator)
        // WebKit posts these KVO changes on the main thread; read the value where it is
        // delivered and apply it on the main actor without assuming (NP1 audit).
        observations = [
            view.observe(\.estimatedProgress, options: [.new]) { @Sendable [weak self] _, change in
                let value = change.newValue ?? 0
                Self.onMain { self?.progress = value }
            },
            view.observe(\.url, options: [.new]) { @Sendable [weak self] _, change in
                let host = (change.newValue ?? nil)?.host
                Self.onMain { self?.host = host }
            },
        ]
        webView = view; self.navigator = navigator; contentView = view
        phase = .loading; progress = 0; host = nil; isPresented = true
        deadline = Task { [weak self, timeout = options.timeout] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            self?.fail(.timedOut)
        }
        view.load(URLRequest(url: MusicSignInNavigation.signInURL))
    }
    func pageFinished() {
        if phase == .loading { phase = .waitingForUser }
        checkCompletion()
    }
    /// Complete only when navigation is on music.youtube.com AND the store holds
    /// a valid SAPISID-family/SID-family pair for `.youtube.com`.
    func checkCompletion() {
        guard continuation != nil, let view = webView, let account, let now,
              MusicSignInNavigation.isMusicDestination(view.url) else { return }
        // A change that lands while a read is in flight triggers one more read.
        guard !checking else { recheck = true; return }
        checking = true; recheck = false
        let store = view.configuration.websiteDataStore.httpCookieStore
        Task { @MainActor [weak self, weak view] in
            let cookies = await store.allCookies()
            guard let self, let view else { return }
            self.checking = false
            guard self.continuation != nil, self.webView === view, MusicSignInNavigation.isMusicDestination(view.url) else { return }
            guard let session = try? MusicCookieSession(accountID: account, cookies: cookies, now: now()) else {
                if self.recheck { self.checkCompletion() }
                return
            }
            self.phase = .verifying
            self.resume(.success(session))
        }
    }
    func fail(_ failure: MusicSignInFailure) {
        guard continuation != nil else { return }
        phase = .failed(failure)
        resume(.failure(failure == .timedOut ? MusicSessionError.timedOut : MusicSessionError.network))
    }
    /// Cancel/close from the sheet, Escape, or task cancellation.
    public func cancel() {
        if continuation != nil { resume(.failure(CancellationError())) }
        isPresented = false; phase = .idle; requestingWindow = nil
    }
    /// Dismisses a finished failure state.
    public func close() {
        guard continuation == nil else { cancel(); return }
        isPresented = false; phase = .idle; requestingWindow = nil
    }
    public func verifying() { if isPresented { phase = .verifying } }
    public func finish(_ failure: MusicSignInFailure?) {
        guard continuation == nil else { return }
        if let failure { phase = .failed(failure); isPresented = true } else { isPresented = false; phase = .idle; requestingWindow = nil }
    }
    /// Ends the attempt: stop the page, wipe the store's cookies and website data
    /// while its object is still alive, then release the web view, then resume.
    private func resume(_ result: Result<MusicCookieSession, any Error>) {
        let pending = continuation; continuation = nil
        deadline?.cancel(); deadline = nil
        var store = webView?.configuration.websiteDataStore
        if let webView {
            webView.stopLoading()
            if let navigator { webView.configuration.websiteDataStore.httpCookieStore.remove(navigator) }
            webView.navigationDelegate = nil; webView.uiDelegate = nil
        }
        weak var released = webView
        // Boxed so the store object is dropped right after the wipe, not when the Task ends.
        let held = HeldStore(store); store = nil
        Task { @MainActor in
            if let current = held.store { await WebKitMusicDataStores.wipe(current) }
            held.store = nil
            self.teardown()
            // SS1: the caller removes the attempt store right after this resumes, and
            // WebKit refuses removal while any web view on that store is alive. Wait
            // (bounded) until the view has really been deallocated.
            await Self.awaitRelease(limit: .seconds(3)) { released == nil }
            pending?.resume(with: result)
        }
    }
    /// Applies a framework callback on the main actor: synchronously when delivered on
    /// the main thread, otherwise by hopping, never by asserting (NP1 audit).
    nonisolated static func onMain(_ body: @escaping @MainActor @Sendable () -> Void) {
        if Thread.isMainThread { MainActor.assumeIsolated { body() } }
        else { Task { @MainActor in body() } }
    }
    /// Polls on the main actor until `isReleased` holds, at most `limit / step` times.
    /// The bound counts sleeps rather than reading a wall clock, so it is
    /// deterministic under load (a busy machine can only make it wait longer,
    /// never return before the view had its chance to go). Returns whether the view
    /// was released. `sleep` is injectable for tests.
    @discardableResult
    static func awaitRelease(limit: Duration, step: Duration = .milliseconds(50),
                             sleep: @MainActor (Duration) async -> Void = { try? await Task.sleep(for: $0) },
                             _ isReleased: @MainActor () -> Bool) async -> Bool {
        let polls = max(1, Int((limit / step).rounded(.up)))
        for _ in 0..<polls {
            if isReleased() { return true }
            await sleep(step)
        }
        return isReleased()
    }
    /// Releases the web view before the caller may remove its data store.
    private func teardown() {
        deadline?.cancel(); deadline = nil
        observations.forEach { $0.invalidate() }; observations = []
        if let webView {
            webView.stopLoading()
            webView.navigationDelegate = nil; webView.uiDelegate = nil
            webView.removeFromSuperview()
        }
        webView = nil; navigator = nil; contentView = nil; account = nil; now = nil; checking = false; recheck = false
    }
}

@MainActor private final class HeldStore {
    var store: WKWebsiteDataStore?
    init(_ store: WKWebsiteDataStore?) { self.store = store }
}

@MainActor private final class SignInNavigator: NSObject, WKNavigationDelegate, WKUIDelegate, WKHTTPCookieStoreObserver {
    private weak var owner: WebMusicSignIn?
    init(owner: WebMusicSignIn) { self.owner = owner }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        let mainFrame = navigationAction.targetFrame?.isMainFrame ?? true
        return MusicSignInNavigation.allows(navigationAction.request.url, mainFrame: mainFrame) ? .allow : .cancel
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { owner?.pageFinished() }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) { failed(error) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) { failed(error) }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { owner?.fail(.network) }
    /// Google opens some steps as popups; keep them in this view when allowed.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if MusicSignInNavigation.allows(navigationAction.request.url, mainFrame: true) { webView.load(navigationAction.request) }
        return nil
    }
    nonisolated func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
        Task { @MainActor [weak self] in self?.owner?.checkCompletion() }
    }
    private func failed(_ error: any Error) {
        let error = error as NSError
        // Redirect/policy interruptions are ordinary sign-in navigation, not failures.
        if error.domain == NSURLErrorDomain, error.code == NSURLErrorCancelled { return }
        if error.domain == "WebKitErrorDomain", error.code == 102 { return }
        if error.domain == NSURLErrorDomain { owner?.fail(.network) }
    }
}
