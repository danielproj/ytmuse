import AccountSession
import DesignSystem
import Domain
import Observation
import SwiftUI

/// W31 injects the verified browser Music session flow. It consumes the challenge,
/// completes AccountLifecycle's handoff, and returns only after success/cancellation.
public typealias AccountAuthenticationAction =
  @Sendable (AuthenticationChallenge) async throws -> Void

/// The in-app YouTube Music web sign-in: Google's own page in the sheet driven by
/// `signIn`, the verified Music session status, and the read-only library proof.
public struct MusicSessionSurface: Sendable {
  public let signIn: WebMusicSignIn
  public let authenticate: AccountAuthenticationAction
  public let status: @Sendable () async -> MusicSessionStatus
  public let proof: @Sendable () async -> MusicProofState
  public init(
    signIn: WebMusicSignIn, authenticate: @escaping AccountAuthenticationAction,
    status: @escaping @Sendable () async -> MusicSessionStatus,
    proof: @escaping @Sendable () async -> MusicProofState
  ) {
    self.signIn = signIn; self.authenticate = authenticate; self.status = status; self.proof = proof
  }
}

@MainActor @Observable public final class AccountsModel {
  public private(set) var identities: [LocalIdentity] = []
  public private(set) var defaultIdentity: AccountContext?
  public private(set) var active: AccountContext?
  public private(set) var busy = false
  public private(set) var message: String?
  public private(set) var connectionStatus = "Development build · No service account connected"
  public let authenticationLabel: String
  public let authenticationCanConnectMusic: Bool
  /// Present only for the web Music session; drives the glass sign-in sheet.
  public let signIn: WebMusicSignIn?
  public private(set) var proof: MusicProofState = .none
  public private(set) var proofLoading = false
  private let musicStatus: (@Sendable () async -> MusicSessionStatus)?
  private let musicProof: (@Sendable () async -> MusicProofState)?
  private let statusAction: (@Sendable () async -> GoogleConnectionState)?
  private var authorizationPresent = false
  private var refreshAvailable = false
  private let refreshAction: (@Sendable () async throws -> Void)?
  private let disconnectAction: (@Sendable () async throws -> Void)?
  private var authenticationTask: Task<Void, any Error>?
  public var canDisconnectAuthorization: Bool { disconnectAction != nil && authorizationPresent }
  public var canRefreshAuthorization: Bool { refreshAction != nil && refreshAvailable }
  public var canAuthenticate: Bool { authentication != nil && lifecycle != nil }
  private let lifecycle: AccountLifecycle?
  private let authentication: AccountAuthenticationAction?
  public init(
    lifecycle: AccountLifecycle? = nil, authentication: AccountAuthenticationAction? = nil,
    authenticationLabel: String = "Sign in with Google",
    authenticationCanConnectMusic: Bool = true,
    connectionStatus: (@Sendable () async -> GoogleConnectionState)? = nil,
    refreshAuthorization: (@Sendable () async throws -> Void)? = nil,
    disconnectAuthorization: (@Sendable () async throws -> Void)? = nil
  ) {
    self.lifecycle = lifecycle
    self.authentication = authentication
    self.authenticationLabel = authenticationLabel; self.authenticationCanConnectMusic = authenticationCanConnectMusic; statusAction = connectionStatus; disconnectAction = disconnectAuthorization; refreshAction = refreshAuthorization
    signIn = nil; musicStatus = nil; musicProof = nil
  }
  /// Primary composition: YouTube Music web sign-in. Google OAuth is not offered.
  public init(lifecycle: AccountLifecycle, music: MusicSessionSurface) {
    self.lifecycle = lifecycle
    authentication = music.authenticate
    authenticationLabel = "Sign in to YouTube Music"
    authenticationCanConnectMusic = true
    statusAction = nil; refreshAction = nil; disconnectAction = nil
    signIn = music.signIn; musicStatus = music.status; musicProof = music.proof
    connectionStatus = MusicSessionStatus.signedOut.explanation
  }
  public var usesMusicSession: Bool { signIn != nil }
  /// The active identity holds a connected Music session.
  public var activeConnected: Bool {
    guard let active else { return false }
    return identities.first(where: { $0.id == active })?.state == .connected
  }
  /// The active identity's session needs a fresh sign-in (service expiry, or a
  /// Keychain record the app cannot read without a prompt).
  public var activeExpired: Bool {
    guard let active else { return false }
    return identities.first(where: { $0.id == active })?.state == .expired
  }
  /// Reads the account menu and one library page for the active identity.
  public func loadProof() async {
    guard let musicProof, !proofLoading else { return }
    guard active != nil else { proof = .none; return }
    proofLoading = true
    let value = await musicProof()
    proofLoading = false
    proof = value
    await refresh()
  }
  public func refresh() async {
    if let musicStatus { connectionStatus = await musicStatus().explanation }
    if let statusAction {
      let state = await statusAction(); connectionStatus = state.explanation
      authorizationPresent = [.profileVerified, .musicConnected, .storedAuthorization, .configurationInvalidStored, .configurationMissingStored, .cleanupRequired].contains(state)
      refreshAvailable = [.profileVerified, .musicConnected].contains(state)
    }
    guard let lifecycle else { return }
    let state = await lifecycle.snapshot()
    identities = state.directory.identities
    defaultIdentity = state.directory.defaultIdentity
    active = state.context.account
    if active == nil { proof = .none }
  }
  private var authorizationWork = false
  public var pendingMessage: String? {
    guard busy else { return nil }
    guard authorizationWork else { return String(localized: "Updating account…") }
    return usesMusicSession ? String(localized: "Signing in to YouTube Music…") : String(localized: "Updating Google authorization…")
  }
  private func run(authorization: Bool = false, _ operation: () async throws -> Void) async {
    guard !busy else { return }
    busy = true; authorizationWork = authorization
    message = nil
    defer { busy = false; authorizationWork = false }
    do { try await operation() } catch let error as DomainError {
      switch error {
      case .forbidden: message = String(localized: "This identity does not have permission for that action.")
      case .regionRestricted: message = String(localized: "This action is unavailable in this identity’s region.")
      case .offline: message = String(localized: "The connection is offline. Try again when connected.")
      case .unavailableContent:
        message = String(localized: "This identity or content is unavailable. Choose another account or item.")
      case .unsupported: message = String(localized: "The connected account provider cannot perform this action.")
      case .capabilityUnknown:
        message = String(localized: "Account eligibility has not been verified. Try again after reconnecting.")
      case .unauthorized: message = String(localized: "Reconnect this account to continue.")
      default: message = String(localized: "The account action failed. Try again.")
      }
    } catch is CancellationError {
      message = usesMusicSession ? String(localized: "Sign-in cancelled.") : String(localized: "Authorization cancelled.")
    } catch let error as MusicSessionError {
      message = MusicSignInFeedback.message(for: error)
    } catch let error as DesktopOAuthError {
      message = GoogleAuthorizationFeedback.message(for: error)
    } catch {
      message = authorization ? String(localized: "Google authorization could not finish. No Music connection was verified. Try again.") : String(localized: "The account action could not finish. Retry the action.")
    }
    await refresh()
  }
  public func switchIdentity(_ account: AccountContext) async {
    proof = .none
    await run { try await lifecycle?.switchIdentity(to: account) }
    await loadProof()
  }
  public func rename(_ account: AccountContext, label: String) async {
    await run { try await lifecycle?.rename(account, label: label) }
  }
  public func setDefault(_ account: AccountContext) async {
    await run { try await lifecycle?.setDefault(account) }
  }
  public func signOut(_ account: AccountContext) async {
    if account == active { proof = .none }
    await run { try await lifecycle?.signOut(account) }
  }
  public func remove(_ account: AccountContext) async {
    if account == active { proof = .none }
    await run { try await lifecycle?.remove(account) }
  }
  public func authenticate(_ account: AccountContext? = nil) async {
    guard let authentication, let lifecycle else { return }
    await run(authorization: true) {
      let challenge = try await lifecycle.beginAuthentication(for: account)
      let pending = Task { try await authentication(challenge) }
      authenticationTask = pending
      defer { authenticationTask = nil }
      do { try await pending.value } catch {
        await lifecycle.cancelAuthentication(challenge)
        throw error
      }
    }
    if usesMusicSession, message == nil { await loadProof() }
  }
  public func cancelAuthentication() async {
    authenticationTask?.cancel()
    signIn?.cancel()
    await lifecycle?.cancelAuthentication()
    do { try await disconnectAction?() } catch { message = String(localized: "Local Google credential cleanup needs retry.") }
    await refresh()
  }
  public func refreshAuthorization() async {
    await run(authorization: true) { try await refreshAction?() }
  }
  public func disconnectAuthorization() async {
    await run(authorization: true) { try await disconnectAction?() }
  }
}

public struct AccountsView: View {
  @Bindable private var model: AccountsModel
  @State private var editing: AccountContext?
  @State private var label = ""
  @State private var removing: LocalIdentity?
  public init(model: AccountsModel) { self.model = model }
  public var body: some View {
    MusicGlassGroup {
      VStack(alignment: .leading, spacing: MusicSpace.md) {
        Text("Accounts").font(.largeTitle.bold()).audit("accountsTitle", group: "accounts-header", alignLeading: "accountsLeading")
        Text(
          "Local labels and defaults apply to this Mac. Service subscriptions remain with YouTube."
        )
        .foregroundStyle(MusicStyle.secondaryText).audit("accountsIntro", group: "accounts-header", alignLeading: "accountsLeading")
        if model.identities.isEmpty {
          ContentUnavailableView(
            "No accounts connected", systemImage: "person.crop.circle",
            description: Text(model.canAuthenticate
              ? "Sign in with your Google account on Google’s own page to connect YouTube Music."
              : "Add an account when browser sign-in is available.")
          ).frame(maxWidth: .infinity).musicSurface().audit("accountsEmpty", group: "accounts-body", alignLeading: "accountsLeading")
        } else {
          // The scrolled glass gets its own container inside the scroll view, and the
          // scroll view clips. One outer container composited the scrolled card's
          // glass outside the clip, over the footer status line (live L4).
          ScrollView {
            MusicGlassGroup {
            LazyVStack(alignment: .leading, spacing: MusicStyle.spacing) {
              if model.usesMusicSession { MusicAccountCard(model: model) }
              ForEach(model.identities) { identity in
                VStack(alignment: .leading, spacing: MusicSpace.xs) {
                  HStack {
                    Text(identity.account.displayName).font(.headline)
                    if model.defaultIdentity == identity.id {
                      Text("Default").foregroundStyle(MusicStyle.secondaryText)
                    }
                    if model.active == identity.id {
                      Text("Active · Paused").foregroundStyle(MusicStyle.secondaryText)
                    }
                  }
                  Text(identity.account.context.channelID.rawValue).font(.caption).foregroundStyle(
                    MusicStyle.secondaryText)
                  Text(status(identity.state)).accessibilityIdentifier(
                    "state-" + identity.account.displayName)
                  ViewThatFits(in: .horizontal) {
                    HStack { accountActions(identity) }
                    VStack(alignment: .leading, spacing: MusicSpace.xs) { accountActions(identity) }
                  }.musicButtons().disabled(model.busy)
                }.padding(MusicSpace.md).frame(maxWidth: .infinity, alignment: .leading).musicSurface()
                  .musicTransition(.reveal)
              }
            }.padding(MusicSpace.xxs)
            }
          }
          .clipShape(Rectangle())
          .contentMargins(.bottom, MusicStyle.compact, for: .scrollContent)
        }
        VStack(alignment: .leading, spacing: MusicStyle.compact) {
          AccountActionFeedback(model: model)
          Text(model.connectionStatus).foregroundStyle(MusicStyle.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("accountsConnectionStatus")
        }
        .layoutPriority(1).audit("accountsStatus", group: "accounts-body", alignLeading: "accountsLeading")
        if !model.canAuthenticate {
          Text("Browser sign-in is not connected in this development build.").foregroundStyle(
            MusicStyle.secondaryText
          ).accessibilityIdentifier("authUnavailable")
        }
        ViewThatFits(in: .horizontal) {
          HStack(spacing: MusicStyle.spacing) { primaryActions }
          VStack(alignment: .leading, spacing: MusicStyle.compact) { primaryActions }
        }.audit("accountsActions", group: "accounts-body", alignLeading: "accountsLeading")
      }.padding(MusicStyle.inset).frame(minWidth: 700, minHeight: 440)
    }.musicCanvas()
      .task {
        await model.refresh()
        if model.proof == .none { await model.loadProof() }
      }
      .alert(
        "Rename local label",
        isPresented: Binding(get: { editing != nil }, set: { if !$0 { editing = nil } })
      ) {
        TextField("Display label", text: $label).accessibilityIdentifier("accountLabel")
        Button("Cancel", role: .cancel) { editing = nil }
        Button("Save") {
          if let account = editing { Task { await model.rename(account, label: label) } }
          editing = nil
        }
      }
      .confirmationDialog(
        "Remove \(removing?.account.displayName ?? "account") from this Mac?",
        isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
        titleVisibility: .visible
      ) {
        Button("Remove Local Data", role: .destructive) {
          if let account = removing?.id { Task { await model.remove(account) } }
          removing = nil
        }
      } message: {
        Text(
          "Deletes local credentials, files and pending writes. Your Google account and remote playlists are unchanged."
        )
      }
  }
  @ViewBuilder private var primaryActions: some View {
    Button(model.usesMusicSession && !model.identities.isEmpty ? "Add Another Account" : model.authenticationLabel) {
      Task { await model.authenticate() }
    }.disabled(!model.canAuthenticate || model.busy)
      .accessibilityIdentifier("addAccount").musicButtons(prominent: true)
    if model.canRefreshAuthorization {
      Button("Refresh Google authorization") { Task { await model.refreshAuthorization() } }.disabled(model.busy)
        .musicButtons()
    }
    if model.canDisconnectAuthorization {
      Button("Disconnect Google authorization") { Task { await model.disconnectAuthorization() } }.disabled(model.busy)
        .musicButtons()
    }
    if model.busy {
      Button(model.usesMusicSession ? "Cancel Sign-In" : "Cancel authorization") {
        Task { await model.cancelAuthentication() }
      }.musicButtons()
    }
  }
  @ViewBuilder private func accountActions(_ identity: LocalIdentity) -> some View {
    if identity.state == .connected || identity.state == .expired {
      Button("Switch") { Task { await model.switchIdentity(identity.id) } }.accessibilityIdentifier(
        "switch-" + identity.account.displayName)
    }
    if identity.state == .expired || identity.state == .signedOut {
      Button(model.usesMusicSession ? "Sign In Again" : "Reconnect") { Task { await model.authenticate(identity.id) } }
        .accessibilityIdentifier("reconnect-" + identity.account.displayName).disabled(
        !model.canAuthenticate || !model.authenticationCanConnectMusic)
      if !model.authenticationCanConnectMusic {
        Text("Music reconnection awaits source-session access.").font(.caption)
      }
    }
    Button("Rename") {
      editing = identity.id
      label = identity.account.displayName
    }.accessibilityIdentifier("rename-" + identity.account.displayName)
    Button("Make Default") { Task { await model.setDefault(identity.id) } }.accessibilityIdentifier(
      "default-" + identity.account.displayName)
    if identity.state == .connected || identity.state == .expired {
      Button("Sign Out") { Task { await model.signOut(identity.id) } }.accessibilityIdentifier(
        "signout-" + identity.account.displayName)
    }
    Button(
      identity.state == .removalPending ? "Retry Removal" : "Remove Local Data", role: .destructive
    ) { removing = identity }.accessibilityIdentifier("remove-" + identity.account.displayName)
  }
  private func status(_ state: LocalSessionState) -> String {
    switch state {
    case .connected: "Connected"
    case .expired: model.usesMusicSession ? "Session expired — sign in again" : "Session expired · Reconnect"
    case .signedOut: "Signed out · Private data locked"
    case .removalPending: "Removal incomplete · Retry removal"
    }
  }
}
