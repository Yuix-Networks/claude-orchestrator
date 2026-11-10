import OrchestratorAgent
import OrchestratorCore
import Foundation

let rawArguments = Array(CommandLine.arguments.dropFirst())

let usage = """
claude-orchestrator — manage Claude Desktop instances and their sessions

USAGE
  claude-orchestrator <command> [arguments]

COMMANDS
  (no arguments)                 Interactive home screen: profiles, start/stop,
                                 sign in, move sessions, new profile
  version                        Print the version
  new <name> [--workdir <path>] [--sessions-from <instance>]
                                 Create an instance (optional: workdir, sessions)
  start <name> [--folder <path>] Start an instance (own profile + config)
  stop <name>                    Stop an instance
  list [--json]                  Status of all instances
  status <name> [--json]         Details of one instance
  logs <name> [-n N] [-f]        Log lines (-f: follow)
  open <name> [--target workdir|profile]
  signin <name> [--restart] [--exclusive]
                                 Sign-in guide; --exclusive closes the others while you sign in
  doctor [<name>] [--json]       Health checks
  remove|delete|rm <name> [--purge [--permanent]] [--force] [--yes]
                                 Delete a profile (--purge: data goes to the Trash,
                                 --permanent: delete for good; --force: stop it if running)
  clone <name> --as <new-name> [--workdir <path>]
                                 Clone an instance with its profile and sessions
  project add <path> [--name <name>] [--folder <extra-path>]... [--replace]
  project list | remove <name> [--keep] | sync [--instance <name>]
  project import --from <instance|default>
  project apply [<file>] [--prune] [--dry-run]
                                 Apply projects.json (default
                                 ~/.config/claude-orchestrator/projects.json)
  project export [<file>] [--force]
                                 Write the registered projects as projects.json
                                 Same projects in every instance ("environment" in Desktop);
                                 alias: env
  memory status | link [--instance <name>] [--force] | unlink
                                 Share ~/.claude/CLAUDE.md with every instance
  session list [--instance <name>] [--project <path>] [--running] [--json]
  session show <id> [--instance <name>] [--json]
  session copy|move <id> --to <instance> [--instance <source>] [--force]
  session move                   Interactive: find/pick a session, pick the target account, confirm
                                 (source and target are closed and reopened in turn)
  session last --from <instance> --to <instance> [--copy] [--force]
                                 Move Claude Code sessions between instances
                                 ('default' = the Claude install outside any instance)
  agent [--install|--uninstall]  Menu bar icons

DATA LOCATION
  ~/Library/Application Support/claude-ctl/

More: https://github.com/Yuix-Networks/claude-orchestrator
"""

do {
    guard let command = rawArguments.first else {
        // No arguments + a terminal: interactive home screen.
        if isatty(STDIN_FILENO) != 0 {
            try HomeInteractive.run()
            exit(ExitCode.success)
        }
        Output.error("a command is required (help: claude-orchestrator help)", code: ExitCode.usage)
    }

    if command == "version" || command == "--version" || command == "-v" {
        print("claude-orchestrator \(AppVersion.current)")
        exit(ExitCode.success)
    }

    if command == "help" || command == "--help" || command == "-h" {
        print(usage)
        exit(ExitCode.success)
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
    case "remove", "delete", "rm":
        try RemoveCommand.run(rest, command: command)
    case "agent":
        try AgentCommand.run(rest)
    case "clone":
        try CloneCommand.run(rest)
    case "session":
        try SessionCommand.run(rest)
    case "project", "env", "environment":
        try ProjectCommand.run(rest)
    case "memory":
        try MemoryCommand.run(rest)
    default:
        Output.error("unknown command: \(command)", code: ExitCode.usage)
    }
} catch let error as OrchestratorError {
    switch error {
    case let .usage(message), let .invalidName(message), let .notFound(message):
        // The user passed bad arguments: usage error (exit 2).
        Output.error(message, code: ExitCode.usage)
    default:
        Output.error(error.description, code: ExitCode.runtime)
    }
} catch {
    Output.error(error.localizedDescription, code: ExitCode.runtime)
}
