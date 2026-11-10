import Foundation

/// Command-line argument parser.
///
/// Supported forms: `--flag`, `--flag value`, `--flag=value`, `-k value`.
/// Unknown flags are an error (never silently ignored).
public struct Arguments {
    /// Long names for the short flags.
    public static let shortToLong: [String: String] = [
        "n": "lines",
        "f": "follow",
        "j": "json"
    ]

    /// Flags that take a value (they consume the next argument); all others are booleans.
    public static let valueTakingFlags: Set<String> = [
        "workdir", "folder", "target", "lines", "instance", "project", "to", "from", "as", "sessions-from", "name"
    ]

    public private(set) var positionals: [String] = []
    public private(set) var flags: [String: String] = [:]
    /// All values of repeated flags (`--folder a --folder b`).
    public private(set) var multiFlags: [String: [String]] = [:]
    public private(set) var booleans: Set<String> = []

    /// - Parameter allowed: The flag names this command accepts.
    public init(_ args: [String], allowed: Set<String>) throws {
        var index = 0
        while index < args.count {
            let arg = args[index]

            if arg.hasPrefix("--") {
                let body = String(arg.dropFirst(2))
                var name = body
                var inlineValue: String?
                if let equals = body.firstIndex(of: "=") {
                    name = String(body[body.startIndex..<equals])
                    inlineValue = String(body[body.index(after: equals)...])
                }
                try validate(name: name, allowed: allowed)

                if let inlineValue {
                    setFlag(name, inlineValue)
                } else if Arguments.valueTakingFlags.contains(name),
                          index + 1 < args.count, !args[index + 1].hasPrefix("-") {
                    setFlag(name, args[index + 1])
                    index += 1
                } else {
                    booleans.insert(name)
                }
            } else if arg.hasPrefix("-"), arg.count > 1 {
                let short = String(arg.dropFirst())
                guard let long = Arguments.shortToLong[short] else {
                    throw OrchestratorError.usage("unknown flag: \(arg)")
                }
                try validate(name: long, allowed: allowed)

                if Arguments.valueTakingFlags.contains(long),
                   index + 1 < args.count, !args[index + 1].hasPrefix("-") {
                    setFlag(long, args[index + 1])
                    index += 1
                } else {
                    booleans.insert(long)
                }
            } else {
                positionals.append(arg)
            }
            index += 1
        }
    }

    private mutating func setFlag(_ name: String, _ value: String) {
        flags[name] = value
        multiFlags[name, default: []].append(value)
    }

    /// All values given for the flag, in order.
    public func values(_ name: String) -> [String] {
        multiFlags[name] ?? []
    }

    private func validate(name: String, allowed: Set<String>) throws {
        guard allowed.contains(name) else {
            throw OrchestratorError.usage("unknown flag: --\(name)")
        }
    }

    /// Required positional argument.
    public func requirePositional(_ index: Int, name: String, command: String) throws -> String {
        guard index < positionals.count else {
            throw OrchestratorError.usage("\(command): \(name) is required")
        }
        return positionals[index]
    }

    /// Required flag value.
    public func requireFlag(_ name: String, command: String) throws -> String {
        guard let value = flags[name] else {
            throw OrchestratorError.usage("\(command): --\(name) is required")
        }
        return value
    }

    /// Optional flag value.
    public func optionalFlag(_ name: String) -> String? {
        flags[name]
    }

    /// Is the flag present?
    public func has(_ name: String) -> Bool {
        booleans.contains(name) || flags[name] != nil
    }
}
