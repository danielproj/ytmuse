// Operator-only helper, never linked into YTMuse. Compile before review/use.
// Input: --client-id PUBLIC_ID --app-executable ABSOLUTE_PATH --secret-file PRIVATE_FILE
// Secret input is one fixed dotenv variable, never argv/env. No secret/error payload output.
import Foundation
import Security
import Darwin

enum ProvisionFailure: Error { case rejected }
func require(_ condition: Bool) throws { if !condition { throw ProvisionFailure.rejected } }
func secretBytes(_ path: String) throws -> Data {
    let fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    try require(fd >= 0); defer { close(fd) }
    var info = stat()
    try require(fstat(fd, &info) == 0 && info.st_uid == getuid() && (info.st_mode & S_IFMT) == S_IFREG && (info.st_mode & 0o777) == 0o600 && info.st_nlink == 1 && info.st_size > 0 && info.st_size <= 4096)
    var bytes = [UInt8](repeating: 0, count: 4097)
    let count = read(fd, &bytes, bytes.count)
    try require(count > 0 && count == info.st_size && count <= 4096)
    let raw = Data(bytes.prefix(count))
    try require(!raw.contains(0))
    guard let text = String(data: raw, encoding: .utf8) else { throw ProvisionFailure.rejected }
    let lines = text.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty && !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }
    try require(lines.count == 1)
    let prefix = "YTMUSE_GOOGLE_DESKTOP_CLIENT_SECRET="
    try require(lines[0].hasPrefix(prefix))
    var value = String(lines[0].dropFirst(prefix.count))
    if value.hasPrefix("\"") {
        value = try JSONDecoder().decode(String.self, from: Data(value.utf8))
    } else if value.hasPrefix("'") {
        try require(value.hasSuffix("'") && value.count >= 2)
        value = String(value.dropFirst().dropLast())
    }
    let data = Data(value.utf8)
    try require(!data.isEmpty && !data.contains(0) && !data.contains(10) && !data.contains(13))
    return data
}
func provision(_ args: [String]) throws {
    try require(args.count == 6 && args[0] == "--client-id" && args[2] == "--app-executable" && args[4] == "--secret-file")
    let client = args[1], executable = args[3]
    let suffix = ".apps.googleusercontent.com"
    let prefix = client.hasSuffix(suffix) ? String(client.dropLast(suffix.count)) : ""
    try require(!prefix.isEmpty && client.utf8.count <= 512 && prefix.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95 })
    let app = URL(fileURLWithPath: executable).standardizedFileURL
    try require(executable.hasPrefix("/") && app.path == executable && app.lastPathComponent == "YTMuse" && app.deletingLastPathComponent().lastPathComponent == "MacOS")
    var code: SecStaticCode?
    try require(SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess)
    try require(SecStaticCodeCheckValidity(code!, [], nil) == errSecSuccess)
    let secret = try secretBytes(args[5])
    var target: SecTrustedApplication?
    try require(SecTrustedApplicationCreateFromPath(executable, &target) == errSecSuccess)
    var access: SecAccess?
    // Explicit target only. Never trust the interpreter, this helper or all apps.
    try require(SecAccessCreate("YTMuse Google OAuth configuration" as CFString, [target!] as CFArray, &access) == errSecSuccess)
    var keychain: SecKeychain?
    let login = NSHomeDirectory() + "/Library/Keychains/login.keychain-db"
    try require(SecKeychainOpen(login, &keychain) == errSecSuccess)
    let service = "local.native-music.development.sessions.oauth-config"
    let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service, kSecAttrAccount as String: client,
        kSecMatchSearchList as String: [keychain!], kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail]
    let changes: [String: Any] = [kSecValueData as String: secret, kSecAttrAccess as String: access!]
    let status = SecItemUpdate(query as CFDictionary, changes as CFDictionary)
    if status == errSecItemNotFound {
        var add = query; add.removeValue(forKey: kSecMatchSearchList as String)
        add[kSecUseKeychain as String] = keychain!; add[kSecAttrSynchronizable as String] = false
        changes.forEach { add[$0.key] = $0.value }
        try require(SecItemAdd(add as CFDictionary, nil) == errSecSuccess)
    } else { try require(status == errSecSuccess) }
}
// Only this entrypoint writes Keychain. Never print arbitrary Error/args/data.
if CommandLine.arguments.dropFirst().first == "--validate-private-input" {
    do { try require(CommandLine.arguments.count == 3); _ = try secretBytes(CommandLine.arguments[2]); print("Private input accepted.") }
    catch { fputs("Private input rejected.\n", stderr); exit(1) }
} else {
    do { try provision(Array(CommandLine.arguments.dropFirst())); print("Exact app-owned record provisioned.") }
    catch { fputs("Provisioning failed; no sensitive details are emitted. Review input, app signature and exact-record access.\n", stderr); exit(1) }
}
