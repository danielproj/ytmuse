import Foundation

// W30 (BUILD06, SEC09). The in-repository updater. Docs/Distribution.md is the design; this module has no AppKit, no SwiftUI and no account or
// playback code. Everything that touches the network, the disk image, the code signature or the running bundle sits behind a protocol so the
// rules below are tested with in-process stand-ins.

/// A semantic version (MAJOR.MINOR.PATCH with an optional pre-release), parsed strictly: ASCII digits, no leading zeros, no whitespace, no build
/// metadata. Ordering follows semantic versioning 2.0 precedence, so `1.2.0-beta.2 < 1.2.0`.
public struct AppVersion: Hashable, Comparable, Sendable, CustomStringConvertible {
    public let major: Int
    public let minor: Int
    public let patch: Int
    public let prerelease: [String]
    public init?(_ text: String) {
        guard text.utf8.count <= 64, text.unicodeScalars.allSatisfy({ $0.isASCII && !$0.properties.isWhitespace }) else { return nil }
        let halves = text.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard !halves.isEmpty, text.contains("+") == false else { return nil }
        let core = halves[0].split(separator: ".", omittingEmptySubsequences: false)
        guard core.count == 3 else { return nil }
        var numbers: [Int] = []
        for part in core {
            guard let value = Self.number(part) else { return nil }
            numbers.append(value)
        }
        var pre: [String] = []
        if halves.count == 2 {
            let parts = halves[1].split(separator: ".", omittingEmptySubsequences: false)
            guard !parts.isEmpty else { return nil }
            for part in parts {
                guard !part.isEmpty, part.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }) else { return nil }
                if part.allSatisfy(\.isNumber), Self.number(part) == nil { return nil }   // numeric identifiers carry no leading zero
                pre.append(String(part))
            }
        }
        major = numbers[0]; minor = numbers[1]; patch = numbers[2]; prerelease = pre
    }
    private static func number(_ part: Substring) -> Int? {
        guard !part.isEmpty, part.count <= 9, part.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        if part.count > 1, part.first == "0" { return nil }
        return Int(part)
    }
    public var description: String {
        "\(major).\(minor).\(patch)" + (prerelease.isEmpty ? "" : "-" + prerelease.joined(separator: "."))
    }
    public static func < (a: AppVersion, b: AppVersion) -> Bool {
        if (a.major, a.minor, a.patch) != (b.major, b.minor, b.patch) { return (a.major, a.minor, a.patch) < (b.major, b.minor, b.patch) }
        switch (a.prerelease.isEmpty, b.prerelease.isEmpty) {
        case (true, true): return false
        case (false, true): return true        // a pre-release precedes its release
        case (true, false): return false
        case (false, false):
            for (x, y) in zip(a.prerelease, b.prerelease) where x != y {
                switch (Int(x), Int(y)) {
                case let (m?, n?): return m < n
                case (_?, nil): return true     // numeric identifiers precede alphanumeric ones
                case (nil, _?): return false
                default: return x < y
                }
            }
            return a.prerelease.count < b.prerelease.count
        }
    }
}

/// The macOS version a release needs, "MAJOR.MINOR" or "MAJOR.MINOR.PATCH".
public struct SystemVersion: Hashable, Comparable, Sendable {
    public let major: Int, minor: Int, patch: Int
    public init(major: Int, minor: Int, patch: Int = 0) { self.major = major; self.minor = minor; self.patch = patch }
    public init?(_ text: String) {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard (2...3).contains(parts.count), parts.allSatisfy({ !$0.isEmpty && $0.count <= 4 && $0.allSatisfy { $0.isASCII && $0.isNumber } }) else { return nil }
        let n = parts.compactMap { Int($0) }
        self.init(major: n[0], minor: n[1], patch: n.count > 2 ? n[2] : 0)
    }
    public static func < (a: SystemVersion, b: SystemVersion) -> Bool { (a.major, a.minor, a.patch) < (b.major, b.minor, b.patch) }
}
