import ClaudeCtlAgent
import ClaudeCtlCore
import Foundation

let rawArguments = Array(CommandLine.arguments.dropFirst())

do {
    guard let command = rawArguments.first else {
        Output.error("komut gerekli: new, start, stop", code: ExitCode.usage)
    }

    let rest = Array(rawArguments.dropFirst())

    switch command {
    case "new":
        try NewCommand.run(rest)
    case "start":
        try StartCommand.run(rest)
    case "stop":
        try StopCommand.run(rest)
    case "list":
        try ListCommand.run(rest)
    case "status":
        try StatusCommand.run(rest)
    case "logs":
        try LogsCommand.run(rest)
    case "open":
        try OpenCommand.run(rest)
    case "signin":
        try SigninCommand.run(rest)
    case "doctor":
        try DoctorCommand.run(rest)
    case "remove":
        try RemoveCommand.run(rest)
    case "agent":
        try AgentCommand.run(rest)
    default:
        Output.error("bilinmeyen komut: \(command)", code: ExitCode.usage)
    }
} catch let error as ClaudeCtlError {
    switch error {
    case let .usage(message), let .invalidName(message):
        // Kullanıcı hatalı argüman verdi — kullanım hatası (exit 2).
        Output.error(message, code: ExitCode.usage)
    default:
        Output.error(error.description, code: ExitCode.runtime)
    }
} catch {
    Output.error(error.localizedDescription, code: ExitCode.runtime)
}
