import AccountSession
import AppKit
import DesignSystem
import ImageIO
import SwiftUI

/// Fixed local text only; never an upstream error description, cookie or URL.
public enum MusicSignInFeedback {
  public static func message(for failure: MusicSignInFailure) -> String {
    switch failure {
    case .network: String(localized: "Google’s sign-in page could not load. Check your connection and try again.")
    case .timedOut: String(localized: "Sign-in timed out. Nothing was saved. Try again when you’re ready.")
    case .signedOut: String(localized: "Google didn’t complete a YouTube Music sign-in. Nothing was saved. Try again.")
    case .unrecognised: String(localized: "YouTube Music answered in a way YTMuse doesn’t recognise yet, so no account was added.")
    case .differentAccount: String(localized: "That’s a different YouTube Music account. Sign in again with the account shown on this row.")
    case .duplicateAccount: String(localized: "That YouTube Music account is already on this Mac. Use Sign In Again on its row.")
    case .rateLimited: String(localized: "YouTube Music is limiting requests. Wait a moment, then try again.")
    case .server: String(localized: "YouTube Music is temporarily unavailable. Try again later.")
    case .generic: String(localized: "Sign-in couldn’t finish. Nothing was saved. Try again.")
    }
  }
  public static func message(for error: MusicSessionError) -> String {
    switch error {
    case .network: message(for: MusicSignInFailure.network)
    case .timedOut: message(for: MusicSignInFailure.timedOut)
    case .signedOut, .notSignedIn, .invalidSession: message(for: MusicSignInFailure.signedOut)
    case .unrecognised, .oversized: message(for: MusicSignInFailure.unrecognised)
    case .differentAccount: message(for: MusicSignInFailure.differentAccount)
    case .duplicateAccount: message(for: MusicSignInFailure.duplicateAccount)
    case .rateLimited: message(for: MusicSignInFailure.rateLimited)
    case .server: message(for: MusicSignInFailure.server)
    case .cancelled, .stale: String(localized: "Sign-in was cancelled or replaced. Try again when you’re ready.")
    case .cleanupRequired: String(localized: "YTMuse couldn’t prepare sign-in on this Mac. Try again.")
    case .keychain: String(localized: "YTMuse couldn’t read or update this account’s saved session in the Keychain on this Mac. Your account was not signed out. Try again, or sign in again.")
    case .policy: message(for: MusicSignInFailure.generic)
    }
  }
  static func symbol(for failure: MusicSignInFailure) -> String {
    switch failure {
    case .network: "wifi.exclamationmark"
    case .timedOut: "clock.badge.exclamationmark"
    case .differentAccount, .duplicateAccount: "person.crop.circle.badge.exclamationmark"
    default: "exclamationmark.triangle"
    }
  }
}

extension View {
  /// Presents the glass sign-in sheet for `signIn` from this view's window.
  /// Only one presenter may be enabled at a time (nested sheets present from the top one).
  public func musicSignInSheet(_ signIn: WebMusicSignIn?, enabled: Bool = true) -> some View {
    modifier(MusicSignInPresentation(signIn: signIn, enabled: enabled))
  }
}

private struct MusicSignInPresentation: ViewModifier {
  let signIn: WebMusicSignIn?
  let enabled: Bool
  @State private var hostWindow: Int?
  func body(content: Content) -> some View {
    // Only the window that asked presents (a second window stays quiet).
    let presented = WebMusicSignIn.shouldPresent(isPresented: signIn?.isPresented == true, enabled: enabled,
                                                 hostWindow: hostWindow, requester: signIn?.requestingWindow)
    content
      .background(HostWindowReader { hostWindow = $0 })
      .sheet(isPresented: Binding(get: { presented }, set: { if !$0 { signIn?.close() } })) {
        if let signIn { MusicSignInSheet(signIn: signIn) }
      }
  }
}

/// Reports the number of the window this view lives in, as it changes.
private struct HostWindowReader: NSViewRepresentable {
  let changed: (Int?) -> Void
  func makeNSView(context: Context) -> Probe { Probe(changed: changed) }
  func updateNSView(_ view: Probe, context: Context) { view.changed = changed }
  final class Probe: NSView {
    var changed: (Int?) -> Void
    init(changed: @escaping (Int?) -> Void) { self.changed = changed; super.init(frame: .zero) }
    required init?(coder: NSCoder) { nil }
    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      let number = window?.windowNumber
      Task { @MainActor [weak self] in self?.changed(number) }
    }
  }
}

/// Native glass frame around Google's page. The page itself is Google's; the
/// header, address, progress, cancel and result states are YTMuse's.
public struct MusicSignInSheet: View {
  @Bindable private var signIn: WebMusicSignIn
  @Environment(\.colorSchemeContrast) private var contrast
  public init(signIn: WebMusicSignIn) { self.signIn = signIn }
  public var body: some View {
    MusicGlassGroup {
      VStack(spacing: MusicStyle.spacing) {
        header
        page
      }.padding(MusicStyle.spacing)
    }
    .frame(minWidth: 540, idealWidth: 580, minHeight: 700, idealHeight: 760)
    .musicCanvas()
    .musicAnimation(.reveal, value: signIn.phase)
  }
  private var header: some View {
    VStack(alignment: .leading, spacing: MusicSpace.sm) {
      HStack(alignment: .center, spacing: MusicSpace.sm) {
        Image(nsImage: NSApplication.shared.applicationIconImage).resizable().aspectRatio(contentMode: .fit)
          .frame(width: 40, height: 40).accessibilityHidden(true)
        VStack(alignment: .leading, spacing: MusicSpace.hairline) {
          Text("Sign in to YouTube Music").font(.title3.bold())
          Text("You’re on Google’s own sign-in page. YTMuse never sees or stores your password.")
            .font(.callout).foregroundStyle(MusicStyle.secondaryText).fixedSize(horizontal: false, vertical: true)
        }
        Spacer(minLength: MusicStyle.compact)
        Button(cancelLabel, role: .cancel) { signIn.close() }
          .keyboardShortcut(.cancelAction).accessibilityIdentifier("cancelMusicSignIn").musicPageAction()
      }
      HStack(spacing: MusicStyle.compact) {
        Image(systemName: "lock.fill").foregroundStyle(MusicStyle.secondaryText).accessibilityHidden(true)
        Text(signIn.host ?? "accounts.google.com").font(.callout.monospaced())
          .foregroundStyle(MusicStyle.secondaryText).lineLimit(1).truncationMode(.middle)
          .accessibilityLabel("Secure page: \(signIn.host ?? "accounts.google.com")")
        Spacer()
      }
      if showsProgress {
        ProgressView(value: signIn.progress).progressViewStyle(.linear).controlSize(.small)
          .accessibilityLabel("Loading Google sign-in")
      }
    }.padding(MusicStyle.spacing).musicInsetSurface()
  }
  private var cancelLabel: String {
    if case .failed = signIn.phase { return "Close" }
    return "Cancel"
  }
  private var showsProgress: Bool {
    (signIn.phase == .loading || signIn.phase == .waitingForUser) && signIn.progress < 1
  }
  private var page: some View {
    ZStack {
      MusicCorner.panelInset.shape
        .fill(Color(nsColor: .textBackgroundColor))
      if let view = signIn.contentView {
        WebContentHost(view: view)
          .musicClip(.panelInset)
          .accessibilityLabel("Google sign-in page")
      }
      overlay
    }
    .overlay(MusicCorner.panelInset.shape
      .stroke(Color.primary.opacity(contrast == .increased ? 0.6 : 0.12), lineWidth: 1))
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
  @ViewBuilder private var overlay: some View {
    switch signIn.phase {
    case .loading where signIn.progress < 0.35:
      StateCard(symbol: nil, title: String(localized: "Opening Google sign-in…"), detail: nil)
    case .verifying:
      StateCard(symbol: nil, title: String(localized: "Verifying your YouTube Music account…"),
                detail: String(localized: "Reading your account name. Nothing in your library is changed."))
    case .failed(let failure):
      StateCard(symbol: MusicSignInFeedback.symbol(for: failure), title: "Sign-in didn’t finish",
                detail: MusicSignInFeedback.message(for: failure)) {
        Button("Close") { signIn.close() }.keyboardShortcut(.defaultAction).musicPageAction(prominent: true)
      }.accessibilityIdentifier("musicSignInFailure")
    default: EmptyView()
    }
  }
}

private struct StateCard<Actions: View>: View {
  let symbol: String?
  let title: String
  let detail: String?
  @ViewBuilder var actions: Actions
  init(symbol: String?, title: String, detail: String?, @ViewBuilder actions: () -> Actions = { EmptyView() }) {
    self.symbol = symbol; self.title = title; self.detail = detail; self.actions = actions()
  }
  var body: some View {
    VStack(spacing: MusicSpace.sm) {
      if let symbol {
        Image(systemName: symbol).font(.system(size: 34, weight: .medium)).foregroundStyle(MusicStyle.accent)
          .accessibilityHidden(true)
      } else {
        ProgressView().controlSize(.large)
      }
      Text(title).font(.headline).multilineTextAlignment(.center)
      if let detail {
        Text(detail).font(.callout).foregroundStyle(MusicStyle.secondaryText)
          .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
      }
      actions
    }
    .padding(MusicStyle.inset).frame(maxWidth: 380).musicInsetSurface()
    .accessibilityElement(children: .contain)
  }
}

/// SS1: SwiftUI keeps representable values (and their containers) alive past the
/// render that removed them, so a strong reference here kept the sign-in web view —
/// and with it the attempt store — "in use" after the attempt ended, and removal
/// failed for the rest of the session. The host therefore holds the view weakly,
/// and detaches it when SwiftUI dismantles the container.
final class WeakWebContent {
  weak var view: NSView?
  init(_ view: NSView) { self.view = view }
}

/// Hosts the sign-in web view supplied by `WebMusicSignIn` inside a SwiftUI-owned container.
struct WebContentHost: NSViewRepresentable {
  let content: WeakWebContent
  init(view: NSView) { content = WeakWebContent(view) }
  func makeNSView(context: Context) -> NSView {
    let container = NSView()
    attach(to: container)
    return container
  }
  func updateNSView(_ container: NSView, context: Context) {
    if let view = content.view, view.superview !== container { attach(to: container) }
  }
  static func dismantleNSView(_ container: NSView, coordinator: ()) {
    container.subviews.forEach { $0.removeFromSuperview() }
  }
  private func attach(to container: NSView) {
    container.subviews.forEach { $0.removeFromSuperview() }
    guard let view = content.view else { return }
    view.frame = container.bounds; view.autoresizingMask = [.width, .height]
    container.addSubview(view)
  }
}

/// Signed-in Music identity and a read-only list of the account's library playlists.
/// TH2: the account photo. The bytes are decoded OFF the main actor (`AvatarDecoding`), to a raster no larger than the 60-point circle needs at 3x, and the view shows the
/// placeholder until it is ready. `NSImage(data:)` here decoded (or deferred decoding to the first draw) on the main actor in `body`.
private struct AvatarImage: View {
  let data: Data?
  @State private var image: CGImage?
  var body: some View {
    Group {
      if let image {
        Image(decorative: image, scale: 3).resizable().aspectRatio(contentMode: .fill)
      } else {
        Image(systemName: "person.crop.circle.fill").resizable().foregroundStyle(MusicStyle.accent.opacity(0.8))
      }
    }
    .task(id: data) {
      image = nil
      image = await AvatarDecoding.load(data).image
    }
  }
}

/// Decodes the account photo with ImageIO into an eager, bounded raster. Not a view and not main-actor: `load` hops to a detached task.
enum AvatarDecoding {
  struct Decoded: @unchecked Sendable { let image: CGImage? }
  static let maximumInputBytes = 5_000_000
  static let maximumPixels = 180
  private static let violations = NSLock()
  nonisolated(unsafe) private static var mainThreadDecodeCount = 0
  /// How many decodes ran on the main thread (tests read it; the product never increments it).
  static var mainThreadDecodes: Int { violations.withLock { mainThreadDecodeCount } }
  static func load(_ data: Data?) async -> Decoded {
    guard let data else { return Decoded(image: nil) }
    return await Task.detached(priority: .utility) { Decoded(image: decode(data)) }.value
  }
  static func decode(_ data: Data) -> CGImage? {
    if Thread.isMainThread { violations.withLock { mainThreadDecodeCount += 1 } }
    guard !data.isEmpty, data.count <= maximumInputBytes,
          let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary), CGImageSourceGetCount(source) == 1 else { return nil }
    return CGImageSourceCreateThumbnailAtIndex(source, 0, [
      kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceShouldCacheImmediately: true, kCGImageSourceThumbnailMaxPixelSize: maximumPixels,
    ] as CFDictionary)
  }
}

struct MusicAccountCard: View {
  let model: AccountsModel
  @Environment(\.colorSchemeContrast) private var contrast
  var body: some View {
    Group {
      if model.proofLoading && model.proof == .none {
        HStack(spacing: MusicSpace.sm) {
          ProgressView().controlSize(.small)
          Text("Reading your YouTube Music account…").foregroundStyle(MusicStyle.secondaryText)
        }.frame(maxWidth: .infinity, alignment: .leading)
      } else {
        content
      }
    }
    .padding(MusicStyle.inset).frame(maxWidth: .infinity, alignment: .leading).musicInsetSurface()
    .accessibilityElement(children: .contain).accessibilityIdentifier("musicAccountCard")
  }
  @ViewBuilder private var content: some View {
    switch model.proof {
    case .none:
      EmptyView()
    case .signedIn(let proof):
      VStack(alignment: .leading, spacing: MusicStyle.spacing) {
        HStack(spacing: MusicStyle.spacing) {
          avatar(proof.avatar)
          VStack(alignment: .leading, spacing: MusicSpace.xxs) {
            Text(proof.identity.displayName).font(MusicPageStyle.section).accessibilityIdentifier("musicIdentityName")
            if let handle = proof.identity.handle {
              Text(handle).foregroundStyle(MusicStyle.secondaryText).accessibilityIdentifier("musicIdentityHandle")
            }
            Label("Signed in to YouTube Music", systemImage: "checkmark.seal.fill").font(.callout)
          }
          Spacer(minLength: MusicStyle.compact)
          Button("Refresh") { Task { await model.loadProof() } }.disabled(model.proofLoading || model.busy)
            .musicPageAction()
        }
        Divider()
        library(proof.library)
      }
    case .expired:
      notice(symbol: "exclamationmark.circle", title: "Session expired — sign in again",
             detail: String(localized: "Google ended this YouTube Music session. Your local data is kept.")) {
        if let active = model.active {
          Button("Sign In Again") { Task { await model.authenticate(active) } }
            .disabled(!model.canAuthenticate || model.busy).musicPageAction(prominent: true)
        }
      }
    case .unrecognised:
      notice(symbol: "questionmark.circle", title: "Library not read",
             detail: String(localized: "YouTube Music answered in a way YTMuse doesn’t recognise yet. This is not an empty library.")) {
        Button("Try Again") { Task { await model.loadProof() } }.disabled(model.proofLoading).musicPageAction()
      }
    case .failed(.keychain):
      notice(symbol: "lock.trianglebadge.exclamationmark", title: "Saved session unavailable on this Mac",
             detail: MusicSignInFeedback.message(for: MusicSessionError.keychain)) {
        Button("Try Again") { Task { await model.loadProof() } }.disabled(model.proofLoading).musicPageAction()
      }
    case .failed(let error):
      notice(symbol: "wifi.exclamationmark", title: "Couldn’t reach YouTube Music",
             detail: MusicSignInFeedback.message(for: error)) {
        Button("Try Again") { Task { await model.loadProof() } }.disabled(model.proofLoading).musicPageAction()
      }
    }
  }
  private func avatar(_ data: Data?) -> some View {
    AvatarImage(data: data)
    .frame(width: 60, height: 60).clipShape(Circle())
    .overlay(Circle().stroke(Color.primary.opacity(contrast == .increased ? 0.6 : 0.15), lineWidth: 1))
    .accessibilityHidden(true)
  }
  @ViewBuilder private func library(_ library: MusicLibraryPlaylists) -> some View {
    VStack(alignment: .leading, spacing: MusicStyle.compact) {
      HStack {
        Text("Library playlists").font(.headline)
        Spacer()
        Text("\(library.playlists.count)").font(.callout.monospacedDigit()).foregroundStyle(MusicStyle.secondaryText)
      }
      if library.playlists.isEmpty {
        Text("No playlists in your library yet.").foregroundStyle(MusicStyle.secondaryText)
          .accessibilityIdentifier("musicLibraryEmpty")
      } else {
        VStack(spacing: 0) {
          ForEach(Array(library.playlists.enumerated()), id: \.element.id) { index, playlist in
            if index > 0 { Divider().padding(.leading, MusicSpace.xl + MusicSpace.xxs) }
            HStack(spacing: MusicSpace.sm) {
              Image(systemName: "music.note.list").foregroundStyle(MusicStyle.accent).frame(width: 24)
                .accessibilityHidden(true)
              Text(playlist.title).lineLimit(1).truncationMode(.tail)
              Spacer(minLength: MusicStyle.compact)
              if let count = playlist.countText {
                Text(count).font(.callout.monospacedDigit()).foregroundStyle(MusicStyle.secondaryText)
              }
            }
            .padding(.vertical, MusicStyle.compact).accessibilityElement(children: .combine)
          }
        }.accessibilityElement(children: .contain).accessibilityIdentifier("musicLibraryList")
      }
      Text(library.complete
        ? "Read-only preview. Nothing in your library is changed."
        : "Showing the first page of your library. Read-only; nothing in your library is changed.")
        .font(.caption).foregroundStyle(MusicStyle.secondaryText)
    }
  }
  private func notice<Actions: View>(symbol: String, title: String, detail: String,
                                     @ViewBuilder actions: () -> Actions) -> some View {
    HStack(alignment: .top, spacing: MusicStyle.spacing) {
      Image(systemName: symbol).font(.title2).foregroundStyle(MusicStyle.accent).accessibilityHidden(true)
      VStack(alignment: .leading, spacing: MusicSpace.xs) {
        Text(title).font(.headline).accessibilityIdentifier("musicProofTitle")
        Text(detail).foregroundStyle(MusicStyle.secondaryText).fixedSize(horizontal: false, vertical: true)
        actions()
      }
    }
  }
}
