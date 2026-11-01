import Testing
import Foundation

/// GLASS08/GLASS10 guard: radii, materials, animations and raw Liquid Glass belong to the design system.
/// Feature and shell code asks for `MusicCorner`, `musicSurface`, `MusicMotion` and friends. A literal radius, a raw
/// material or an ad-hoc animation outside `Sources/DesignSystem` fails here unless it is listed in `exemptions` with a reason.
@Suite struct SourceGuardTests {
    struct Rule { let name: String; let pattern: String }
    static let rules: [Rule] = [
        .init(name: "literal corner radius", pattern: #"cornerRadius\s*:"#),
        .init(name: "uneven rounded rectangle", pattern: #"UnevenRoundedRectangle\s*\("#),
        .init(name: "raw material", pattern: #"\.(ultraThin|thin|regular|thick|ultraThick|bar)Material\b|\bMaterial\.|:\s*Material\b"#),
        .init(name: "ad-hoc animation modifier", pattern: #"\.animation\s*\("#),
        .init(name: "ad-hoc withAnimation", pattern: #"\bwithAnimation\s*\("#),
        .init(name: "ad-hoc transition", pattern: #"\.transition\s*\("#),
        .init(name: "ad-hoc animation curve", pattern: #"\.(spring|snappy|smooth|bouncy|easeIn|easeOut|easeInOut|linear|interpolatingSpring|interactiveSpring)\s*\(|\bAnimation\s*\.\s*\w+"#),
        .init(name: "raw glass effect", pattern: #"\.glassEffect\s*\(|GlassEffectContainer\s*[\(\{<]|\.glassEffectID\s*\(|\.glassEffectUnion\s*\("#),
        .init(name: "raw glass button style", pattern: #"\.buttonStyle\s*\(\s*\.glass"#),
        .init(name: "literal spacing or padding", pattern: #"spacing:\s*(?!0(?![.\d]))\d|\.padding\((?:[^)]*,\s*)?(?!0\s*\))\d"#),
        // Bypasses a literal-only guard would miss (V02 rework 1): arithmetic on a token, other shadow/corner/inset spellings, decorative loops.
        .init(name: "arithmetic on a spacing token", pattern: #"MusicSpace\.\w+\s*[-+*/]\s*\d|\d\s*[-+*/]\s*MusicSpace\.|MusicStyle\.(spacing|compact|inset)\s*[-+*/]\s*\d"#),
        .init(name: "ad-hoc shadow, blur, corner or inset shape", pattern: #"\.shadow\s*\(|\.blur\s*\(|NSVisualEffectView|cornerSize|cornerRadii|EdgeInsets\s*\("#),
        .init(name: "decorative animation loop", pattern: #"phaseAnimator|keyframeAnimator|repeatForever|\bTimelineView\s*\(|\.symbolEffect\(\s*\.(pulse|variableColor|breathe|rotate|wiggle)"#),
    ]
    /// A literal frame edge that is not on the 4 pt grid (1 pt probes and 0 are fine).
    static let offGridFrame = "off-grid literal frame"
    /// path suffix + rule name -> reason. Keep this list empty unless a literal truly cannot live in the design system.
    static let exemptions: [(path: String, rule: String, reason: String)] = []

    static let root: URL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    static func sourceFiles() throws -> [URL] {
        var result: [URL] = []
        for base in ["Packages/NativeMusic/Sources", "App/Sources", "Extensions/Sources"] {
            let directory = root.appendingPathComponent(base)
            guard let walker = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in walker where url.pathExtension == "swift" && !url.path.contains("/Sources/DesignSystem/") { result.append(url) }
        }
        return result
    }
    /// Code without line comments (a `//` that opens a comment, not one inside a string such as a URL scheme).
    static func code(_ text: String) -> [(line: Int, text: String)] {
        text.components(separatedBy: "\n").enumerated().map { index, raw in
            var inString = false, previous: Character = " "
            var out = ""
            for character in raw {
                if character == "\"" && previous != "\\" { inString.toggle() }
                if !inString, character == "/", previous == "/" { out.removeLast(); break }
                out.append(character); previous = character
            }
            return (index + 1, out)
        }
    }
    static func findings(in text: String, path: String) -> [String] {
        var found: [String] = []
        for (line, content) in code(text) {
            for rule in rules where content.range(of: rule.pattern, options: .regularExpression) != nil {
                if exemptions.contains(where: { path.hasSuffix($0.path) && $0.rule == rule.name }) { continue }
                found.append("\(path):\(line): \(rule.name): \(content.trimmingCharacters(in: .whitespaces))")
            }
            if content.contains(".frame("), !exemptions.contains(where: { path.hasSuffix($0.path) && $0.rule == offGridFrame }) {
                let numbers = content.matches(of: /(?:width|height|minWidth|idealWidth|maxWidth|minHeight|idealHeight|maxHeight)\s*:\s*(\d+(?:\.\d+)?)/)
                for match in numbers { if let value = Double(match.output.1), value != 0, value != 1, value.truncatingRemainder(dividingBy: 4) != 0 {
                    found.append("\(path):\(line): \(offGridFrame): \(content.trimmingCharacters(in: .whitespaces))"); break
                } }
            }
        }
        return found
    }

    @Test func noLiteralRadiusMaterialAnimationOrRawGlassOutsideTheDesignSystem() throws {
        let files = try Self.sourceFiles()
        #expect(files.count > 100, "the sweep must inspect the real source population, not an empty one (\(files.count) files)")
        var findings: [String] = []
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            findings += Self.findings(in: text, path: file.path.replacingOccurrences(of: Self.root.path + "/", with: ""))
        }
        #expect(findings.isEmpty, Comment(rawValue: findings.joined(separator: "\n")))
    }
    /// Controls: every rule must fire on a sample, or the sweep above could pass vacuously.
    @Test func everyRuleDetectsItsOwnSample() {
        let samples: [String: String] = [
            "literal corner radius": "RoundedRectangle(cornerRadius: 8)",
            "uneven rounded rectangle": "UnevenRoundedRectangle(topLeadingRadius: 4)",
            "raw material": ".background(.regularMaterial)",
            "ad-hoc animation modifier": ".animation(.default, value: x)",
            "ad-hoc withAnimation": "withAnimation(nil) { x = 1 }",
            "ad-hoc transition": ".transition(.opacity)",
            "ad-hoc animation curve": "x.spring(duration: 0.3)",
            "raw glass effect": ".glassEffect(.regular, in: shape)",
            "raw glass button style": ".buttonStyle(.glassProminent)",
            "literal spacing or padding": "VStack(spacing: 12) { }.padding(.horizontal, 16)",
            "arithmetic on a spacing token": ".padding(MusicSpace.lg + 2)",
            "ad-hoc shadow, blur, corner or inset shape": ".shadow(radius: 7)",
            "decorative animation loop": ".phaseAnimator([0.2, 1]) { v, p in v }",
        ]
        #expect(Set(samples.keys) == Set(Self.rules.map(\.name)), "a sample exists for every rule")
        #expect(Self.findings(in: "Color.red.frame(width: 190)", path: "Sample.swift").contains { $0.contains(Self.offGridFrame) }, "an off-grid literal frame is flagged")
        #expect(Self.findings(in: "Color.red.frame(width: 192, height: 1)", path: "Sample.swift").isEmpty, "on-grid and 1 pt frames pass")
        for sample in ["RoundedRectangle(cornerSize: CGSize(width: 5, height: 5))", ".padding(EdgeInsets(top: 6, leading: 0, bottom: 0, trailing: 0))", ".padding(0.5)", ".keyframeAnimator(initialValue: 0) { v, _ in v } keyframes: { _ in }", "TimelineView(.animation) { _ in }"] {
            #expect(!Self.findings(in: sample, path: "Sample.swift").isEmpty, "bypass \(sample) is flagged")
        }
        #expect(Self.findings(in: "WebMusicTimelineView(player: player)", path: "Sample.swift").isEmpty, "a view merely named ...TimelineView is not a TimelineView")
        for rule in Self.rules {
            let sample = samples[rule.name] ?? ""
            #expect(Self.findings(in: sample, path: "Sample.swift").contains { $0.contains(rule.name) }, "\(rule.name) must flag its sample")
        }
        #expect(Self.findings(in: "// RoundedRectangle(cornerRadius: 8) in a comment", path: "Sample.swift").isEmpty, "comments are not code")
        #expect(Self.findings(in: "let url = \"https://example.invalid\" ; MusicCorner.panel.shape", path: "Sample.swift").isEmpty, "tokens and string literals pass")
        #expect(Self.findings(in: "let derived = HKDF<SHA256>.deriveKey(inputKeyMaterial: key)", path: "Sample.swift").isEmpty, "inputKeyMaterial is not a Material")
    }
    @Test func theExemptionListIsJustifiedAndCurrent() throws {
        for exemption in Self.exemptions {
            #expect(!exemption.reason.isEmpty)
            let file = Self.root.appendingPathComponent(exemption.path)
            #expect(FileManager.default.fileExists(atPath: file.path), "\(exemption.path) still exists")
        }
    }
    /// The design system is the only place the raw APIs live, so the guard's allowance is real: the same calls do appear there.
    @Test func theDesignSystemItselfHoldsTheNativeGlassCalls() throws {
        let directory = Self.root.appendingPathComponent("Packages/NativeMusic/Sources/DesignSystem")
        let text = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).filter { $0.pathExtension == "swift" }
            .map { try String(contentsOf: $0, encoding: .utf8) }.joined()
        for needle in [".glassEffect(", "GlassEffectContainer(", ".glassEffectID(", ".buttonStyle(.glass", "cornerRadius:"] { #expect(text.contains(needle), "\(needle)") }
    }
    /// UI-test share stand-in (V02 rework 1): the system `ShareLink` must exist in exactly one place, behind the stand-in seam, so an isolated Debug run
    /// never reaches the system sharing machinery (and its Contacts lookups).
    @Test func shareLinkAppearsOnlyBehindTheIsolationStandIn() throws {
        var sites: [(file: String, window: String)] = []
        for file in try Self.sourceFiles() {
            let lines = try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n")
            for (index, line) in lines.enumerated() where line.contains("ShareLink(") && !line.trimmingCharacters(in: .whitespaces).hasPrefix("//") {
                sites.append((file.lastPathComponent, lines[max(0, index - 6)..<index].joined(separator: "\n")))
            }
        }
        #expect(sites.count == 1, "exactly one ShareLink in the product sources: \(sites.map(\.file))")
        #expect(sites.allSatisfy { $0.window.contains("if sharingStandIn") && $0.window.contains("} else {") }, "the ShareLink sits in the else branch of `if sharingStandIn`")
    }
}
