import Testing
import Foundation
import SwiftUI
import Domain
import DesignSystem

// W28: the raw traces the report cites. They are always computed (and checked); they are written only when W28_TRACE_DIR names a directory, so a normal
// run writes nothing outside the build folder.

@Suite struct TraceExportTests {
  private func write(_ text: String, _ name: String) throws {
    guard let directory = ProcessInfo.processInfo.environment["W28_TRACE_DIR"] else { return }
    let url = URL(fileURLWithPath: directory, isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    try text.write(to: url.appendingPathComponent(name), atomically: true, encoding: .utf8)
  }
  @Test func contrastTrace() throws {
    var rows: [String] = ["scheme,mode,role,palette,ratio,required,passes"]
    var worst: [String: Double] = [:]
    for scheme in [ColorScheme.light, .dark] { for mode in ContrastMode.allCases {
      for sample in ContrastAudit.samples(scheme: scheme, mode: mode) {
        rows.append("\(scheme),\(mode.rawValue),\(sample.role),\(sample.palette.map(String.init) ?? "-"),\(String(format: "%.3f", sample.ratio)),\(sample.requirement.rawValue),\(sample.passes)")
        let key = "\(sample.role) | \(scheme) | \(mode.rawValue)"
        worst[key] = min(worst[key] ?? .infinity, sample.ratio)
      }
    } }
    #expect(rows.count == 8 * (9 + 2 * ContrastAudit.albumPalettes.count) + 1, "two appearances x four modes x (nine fixed roles + two per palette), plus the header: \(rows.count)")
    #expect(worst.values.allSatisfy { $0 >= 3.0 })
    let summary = worst.sorted { $0.key < $1.key }.map { "\($0.key): worst \(String(format: "%.2f", $0.value)):1" }.joined(separator: "\n")
    try write(rows.joined(separator: "\n") + "\n", "contrast-samples.csv")
    try write(summary + "\n", "contrast-worst-by-role.txt")
  }
  @Test func pseudolocalizationTrace() throws {
    let core = try CatalogCoverageTests.core()
    var lines: [String] = []
    for item in core.simple.prefix(63) {
      lines.append("\(item.id)\t\(item.text)\n  accented: \(Pseudolocalizer.apply(item.text, style: .accented))\n  long:     \(Pseudolocalizer.apply(item.text, style: .long))\n  rtl:      \(Pseudolocalizer.apply(item.text, style: .rightToLeft))")
    }
    #expect(lines.count == 63)
    try write(lines.joined(separator: "\n") + "\n", "pseudolocalization.txt")
  }
  @Test func mixedScriptTrace() throws {
    let names = ["Beyoncé", "Sigur Rós", "الشيخ إمام", "שלמה ארצי", "宇多田ヒカル", "Ελευθερία Αρβανιτάκη", "Наталья Ветлицкая", "მზე თუნე", "Աիդա Ջասմենյան", "Þórunn Antonía", "Ñengo Flow"]
    var lines: [String] = []
    for locale in ["en", "de", "ru", "ka", "hy", "tr", "ga", "pl"] {
      let strings = try CatalogCoverageTests.catalog()
      let template = CatalogCoverageTests.value(CatalogCoverageTests.localizations(strings["Now playing “%@” by %@."]!)[locale]) ?? "Now playing “%@” by %@."
      for name in names { let out = String(format: template, name, name); #expect(out.contains(name)); lines.append("\(locale)\t\(out)") }
    }
    let sorted = NaturalOrder.sorted(names, locale: Locale(identifier: "en"))
    lines.append("sorted(en): " + sorted.joined(separator: " | "))
    #expect(Set(sorted) == Set(names))
    try write(lines.joined(separator: "\n") + "\n", "mixed-scripts.txt")
  }
  @Test func localeAndCatalogTrace() throws {
    let manifest = try Repo.json("Resources/LocalizationManifest.json")
    let locales = manifest["locales"] as! [String: [String: Any]]
    var lines = ["locale,kind,complete,translatedKeys,coverage,review,pluralCategories"]
    for id in AppLocales.allIdentifiers {
      let entry = locales[id]!
      lines.append("\(id),\(entry["kind"] ?? ""),\(entry["complete"] ?? ""),\(entry["translatedKeys"] ?? ""),\(entry["coverage"] ?? ""),\(entry["review"] ?? ""),\((entry["plural_categories"] as? [String] ?? []).joined(separator: "+"))")
    }
    #expect(lines.count == 54)
    try write(lines.joined(separator: "\n") + "\n", "locale-coverage.csv")
  }
}
