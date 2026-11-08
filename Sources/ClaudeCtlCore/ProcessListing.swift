import Foundation

/// Çalışan süreçlerin listesi. Testlerde sahte (fake) uygulanabilir.
public protocol ProcessListing {
    func processes() -> [(pid: Int32, command: String)]
}

/// `/bin/ps` üzerinden süreç listesi.
public struct PsProcessListing: ProcessListing {
    public init() {}

    public func processes() -> [(pid: Int32, command: String)] {
        guard let output = run("/bin/ps", ["-axo", "pid=,command="]) else { return [] }

        return output
            .split(separator: "\n")
            .compactMap { line -> (pid: Int32, command: String)? in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard let space = trimmed.firstIndex(of: " ") else { return nil }
                guard let pid = Int32(trimmed[trimmed.startIndex..<space].trimmingCharacters(in: .whitespaces)) else {
                    return nil
                }
                let command = String(trimmed[trimmed.index(after: space)...]).trimmingCharacters(in: .whitespaces)
                return (pid, command)
            }
    }

    private func run(_ executable: String, _ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }
}
