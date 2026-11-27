import Foundation
import Security

/// Code signature checks in this process. Where root acts on the result, root repeats the check with
/// `codesign` on a copy only it can change (see `Updater.rootInstallCommand`). The same as in Maben Awake.
enum CodeSignature {
    /// `(identifier "a" or identifier "b")` for a code requirement. An ID with anything but letters, digits,
    /// dots and hyphens is left out, so an ID can never change what the rest of the requirement says.
    static func identifiers(_ ids: [String]) -> String {
        let safe = ids.filter { !$0.isEmpty && $0.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "." || $0 == "-") } }
        return "(" + safe.map { "identifier \"\($0)\"" }.joined(separator: " or ") + ")"
    }

    /// Whether the app on disk at `app` has a valid signature that satisfies `requirement`: every
    /// architecture, strictly, nested code included.
    static func satisfies(_ app: URL, _ requirement: String) -> Bool {
        var code: SecStaticCode?
        var parsed: SecRequirement?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code,
              SecRequirementCreateWithString(requirement as CFString, [], &parsed) == errSecSuccess, let parsed else { return false }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
        return SecStaticCodeCheckValidity(code, flags, parsed) == errSecSuccess
    }
}
