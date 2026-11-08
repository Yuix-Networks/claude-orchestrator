# claude-ctl

Run **Claude Desktop** as many independent instances as you want on macOS — each with
its own profile, account, sessions, Claude Code config and working directory.

`claude-ctl` never copies, patches or re-signs `/Applications/Claude.app`. It launches the
**original, signed** app with a different data directory, so code signature, notarization,
permissions and the built-in updater all keep working.

```
claude-ctl new work --workdir ~/workspace/my-project
claude-ctl start work
claude-ctl list
```

---

## Why

Claude Desktop stores everything in a single Electron profile, so a second launch either
reuses the first one's session or refuses to start. Copying the app bundle works, but the
copy falls behind on updates and has to be rebuilt every time.

`claude-ctl` uses the mechanism Claude already ships for this:

| What | How |
|---|---|
| Separate Electron profile (cookies, sessions, settings) | `--user-data-dir=<per-instance path>` |
| Separate Claude Code config (`~/.claude`, sessions) | `CLAUDE_CONFIG_DIR=<per-instance path>` |
| Separate Dock tile | `open -n` (new application instance) |

The result: several Claude instances side by side, each working on a different project.

## Install

### Homebrew

```bash
brew install --formula ./Formula/claude-ctl.rb
```

### From a release

Download the `claude-ctl` binary from [Releases](https://github.com/OWNER/claude-ctl/releases)
and put it on your `PATH`:

```bash
install -m 755 claude-ctl /usr/local/bin/
```

### From source

```bash
swift build -c release
cp .build/release/claude-ctl /usr/local/bin/
```

**Requirements:** macOS 13 (Ventura) or later — `open --env` is needed to pass the
per-instance environment. Claude Desktop must be installed in `/Applications`.

## Commands

| Command | What it does |
|---|---|
| `claude-ctl new <name> --workdir <path>` | Create an instance; seeds the workdir into the profile |
| `claude-ctl start <name> [--folder <path>]` | Start the instance (separate profile + config) |
| `claude-ctl stop <name>` | Stop the instance (SIGTERM, then SIGKILL if needed) |
| `claude-ctl list [--json]` | All instances with state, pid and workdir |
| `claude-ctl status <name> [--json]` | Details for one instance |
| `claude-ctl logs <name> [-n N] [-f]` | Instance log lines (`-f` follows) |
| `claude-ctl open <name> [--target workdir\|profile]` | Open a folder in Finder |
| `claude-ctl signin <name> [--restart]` | Sign-in guide (the `claude://` deep link goes to one instance) |
| `claude-ctl doctor [<name>]` | Health checks: app version, profile, lock, disk, workdir, session |
| `claude-ctl remove <name> [--purge]` | Delete the instance (`--purge` also deletes its data) |
| `claude-ctl agent [--install\|--uninstall]` | Menu bar icons (one per instance), installable as a login item |

Exit codes: `0` success, `1` runtime error, `2` usage error.

## Menu bar agent

```bash
claude-ctl agent --install     # login item
claude-ctl agent               # run now
```

Each instance gets a menu bar icon (Claude's icon plus a badge). The menu can bring an
instance to the front, stop it, open its workdir or profile folder, show its logs and
display the sign-in guide. The agent is a single process; it refreshes every 5 seconds.

## How it works

`claude-ctl start` runs exactly this:

```
open -n -a /Applications/Claude.app \
     --args --user-data-dir=~/Library/Application\ Support/claude-ctl/instances/<name>/profile \
     --env  CLAUDE_CONFIG_DIR=~/Library/Application\ Support/claude-ctl/instances/<name>/claude-code
```

`-n` asks macOS for a new application instance, so the second Claude does not join the
first one. The per-instance data path comes from Claude's own Electron profile, and the
Claude Code CLI is redirected with `CLAUDE_CONFIG_DIR`.

Before starting, the instance profile is seeded so the Code tab opens in the right project:

- `claude_desktop_config.json` → `preferences.localAgentModeTrustedFolders`
- `ccd-session-presets.json` → a session preset whose `target.cwd` is your workdir

## Where things live

```
~/Library/Application Support/claude-ctl/
├── config.json                     # instance definitions
└── instances/<name>/
    ├── profile/                    # Electron profile
    ├── claude-code/                # CLAUDE_CONFIG_DIR
    └── state.json                  # pid, start time, Claude version
```

## Known limitations

- **No separate Dock icon.** Every instance shows Claude's icon; the menu bar agent's
  badges are what tell them apart. Giving an instance its own Dock icon requires
  changing the app's bundle identity, which breaks macOS/Electron security guarantees.
- **The application menu still says "Claude"** (the name is compiled into the app).
- **Log files are shared.** Claude writes to `~/Library/Logs/Claude/`; `claude-ctl logs`
  filters by the instance's start time, so the separation is approximate.
- **One `claude://` handler.** The OAuth deep link is delivered to a single instance;
  close the others while signing in (or use `claude-ctl signin <name> --restart`).
- **Disk usage.** Each instance keeps its own Claude Code CLI download (~500 MB) plus
  its profile.
- Claude Desktop itself enforces some single-instance behaviour; if an instance refuses
  to start, `claude-ctl doctor <name>` explains why.

## Development

```bash
swift build
swift test
./Scripts/smoke.sh     # live end-to-end check (starts real Claude instances)
```

## License

MIT — see [LICENSE](LICENSE).
