public enum Appearance: String, CaseIterable, Sendable {
    case system, light, dark
    public init(storedValue: String?) {
        self = storedValue.flatMap(Self.init(rawValue:)) ?? .system
    }
}
