import AccountSession
import DesignSystem
import Domain
import SwiftUI

/// W28 (A11Y04): what changed about the account, in words a VoiceOver user needs. Only a change of who is signed in, or whether their
/// session still works, is announced; refreshing the same account says nothing.
public struct AccountAnnouncementState: Equatable, Sendable {
  public var active: AccountContext?
  public var name: String?
  public var expired: Bool
  public var hasIdentities: Bool
  public init(active: AccountContext?, name: String?, expired: Bool, hasIdentities: Bool) {
    self.active = active; self.name = name; self.expired = expired; self.hasIdentities = hasIdentities
  }
}
public enum AccountAnnouncement {
  public static func message(from old: AccountAnnouncementState, to new: AccountAnnouncementState) -> String? {
    guard old != new else { return nil }
    switch (old.active, new.active) {
    case (nil, nil): return nil
    case (_?, nil): return String(localized: "Signed out.")
    case (nil, let _?): return new.expired ? nil : new.name.map { String(localized: "Signed in as \($0).") }
    case (let before?, let after?):
      if before != after { return new.name.map { String(localized: "Switched to \($0).") } }
      if !old.expired && new.expired { return new.name.map { String(localized: "The session for \($0) ended. Sign in again.") } }
      if old.expired && !new.expired { return new.name.map { String(localized: "Signed in again as \($0).") } }
      return nil
    }
  }
}
extension AccountsModel {
  public var announcementState: AccountAnnouncementState {
    AccountAnnouncementState(active: active, name: identities.first(where: { $0.id == active })?.account.displayName, expired: activeExpired, hasIdentities: !identities.isEmpty)
  }
}
extension View {
  /// Announces account changes (not refreshes) to VoiceOver.
  public func announcesAccountChanges(_ accounts: AccountsModel) -> some View {
    onChange(of: accounts.announcementState) { old, new in
      if let text = AccountAnnouncement.message(from: old, to: new) { Announcer.post(text, kind: .account) }
    }
  }
}
