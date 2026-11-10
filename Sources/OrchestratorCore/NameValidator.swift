import Foundation

/// Instance name validation.
///
/// The name must be safe to use on the file system: no path separators, `..`
/// or spaces; uppercase letters and Unicode are not allowed.
public enum NameValidator {
    /// `[a-z0-9][a-z0-9-]{0,31}` — 1-32 characters: lowercase letters, digits, hyphens.
    public static let pattern = "^[a-z0-9][a-z0-9-]{0,31}\\z"

    /// Throws `OrchestratorError.invalidName` if the name is invalid.
    public static func validate(_ name: String) throws {
        guard name.range(of: pattern, options: .regularExpression) != nil else {
            throw OrchestratorError.invalidName(
                "invalid instance name '\(name)': use lowercase letters, digits and hyphens only, 1-32 characters"
            )
        }
    }

    /// Is the name valid?
    public static func isValid(_ name: String) -> Bool {
        name.range(of: pattern, options: .regularExpression) != nil
    }
}
