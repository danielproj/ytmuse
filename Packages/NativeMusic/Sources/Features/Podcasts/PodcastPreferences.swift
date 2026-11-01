import Foundation

/// Listening speed for spoken audio. The bounds are the playback command layer's own (`0.5…3`); a value outside them is refused, never
/// clamped to something the person did not choose. Pitch is preserved by the player (the web player's `<video>` keeps `preservesPitch` on).
public enum PodcastRate {
    public static let range: ClosedRange<Double> = 0.5...3
    public static let normal = 1.0
    /// The speeds the menu offers. Any value inside `range` is valid; these are the steps the control lists.
    public static let steps: [Double] = [0.5, 0.75, 1, 1.25, 1.5, 1.75, 2, 2.5, 3]
    public static func isValid(_ rate: Double) -> Bool { rate.isFinite && range.contains(rate) }
    /// "1.5×", "1×", "0.75×": no trailing zeros.
    public static func label(_ rate: Double) -> String {
        let text = rate == rate.rounded() ? String(Int(rate)) : String(rate)
        return text + "×"
    }
}

/// The jump buttons' lengths. Defaults are 15 s back and 30 s forward; the person may choose from the lists below.
public struct PodcastSkipIntervals: Codable, Equatable, Sendable {
    public static let defaultBack = 15
    public static let defaultForward = 30
    public static let backChoices = [5, 10, 15, 30, 45, 60]
    public static let forwardChoices = [10, 15, 30, 45, 60, 90]
    public private(set) var back: Int
    public private(set) var forward: Int
    public static let standard = PodcastSkipIntervals(unchecked: defaultBack, forward: defaultForward)
    private init(unchecked back: Int, forward: Int) { self.back = back; self.forward = forward }
    /// Nil when either length is not one the app offers.
    public init?(back: Int, forward: Int) {
        guard Self.backChoices.contains(back), Self.forwardChoices.contains(forward) else { return nil }
        self.back = back; self.forward = forward
    }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: Keys.self)
        let back = try values.decode(Int.self, forKey: .back), forward = try values.decode(Int.self, forKey: .forward)
        // A damaged or hand-edited file falls back to the defaults rather than carrying an unsupported length.
        self = Self(back: back, forward: forward) ?? PodcastSkipIntervals.standard
    }
    private enum Keys: String, CodingKey { case back, forward }
    /// Where a jump lands: clamped to the item (0 … duration when the length is known). A jump never leaves the item.
    public static func target(from position: Double, by seconds: Int, duration: Double) -> Double {
        let raw = position + Double(seconds)
        let upper = duration > 0 ? duration : .greatestFiniteMagnitude
        return min(max(raw, 0), upper)
    }
}

/// The person's podcast playback choices, kept on this Mac only (they are not a service setting and nothing syncs them).
public struct PodcastPlaybackPreferences: Codable, Equatable, Sendable {
    public var skip: PodcastSkipIntervals = PodcastSkipIntervals.standard
    /// The speed a show without its own choice plays at.
    public private(set) var defaultRate: Double = PodcastRate.normal
    /// Per show (the show page's browse id): the speed the person chose for it.
    public private(set) var showRates: [String: Double] = [:]
    public init() {}
    public func rate(forShow show: String?) -> Double {
        if let show, let own = showRates[show], PodcastRate.isValid(own) { return own }
        return PodcastRate.isValid(defaultRate) ? defaultRate : PodcastRate.normal
    }
    public func hasOwnRate(forShow show: String) -> Bool { showRates[show] != nil }
    /// False (nothing changes) for a speed outside the bounds.
    @discardableResult public mutating func setRate(_ rate: Double, forShow show: String) -> Bool {
        guard PodcastRate.isValid(rate), Self.isShowKey(show) else { return false }
        showRates[show] = rate; return true
    }
    @discardableResult public mutating func setDefaultRate(_ rate: Double) -> Bool {
        guard PodcastRate.isValid(rate) else { return false }
        defaultRate = rate; return true
    }
    public mutating func clearRate(forShow show: String) { showRates[show] = nil }
    static func isShowKey(_ value: String) -> Bool { value.range(of: #"^[A-Za-z0-9_-]{1,128}$"#, options: .regularExpression) != nil }
    private enum Keys: String, CodingKey { case skip, defaultRate, showRates }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: Keys.self)
        skip = (try? values.decode(PodcastSkipIntervals.self, forKey: .skip)) ?? PodcastSkipIntervals.standard
        let rate = (try? values.decode(Double.self, forKey: .defaultRate)) ?? PodcastRate.normal
        defaultRate = PodcastRate.isValid(rate) ? rate : PodcastRate.normal
        let stored = (try? values.decode([String: Double].self, forKey: .showRates)) ?? [:]
        showRates = stored.filter { PodcastRate.isValid($0.value) && Self.isShowKey($0.key) }
    }
}
