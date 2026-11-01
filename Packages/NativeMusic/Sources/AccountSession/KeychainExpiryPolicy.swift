import Foundation
import Security

/// Whether this build may write "Session expired" to the stored roster when the Keychain would
/// only release a record after a prompt. Only a Release build signed with a real identity may:
/// it is the one whose signature owns the records, so "needs a prompt" there means the session is
/// really unusable. A Debug or ad-hoc/unsigned build gets the same answer for a record a different
/// signature wrote, and persisting it would lock the real account out of the build that can read it
/// (observed 2026-10-29: a stray Debug launch persisted `expired` for the real account).
public enum KeychainExpiryPolicy {
    public enum Signature: Equatable, Sendable { case unsigned, adHoc, identity }
    /// The pure decision. `isDebugBuild` is the compile configuration, not a runtime flag.
    public static func persistsPromptExpiry(isDebugBuild: Bool, signature: Signature) -> Bool {
        !isDebugBuild && signature == .identity
    }
    /// The running executable's signature, read from its own code object.
    public static func currentSignature() -> Signature {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return .unsigned }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return .unsigned }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let values = info as? [String: Any] else { return .unsigned }
        let flags = (values[kSecCodeInfoFlags as String] as? UInt32) ?? 0
        if flags & SecCodeSignatureFlags.adhoc.rawValue != 0 { return .adHoc }
        let certificates = values[kSecCodeInfoCertificates as String] as? [Any] ?? []
        return certificates.isEmpty ? .unsigned : .identity
    }
    /// This build's answer, for the composition root.
    public static var currentBuildPersistsPromptExpiry: Bool {
        #if DEBUG
        persistsPromptExpiry(isDebugBuild: true, signature: currentSignature())
        #else
        persistsPromptExpiry(isDebugBuild: false, signature: currentSignature())
        #endif
    }
}
