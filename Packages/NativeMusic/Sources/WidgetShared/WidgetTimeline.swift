import Foundation
import SwiftUI
import WidgetKit

// W25 (MAC06, T25.1). The timeline provider and the widget. It READS the cached snapshot and returns one entry with the policy `.never`: it never schedules
// a refresh of its own, so the widget does not poll. The app reloads the timeline (WidgetCenter, from the app target) when something the widget shows changed.
// The provider holds no network client, no timer, no player and no store other than the snapshot reader it is given.

public struct NowPlayingWidgetEntry: TimelineEntry {
    public let date: Date
    public let display: WidgetDisplay
    public init(date: Date = Date(), display: WidgetDisplay) { self.date = date; self.display = display }
}

public struct NowPlayingTimelineProvider: TimelineProvider {
    public typealias Entry = NowPlayingWidgetEntry
    /// Reads the cached snapshot. The extension supplies the App Group's reader; a test supplies a fixture.
    public let read: @Sendable () -> WidgetReadResult
    public init(read: @escaping @Sendable () -> WidgetReadResult) { self.read = read }
    public func placeholder(in context: Context) -> Entry { Entry(display: .placeholder) }
    public func getSnapshot(in context: Context, completion: @escaping @Sendable (Entry) -> Void) {
        completion(context.isPreview ? Entry(display: .placeholder) : entry())
    }
    public func getTimeline(in context: Context, completion: @escaping @Sendable (Timeline<Entry>) -> Void) {
        completion(timeline())
    }
    func entry() -> Entry { Entry(display: WidgetDisplay(read())) }
    /// One entry, never refreshed on a schedule.
    public func timeline() -> Timeline<Entry> { Timeline(entries: [entry()], policy: .never) }
}

/// The widget's configuration. A `Widget` type must have an empty initialiser, so the extension target declares that type and builds its body from this;
/// `directory` is where the App Group's snapshot lives. Only the extension target can name the real container; nothing here does.
public enum NowPlayingWidgetConfiguration {
    public static let families: [WidgetFamily] = [.systemSmall, .systemMedium]
    @MainActor public static func make(directory: @escaping @Sendable () -> URL?) -> some WidgetConfiguration {
        let provider = NowPlayingTimelineProvider(read: { directory().map { WidgetSnapshotStore(directory: $0).read() } ?? .missing })
        return StaticConfiguration(kind: WidgetIdentity.widgetKind, provider: provider) { entry in
            NowPlayingWidgetView(entry: entry)
        }
        .configurationDisplayName(String(localized: "Now Playing"))
        .description(String(localized: "The last or current item, with play, previous and next."))
        .supportedFamilies(families)
    }
}
