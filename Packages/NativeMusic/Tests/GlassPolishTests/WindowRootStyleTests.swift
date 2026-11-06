import Foundation
import Testing

/// APPEARANCE-STYLE finding 3: a window that misses the style injection falls back to YTMuse inside a Standard app, a mixed look nobody would
/// notice in review. Every window root in the app's sources must therefore go through the one style hook: the two SwiftUI scenes apply
/// `.appStyle(...)`, and every manually hosted window hosts its root with `.appAppearance()` (which applies the style). Only the main window
/// may be translucent. (Before this work the web and native video windows had no hook at all and ignored even Light/Dark.)
@Suite struct WindowRootStyleTests {
  static let root = SourceGuardTests.root
  /// A hosting root in a statement: `NSHostingView(rootView:` or `NSHostingController(rootView:`, up to the end of the call's line.
  static let hostingRoot = #"NSHosting(View|Controller)\s*\(\s*rootView:"#
  static func hosts(_ line: String) -> Bool { line.range(of: hostingRoot, options: .regularExpression) != nil }

  static func findings(in text: String, path: String) -> [String] {
    var found: [String] = []
    for (line, content) in SourceGuardTests.code(text) where hosts(content) {
      if !content.contains(".appAppearance()") { found.append("\(path):\(line): a hosted window root without .appAppearance(): \(content.trimmingCharacters(in: .whitespaces))") }
    }
    return found
  }
  /// The body of each scene in `NativeMusicScenes` (from its opening line to the next scene or the end of `body`).
  static func scenes(in text: String) -> [(name: String, body: String)] {
    let lines = text.components(separatedBy: "\n")
    var out: [(String, String)] = [], current: (String, [String])?
    for line in lines {
      if line.contains("WindowGroup(") || line.contains("Settings {") || line.contains("MenuBarExtra(") || line.range(of: #"\bWindow\("#, options: .regularExpression) != nil {
        if let current { out.append((current.0, current.1.joined(separator: "\n"))) }
        current = (line.trimmingCharacters(in: .whitespaces), [line])
      } else if current != nil { current!.1.append(line) }
      if line.hasPrefix("private struct") || line.hasPrefix("struct ") { if let c = current { out.append((c.0, c.1.joined(separator: "\n"))); current = nil } }
    }
    if let current { out.append((current.0, current.1.joined(separator: "\n"))) }
    return out
  }

  @Test func everyManuallyHostedWindowRootAppliesTheAppearanceAndStyleHook() throws {
    var hosts = 0, findings: [String] = []
    for file in try SourceGuardTests.sourceFiles() where !file.path.contains("/Extensions/") {
      let text = try String(contentsOf: file, encoding: .utf8)
      hosts += SourceGuardTests.code(text).filter { Self.hosts($0.text) }.count
      findings += Self.findings(in: text, path: file.path.replacingOccurrences(of: Self.root.path + "/", with: ""))
    }
    #expect(hosts >= 3, "the sweep sees the mini-player, the status popover and the video/full-screen presenter (\(hosts))")
    #expect(findings.isEmpty, Comment(rawValue: findings.joined(separator: "\n")))
  }

  @Test func everySceneAppliesTheStyleAndOnlyTheMainWindowMayBeTranslucent() throws {
    let url = Self.root.appendingPathComponent("Packages/NativeMusic/Sources/AppShell/NativeMusicScenes.swift")
    let scenes = Self.scenes(in: try String(contentsOf: url, encoding: .utf8))
    #expect(scenes.count >= 2, "the main window and Settings (\(scenes.map(\.name)))")
    for scene in scenes {
      #expect(scene.body.contains(".appStyle("), "\(scene.name) applies the style")
      let translucent = scene.body.contains(".appStyle(translucentWindow: true)")
      #expect(translucent == scene.name.contains("id: \"main\""), "\(scene.name): only the main window may show the desktop")
    }
  }

  /// Controls: the sweep flags a root without the hook, and accepts one with it.
  @Test func theSweepCatchesARootWithoutTheHook() {
    #expect(Self.findings(in: "let hosting = NSHostingView(rootView: Panel())", path: "Sample.swift").count == 1)
    #expect(Self.findings(in: "popover.contentViewController = NSHostingController(rootView: Panel())", path: "Sample.swift").count == 1)
    #expect(Self.findings(in: "let hosting = NSHostingView(rootView: Panel().appAppearance())", path: "Sample.swift").isEmpty)
    #expect(Self.findings(in: "// NSHostingView(rootView: Panel()) in a comment", path: "Sample.swift").isEmpty)
    let scenes = Self.scenes(in: "        WindowGroup(\"YTMuse\", id: \"main\") {\n            Root().appStyle(translucentWindow: true)\n        }\n        Settings {\n            Panel()\n        }\n")
    #expect(scenes.count == 2 && !scenes[1].body.contains(".appStyle("), "a scene without the hook is visible to the check")
  }
}
