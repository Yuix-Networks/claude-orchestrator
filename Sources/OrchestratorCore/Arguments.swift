import Foundation

/// Komut satırı argüman ayrıştırıcı.
///
/// Desteklenen biçimler: `--flag`, `--flag değer`, `--flag=değer`, `-k değer`.
/// Bilinmeyen bayraklar hata üretir (sessizce yutulmaz).
public struct Arguments {
    /// Kısa bayrakların karşılığı.
    public static let shortToLong: [String: String] = [
        "n": "lines",
        "f": "follow",
        "j": "json"
    ]

    /// Değer alan bayraklar (sonraki argümanı tüketir); diğerleri boolean'dır.
    public static let valueTakingFlags: Set<String> = [
        "workdir", "folder", "target", "lines", "instance", "project", "to", "from", "as", "sessions-from", "name"
    ]

    public private(set) var positionals: [String] = []
    public private(set) var flags: [String: String] = [:]
    /// Tekrarlanan bayrakların tüm değerleri (`--folder a --folder b`).
    public private(set) var multiFlags: [String: [String]] = [:]
    public private(set) var booleans: Set<String> = []

    /// - Parameter allowed: Bu komutun kabul ettiği bayrak adları.
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
                    throw OrchestratorError.usage("bilinmeyen bayrak: \(arg)")
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

    /// Bayrağın verilen tüm değerleri (sırayla).
    public func values(_ name: String) -> [String] {
        multiFlags[name] ?? []
    }

    private func validate(name: String, allowed: Set<String>) throws {
        guard allowed.contains(name) else {
            throw OrchestratorError.usage("bilinmeyen bayrak: --\(name)")
        }
    }

    /// Zorunlu konumsal argüman.
    public func requirePositional(_ index: Int, name: String, command: String) throws -> String {
        guard index < positionals.count else {
            throw OrchestratorError.usage("\(command): \(name) zorunlu")
        }
        return positionals[index]
    }

    /// Zorunlu bayrak değeri.
    public func requireFlag(_ name: String, command: String) throws -> String {
        guard let value = flags[name] else {
            throw OrchestratorError.usage("\(command): --\(name) zorunlu")
        }
        return value
    }

    /// İsteğe bağlı bayrak değeri.
    public func optionalFlag(_ name: String) -> String? {
        flags[name]
    }

    /// Bayrak var mı?
    public func has(_ name: String) -> Bool {
        booleans.contains(name) || flags[name] != nil
    }
}
