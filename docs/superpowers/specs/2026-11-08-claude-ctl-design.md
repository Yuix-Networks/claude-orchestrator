# claude-ctl — multi-instance manager for Claude Desktop (macOS)

Date: 2026-11-08
Status: Approved (design Section 1 + 2)
Scope: v1 = CLI core + menu bar icon

---

## 1. Goal

A macOS command-line tool that runs `/Applications/Claude.app` as N independent instances
at the same time. Each instance needs:

- its own Electron profile (cookies, session, settings, logs),
- its own Claude Code config (the equivalent of `~/.claude`),
- its own signed-in account,
- its own working folder (workdir),
- its own Dock tile.

The tool **never touches the original `Claude.app` bundle**: it doesn't copy, patch or re-sign it.
That way code signing, notarization, automatic updates and macOS permissions keep working.

Reference: https://parall.app (commercial, USD 10.99) — this tool is a CLI-style, Claude-specific,
open source take on it.

### Out of scope (v1)

- Apps other than `Claude.app` (this is not a general-purpose multi-instance launcher).
- A separate Dock icon / app name (see "Known limitations" below).
- A GUI (SwiftUI settings app).
- Parall's menu bar icon, Web App Shortcut and HOME override modes.

---

## 2. Verified findings (measurement results)

The experiments behind this design were run on 2026-11-08 against a real `Claude.app` (4.4212.0).
Each item is recorded with its evidence.

| # | Finding | Evidence |
|---|---|---|
| F1 | `--user-data-dir=<path>` fully relocates the Electron profile (Cookies, Local Storage, IndexedDB, Cache) | `Cookies`, `Local Storage`, `IndexedDB` were created in the profile |
| F2 | `CLAUDE_CONFIG_DIR=<path>` separates the Claude Code config (`~/.claude`, `.claude.json`, sessions) | `sessions/`, `.claude.json` were created under `claude-code-home/` |
| F3 | `CLAUDE_USER_DATA_DIR` **is ignored in signed builds** | `~/Library/Logs/Claude/main.log`: `[user-data-dir] CLAUDE_USER_DATA_DIR is set and signed builds ignore it (path kind: local); this launch uses the default data folder` |
| F4 | `open -n` opens a separate Dock tile for each instance | `lsappinfo` → 3 separate ASNs; Dock screenshot shows 3 Claude icons side by side |
| F5 | Since the original bundle is not touched, the signature/updater are preserved | `codesign -dv` → `Developer ID Application: Anthropic PBC`, notarized; the tool never writes to the bundle |
| F6 | Claude.app is not sandboxed; `Contents/MacOS/Claude` is only 54 KB, `Frameworks` 288 MB, `app.asar` 55 MB | `codesign -d --entitlements -` → no `app-sandbox` |
| F7 | The Electron clone (stub) approach runs into macOS security walls: (a) library validation — "mapping process and mapped file have different Team IDs"; (b) after the `disable-library-validation` entitlement, "Unable to find helper app" (the helper name is derived from `CFBundleName`); (c) with `CFBundleName` set to "Claude", a sandbox extension error and the process dies | Direct attempt, logs |
| F8 | Native launcher + `execve` reverts the identity: the process is re-registered under Claude.app | `lsappinfo` → no launcher bundle ID, Claude's bundle path is shown |
| F9 | The `claude://` deep link goes to a single handler; a `disableDeepLinkRegistration` managed config key exists | `Disable claude:// deep-link handling` definition inside the asar |
| F10 | The workdir is stored in the profile: `claude_desktop_config.json` → `preferences.localAgentModeTrustedFolders` and `ccd-session-presets.json` → `byAccount[accountUuid].presets[].target.cwd` | Profile files were read |
| F11 | The session is encrypted with `safeStorage` and stored inside the profile (Keychain only holds the encryption key) → a separate account per profile is possible | 138 `safeStorage` references inside the asar |
| F12 | The Electron stub's `CFBundleName` determines the helper names (`Claude Helper.app`) | "Unable to find helper app" error |

### Chosen approach

F1 + F2 together give the only verified, workable isolation mechanism:

```
open -n -a /Applications/Claude.app \
     --args --user-data-dir=<profile> \
     --env  CLAUDE_CONFIG_DIR=<codeDir>
```

`open --env` is available in macOS 13 (Ventura) and later → **minimum macOS 13**.

---

## 3. Architecture

One Swift binary, two modes.

```
claude-ctl              # CLI mode (default)
claude-ctl agent        # menu bar icons
```

### Components

| Component | Responsibility |
|---|---|
| `Command` layer | Subcommand parsing, `--json` output, exit codes |
| `InstanceStore` | Reading/writing `config.json`, instance CRUD, path generation |
| `Launcher` | The `open -n` call, capturing the PID, profile lock check |
| `ProfileSeeder` | Workdir → trusted folders + session preset writes (idempotent merge) |
| `Agent` | Creating `NSStatusItem`s, watching instance state, action menus |
| `Doctor` | Version compatibility, lock, permission and disk checks |

### Dependency direction between modules

`Command` → (`InstanceStore`, `Launcher`, `ProfileSeeder`, `Doctor`) and
`Agent` → (`InstanceStore` + `Launcher`).
No module calls another directly; they all access data through `InstanceStore`.

---

## 4. Data layout

All data lives under `~/Library/Application Support/claude-ctl/`:

```
~/Library/Application Support/claude-ctl/
├── config.json                       # instance definitions
├── state/
│   └── agent.pid                     # agent singleton lock
└── instances/
    └── <name>/
        ├── profile/                  # Electron profile  (--user-data-dir)
        ├── claude-code/              # separate ~/.claude (CLAUDE_CONFIG_DIR)
        └── state.json                # pid, startedAt, last known version, account state
```

### `config.json` schema

```json
{
  "version": 1,
  "instances": {
    "work": {
      "name": "work",
      "workdir": "/Users/serdar/workspace/nameocean",
      "createdAt": "2026-11-08T10:00:00Z",
      "autoStart": false,
      "iconBadge": null
    }
  }
}
```

The `profile` and `claude-code` paths are derived (not stored in the config), so instances
don't break if the root directory moves.

---

## 5. Command surface

| Command | What it does | Notes |
|---|---|---|
| `new <name> --workdir <path>` | Creates an instance and seeds the profile | Existing name → error |
| `start <name>` | Starts the instance | No-op if running; `--folder <path>` passes a one-off folder argument (§7 fallback) |
| `stop <name>` | Stops the instance | Gentle first (SIGTERM), then forced |
| `list` | Table: name, state, pid, workdir, profile size | Supports `--json` |
| `status <name>` | Details: paths, last version, account state, last log line | Supports `--json` |
| `logs <name>` | Prints Claude logs | `-f/--follow`, `--lines N`. Logs are **shared across all instances** (`~/Library/Logs/Claude/main.log`); output is filtered by the instance's start time |
| `signin <name>` | Sign-in guide + `claude://` handler routing | See §9 |
| `open <name>` | Opens the workdir / profile folder in Finder | `--target workdir\|profile` |
| `agent --install` | Installs the menu bar icon as a LaunchAgent | `--uninstall` too |
| `doctor [<name>]` | Health check | All instances or a single one |

Output contract: exit code `0` success, `1` runtime error, `2` usage error.
Every command supports `--json`; error messages are actionable ("run this: …").

---

## 6. Start flow

```
claude-ctl start <name>
 1. Does the instance exist?  → if not, error (2)
 2. Is it running?            → if the PID is alive, no-op (0)
 3. Is the profile locked?    → if SingletonLock exists: "used by another instance" (1)
 4. Is the workdir still valid? → if not, warn and skip seeding
 5. Seed the profile          → idempotent merge (see §7)
 6. open -n -a ... --args --user-data-dir --env
 7. Wait for the PID (max 10 s) → if not found, error (1)
 8. Update state.json         → pid, startedAt, claudeVersion
 9. Agent menu is updated     → the agent polls every 5 seconds (no instant notification)
```

`stop`: SIGTERM → wait 5 s → SIGKILL if still alive. `state.json` is cleared.

---

## 7. Workdir seeding (profile seeding)

In Claude Desktop, the Code tab's folder is kept inside the profile. When the instance is created
and before every start (while the instance is closed), two files are written:

**a) `profile/claude_desktop_config.json`**

```jsonc
// the workdir is added to the preferences.localAgentModeTrustedFolders array
"preferences": {
  "localAgentModeTrustedFolders": ["/Users/serdar/workspace/nameocean"]
}
```

**b) `profile/ccd-session-presets.json`**

```jsonc
// a preset for the workdir is added to byAccount[<accountUuid>].presets
{
  "byAccount": {
    "<accountUuid>": {
      "presets": [
        {
          "id": "<uuid>",
          "name": "nameocean",
          "createdAt": 1791993478191,
          "lastUsedAt": 1791993478191,
          "target": { "kind": "local", "cwd": "/Users/serdar/workspace/nameocean" }
        }
      ]
    }
  }
}
```

`<accountUuid>` is found from the profile files (the `ccd-session-presets.json` keys,
`bridge-state.json`); if there is no account yet (before the first sign in), no preset is written, the trusted folder
is written, and the preset is completed after the first `start` (once the account exists).

**Idempotency:** both merges follow the rule "don't add if the path already exists"; running
the seeding N times gives the same result. Existing file content is preserved, only the relevant fields
are updated (by merging the target field, not rewriting the JSON from scratch).

**Alternative (fallback):** `claude-ctl start <name> --folder <path>` → the folder is passed as an app
argument. It writes no persistent settings; it's used if profile seeding fails.

---

## 8. Menu bar agent

One process (`claude-ctl agent`), one `NSStatusItem` per instance.

- Icon: the Claude icon + an instance badge (a number or a short name). Rendered as a template image.
- Menu: **Bring to front** / **Stop** / **Open workdir** / **Open profile folder** / **Logs** /
  **Sign-in help**.
- "Bring to front": `NSRunningApplication.activate(options: [.activateAllWindows])` via the PID
  in `state.json`.
- State updates: `config.json` and PID liveness are checked by polling every 5 seconds and
  the menus are refreshed (no instant notifications/FSEvents).
- Singleton: the `state/agent.pid` file; if the pid in it is alive, a second agent doesn't start.
- Install: `claude-ctl agent --install` → writes `~/Library/LaunchAgents/com.claude-ctl.agent.plist`
  (RunAtLoad + KeepAlive).

v1 has no "New window" in the menu: making an Electron app open a new window through AppleScript
is not reliable; "Bring to front" is enough.

---

## 9. Edge cases and decisions

| Situation | Decision |
|---|---|
| Log files are shared | Claude writes logs under `~/Library/Logs/Claude/` and that path is not affected by `--user-data-dir` (`app.setPath("logs", …)` only works for the ignored `CLAUDE_USER_DATA_DIR`). The `logs` command filters by the instance's `startedAt` time; there is no exact separation |
| Same profile in two instances | Chromium `SingletonLock` → the second launch is refused. `start` checks the lock beforehand and doesn't crash |
| Claude update | The bundle is not touched → the new version on the next launch. `doctor` notices the version change and re-seeds the profile |
| Dead instance / stale state | `list` checks PID liveness; stale `state.json` is cleaned up |
| `claude://` sign-in routing | `signin` restarts the target instance (the handler is whichever registered last) and asks for the other instances to be closed. Which instance is the handler will be measured during implementation and finalized accordingly |
| Disk | ~500 MB per instance (its own copy of the Claude Code CLI) + profile growth. `list` shows the size, `doctor` warns past a threshold |
| macOS permissions (camera/microphone) | Same bundle ID → the original app's permissions are shared; no new permission prompt per instance |
| Slow first launch | Each instance downloads its own Claude Code CLI (needs network) |
| Corrupt state file | If `config.json` is not valid JSON, `start`/`list` give a descriptive error and don't delete or overwrite the file |
| Instance name normalization | `[a-z0-9-]`, 1-32 characters; `..` and `/` are rejected (path traversal) |
| Workdir deleted | `start` warns, skips seeding, and the instance still opens |

---

## 10. Known limitations

1. **No separate Dock icon.** All tiles show the Claude icon (F4). To tell instances apart,
   the menu bar icon + window titles are used. Parall's separate Dock icon needs the target app's
   bundle identity to change; that is exactly the path where the Electron clone hits the security walls
   (F7, F8).
2. **The app menu name stays "Claude"** — Electron's `productName` is baked into the bundle.
3. **Separate accounts** rely on per-profile `safeStorage` blobs (F11) and will be verified
   during the initial implementation.
4. The `claude://` handler goes to a single instance (§9).
5. **Log files are shared** (`~/Library/Logs/Claude/`); no per-instance logs (§9).
6. The tool only works on macOS 13+ and when `Claude.app` is on the `PATH`/in a known location.

---

## 11. Test strategy

**1. Unit tests (XCTest)**
- `InstanceStore`: config read/write, name normalization, path traversal rejection, default config.
- `ProfileSeeder`: JSON merge idempotency (same seed 2× → same output), preservation of existing
  fields, missing file case, behavior when no account is found.
- `Command`: subcommand parsing, `--json` output format, exit codes.
- `Launcher`: command generation (argument array in the right order, paths with spaces escaped).

**2. Integration tests** (macOS, Claude installed)
- Start two instances with `open -n` → the profiles are in different directories and independent
  of each other (neither should see the other's `Cookies`).
- Does `--user-data-dir` really write to the profile (does the file exist)?
- Opening the same profile twice → SingletonLock behavior is reported correctly.
- Skipped in CI if Claude is not installed.

**3. E2E smoke (manual, macOS)**
`new` → `start` → two instances in parallel → verify workdir seeding (right project in the Code tab)
→ menu bar icons → `stop` → profile files remain.

---

## 12. Distribution

- GitHub Releases: a single compiled binary (universal: arm64 + x86_64).
- Homebrew tap: `brew install serdar/tap/claude-ctl` (its own tap repo).
- Install path: `/usr/local/bin` or `/opt/homebrew/bin` (managed by Homebrew).
- License: MIT.

---

## 13. Open questions to measure during implementation

1. Which instance does the `claude://` deep link go to? (the most recently started, or the frontmost?)
2. Do `open --env` + `--args` together behave the same on every macOS 13 release?
3. Reliably getting the PID of an instance opened with `open -n`: `open` doesn't return a PID → the process
   will be found by matching the `--user-data-dir=<unique path>` argument.
4. Is profile seeding enough instead of `selected-folder` (Local Storage/leveldb), i.e. are
   `claude_desktop_config.json` + `ccd-session-presets.json` enough? (F10 confirmed it; to be
   double-checked in the first smoke test.)
5. Does changing `localAgentModeTrustedFolders` require a "trusted folder" approval in the app?
6. Do two instances with two different Anthropic accounts really keep separate sessions (verifying the
   F11 assumption)?
