import AppKit
import DesignSystem
import SwiftUI

public struct WelcomeView: View {
  private let accounts: AccountsModel
  @State private var showingAccounts = false
  public init(accounts: AccountsModel = AccountsModel()) { self.accounts = accounts }
  public var body: some View {
    GeometryReader { geometry in
      ScrollView {
        welcomeCard.padding(MusicSpace.xl).frame(maxWidth: .infinity).frame(minHeight: geometry.size.height)
      }
    }.sheet(isPresented: $showingAccounts) {
      VStack {
        AccountsView(model: accounts)
        Button("Done") { showingAccounts = false }.keyboardShortcut(.cancelAction).musicPageAction()
          .padding()
      }.musicCanvas().musicSignInSheet(accounts.signIn)
    }.musicCanvas()
      .musicSignInSheet(accounts.signIn, enabled: !showingAccounts)
  }
  private var welcomeCard: some View {
    MusicGlassGroup {
      VStack(spacing: MusicSpace.lg) {
        Image(nsImage: NSApplication.shared.applicationIconImage).resizable().aspectRatio(
          contentMode: .fit
        )
        .frame(width: 88, height: 88).accessibilityHidden(true)
        Text("YTMuse").font(MusicPageStyle.title)
        Text("YouTube Music, native on Mac.").font(.title3)
        Text("An independent native YouTube Music client for Mac").foregroundStyle(
          MusicStyle.secondaryText)
        Text(accounts.connectionStatus)
          .foregroundStyle(MusicStyle.secondaryText).accessibilityIdentifier("connectionStatus")
        Text("You can choose the app’s appearance in Settings.")
          .foregroundStyle(MusicStyle.secondaryText)
        Text("Service subscriptions remain with YouTube.").foregroundStyle(MusicStyle.secondaryText)
        if accounts.usesMusicSession && accounts.activeConnected {
          Button("Your Music Account") { showingAccounts = true }
            .accessibilityIdentifier("musicAccount").musicPageAction(prominent: true)
        } else {
          // An active expired identity signs in again as itself (a new record), never
          // as a new account that the duplicate-account check would refuse.
          Button(accounts.activeExpired ? "Sign In Again" : accounts.authenticationLabel) {
            Task { await accounts.authenticate(accounts.activeExpired ? accounts.active : nil) }
          }
            .disabled(!accounts.canAuthenticate || accounts.busy).accessibilityIdentifier(
              "musicSignIn"
            ).musicPageAction(prominent: true)
        }
        if accounts.usesMusicSession && !accounts.activeConnected {
          Label("Your password is entered on Google’s page, never in YTMuse.", systemImage: "lock.shield")
            .font(.callout).foregroundStyle(MusicStyle.secondaryText)
        }
        AccountActionFeedback(model: accounts)
        if accounts.busy {
          Button(accounts.usesMusicSession ? "Cancel Sign-In" : "Cancel authorization") {
            Task { await accounts.cancelAuthentication() }
          }.musicPageAction()
        }
        if !accounts.canAuthenticate {
          Text("Browser sign-in is not connected in this development build.").foregroundStyle(
            MusicStyle.secondaryText)
        }
        Button("Manage Accounts") { showingAccounts = true }.accessibilityIdentifier(
          "manageAccounts"
        ).musicPageAction()
        SettingsLink { Text("Open Settings") }.accessibilityIdentifier("openSettings")
          .musicPageAction()
      }.padding(MusicSpace.xl).frame(maxWidth: 560).musicInsetSurface()
    }
  }
}
