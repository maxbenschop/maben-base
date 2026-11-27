import Foundation

/// Text that goes into AppleScript source.
enum AppleScript {
    /// `s` as an AppleScript string, quotes included. Anything in a script that isn't written out in this
    /// app's own source goes through here, so it can never end the string and continue as script.
    static func string(_ s: String) -> String {
        var out = "\""
        for c in s.unicodeScalars {
            switch c {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default: out.unicodeScalars.append(c)
            }
        }
        return out + "\""
    }
}

/// Shell commands that run as root after a password prompt (`do shell script … with administrator
/// privileges`). The same as in Maben Awake.
enum AdminShell {
    enum Outcome { case done, cancelled, failed }

    /// `s` as one word for `/bin/sh`.
    static func quote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// The AppleScript that runs `command` as root.
    static func source(_ command: String, prompt: String? = nil) -> String {
        "do shell script " + AppleScript.string(command)
            + (prompt.map { " with prompt " + AppleScript.string($0) } ?? "")
            + " with administrator privileges"
    }

    /// Runs `command` as root in a separate `osascript` process and waits for it. Not for the main thread.
    static func runAndWait(_ command: String, prompt: String) -> Outcome {
        let p = Process(), errors = Pipe()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", source(command, prompt: prompt)]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = errors
        do { try p.run() } catch { return .failed }
        p.waitUntilExit()
        if p.terminationStatus == 0 { return .done }
        // osascript always says why it failed; -128 is Cancel in the password dialog.
        let message = String(decoding: errors.fileHandleForReading.availableData, as: UTF8.self)
        return message.contains("(-128)") ? .cancelled : .failed
    }
}
