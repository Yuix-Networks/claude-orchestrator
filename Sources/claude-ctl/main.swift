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
    case "agent":
        Output.error("agent modu henüz uygulanmadı", code: ExitCode.usage)
    default:
        Output.error("bilinmeyen komut: \(command)", code: ExitCode.usage)
    }
} catch let error as ClaudeCtlError {
    switch error {
    case let .usage(message):
        Output.error(message, code: ExitCode.usage)
    default:
        Output.error(error.description, code: ExitCode.runtime)
    }
} catch {
    Output.error(error.localizedDescription, code: ExitCode.runtime)
}
