import AppKit
import BaseCore
import LocalAuthentication

extension Workspace {
    /// The one gate in front of everything the user runs, following the connection's safe mode.
    /// `alreadyConfirmed`: the caller has asked "are you sure?" itself, so only read-only and Touch ID still apply.
    func allow(_ sql: String, write: Bool, alreadyConfirmed: Bool = false) async -> Bool {
        let name = config.displayName
        let env = config.environment == .local ? "" : " (\(config.environment.title.lowercased()))"
        switch config.safeMode {
        case .off:
            return true
        case .readOnly:
            guard write else { return true }
            showError(DatabaseError("\(name) is read-only.", detail: "Change its safe mode in the connection's settings to run statements that change data."),
                      in: window, title: "Not run")
            return false
        case .confirmWrites:
            guard write, !alreadyConfirmed else { return true }
            return await confirm("Run this on \(name)\(env)?", detail: "It changes data or structure:\n\n" + String(sql.prefix(700)),
                                 button: "Run", window: window)
        case .confirmAll:
            guard !alreadyConfirmed else { return true }
            return await confirm("Run this on \(name)\(env)?", detail: String(sql.prefix(700)), button: "Run", destructive: write, window: window)
        case .authenticate:
            guard write else { return true }
            return await Self.authenticate(reason: "run statements that change data on \(name)")
        }
    }

    /// Touch ID, or the Mac's password when there's no Touch ID.
    static func authenticate(reason: String) async -> Bool {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else { return false }
        return (try? await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)) ?? false
    }
}
