import Foundation

/// W29 (SEC03, T29.1). The one way an `Error` becomes text that is stored, shown or logged outside the code that threw it.
///
/// A thrown error can carry anything the layer below knew: Foundation's `URLError` and `NSError` print their failing URL (a signed media link, a query
/// that holds a search), `DecodingError` prints a coding path and a payload fragment, and a service's own error can hold a header or a message. None of
/// that belongs in a state field, a failure list or a log line. So:
///  - an error Foundation produced is reduced to its domain and numeric code;
///  - anything else keeps its case name (the app's own error enums are the common case and their text is useful) with every URL, email address and home-folder
///    path removed, and a hard length cap. TH2: its PAYLOAD is not text we can recognise (a playlist name, a search the person typed, a title has no shape a
///    pattern finds), so an error that carries values keeps its case or type name and its labels, and each value is replaced by `…` unless it is a number, a
///    boolean or nil;
///  - the text never depends on `localizedDescription`, which a service or the system can fill with anything.
/// A source sweep (`SafeErrorTextSweepTests`) forbids `String(describing: error)` and `\(error)` interpolation anywhere else in the product's text paths.
public enum SafeErrorText {
    public static let maximumLength = 160

    public static func describe(_ error: any Error) -> String {
        if error is CancellationError { return "cancelled" }
        if let url = error as? URLError { return "network error \(url.code.rawValue)" }
        if error is DecodingError { return "unreadable response" }
        let raw = String(describing: error)
        // Foundation's own errors (and anything that prints like one) are reduced to domain and code: their text carries userInfo.
        if raw.contains("Error Domain=") || raw.contains("UserInfo=") || raw.contains("NSLocalizedDescription") || raw.contains("NSUnderlyingError") {
            let ns = error as NSError
            return "\(ns.domain) \(ns.code)"
        }
        let shaped = shape(error)
        return scrub(shaped ?? raw)
    }

    /// TH2: the case (or type) name and labels of a value that carries a payload, with every non-numeric value replaced. Nil for a value without children (a bare case
    /// name or an error with its own description), which `describe` then scrubs as before.
    private static func shape(_ value: Any, depth: Int = 0) -> String? {
        let mirror = Mirror(reflecting: value)
        guard !mirror.children.isEmpty, depth < 4 else { return nil }
        let name: String
        switch mirror.displayStyle {
        case .enum:
            // An enum's single child is labelled with the case name; its value is the payload (a tuple when there are several).
            guard let child = mirror.children.first else { return nil }
            let label = child.label ?? String(describing: type(of: value))
            return label + "(" + payload(child.value, depth: depth + 1) + ")"
        case .optional: return payload(mirror.children.first?.value as Any, depth: depth)
        default: name = String(describing: type(of: value))
        }
        let parts = mirror.children.map { child -> String in
            let rendered = payload(child.value, depth: depth + 1)
            return child.label.map { "\($0): \(rendered)" } ?? rendered
        }
        return name + "(" + parts.joined(separator: ", ") + ")"
    }
    private static func payload(_ value: Any, depth: Int) -> String {
        switch value {
        case is Bool, is Int, is Int8, is Int16, is Int32, is Int64, is UInt, is UInt8, is UInt16, is UInt32, is UInt64, is Double, is Float: return "\(value)"
        case is String, is Substring, is Character, is URL, is Data: return "…"
        default: break
        }
        let mirror = Mirror(reflecting: value)
        if mirror.displayStyle == .optional { return mirror.children.isEmpty ? "nil" : payload(mirror.children[mirror.children.startIndex].value, depth: depth) }
        if mirror.displayStyle == .tuple { return mirror.children.map { child in child.label.flatMap { $0.hasPrefix(".") ? nil : $0 }.map { "\($0): \(payload(child.value, depth: depth + 1))" } ?? payload(child.value, depth: depth + 1) }.joined(separator: ", ") }
        if mirror.displayStyle == .enum, mirror.children.isEmpty { return String(describing: value) }   // a case without payload: its name
        return shape(value, depth: depth) ?? "…"
    }

    /// Removes what must never travel in an error's text, then caps it.
    public static func scrub(_ text: String) -> String {
        var value = text
        for (pattern, replacement) in patterns {
            value = value.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
        }
        value = value.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
        return value.count > maximumLength ? String(value.prefix(maximumLength)) + "…" : value
    }
    private static let patterns: [(String, String)] = [
        (#"[A-Za-z][A-Za-z0-9+.\-]*://[^\s"']*"#, "<url>"),
        (#"[A-Za-z0-9._%+'\-]+(?:@|%40)[A-Za-z0-9.\-]+\.[A-Za-z]{2,}"#, "<email>"),
        // A home-folder path may hold spaces (a file named after a playlist): everything up to a quote, bracket or line end goes.
        (#"/Users/[^"'\)\]\n\r]*"#, "<path>"),
        (#"(?i)\b(?:bearer|basic)\s+[A-Za-z0-9._~+/=\-]+"#, "<credential>"),
        (#"\beyJ[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{4,}\.[A-Za-z0-9_\-]*"#, "<token>"),
    ]
}
