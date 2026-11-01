import Foundation

/// SEC03, T27.4. The support bundle: one JSON document the person can read in full BEFORE exporting. What is exported is byte-for-byte what the preview
/// showed, so nothing can differ between "looked fine" and "was sent". Nothing here sends anything: export writes a single file to the destination the
/// caller injects (a save panel in the app, a temporary directory in a test). Media files and credentials are not inputs to this type at all.
public struct SupportBundle: Sendable, Equatable {
    public static let maxBytes = 256 * 1024
    public let text: String
    public let redactions: Int
    public var data: Data { Data(text.utf8) }
    public var byteCount: Int { text.utf8.count }
    public let sections: [String]

    /// Builds the bundle from a finished report. The text is encoded, then redacted AS TEXT with the full context, so a field a future change adds to the
    /// report is covered too. Over-size input is cut at entry boundaries, never mid-document.
    public static func make(report: DiagnosticsReport, context: RedactionContext) -> SupportBundle {
        var report = report
        var text = render(report, context: context)
        while text.utf8.count > maxBytes, !report.recentErrors.isEmpty {
            report.recentErrors.removeFirst(Swift.max(1, report.recentErrors.count / 4))
            text = render(report, context: context)
        }
        return SupportBundle(text: text, redactions: DiagnosticRedactor.redactionCount(in: rawJSON(report), context: context), sections: ["app", "adapter", "playback", "storage", "errors", "settings", "profiling", "exclusions"])
    }
    /// The error path. When the report itself cannot be built (a provider threw), the bundle still says what failed, as a category and redacted text.
    public static func makeFailure(category: DiagnosticCategory, component: String, error: String, generatedAt: Date, context: RedactionContext) -> SupportBundle {
        struct Failure: Codable { let generatedAt: Date; let category: DiagnosticCategory; let component: String; let error: String; let note: String }
        let failure = Failure(generatedAt: generatedAt, category: category, component: DiagnosticLog.componentName(component), error: DiagnosticRedactor.redact(error, context: context), note: "The diagnostics report could not be built. Only this failure is included.")
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]; encoder.dateEncodingStrategy = .iso8601
        let raw = String(decoding: (try? encoder.encode(failure)) ?? Data(), as: UTF8.self)
        return SupportBundle(text: DiagnosticRedactor.redact(raw, context: context), redactions: DiagnosticRedactor.redactionCount(in: raw, context: context), sections: ["failure"])
    }
    private static func rawJSON(_ report: DiagnosticsReport) -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]; encoder.dateEncodingStrategy = .iso8601
        return String(decoding: (try? encoder.encode(report)) ?? Data(), as: UTF8.self)
    }
    private static func render(_ report: DiagnosticsReport, context: RedactionContext) -> String { DiagnosticRedactor.redact(rawJSON(report), context: context) }

    public enum ExportError: Error, Equatable { case notAFileURL, destinationIsADirectory, tooLarge, writeFailed }
    /// Writes the previewed bytes to `destination` (an injected file URL), owner-only, atomically. Returns the bytes written.
    @discardableResult
    public func export(to destination: URL) throws -> Int {
        guard destination.isFileURL else { throw ExportError.notAFileURL }
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: destination.path, isDirectory: &isDirectory), isDirectory.boolValue { throw ExportError.destinationIsADirectory }
        guard byteCount <= Self.maxBytes else { throw ExportError.tooLarge }
        do {
            try data.write(to: destination, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        } catch { throw ExportError.writeFailed }
        return byteCount
    }
}
