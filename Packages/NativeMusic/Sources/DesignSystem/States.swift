import SwiftUI

// DESIGN-ALIGN (2026-11-06): one look for "nothing to show yet" across the app. A page or panel that is loading, empty, failed, restricted or
// offline uses `MusicState` (built on the system's ContentUnavailableView) or one of the shorthands below. A status line inside other content uses
// `MusicInlineError`. Every action button goes through `musicStateAction()`, so the app's button choice changes in one place.

/// The action a state offers, usually Try Again.
public struct MusicStateAction {
  public let title: LocalizedStringKey
  public let identifier: String?
  public let perform: () -> Void
  public init(_ title: LocalizedStringKey, identifier: String? = nil, perform: @escaping () -> Void) {
    self.title = title; self.identifier = identifier; self.perform = perform
  }
  public static func tryAgain(identifier: String? = nil, _ perform: @escaping () -> Void) -> MusicStateAction {
    MusicStateAction("Try Again", identifier: identifier, perform: perform)
  }
}

public enum MusicStateSymbol {
  /// Every error uses this symbol, whether it fills a page or sits on one line.
  public static let error = "exclamationmark.triangle"
  public static let empty = "music.note.list"
  public static let offline = "wifi.slash"
  public static let restricted = "lock"
}

/// A page or panel with nothing to show yet.
public struct MusicState<Description: View>: View {
  let title: Text
  let systemImage: String
  let action: MusicStateAction?
  let description: Description
  public init(_ title: LocalizedStringKey, systemImage: String, action: MusicStateAction? = nil, @ViewBuilder description: () -> Description) {
    self.title = Text(title); self.systemImage = systemImage; self.action = action; self.description = description()
  }
  /// For a title computed at run time (already localized).
  public init(verbatim title: String, systemImage: String, action: MusicStateAction? = nil, @ViewBuilder description: () -> Description) {
    self.title = Text(verbatim: title); self.systemImage = systemImage; self.action = action; self.description = description()
  }
  public var body: some View {
    ContentUnavailableView {
      Label { title } icon: { Image(systemName: systemImage) }
    } description: {
      description
    } actions: {
      if let action {
        Button(action.title, action: action.perform).musicStateAction().accessibilityIdentifier(action.identifier ?? "stateAction")
      }
    }
  }
}

/// A failed read: the error symbol, a title, the failure's own words and Try Again.
public struct ErrorState: View {
  let title: LocalizedStringKey; let detail: Text; let action: MusicStateAction?
  public init(title: LocalizedStringKey, message: LocalizedStringKey, recovery: LocalizedStringKey = "Try Again", action: @escaping () -> Void) {
    self.title = title; self.detail = Text(message); self.action = MusicStateAction(recovery, perform: action)
  }
  /// The failure's own message (already localized, often from the service).
  public init(title: LocalizedStringKey, detail: String, retryIdentifier: String? = nil, retry: (() -> Void)?) {
    self.title = title; self.detail = Text(verbatim: detail); self.action = retry.map { MusicStateAction.tryAgain(identifier: retryIdentifier, $0) }
  }
  public var body: some View {
    MusicState(title, systemImage: MusicStateSymbol.error, action: action) { detail }
  }
}

/// Nothing here: read completely and empty.
public struct EmptyState: View {
  let title: LocalizedStringKey; let message: LocalizedStringKey; let systemImage: String
  public init(title: LocalizedStringKey, message: LocalizedStringKey, systemImage: String = MusicStateSymbol.empty) {
    self.title = title; self.message = message; self.systemImage = systemImage
  }
  public var body: some View { MusicState(title, systemImage: systemImage) { Text(message) } }
}

/// Loading a page or panel: a spinner with a short caption, the same height everywhere.
public struct LoadingState: View {
  let title: LocalizedStringKey
  public init(_ title: LocalizedStringKey = "Loading…") { self.title = title }
  public var body: some View {
    ProgressView(title).frame(maxWidth: .infinity, minHeight: 160).frame(maxHeight: .infinity)
  }
}

/// A failure inside other content (a search status line, one row): the error symbol and colour, the message, and Try Again when offered.
public struct MusicInlineError: View {
  let message: Text; let retry: (() -> Void)?; let retryIdentifier: String?
  /// A message already localized (often the service's own words).
  public init(_ message: String, retryIdentifier: String? = nil, retry: (() -> Void)? = nil) {
    self.message = Text(verbatim: message); self.retry = retry; self.retryIdentifier = retryIdentifier
  }
  public init(_ key: LocalizedStringKey, retryIdentifier: String? = nil, retry: (() -> Void)? = nil) {
    self.message = Text(key); self.retry = retry; self.retryIdentifier = retryIdentifier
  }
  public var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: MusicSpace.xs) {
      Label { message } icon: { Image(systemName: MusicStateSymbol.error) }.foregroundStyle(MusicStyle.errorText)
      if let retry { Button("Try Again", action: retry).musicStateAction().accessibilityIdentifier(retryIdentifier ?? "inlineRetry") }
    }
  }
}

extension View {
  /// The button style of every state's action (Try Again, Manage Accounts, Sign In). One place for the app-wide button choice.
  public func musicStateAction() -> some View { musicAction(.secondary) }
}
