import AccountSession
import AppKit
import DesignSystem
import Domain
import Features
import Persistence
import Security
// This app target is built by tests only. It is absent from the production app.
import SwiftUI

private enum TestCredentials {
  static let uuid = UUID(uuidString: "00000000-0000-0000-0004-000000000001")!
  static let namespace = KeychainVault.applicationNamespace + ".test.native-ui"
  static func cleanup() {
    for channel in ["Alpha", "Beta"] {
      let service = namespace + ":" + uuid.uuidString + ":\(channel.utf8.count):" + channel + ":US"
      SecItemDelete(
        [
          kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
          kSecUseDataProtectionKeychain as String: false,
        ] as CFDictionary)
    }
  }
}
private final class TestAppDelegate: NSObject, NSApplicationDelegate {
  func applicationWillTerminate(_ notification: Notification) { TestCredentials.cleanup() }
}
@main struct NativeAccountTestHost: App {
  @NSApplicationDelegateAdaptor(TestAppDelegate.self) private var delegate
  var body: some Scene {
    WindowGroup("YTMuse Account Tests") {
      if let mode = ProcessInfo.processInfo.environment["T50_VISUAL_MODE"] {
        VisualTestRoot(mode: mode)
      } else {
        TestRoot()
      }
    }.defaultSize(
      width: ProcessInfo.processInfo.environment["T50_VISUAL_MODE"]?.contains("compact") == true
        ? 840 : 1050,
      height: ProcessInfo.processInfo.environment["T50_VISUAL_MODE"]?.contains("compact") == true
        ? 560 : 740
    )
    .restorationBehavior(.disabled)
    .defaultLaunchBehavior(.presented)
    Settings { PreferencesView() }
  }
}
struct TestRoot: View {
  @State private var model: AccountsModel?
  @State private var lifecycle: AccountLifecycle?
  @State private var status = "Preparing isolated native test accounts"
  var body: some View {
    VStack {
      Text("Synthetic account test composition · No YouTube session").accessibilityIdentifier(
        "testComposition")
      Text(status).accessibilityIdentifier("keychainStatus")
      if let model {
        AccountsView(model: model)
        Button("Expire Active Test Session") {
          Task {
            if let lifecycle {
              try? await lifecycle.expire(context: lifecycle.snapshot().context)
              await model.refresh()
            }
          }
        }.accessibilityIdentifier("expireTestSession")
      }
    }.task {
      do {
        let initial = RequestContext(account: nil, accountGeneration: 0, requestGeneration: 0)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
          "native-music-account-ui-" + UUID().uuidString)
        let store = try SQLiteStore(directory: root, context: initial)
        let directory = SQLiteAccountDirectory(store: store, context: initial)
        // Real production macOS SecItem APIs, isolated app-owned records.
        let vault = try KeychainVault(namespace: TestCredentials.namespace)
        let owner = try await AccountLifecycle.open(
          vault: vault, store: directory,
          participants: [
            SQLiteAccountParticipant(store: store, directory: directory), ScopedAccountWork(),
          ])
        TestCredentials.cleanup()
        let uuid = TestCredentials.uuid
        let accounts = try ["Alpha", "Beta"].map { channel in
          let context = try AccountContext(
            accountID: uuid, channelID: ID<ChannelTag>(channel), region: "US")
          return try Account(
            id: uuid, serviceIdentity: ServiceID("synthetic-service"), context: context,
            displayName: "Synthetic " + channel, credential: nil)
        }
        for account in accounts {
          let challenge = try await owner.beginAuthentication()
          try await owner.completeAuthentication(
            challenge, account: account, secret: Data([11, 22, 33]))
        }
        try await owner.switchIdentity(to: accounts[0].context)
        let context = await owner.snapshot().context
        let reference = await owner.snapshot().directory.identities[0].account.credential!
        guard try await vault.read(reference, context: context) == Data([11, 22, 33]) else {
          throw DomainError.unauthorized
        }
        let model = AccountsModel(
          lifecycle: owner,
          authentication: { challenge in
            guard let account = accounts.first(where: { $0.context == challenge.identity }) else {
              throw DomainError.unsupported
            }
            try await owner.completeAuthentication(
              challenge, account: account, secret: Data([44, 55]))
          })
        await model.refresh()
        self.model = model
        lifecycle = owner
        status = "Native macOS Keychain round-trip passed"
      } catch let error as LifecycleError { status = "Native test setup failed: \(error)" } catch {
        status = "Native test setup failed"
      }
    }
  }
}

// Test-process-only SwiftUI environment simulation. No production override or OS preference mutation.
private struct VisualTestRoot: View {
  let mode: String
  var body: some View {
    VStack {
      Text("T50 simulated environment: " + mode).accessibilityIdentifier("visualMode")
      if mode.contains("settings") {
        PreferencesView()
      } else if mode.contains("accounts") {
        TestRoot()
      } else {
        WelcomeView()
      }
    }
    .environment(\._accessibilityReduceTransparency, mode.contains("transparency"))
    .environment(\._colorSchemeContrast, mode.contains("contrast") ? .increased : .standard)
    .environment(\._accessibilityReduceMotion, mode.contains("motion"))
    .preferredColorScheme(mode.contains("dark") ? .dark : .light)
  }
}
