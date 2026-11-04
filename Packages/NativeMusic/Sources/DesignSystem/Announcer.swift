import SwiftUI

// W28 (A11Y04, T28.6): the one way the app speaks to VoiceOver. A significant change in state, an error that needs a
// recovery, or a change of account is announced; the playback clock and the lyric line are not, and the API gives them no
// way in: there is no kind for them. Every announcement goes through `Announcer.post`, a source guard (T28) fails the
// build of any other `AccessibilityNotification.Announcement` use, and the policy below drops repeats and bursts.

/// What an announcement is about. Deliberately no `position`, `tick` or `lyricLine` kind.
public enum AnnouncementKind: String, CaseIterable, Sendable {
  /// Play, pause, stop, a new track, an ad starting or ending, buffering that lasts.
  case transport
  /// A failed action, with its recovery.
  case error
  /// Sign-in, sign-out, a switched or expired account.
  case account
  /// A download finished, failed or was cancelled.
  case download
  /// A change the person asked for that has no other visible confirmation (copied, removed, moved).
  case confirmation
}

/// Decides whether one announcement is spoken. Pure value logic over an injected clock, so tests drive time.
public struct AnnouncementPolicy: Sendable {
  /// The same words are not repeated within this window (a retry loop that fails the same way every second is one announcement).
  public var repeatWindow: TimeInterval = 8
  /// At most `burstLimit` announcements per `burstWindow` (downloads, confirmations); errors, account changes and transport states always pass.
  public var burstLimit = 3
  public var burstWindow: TimeInterval = 10
  private var lastSpoken: [String: Date] = [:]
  private var recent: [Date] = []
  public init() {}
  public enum Decision: Equatable, Sendable { case speak, repeated, throttled, empty }
  public mutating func decide(_ text: String, kind: AnnouncementKind, at now: Date) -> Decision {
    let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !words.isEmpty else { return .empty }
    if let last = lastSpoken[words], now.timeIntervalSince(last) < repeatWindow { return .repeated }
    recent.removeAll { now.timeIntervalSince($0) >= burstWindow }
    switch kind {
    case .error, .account: break
    case .transport: break   // coalesced by the Announcer (the LATEST state wins), not dropped here
    case .download, .confirmation:
      if recent.count >= burstLimit { return .throttled }
    }
    lastSpoken = lastSpoken.filter { now.timeIntervalSince($0.value) < repeatWindow }
    lastSpoken[words] = now
    recent.append(now)
    return .speak
  }
}

/// Runs `work` after `seconds` and returns a function that cancels it. Injectable so a test drives time.
public typealias AnnouncementScheduler = @MainActor (TimeInterval, @escaping @MainActor () -> Void) -> () -> Void

@MainActor public final class Announcer {
  public static let shared = Announcer()
  private var policy = AnnouncementPolicy()
  private let clock: () -> Date
  private let sink: (String) -> Void
  private let schedule: AnnouncementScheduler
  /// Transport changes settle for this long before the newest one is spoken: skipping A, then B, then C quickly says C, never A (A11Y04).
  public var transportSettle: TimeInterval = 0.45
  private var pendingTransport: String?
  private var cancelPending: (() -> Void)?
  /// Production: VoiceOver. Tests inject a sink, a clock and a scheduler.
  public init(clock: @escaping () -> Date = Date.init, sink: @escaping (String) -> Void = { AccessibilityNotification.Announcement($0).post() },
              scheduler: @escaping AnnouncementScheduler = { seconds, work in
                let task = Task { @MainActor in try? await Task.sleep(for: .seconds(seconds)); if !Task.isCancelled { work() } }
                return { task.cancel() }
              }) {
    self.clock = clock; self.sink = sink; self.schedule = scheduler
  }
  public func configure(policy: AnnouncementPolicy) { self.policy = policy }
  /// Returns the policy's decision for an immediate kind; a transport message is held (`.throttled` means "held for the newest state").
  @discardableResult
  public func post(_ text: String, kind: AnnouncementKind) -> AnnouncementPolicy.Decision {
    if kind == .transport {
      let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !words.isEmpty else { return .empty }
      pendingTransport = words
      cancelPending?()
      cancelPending = schedule(transportSettle) { [weak self] in self?.flushTransport() }
      return .throttled
    }
    let decision = policy.decide(text, kind: kind, at: clock())
    if decision == .speak { sink(text) }
    return decision
  }
  private func flushTransport() {
    guard let text = pendingTransport else { return }
    pendingTransport = nil; cancelPending = nil
    if policy.decide(text, kind: .transport, at: clock()) == .speak { sink(text) }
  }
  public static func post(_ text: String, kind: AnnouncementKind) { shared.post(text, kind: kind) }
}
