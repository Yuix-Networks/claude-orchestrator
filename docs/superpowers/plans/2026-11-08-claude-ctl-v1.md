# claude-ctl v1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A macOS CLI tool that runs `/Applications/Claude.app` as N independent instances at the same time, giving each instance its own profile / its own `~/.claude` / its own account / its own workdir / its own Dock tile.

**Architecture:** One Swift binary, two modes (`claude-ctl` CLI, `claude-ctl agent` menu bar). Core logic lives in the `ClaudeCtlCore` library (no AppKit, testable); agent logic in the `ClaudeCtlAgent` library. Instance isolation is done with `open -n -a /Applications/Claude.app --env CLAUDE_CONFIG_DIR=<codeDir> --args --user-data-dir=<profile>` — the original bundle is never touched.

**Tech Stack:** Swift 6.0 toolchain, SwiftPM, XCTest, Foundation + AppKit, macOS 13+ (Ventura). No third-party dependencies.

**Spec:** `docs/superpowers/specs/2026-11-08-claude-ctl-design.md`

## Global Constraints

- Minimum macOS 13 (Ventura): `open --env` only exists in Ventura and later.
- Swift tools version 6.0, **language mode v5** (`swiftLanguageMode(.v5)`) — strict concurrency errors are out of scope for this plan.
- **ABSOLUTE RULE:** never write to, delete, copy, patch or re-sign the `/Applications/Claude.app` bundle (or any file inside it).
- Instance data root: `~/Library/Application Support/claude-ctl/`.
- The launch command is built in exactly this form (argument order matters):
  `open -n -a /Applications/Claude.app --env CLAUDE_CONFIG_DIR=<codeDir> --args --user-data-dir=<profile>`
  (an extra `--folder <path>` is added inside `--args` only when given with `start --folder`).
  **`--env` always comes before `--args`** — everything after `open --args` is passed
  to the app as argv; if `--env` ends up in the wrong place, Claude sees `--env` and its value
  in its argv.
- Exit codes: `0` success, `1` runtime error, `2` usage error.
- Instance name regex: `^[a-z0-9][a-z0-9-]{0,31}$` (`..`, `/`, empty, 32+ characters are rejected).
- The Claude version is detected by reading `/Applications/Claude.app/Contents/Info.plist` → `CFBundleShortVersionString`.
- Claude logs are shared: `~/Library/Logs/Claude/main.log`, line format `YYYY-MM-DD HH:MM:SS [level] [component] message` (local time, the first 19 characters are the timestamp).
- License: MIT. Tests run with `swift test`; in CI, integration tests that depend on Claude are skipped if Claude is not installed.

## Review Focus

Input/condition classes implied by the spec but not verified by any task's tests, which would hurt users the most:

1. **Instance name path traversal / format** — `new ../x`, `new a/b`, `new ""`, `new <33 characters>` must be rejected; the existing `config.json` must not be corrupted.
2. **Corrupt `config.json`** — invalid JSON or an unexpected schema: `list`/`start` must not return an empty list, must not delete/overwrite the file, and must give a descriptive error.
3. **Workdir deleted or inaccessible** — `start` must not crash; it should warn, skip seeding, and still open the instance.
4. **Profile lock (SingletonLock)** — `start` must not crash when the same profile is already open; it should report "this profile is being used by another instance".
5. **Workdir path with spaces / Unicode** — seeding must write the right path without breaking the JSON.
6. **Claude update (version change)** — `start` must not crash; `doctor` should report the version difference.

---

## File structure

```
Package.swift
Sources/
  ClaudeCtlCore/          # core library without AppKit (all logic + tests)
    Paths.swift           # directory layout (root can be injected)
    Errors.swift          # ClaudeCtlError
    Instance.swift        # Instance, Config models
    NameValidator.swift   # instance name validation
    InstanceStore.swift   # config.json CRUD
    JSONFile.swift        # atomic JSON read/write (Codable)
    ProfileSeeder.swift   # workdir seeding (JSON merge)
    ProcessListing.swift  # /bin/ps-based process list (injectable)
    Launcher.swift        # open command generation, SingletonLock, PID lookup
    LogReader.swift       # filtering the shared log by time range
    Doctor.swift          # health checks
    ClaudeCtl.swift       # facade: new/start/stop/list/status/logs/open/signin/doctor
  Sources/ClaudeCtlAgent/ # menu bar agent (AppKit)
    AgentModel.swift      # UI-less: state + menu item generation
    StatusItemController.swift # NSStatusItem management
    LaunchAgentInstaller.swift # login item plist
  Sources/claude-ctl/     # executable (single binary)
    main.swift            # mode selection + command table
    Output.swift          # table/JSON output, exit codes
    Commands/
      NewCommand.swift  StartCommand.swift  StopCommand.swift  ListCommand.swift
      StatusCommand.swift  LogsCommand.swift  OpenCommand.swift  SigninCommand.swift
      DoctorCommand.swift  AgentCommand.swift
Tests/ClaudeCtlCoreTests/
  NameValidatorTests.swift  InstanceStoreTests.swift  ProfileSeederTests.swift
  LauncherTests.swift  LogReaderTests.swift  DoctorTests.swift
Tests/ClaudeCtlAgentTests/
  AgentModelTests.swift
Scripts/smoke.sh          # live E2E verification script
```

---

### Task 1: Project skeleton, Paths, Instance model, name validation

**Files:**
- Create: `Package.swift`
- Create: `Sources/ClaudeCtlCore/Paths.swift`
- Create: `Sources/ClaudeCtlCore/Errors.swift`
- Create: `Sources/ClaudeCtlCore/Instance.swift`
- Create: `Sources/ClaudeCtlCore/NameValidator.swift`
- Create: `Tests/ClaudeCtlCoreTests/NameValidatorTests.swift`

**Interfaces:**
- Consumes: —
- Produces:
  - `public struct Paths { public init(root: URL); public static var `default`: Paths; public var configFile: URL; public var instancesRoot: URL; public func instanceDir(_ name: String) -> URL; public func profileDir(_ name: String) -> URL; public func codeDir(_ name: String) -> URL; public func stateFile(_ name: String) -> URL }`
    — `root` = `~/Library/Application Support/claude-ctl` (tests pass a temporary directory).
  - `public enum ClaudeCtlError: Error { case usage(String); case runtime(String); case notFound(String); case invalidName(String); case corruptConfig(URL) }`
  - `public struct Instance: Codable, Equatable { public var name: String; public var workdir: String?; public var createdAt: Date; public var autoStart: Bool; public var iconBadge: String? }`
  - `public struct Config: Codable, Equatable { public var version: Int; public var instances: [String: Instance] }`
  - `public enum NameValidator { public static func validate(_ name: String) throws }` — returns `()` if valid, otherwise throws `.invalidName`.

- [ ] **Step 1: Write `Package.swift`**

  `swift-tools-version:6.0`, `platforms: [.macOS(.v13)]`, `swiftLanguageMode(.v5)`.
  Targets: `.target(name: "ClaudeCtlCore")`, `.target(name: "ClaudeCtlAgent", dependencies: ["ClaudeCtlCore"])`, `.executableTarget(name: "claude-ctl", dependencies: ["ClaudeCtlCore", "ClaudeCtlAgent"])`,
  `.testTarget(name: "ClaudeCtlCoreTests", dependencies: ["ClaudeCtlCore"])`,
  `.testTarget(name: "ClaudeCtlAgentTests", dependencies: ["ClaudeCtlAgent", "ClaudeCtlCore"])`.

- [ ] **Step 2: Write `Paths.swift` and `Errors.swift`**

  `Paths.default.root` = `URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support/claude-ctl")`.
  Subpaths: `config.json`, `instances/`, `instances/<name>/`, `.../profile`, `.../claude-code`, `.../state.json`.

- [ ] **Step 3: Write `Instance.swift` and `NameValidator.swift`**

  `Config.version` defaults to `1`. The `NameValidator.validate` regex is `^[a-z0-9][a-z0-9-]{0,31}$`; on no match, `ClaudeCtlError.invalidName("instance name '<name>' is invalid: only lowercase letters, digits and hyphens, 1-32 characters")`.

- [ ] **Step 4: Write `NameValidatorTests.swift` (failing test)**

  Tests: `"work"` is valid; `""`, `"Work"`, `"a/b"`, `"../x"`, `"a b"`, `String(repeating: "a", count: 33)` are invalid.
  The error message must include the instance name.

- [ ] **Step 5: Run the tests and watch them fail**

  Run: `swift test --filter NameValidatorTests`
  Expected: FAIL — "no such module 'ClaudeCtlCore'" or "cannot find 'NameValidator' in scope".

- [ ] **Step 6: Make the tests pass by writing the code from Steps 3-4**

- [ ] **Step 7: Run all tests**

  Run: `swift test`
  Expected: PASS (0 failures).

- [ ] **Step 8: Commit**

  ```bash
  git add Package.swift Sources/ClaudeCtlCore Tests/ClaudeCtlCoreTests
  git commit -m "feat(core): project skeleton, Paths, Instance model, name validation"
  ```

---

### Task 2: InstanceStore — config.json CRUD

**Files:**
- Create: `Sources/ClaudeCtlCore/InstanceStore.swift`
- Create: `Sources/ClaudeCtlCore/JSONFile.swift`
- Create: `Tests/ClaudeCtlCoreTests/InstanceStoreTests.swift`

**Interfaces:**
- Consumes: `Paths` (Task 1), `Instance`, `Config`, `ClaudeCtlError` (Task 1).
- Produces:
  - `public final class InstanceStore { public init(paths: Paths); public func load() throws -> Config; public func save(_ config: Config) throws; public func instance(named: String) throws -> Instance; public func upsert(_ instance: Instance) throws; public func remove(named: String) throws }`
  - `public enum JSONFile { public static func read<T: Decodable>(_ type: T.Type, from url: URL) throws -> T?; public static func write<T: Encodable>(_ value: T, to url: URL) throws }`
    — `write` is atomic: first write `url + ".tmp"`, then `FileManager.replaceItemAt`.

- [ ] **Step 1: Write `InstanceStoreTests.swift` (failing test)**

  `setUp` → `paths = Paths(root: FileManager.default.temporaryDirectory.appendingPathComponent("claude-ctl-test-\(UUID().uuidString)"))`.
  Tests:
  1. `load()` returns `Config(version: 1, instances: [:])` when the file doesn't exist, without throwing.
  2. After `upsert`, `load()` returns the instance with the same values.
  3. `instance(named: "missing")` → `.notFound` error.
  4. After `remove(named:)`, `load().instances` is empty.
  5. **Review Focus #2**: write `"{{{{ broken"` into `config.json` → `load()` throws, error `.corruptConfig(url)`; the file content must be unchanged (`assertEqual(readFile, "{{{{ broken")`).
  6. **Review Focus #1**: if `upsert` is called with an Instance with `name: "../x"`, it throws `.invalidName` and `config.json` is not written.

- [ ] **Step 2: Run the tests, watch them fail**

  Run: `swift test --filter InstanceStoreTests`
  Expected: FAIL — "cannot find 'InstanceStore' in scope".

- [ ] **Step 3: Write `JSONFile.swift`**

  `read`: `nil` if the file doesn't exist; a `JSONDecoder` error → `ClaudeCtlError.corruptConfig(url)`; a read error → `.runtime`.
  `write`: `JSONEncoder` (`outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]`), `.atomic` Data write.

- [ ] **Step 4: Write `InstanceStore.swift`**

  `load()`: `JSONFile.read(Config.self, from: paths.configFile)` → empty config if nil; errors propagate.
  `save(_:)`: create the parent directory of `paths.configFile`, `JSONFile.write`.
  `instance(named:)`: `load()` → `config.instances[name]` → if missing, `.notFound("instance '<name>' not found")`.
  `upsert(_:)`: `NameValidator.validate(instance.name)` → then `config.instances[name] = instance`, `save`.
  `remove(named:)`: `config.instances.removeValue(forKey:)` → `save`.

- [ ] **Step 5: Run the tests, watch them all pass**

  Run: `swift test --filter InstanceStoreTests`
  Expected: PASS (6 tests).

- [ ] **Step 6: Commit**

  ```bash
  git add Sources/ClaudeCtlCore/InstanceStore.swift Sources/ClaudeCtlCore/JSONFile.swift Tests/ClaudeCtlCoreTests/InstanceStoreTests.swift
  git commit -m "feat(core): config.json CRUD with InstanceStore and corrupt config protection"
  ```

---

### Task 3: ProfileSeeder — workdir seeding

**Files:**
- Create: `Sources/ClaudeCtlCore/ProfileSeeder.swift`
- Create: `Tests/ClaudeCtlCoreTests/ProfileSeederTests.swift`

**Interfaces:**
- Consumes: `Paths` (Task 1), `Instance` (Task 1), `JSONFile` (Task 2).
- Produces:
  - `public struct SeedResult: Equatable { public var trustedFolderAdded: Bool; public var presetAdded: Bool; public var accountUUID: String? }`
  - `public struct ProfileSeeder { public init(paths: Paths); public func seed(profileDir: URL, workdir: String) throws -> SeedResult }`

- [ ] **Step 1: Write `ProfileSeederTests.swift` (failing test)**

  `setUp` creates a temporary `profile` directory; `claude_desktop_config.json` and `ccd-session-presets.json` are created in the test.
  Tests:
  1. **Existing config is preserved**: with `"mcpServers": {"x": {"command": "y"}}` in `claude_desktop_config.json` and `"menuBarEnabled": false` under `preferences`, both are still in the file after seeding.
  2. **Trusted folder is added**: the workdir goes into `preferences.localAgentModeTrustedFolders`.
  3. **Idempotent**: seeding the same workdir twice gives file content **byte-for-byte identical** to seeding it once (stable because the JSON output uses sortedKeys).
  4. **Preset is added**: with `ccd-session-presets.json` = `{"byAccount":{"acct-1":{"presets":[]}}}`, after seeding `byAccount["acct-1"].presets` has a preset with `target.cwd == workdir` and `name ==` the last segment of the workdir.
  5. **No account, no preset**: `ccd-session-presets.json` is `{"byAccount":{}}` and there is no `bridge-state.json` → `seedResult.accountUUID == nil`, `presetAdded == false`.
  6. **Account is found from `bridge-state.json`**: `bridge-state.json` = `{"ws-1:acct-9": {}}` → `accountUUID == "acct-9"`.
  7. **Review Focus #5**: workdir = `"/tmp/with spaces and ü é"` → seeding succeeds, `trustedFolders` contains exactly this path, the file is valid JSON.
  8. **Error if the workdir doesn't exist**: `seed(profileDir:workdir: "/tmp/no-such-folder-\(UUID())")` → `.runtime` error (no seeding if the folder doesn't exist).

- [ ] **Step 2: Run the tests, watch them fail**

  Run: `swift test --filter ProfileSeederTests`
  Expected: FAIL — "cannot find 'ProfileSeeder' in scope".

- [ ] **Step 3: Write `ProfileSeeder.swift`**

  - `seed(profileDir:workdir:)`:
    1. `guard FileManager.default.fileExists(atPath: workdir)` else `throw .runtime("workdir not found: \(workdir)")`.
    2. `trustedFolders` merge → `profileDir/claude_desktop_config.json`:
       - if the file doesn't exist, start with `["mcpServers": [:], "preferences": [:]]`;
       - `[:]` if there is no `preferences`; `[]` if there is no `localAgentModeTrustedFolders`;
       - if the workdir is not in the list, add it, `trustedFolderAdded = true`.
    3. Find the account UUID: first the `byAccount` keys in `ccd-session-presets.json` (the first key), otherwise the part after `:` in the `bridge-state.json` keys.
    4. If there is an account, preset merge → `profileDir/ccd-session-presets.json`:
       - if `byAccount[uuid].presets` has no preset with `target.cwd == workdir`, add:
         `{"id": UUID().uuidString, "name": URL(fileURLWithPath: workdir).lastPathComponent, "createdAt": Int64(Date().timeIntervalSince1970 * 1000), "lastUsedAt": <same>, "target": {"kind": "local", "cwd": workdir}}`; `presetAdded = true`.
    5. Write both files with `JSONFile.write` (`.prettyPrinted, .sortedKeys`).

- [ ] **Step 4: Run the tests, watch them all pass**

  Run: `swift test --filter ProfileSeederTests`
  Expected: PASS (8 tests).

- [ ] **Step 5: Commit**

  ```bash
  git add Sources/ClaudeCtlCore/ProfileSeeder.swift Tests/ClaudeCtlCoreTests/ProfileSeederTests.swift
  git commit -m "feat(core): workdir seeding (trusted folders + session preset)"
  ```

---

### Task 4: Launcher — open command, PID lookup, profile lock

**Files:**
- Create: `Sources/ClaudeCtlCore/ProcessListing.swift`
- Create: `Sources/ClaudeCtlCore/Launcher.swift`
- Create: `Tests/ClaudeCtlCoreTests/LauncherTests.swift`

**Interfaces:**
- Consumes: `Paths` (Task 1), `ClaudeCtlError` (Task 1).
- Produces:
  - `public struct LaunchRequest: Equatable { public var appPath: String; public var profileDir: String; public var codeDir: String; public var extraArgs: [String] }`
  - `public protocol ProcessListing { func processes() -> [(pid: Int32, command: String)] }`
  - `public struct PsProcessListing: ProcessListing` — runs `/bin/ps -axo pid=,command=` and parses it.
  - `public final class Launcher { public init(appPath: String = "/Applications/Claude.app", processListing: ProcessListing = PsProcessListing(), fileManager: FileManager = .default); public func launchArguments(_ request: LaunchRequest) -> [String]; public func isProfileLocked(profileDir: URL) -> Bool; public func runningPid(profileDir: URL) -> Int32?; public func launch(_ request: LaunchRequest) throws }`

- [ ] **Step 1: Write `LauncherTests.swift` (failing test)**

  Tests:
  1. `launchArguments` returns exactly:
     `["open", "-n", "-a", "/Applications/Claude.app", "--args", "--user-data-dir=/p", "--env", "CLAUDE_CONFIG_DIR=/c"]`
     (when `extraArgs` is empty).
  2. With `extraArgs = ["/tmp/project"]`, the `--args` section is `--user-data-dir=/p`, `--env`, `CLAUDE_CONFIG_DIR=/c`, `/tmp/project` in that order.
  3. `isProfileLocked`: `true` if there is a `SingletonLock` file in the profile directory, otherwise `false`.
  4. `runningPid`: fake process list `[(123, "/Applications/Claude.app/Contents/MacOS/Claude --user-data-dir=/p ...")]` → returns `123`; `nil` if nothing matches.
  5. `runningPid` returns only on an **exact path** match: a search for `--user-data-dir=/p2` returns `nil` for `/p`.

- [ ] **Step 2: Run the tests, watch them fail**

  Run: `swift test --filter LauncherTests`
  Expected: FAIL — "cannot find 'Launcher' in scope".

- [ ] **Step 3: Write `ProcessListing.swift`**

  `PsProcessListing.processes()`: run `/bin/ps` with `Process` (`-axo pid=,command=`), split stdout lines into `pid` + `command` (split at the first space), pid as `Int32`.

- [ ] **Step 4: Write `Launcher.swift`**

  - `launchArguments`: the fixed order above; `--user-data-dir=<profileDir>` and `CLAUDE_CONFIG_DIR=<codeDir>` always after `--args`/`--env`, each as a **single argument** (not split on paths with spaces).
  - `isProfileLocked(profileDir:)`: does `profileDir.appendingPathComponent("SingletonLock")` exist → `true`.
  - `runningPid(profileDir:)`: the pid of the entry in `processes()` whose `command` contains `--user-data-dir=\(profileDir.path)` **and** `"/Applications/Claude.app/Contents/MacOS/Claude"`; if there are several matches, the smallest pid.
  - `launch(_:)`: run `launchArguments` with `Process` (`/usr/bin/open`), `.runtime` on failure.

- [ ] **Step 5: Run the tests, watch them all pass**

  Run: `swift test --filter LauncherTests`
  Expected: PASS (5 tests).

- [ ] **Step 6: Commit**

  ```bash
  git add Sources/ClaudeCtlCore/ProcessListing.swift Sources/ClaudeCtlCore/Launcher.swift Tests/ClaudeCtlCoreTests/LauncherTests.swift
  git commit -m "feat(core): open command, PID lookup and profile lock check with Launcher"
  ```

---

### Task 5: CLI core — new / start / stop

**Files:**
- Create: `Sources/ClaudeCtlCore/ClaudeCtl.swift` (facade; `new`, `start`, `stop` in this task)
- Create: `Sources/ClaudeCtlCore/InstanceState.swift`
- Create: `Sources/claude-ctl/Output.swift`
- Create: `Sources/claude-ctl/Commands/NewCommand.swift`
- Create: `Sources/claude-ctl/Commands/StartCommand.swift`
- Create: `Sources/claude-ctl/Commands/StopCommand.swift`
- Create: `Sources/claude-ctl/main.swift`
- Create: `Tests/ClaudeCtlCoreTests/ClaudeCtlStartTests.swift`

**Interfaces:**
- Consumes: `Paths`, `ClaudeCtlError`, `Instance`, `Config` (Task 1); `InstanceStore`, `JSONFile` (Task 2); `ProfileSeeder`, `SeedResult` (Task 3); `Launcher`, `LaunchRequest` (Task 4).
- Produces:
  - `public struct InstanceState: Codable, Equatable { public var pid: Int32; public var startedAt: Date; public var claudeVersion: String? }`
  - `public final class ClaudeCtl { public init(paths: Paths = .default, appPath: String = "/Applications/Claude.app", processListing: ProcessListing = PsProcessListing()); public func new(name: String, workdir: String?) throws -> Instance; public func start(name: String, folder: String?) throws -> StartResult; public func stop(name: String) throws -> StopResult }`
  - `public struct StartResult: Equatable { public var instance: Instance; public var pid: Int32; public var alreadyRunning: Bool; public var seed: SeedResult?; public var warning: String? }`
  - `public struct StopResult: Equatable { public var wasRunning: Bool; public var forced: Bool }`
  - `public enum ExitCode { public static let success: Int32 = 0; public static let runtime: Int32 = 1; public static let usage: Int32 = 2 }`
  - `public enum Output { public static func error(_ message: String, code: Int32) -> Never; public static func line(_ text: String); public static func json(_ value: [String: Any]) }` — `error` writes the message to stderr and calls `exit(code)`.

- [ ] **Step 1: Write `ClaudeCtlStartTests.swift` (failing test)**

  Tests (all with a temporary `paths.root`):
  1. `new(name: "work", workdir: "/tmp")` → the instance is written to the config, the `profile` and `claude-code` directories are created.
  2. `new` a second time with the same name → `.runtime` error ("already exists").
  3. `start` on a running instance gives `alreadyRunning == true` and no new process is started (fake ProcessListing, `runningPid` returns non-nil).
  4. **Review Focus #4**: `start` with a `SingletonLock` file in the profile directory → `.runtime` error, and the message contains "SingletonLock".
  5. **Review Focus #3**: `start` with `workdir` = `/tmp/missing-\(UUID())` → does **not** throw; `warning` is non-nil and contains "workdir"; `seed == nil`.
  6. `stop` stops a running pid with SIGTERM (`wasRunning == false` for a dead process).

- [ ] **Step 2: Run the tests, watch them fail**

  Run: `swift test --filter ClaudeCtlStartTests`
  Expected: FAIL — "cannot find 'ClaudeCtl' in scope".

- [ ] **Step 3: Write `InstanceState.swift` and `ClaudeCtl.swift` (new/start/stop)**

  - `new(name:workdir:)`: `NameValidator.validate` → if the name is in the config, `.runtime("instance '<name>' already exists")` → `Instance(name:workdir:createdAt: Date(), autoStart: false, iconBadge: nil)` → `store.upsert` → create the `profile` and `claude-code` directories (`withIntermediateDirectories: true`).
  - `start(name:folder:)`:
    1. `store.instance(named:)` (`.notFound` if missing).
    2. `launcher.runningPid(profileDir:)` non-nil → `StartResult(alreadyRunning: true, pid: pid)`.
    3. `launcher.isProfileLocked(profileDir:)` → `.runtime("profile locked: <path> is being used by another Claude instance")`.
    4. Workdir check: if `instance.workdir` is set and doesn't exist on disk, `warning = "workdir not found: <path> — seeding skipped"`, `seed = nil`; if it exists, `seeder.seed(...)`.
    5. `launcher.launch(LaunchRequest(appPath:appPath, profileDir:profile.path, codeDir:codeDir.path, extraArgs: folder.map { [$0] } ?? []))`.
    6. Wait for the PID: up to 10 seconds, `launcher.runningPid(profileDir:)` every 250 ms → if not found, `.runtime("could not start the instance: process not found")`.
    7. Write `state.json`: `InstanceState(pid:startedAt: Date(), claudeVersion: currentClaudeVersion())`.
  - `stop(name:)`: read `state.json` (if missing, `wasRunning == false`); if the pid is running, send `SIGTERM` (`kill(pid, SIGTERM)`), wait 5 s, `SIGKILL` if still alive (`forced = true`); delete `state.json`.
  - `currentClaudeVersion()`: `/Applications/Claude.app/Contents/Info.plist` → `PropertyListSerialization` → `CFBundleShortVersionString`; `nil` if it can't be read.

- [ ] **Step 4: Write `Output.swift` and the command files**

  `main.swift`: if `argv[1]` is "agent", go to agent mode (added in Task 7; until then an "agent mode not available yet" error + exit 2), otherwise the command table: `new`, `start`, `stop` (`list`, `status`, `logs`, `open`, `signin`, `doctor`, `agent` are added in Task 6).
  `NewCommand`: `--workdir <path>` is required; without `--workdir`, `Output.error("new: --workdir is required", .usage)`.
  `StartCommand`: `--folder <path>` optional.
  `StopCommand`: name required.
  All commands: `ClaudeCtlError.usage` and `.invalidName` → exit 2 (usage error), other errors → exit 1, error message to stderr as `error: <message>`.

- [ ] **Step 5: Run the tests, watch them all pass**

  Run: `swift test --filter ClaudeCtlStartTests`
  Expected: PASS (6 tests).

- [ ] **Step 6: Try the binary by hand**

  Run:
  ```bash
  swift build -c release
  XDG_TMP=$(mktemp -d)
  ./build/release/claude-ctl new demo --workdir "$XDG_TMP"
  ./build/release/claude-ctl start demo
  ```
  Expected: the `demo` instance starts, and a `Cookies` file is created under `~/Library/Application Support/claude-ctl/instances/demo/profile`. (Manual check; skip this step if Claude is not installed.)

- [ ] **Step 7: Commit**

  ```bash
  git add Sources/ClaudeCtlCore/ClaudeCtl.swift Sources/ClaudeCtlCore/InstanceState.swift Sources/claude-ctl
  git commit -m "feat(cli): new/start/stop commands and the ClaudeCtl facade"
  ```

---

### Task 6: CLI core — list / status / logs / open / signin / doctor

**Files:**
- Create: `Sources/ClaudeCtlCore/LogReader.swift`
- Create: `Sources/ClaudeCtlCore/Doctor.swift`
- Create: `Sources/claude-ctl/Commands/ListCommand.swift`
- Create: `Sources/claude-ctl/Commands/StatusCommand.swift`
- Create: `Sources/claude-ctl/Commands/LogsCommand.swift`
- Create: `Sources/claude-ctl/Commands/OpenCommand.swift`
- Create: `Sources/claude-ctl/Commands/SigninCommand.swift`
- Create: `Sources/claude-ctl/Commands/DoctorCommand.swift`
- Modify: `Sources/claude-ctl/main.swift` (extend the command table)
- Create: `Tests/ClaudeCtlCoreTests/LogReaderTests.swift`
- Create: `Tests/ClaudeCtlCoreTests/DoctorTests.swift`

**Interfaces:**
- Consumes: outputs of Tasks 1-5 (`ClaudeCtl`, `InstanceStore`, `Launcher`, `InstanceState`, `Output`, `ExitCode`).
- Produces:
  - `public struct LogReader { public init(logDirectory: URL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Logs/Claude")); public func lines(since: Date, pid: Int32? = nil, limit: Int = 50) -> [String] }`
  - `public struct InstanceStatus: Equatable { public var name: String; public var workdir: String?; public var isRunning: Bool; public var pid: Int32?; public var startedAt: Date?; public var profileSizeBytes: Int64; public var accountSignedIn: Bool }`
  - `public enum CheckStatus: String, Equatable { case ok, warn, fail }`
  - `public struct DoctorCheck: Equatable { public var name: String; public var status: CheckStatus; public var detail: String }`
  - `ClaudeCtl` extensions: `public func list() throws -> [InstanceStatus]`, `public func status(name: String) throws -> InstanceStatus`, `public func logs(name: String, lines: Int) throws -> [String]`, `public func open(name: String, target: OpenTarget) throws`, `public func signin(name: String) throws -> SigninPlan`, `public func doctor(name: String?) throws -> [DoctorCheck]`
  - `public enum OpenTarget { case workdir; case profile }`
  - `public struct SigninPlan: Equatable { public var instance: String; public var handlerInstance: String?; public var otherInstancesRunning: [String]; public var instructions: [String] }`

- [ ] **Step 1: Write `LogReaderTests.swift` and `DoctorTests.swift` (failing test)**

  `LogReaderTests`:
  1. If the log file doesn't exist, `lines(since:limit:)` returns an empty array (doesn't throw).
  2. Lines that start with `YYYY-MM-DD HH:MM:SS` and are older than `since` are dropped.
  3. When `pid` is given, lines that don't contain `electron_main:<pid>` are dropped.
  4. When `limit` is given, the **last** `limit` lines are returned.

  `DoctorTests`:
  5. **Review Focus #6**: if `claudeVersion` in `state.json` differs from the current version, `doctor` produces a "version changed" warning (`status == .warn`).
  6. `.fail` if the profile directory doesn't exist; `.warn` if there is a `SingletonLock` ("used by another instance").
  7. Disk: `warn` if the profile size is over 5 GB.

- [ ] **Step 2: Run the tests, watch them fail**

  Run: `swift test --filter "LogReaderTests|DoctorTests"`
  Expected: FAIL — "cannot find 'LogReader' in scope".

- [ ] **Step 3: Write `LogReader.swift`**

  Read `main.log` line by line; the first 19 characters of each line are in `yyyy-MM-dd HH:mm:ss` format → parse with `DateFormatter` ("yyyy-MM-dd HH:mm:ss", `Locale(identifier: "en_US_POSIX")`, current timezone); a line that can't be parsed is **not run through** the `since` filter (not dropped) but the pid filter still applies. Collect lines after `since` that match the pid, return the last `limit`.

- [ ] **Step 4: Write `Doctor.swift`**

  Checks (each a `DoctorCheck`):
  - `claude-app`: does `/Applications/Claude.app` exist → `fail` if not.
  - `claude-version`: compare `claudeVersion` in `state.json` with the current `CFBundleShortVersionString` → `warn` if different ("version changed: <old> → <new>"), `ok` if the same.
  - `profile-dir`: does the profile directory exist → `fail` if not.
  - `profile-lock`: is there a `SingletonLock` → `warn`.
  - `disk`: profile size → `warn` over 5 GB, `ok` below.
  - `workdir`: does instance.workdir exist on disk → `warn` if not.
  - `signin`: does the profile have a `Cookies` file → `ok` / `warn`.

- [ ] **Step 5: Extend the `ClaudeCtl` facade**

  - `list()`: for each instance `runningPid` → `isRunning`/`pid`; `state.json` → `startedAt`; profile size (`FileManager` recursive size, `Int64`); `accountSignedIn` = does the profile have a `Cookies` file. **Stale state cleanup**: if the pid is dead, `state.json` is deleted and `startedAt`/`pid` are reported as `nil`.
  - `status(name:)`: the matching instance from `list()`.
  - `logs(name:lines:)`: `LogReader.lines(...)` with `startedAt` + pid from `state.json`.
  - `open(name:target:)`: `workdir` → instead of opening via `NSWorkspace`, `/usr/bin/open <path>` with `Process`; `profile` → the profile directory.
  - `signin(name:)`: check `Cookies`/`Local Storage` in the target instance's profile; `handlerInstance`: `nil` if it can't be measured which instance the `claude://` handler goes to; `otherInstancesRunning`: names of the other running instances from `list()`; `instructions`: fixed text ("1) Close the other instances 2) The 'claude://' handler must be on the target 3) Sign in in the browser").
  - `doctor(name:)`: that instance if `name` is given, otherwise all instances (checks for each instance + app checks).

- [ ] **Step 6: Write the command files and `main.swift`**

  `list` → table (name, state, pid, workdir, size); `--json` → `[{name, isRunning, pid, workdir, startedAt, profileSizeBytes}]`.
  `status <name>` → details; `--json`.
  `logs <name> [-n N] [-f]` → print the lines; with `-f`, tail the file (print new lines as they arrive, exit with Ctrl-C).
  `open <name> [--target workdir|profile]`.
  `signin <name>` → print the `instructions` lines, numbered.
  `doctor [<name>]` → lists the checks; exit 1 if any of them is `fail`, exit 0 if all are `ok`/`warn`.

  **Added during Task 6:** `remove <name> [--purge]` — removes the instance from the config,
  `--purge` also deletes the profile folder from disk. The plan and spec had no way
  to delete an instance; Task 9's smoke script couldn't clean up, and the user had to
  edit the config by hand.

- [ ] **Step 7: Run the tests, watch them all pass**

  Run: `swift test`
  Expected: PASS (all tests).

- [ ] **Step 8: Commit**

  ```bash
  git add Sources/ClaudeCtlCore/LogReader.swift Sources/ClaudeCtlCore/Doctor.swift Sources/claude-ctl Tests/ClaudeCtlCoreTests
  git commit -m "feat(cli): list/status/logs/open/signin/doctor commands"
  ```

---

### Task 7: Menu bar agent

**Files:**
- Create: `Sources/ClaudeCtlAgent/AgentModel.swift`
- Create: `Sources/ClaudeCtlAgent/StatusItemController.swift`
- Create: `Sources/ClaudeCtlAgent/LaunchAgentInstaller.swift`
- Create: `Sources/claude-ctl/Commands/AgentCommand.swift`
- Create: `Tests/ClaudeCtlAgentTests/AgentModelTests.swift`
- Modify: `Sources/claude-ctl/main.swift` ("agent" mode)

**Interfaces:**
- Consumes: `ClaudeCtl`, `InstanceStatus`, `InstanceStore`, `Launcher`, `Paths` (Tasks 1-6).
- Produces:
  - `public enum AgentAction: Equatable { case activate; case stop; case openWorkdir; case openProfile; case showLogs; case signinHelp }`
  - `public struct AgentMenuItem: Equatable { public var title: String; public var action: AgentAction; public var isEnabled: Bool }`
  - `public final class AgentModel { public init(ctl: ClaudeCtl); public func refresh() -> [InstanceStatus]; public func menuItems(for status: InstanceStatus) -> [AgentMenuItem] }`
  - `public final class StatusItemController { public init(model: AgentModel); public func start() }` — an `NSStatusItem` per instance (icon: Claude icon + badge text).
  - `public struct LaunchAgentInstaller { public init(label: String = "com.claude-ctl.agent"); public func install(executablePath: String) throws -> URL; public func uninstall() throws }`
  - `AgentCommand`: `claude-ctl agent` → runs agent mode **in this process** (not a separate process — `main.swift` starts `StatusItemController` on the "agent" argument); `claude-ctl agent --install` → writes the LaunchAgent plist + `launchctl bootstrap`; `--uninstall` → deletes the plist + `launchctl bootout`.

- [ ] **Step 1: Write `AgentModelTests.swift` (failing test)**

  Tests:
  1. `refresh()` returns running and stopped instances with the correct `isRunning`.
  2. `menuItems(for:)` includes "Stop" and "Bring to Front" for a running instance, and does not include "Stop" for a stopped instance (`isEnabled == false`).
  3. The menu always has "Open Workdir", "Logs", "Sign-in Help".

- [ ] **Step 2: Run the tests, watch them fail**

  Run: `swift test --filter AgentModelTests`
  Expected: FAIL — "cannot find 'AgentModel' in scope".

- [ ] **Step 3: Write `AgentModel.swift`**

  `refresh()` → `ctl.list()`. `menuItems(for:)` → order: "Bring to Front" (enabled if running), "Stop" (enabled if running), "Open Workdir", "Open Profile Folder", "Logs", "Sign-in Help".

- [ ] **Step 4: Write `StatusItemController.swift`**

  Singleton: the `paths.state/agent.pid` file; if the file exists and the pid in it is alive, this agent is a second copy → `start()` exits immediately ("agent is already running"); if the pid is dead, the file is deleted and a new one is written.
  `start()`: `AgentModel.refresh()` → an `NSStatusItem` per instance; `button.image` = Claude icon (`/Applications/Claude.app/Contents/Resources/electron.icns` read into an `NSImage`) + `button.title` = badge (last 2 characters of the instance name); `button.menu` = `NSMenu` (menuItems → `NSMenuItem`, bound to `AgentAction` via `target/action`).
  actions: `activate` → `NSRunningApplication(processIdentifier: pid)?.activate(options: [.activateAllWindows])`; `stop` → `ctl.stop(name:)`; `openWorkdir`/`openProfile` → `ctl.open(...)`; `showLogs` → write the `ctl.logs(...)` output to a window (a simple `NSWindow` with an `NSTextView`) or `open -a Terminal <log file>`; `signinHelp` → write the `ctl.signin(name:)` output to the same window.
  A `Timer` calls `refresh()` every 5 s and the menus are refreshed (config changes are picked up by this polling).

- [ ] **Step 5: Write `LaunchAgentInstaller.swift`**

  `install(executablePath:)`: write `~/Library/LaunchAgents/com.claude-ctl.agent.plist`:
  ```xml
  <key>ProgramArguments</key><array><string>/usr/local/bin/claude-ctl</string><string>agent</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ProcessType</key><string>Interactive</string>
  ```
  then `launchctl bootstrap gui/$UID <plist>` (if it fails, a warning is printed, exit 1).
  `uninstall()`: `launchctl bootout gui/$UID/com.claude-ctl.agent` + delete the plist.

- [ ] **Step 6: Write `AgentCommand.swift` and `main.swift`**

  `main.swift`: `argv[1] == "agent"` → without `--install`/`--uninstall`, `StatusItemController(model:).start()` + `NSApplication.shared.run()`; `--install`/`--uninstall` → call `LaunchAgentInstaller` and exit.

- [ ] **Step 7: Run the tests, watch them all pass**

  Run: `swift test`
  Expected: PASS (all tests).

- [ ] **Step 8: Manual check**

  Run:
  ```bash
  swift build -c release
  ./build/release/claude-ctl agent &
  ```
  Expected: one icon per instance appears in the menu bar; clicking an icon opens its menu.

- [ ] **Step 9: Commit**

  ```bash
  git add Sources/ClaudeCtlAgent Sources/claude-ctl/Commands/AgentCommand.swift Sources/claude-ctl/main.swift Tests/ClaudeCtlAgentTests
  git commit -m "feat(agent): menu bar icons and LaunchAgent install"
  ```

---

### Task 8: Distribution — README, LICENSE, Homebrew tap, release workflow

**Files:**
- Create: `README.md`
- Create: `LICENSE` (MIT, 2026 Serdar)
- Create: `Formula/claude-ctl.rb`
- Create: `.github/workflows/release.yml`

**Interfaces:**
- Consumes: outputs of Tasks 1-7 (the compiled `claude-ctl` binary).
- Produces: distribution artifacts — no new interface (type).

- [ ] **Step 1: Write `README.md`**

  Sections: what it does (2-3 sentences, "multiple instances of Claude Desktop"), quick start
  (`brew install --formula ./Formula/claude-ctl.rb` or install from Releases with `curl`),
  command table (exactly the commands from Task 6), **how it works** (the F1/F2 mechanism:
  `--user-data-dir` + `CLAUDE_CONFIG_DIR`, the original bundle is not touched), known limitations
  (no separate Dock icon, logs are shared, `claude://` handler goes to one instance), license.

- [ ] **Step 2: Write `LICENSE`** — MIT, "Copyright (c) 2026 Serdar".

- [ ] **Step 3: Write `Formula/claude-ctl.rb`**

  `class ClaudeCtl < Formula`; `desc "Multi-instance manager for Claude Desktop"`; `homepage` the GitHub repo URL; `license "MIT"`; `version "0.1.0"`;
  `url "https://github.com/<OWNER>/claude-ctl/releases/download/v0.1.0/claude-ctl-0.1.0.tar.gz"`; `sha256 "<SHA256>"`.
  `depends_on "macos" => :ventura`; `bin.install "claude-ctl"`.
  **The `<OWNER>` and `<SHA256>` placeholders are deliberately left in this task**; both are filled in after the first release
  (the two steps below). This is the only file with placeholders left in it.

- [ ] **Step 4: Write `.github/workflows/release.yml`**

  Trigger: `on: push: tags: ["v*"]`. Job: `runs-on: macos-14`; steps: `swift build -c release --arch arm64 --arch x86_64` (universal), `swift test`, compute the `tar` archive + `shasum -a 256`, upload with `gh release create`.

- [ ] **Step 5: Create the GitHub repo and resolve the `<OWNER>` placeholder**

  Run: `gh repo create claude-ctl --public --source=. --remote=origin --push && gh repo view --json owner -q .owner.login`
  Expected: the remote is added and the real username replaces `<OWNER>` (Formula + workflow).

- [ ] **Step 6: Create the first release and fill in the `<SHA256>` placeholder**

  Run: `git tag v0.1.0 && git push origin v0.1.0` (the workflow uploads the release automatically), then
  `curl -sL https://github.com/<OWNER>/claude-ctl/releases/download/v0.1.0/claude-ctl-0.1.0.tar.gz | shasum -a 256`
  Expected: the SHA256 output is written to the `sha256` field in the Formula and committed.

- [ ] **Step 7: `swift build -c release` completes without errors and `swift test` passes**

  Run: `swift build -c release && swift test`
  Expected: build succeeds, tests PASS.

- [ ] **Step 8: Commit**

  ```bash
  git add README.md LICENSE Formula .github
  git commit -m "docs: README, MIT license, Homebrew formula and release workflow"
  ```

---

### Task 9: E2E smoke script and live verification

**Files:**
- Create: `Scripts/smoke.sh`

**Interfaces:**
- Consumes: the compiled `claude-ctl` binary (`build/release/claude-ctl`), the real `Claude.app`.
- Produces: `Scripts/smoke.sh` — exit code 0 (all passed) / 1 (something failed).

- [ ] **Step 1: Write `Scripts/smoke.sh`**

  Bash, `set -euo pipefail`. Steps:
  1. `BIN` = `.build/release/claude-ctl` (build it with `swift build -c release` if missing).
  2. `WORK=$(mktemp -d)`; `SMOKE_NAME="smoke-$$"`.
  3. `$BIN new "$SMOKE_NAME" --workdir "$WORK"` → exit 0.
  4. `$BIN start "$SMOKE_NAME"` → exit 0; wait 10 s.
  5. `PROFILE=~/Library/Application\ Support/claude-ctl/instances/$SMOKE_NAME/profile` → `test -f "$PROFILE/Cookies"` (profile is separate ✓).
  6. `$BIN list --json` → the output contains `"$SMOKE_NAME"` and `"isRunning": true`.
  7. `$BIN status "$SMOKE_NAME"` → exit 0.
  8. `$BIN doctor "$SMOKE_NAME"` → exit 0 or 1 (0 if no fail) — the output contains "claude-app".
  9. `$BIN logs "$SMOKE_NAME" -n 5` → exit 0.
  10. `$BIN stop "$SMOKE_NAME"` → exit 0; wait 3 s; `$BIN list --json` → `"isRunning": false`.
  11. `$BIN new "$SMOKE_NAME" --workdir "$WORK"` → **exit != 0** (duplicate rejected) — the error contains "`already exists`".
  12. `$BIN new "INVALID NAME" --workdir "$WORK"` → exit 2 (usage error, invalid name).
  13. `$BIN new "invalid-name"` → exit 2 (missing `--workdir`).
  14. **Two-instance isolation**: a second instance (`smoke2-$$`) is created, both are started,
      then it is verified that `PROFILE1` and `PROFILE2` **have** a `Cookies` file and are **in different directories**;
      it is checked that the sizes/contents of `PROFILE1/Cookies` and `PROFILE2/Cookies` are not mixed up
      (each should have its own `Local Storage` and `IndexedDB` directory in its profile).
  15. The second instance is stopped.
  16. At the end: `$BIN stop "$SMOKE_NAME" || true`, `$BIN stop "smoke2-$$" || true` and `rm -rf "$WORK"`.

- [ ] **Step 2: Run the script and verify**

  Run: `chmod +x Scripts/smoke.sh && ./Scripts/smoke.sh`
  Expected: all steps succeed, the script exits 0, and the `echo` output shows which step passed.

- [ ] **Step 3: Manual verification (spec §13 open questions)**

  Checklist (by eye):
  1. **Workdir seeding**: when the `smoke` instance's Code tab opens, is the selected folder the project
     folder inside `WORK`? (Also, are `claude_desktop_config.json` → `localAgentModeTrustedFolders` and
     `ccd-session-presets.json` → the preset entry correct?)
  2. **Separate account**: can you sign in with a different Anthropic account in the second instance?
     (The first instance's session must not be affected.)
  3. **Dock**: with two instances running, are there two separate Claude tiles in the Dock?
  4. **`claude://`**: when a "Sign in" flow is started in a new instance, which instance does the
     browser's callback land in?
  5. **Update**: after Claude Desktop updates, does `doctor <name>` report the version difference,
     and does `start` open the new version without crashing?

- [ ] **Step 3: Commit**

  ```bash
  git add Scripts/smoke.sh
  git commit -m "test: live E2E smoke script"
  ```
