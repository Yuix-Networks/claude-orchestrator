import ClaudeCtlCore
import Foundation

/// Basit komut satırı argüman ayrıştırıcı.
///
/// `--workdir /path` ve `--workdir=/path` biçimlerini destekler; değer almayan
/// bayraklar (`--json`) için değer `true` olur.
struct Arguments {
    private(set) var positionals: [String] = []
    private(set) var flags: [String: String] = [:]
    private(set) var booleans: Set<String> = []

    init(_ args: [String]) {
        var index = 0
        while index < args.count {
            let arg = args[index]
            if arg.hasPrefix("--") {
                let name = String(arg.dropFirst(2))
                if let equals = name.firstIndex(of: "=") {
                    flags[String(name[name.startIndex..<equals])] = String(name[name.index(after: equals)...])
                } else if index + 1 < args.count && !args[index + 1].hasPrefix("--") {
                    flags[name] = args[index + 1]
                    index += 1
                } else {
                    booleans.insert(name)
                }
            } else {
                positionals.append(arg)
            }
            index += 1
        }
    }

    /// Zorunlu konumsal argüman.
    func requirePositional(_ index: Int, name: String, command: String) throws -> String {
        guard index < positionals.count else {
            throw ClaudeCtlError.usage("\(command): \(name) zorunlu")
        }
        return positionals[index]
    }

    /// Zorunlu bayrak değeri.
    func requireFlag(_ name: String, command: String) throws -> String {
        guard let value = flags[name] else {
            throw ClaudeCtlError.usage("\(command): --\(name) zorunlu")
        }
        return value
    }

    /// İsteğe bağlı bayrak değeri.
    func optionalFlag(_ name: String) -> String? {
        flags[name]
    }

    /// Bayrak var mı?
    func has(_ name: String) -> Bool {
        booleans.contains(name) || flags[name] != nil
    }
}
