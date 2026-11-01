import Foundation

/// Where the repository's files are, for tests that read the catalog, the manifest, the specification and the sources.
enum Repo {
  /// …/Packages/NativeMusic/Tests/AccessibilityLocalizationTests/<file> → the repository root.
  static let root: URL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
  static func text(_ path: String) throws -> String { try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8) }
  static func json(_ path: String) throws -> [String: Any] {
    try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent(path))) as! [String: Any]
  }
  /// Every Swift file under a directory of the repository, with its text.
  static func swiftFiles(under path: String) -> [(path: String, text: String)] {
    let base = root.appendingPathComponent(path)
    guard let walker = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil) else { return [] }
    var out: [(String, String)] = []
    for case let url as URL in walker where url.pathExtension == "swift" {
      if let text = try? String(contentsOf: url, encoding: .utf8) { out.append((String(url.path.dropFirst(root.path.count + 1)), text)) }
    }
    return out.sorted { $0.0 < $1.0 }
  }
  /// The code of a Swift file with `//` comments removed (a comment may name what the code must not do).
  static func code(_ text: String) -> String {
    text.split(separator: "\n", omittingEmptySubsequences: false).map { line -> Substring in
      if let range = line.range(of: "//") { return line[..<range.lowerBound] }
      return line
    }.joined(separator: "\n")
  }
}
