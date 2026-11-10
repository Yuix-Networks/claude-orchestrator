import Foundation

/// Exit codes.
public enum ExitCode {
    public static let success: Int32 = 0
    public static let runtime: Int32 = 1
    public static let usage: Int32 = 2
}

/// Console output and error handling.
enum Output {
    static func error(_ message: String, code: Int32) -> Never {
        FileHandle.standardError.write(Data("error: \(message)\n".utf8))
        exit(code)
    }

    static func line(_ text: String) {
        print(text)
    }

    /// Schema version of the JSON output. Bumped on breaking changes such as
    /// removing or renaming a field; adding a new field does not require a bump.
    static let schemaVersion = 1

    /// Prints the object as JSON; every output gets a `schemaVersion` field.
    static func json(_ value: [String: Any]) {
        var value = value
        if value["schemaVersion"] == nil { value["schemaVersion"] = schemaVersion }
        guard let data = try? JSONSerialization.data(
            withJSONObject: value,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        ), let text = String(data: data, encoding: .utf8) else { return }
        print(text)
    }
}

/// Interactive confirmation.
enum Confirm {
    /// Asks yes/no in the terminal. Without a terminal (script, pipe) consent
    /// is not assumed: the user is told that `--yes` is required.
    static func ask(_ prompt: String) -> Bool {
        guard isatty(STDIN_FILENO) != 0 else {
            Output.error("\(prompt)\nno terminal to confirm in: add --yes to continue", code: ExitCode.usage)
        }
        FileHandle.standardError.write(Data("\(prompt)\nContinue? [y/N] ".utf8))
        guard let answer = readLine()?.trimmingCharacters(in: .whitespaces).lowercased() else { return false }
        // "e"/"evet" (Turkish yes) are still accepted for existing users.
        return ["e", "evet", "y", "yes"].contains(answer)
    }
}

/// Version (kept in step with the release tag: `v<current>`).
enum AppVersion {
    static let current = "0.2.9"
}
