import Foundation
import Testing

/// TH1 / AB1 (real-data safety): no test target, script or source reaches the account holder's Contacts (AddressBook) store.
///
/// What happened: every whole-package `swift test` printed `CoreData: error: ... AddressBook-v22.abcddb ... com.apple.contactsd.persistence`. No test
/// calls Contacts. The cause (found with lldb, by stack, never by opening the store) is `xctest` itself: given XCTest names from more than one test bundle
/// in one run, it resolves them through `+[XCTestCase allSubclasses]` -> `objc_copyClassList` -> `realizeAllClasses()`, which initialises every Objective-C
/// class of every loaded image. ContactsUICore's is loaded through QuickLookUI -> ScreenTimeUI -> ContactsUI (a chain AVKit/AppKit pull in), and its
/// `+[CNContactStore initialize]` connects to contactsd for the AddressBook store. So the fix is in how `scripts/test.sh` invokes the runner
/// (`counted_whole_package`: one module with XCTest tests per run), and the guards are:
///   1. no file in the repository names a Contacts API or the AddressBook store (this sweep);
///   2. `scripts/test.sh` never makes the unfiltered whole-package call again, and every counted run fails if its own output shows the store.
enum ContactsGuard {
    /// Built from pieces so that this file does not itself contain a name it forbids.
    private static func p(_ parts: String...) -> String { parts.joined() }
    static let rules: [(name: String, pattern: String)] = [
        ("Contacts API", p("\\bCN", "Contact(Store|Fetch|Request|Formatter|Picker)?\\b|\\bCN", "(Postal|Phone|Labeled|Mutable)\\w*")),
        ("Contacts import", p("\\bimport\\s+Con", "tacts(UI)?\\b|#import\\s*<Con", "tacts")),
        ("AddressBook API", p("\\bAB", "AddressBook\\w*|\\bAB", "(Person|Record|MultiValue)\\w*|\\bimport\\s+Address", "Book\\b|<Address", "Book/")),
        ("AddressBook store", p("Address", "Book-v\\d+|\\.abc", "ddb|Application Support/Address", "Book")),
        ("Contacts daemon", p("com\\.apple\\.con", "tactsd|\\bcon", "tactsd\\b")),
        ("INPerson", p("\\bINP", "erson\\w*")),
    ]
    static let directories = ["Packages/NativeMusic/Sources", "Packages/NativeMusic/Tests", "Tests", "App", "Extensions", "Tools", "scripts"]
    static let extensions: Set<String> = ["swift", "m", "mm", "h", "py", "sh", "bash", "zsh", "js", "rb", "pl", "applescript", "plist", "json", "yml", "yaml"]
    /// The files that name the store because they ARE the guard: this file, and test.sh, whose output check greps for the store's name.
    static let exempt: Set<String> = ["Packages/NativeMusic/Tests/PlaybackTests/Integration/ContactsStoreGuardTests.swift", "scripts/test.sh"]

    static func findings(inText text: String, path: String) -> [String] {
        guard !exempt.contains(path) else { return [] }
        return rules.filter { text.range(of: $0.pattern, options: .regularExpression) != nil }.map { "\(path): \($0.name)" }
    }
    static func scan(root: URL) -> (findings: [String], files: Int) {
        var found: [String] = [], count = 0
        let base = root.resolvingSymlinksInPath().path
        for directory in directories {
            guard let walker = FileManager.default.enumerator(at: root.appendingPathComponent(directory), includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]) else { continue }
            for case let url as URL in walker {
                if [".build", ".git", "DerivedData", ".swiftpm"].contains(url.lastPathComponent) { walker.skipDescendants(); continue }
                guard extensions.contains(url.pathExtension), (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true,
                      (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0 <= 2_000_000, let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
                count += 1
                found += findings(inText: text, path: url.resolvingSymlinksInPath().path.replacingOccurrences(of: base + "/", with: ""))
            }
        }
        return (found, count)
    }
}

@Suite struct ContactsStoreGuardTests {
    @Test func nothingInTheRepositoryNamesAContactsApiOrTheAddressBookStore() async {
        let (found, count) = await LifecycleSources.offMain { ContactsGuard.scan(root: LifecycleSources.repositoryRoot) }
        #expect(count > 400, "the sweep read the repository (\(count) files)")
        #expect(found.isEmpty, "\(found)")
    }

    /// The runner is the only thing that ever reached the store, so its invocation is pinned: the unfiltered whole-package call must not return, and the
    /// output check must stay in the counted helper.
    @Test func theTestRunnerNeverMakesTheUnfilteredWholePackageCallAndChecksEveryRunsOutput() throws {
        let script = try IntegrationSources.text("scripts/test.sh")
        let lines = script.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.hasPrefix("#") }
        #expect(!lines.contains { $0 == "counted_swift_test ''" || $0 == "counted_swift_test \"\"" || $0 == "counted_swift_test" },
                "an unfiltered whole-package run makes xctest realize every class in the process")
        #expect(lines.filter { $0 == "counted_whole_package" }.count == 2, "the T50 run and the full run both use the per-module helper")
        #expect(script.contains("CONTACTS GUARD") && script.contains("AddressBook-v[0-9]+\\.abcddb|com\\.apple\\.contactsd"), "every counted run fails if its output shows the store")
        let helper = try #require(script.range(of: "counted_whole_package() {").map { String(script[$0.lowerBound...].prefix(900)) })
        #expect(helper.contains("xcmodules") && helper.contains("counted_swift_test \"^$m"), "one module with XCTest tests per run")
    }

    @Test func theRulesFlagEachFormAndPassHarmlessText() {
        let flagged = [
            "let s = CN" + "ContactStore()", "import Con" + "tacts", "import Con" + "tactsUI", "#import <Con" + "tacts/Con" + "tacts.h>", "ABAddress" + "BookCreate(nil, nil)",
            "import Address" + "Book", "~/Library/Application Support/Address" + "Book/", "Address" + "Book-v22.abc" + "ddb", "com.apple.con" + "tactsd.persistence", "let p: INP" + "erson",
        ]
        for text in flagged { #expect(!ContactsGuard.findings(inText: text, path: "Tests/X.swift").isEmpty, Comment(rawValue: text)) }
        for text in ["let contactInfo = \"support contact page\"", "// the person who contacted us", "func addressLine() -> String { \"\" }", "let book = Library()", "print(\"contacts\")"] {
            #expect(ContactsGuard.findings(inText: text, path: "Tests/X.swift").isEmpty, Comment(rawValue: text))
        }
        #expect(ContactsGuard.findings(inText: flagged[0], path: "scripts/test.sh").isEmpty, "only the guard's own two files may name the store")
    }
}
