# claude-orchestrator

Run **Claude Desktop** as many independent instances as you want on macOS — each with
its own profile, account, sessions, Claude Code config and working directory.

`claude-orchestrator` never copies, patches or re-signs `/Applications/Claude.app`. It launches the
**original, signed** app with a different data directory, so code signature, notarization,
permissions and the built-in updater all keep working.

```
claude-orchestrator new work --workdir ~/workspace/my-project
claude-orchestrator start work
claude-orchestrator list
```

> **Renamed in v0.2.0:** `claude-ctl` is now `claude-orchestrator`, because the tool
> manages sessions as well as instances. The old name still works as a deprecated alias
> (it prints a warning), and the data directory stays at
> `~/Library/Application Support/claude-ctl/`, so existing instances keep working.

## Quick start: one instance per account

Keep work, school and a second work account signed in side by side:

```bash
claude-orchestrator new work
claude-orchestrator new school
claude-orchestrator new client --workdir ~/workspace/client   # optional default project

claude-orchestrator signin work --exclusive     # sign in, one instance at a time
claude-orchestrator signin school --exclusive
claude-orchestrator signin client --exclusive

claude-orchestrator project import --from default   # reuse the projects you already have
claude-orchestrator project add ~/workspace/api       # or add new ones: every instance gets them

claude-orchestrator start work && claude-orchestrator start school && claude-orchestrator start client
claude-orchestrator agent --install             # menu bar icons to start/stop/switch
```

`signin --exclusive` closes the other instances while you sign in, because the browser
hands the login back through a single `claude://` link that only one running Claude can
receive. It reopens them when you press Enter.

---

## Why

Claude Desktop stores everything in a single Electron profile, so a second launch either
reuses the first one's session or refuses to start. Copying the app bundle works, but the
copy falls behind on updates and has to be rebuilt every time.

`claude-orchestrator` uses the mechanism Claude already ships for this:

| What | How |
|---|---|
| Separate Electron profile (cookies, sessions, settings) | `--user-data-dir=<per-instance path>` |
| Separate Claude Code config (`~/.claude`, sessions) | `CLAUDE_CONFIG_DIR=<per-instance path>` |
| Separate Dock tile | `open -n` (new application instance) |

The result: several Claude instances side by side, each working on a different project.

## Install

### Homebrew

```bash
brew install yuix-networks/tap/claude-orchestrator
```

The formula lives in [Yuix-Networks/homebrew-tap](https://github.com/Yuix-Networks/homebrew-tap).
It also installs `claude-ctl` as a deprecated alias.

### From a release

Download the `claude-orchestrator` binary from [Releases](https://github.com/Yuix-Networks/claude-orchestrator/releases)
and put it on your `PATH`:

```bash
install -m 755 claude-orchestrator /usr/local/bin/
```

### From source

```bash
swift build -c release
cp .build/release/claude-orchestrator /usr/local/bin/
```

**Requirements:** macOS 13 (Ventura) or later — `open --env` is needed to pass the
per-instance environment. Claude Desktop must be installed in `/Applications`.

## Commands

| Command | What it does |
|---|---|
| `claude-orchestrator new <name> [--workdir <path>] [--sessions-from <instance>]` | Create an instance; optionally seed a default project and copy another instance's sessions |
| `claude-orchestrator start <name> [--folder <path>]` | Start the instance (separate profile + config) |
| `claude-orchestrator stop <name>` | Stop the instance (SIGTERM, then SIGKILL if needed) |
| `claude-orchestrator list [--json]` | All instances with state, pid and workdir |
| `claude-orchestrator status <name> [--json]` | Details for one instance |
| `claude-orchestrator logs <name> [-n N] [-f]` | Instance log lines (`-f` follows, survives log rotation) |
| `claude-orchestrator open <name> [--target workdir\|profile]` | Open a folder in Finder |
| `claude-orchestrator signin <name> [--restart] [--exclusive]` | Sign-in guide; `--exclusive` closes the other instances while you sign in |
| `claude-orchestrator doctor [<name>] [--json]` | Health checks: app version, profile, lock, disk, workdir, session |
| `claude-orchestrator clone <name> --as <new> [--workdir <path>]` | Copy an instance with its profile, config and sessions |
| `claude-orchestrator project …` (alias `env`) | Projects shared by every instance — Claude Desktop calls them environments (see below) |
| `claude-orchestrator session …` | List, inspect, copy and move Claude Code sessions (see below) |
| `claude-orchestrator remove <name> [--purge [--permanent]] [--yes]` | Delete the instance; `--purge` moves its data to the Trash (asks first) |
| `claude-orchestrator agent [--install\|--uninstall]` | Menu bar icons (one per instance), installable as a login item |

Every `--json` output carries a `schemaVersion` field (currently `1`). It is bumped only
when a field is removed or renamed.

Exit codes: `0` success, `1` runtime error, `2` usage error.

## Projects (environments) in every instance

Claude Desktop keeps the Code tab's environments per profile and per account. Without
help, you'd create every project again in each instance. `project` keeps one list and
writes it into all of them:

```bash
claude-orchestrator project add ~/workspace/api                       # name = folder name
claude-orchestrator project add ~/workspace/site --name "Site" --folder ~/workspace/shared
claude-orchestrator project import --from default    # take over the regular Claude's environments
claude-orchestrator project list                     # ✓ synced  ✗ missing  … waiting for sign-in
claude-orchestrator project sync                     # re-apply to every instance
claude-orchestrator project remove "Site"            # also removes it from the instances (--keep: don't)
```

- The list lives in `config.json`. New instances get it automatically, and every
  `start` applies it again.
- An environment belongs to an account, so before the first sign-in only the folder is
  trusted. The environment itself is written on the first `start` after you sign in.
  In a profile that has seen several accounts, every account gets the project.
- An environment that already exists for the same folder is left alone, including its
  name, model and other settings.
- A running instance sees changes after a restart. If Claude overwrites the file
  meanwhile, the next `start` writes the changes again.
- `project remove` keeps a folder trusted if another project or the instance's workdir
  still uses it.

## Sessions

Each instance has its own Claude Code config directory, so its sessions stay with it.
The `session` commands move them around:

```bash
claude-orchestrator session list                          # every instance, newest first
claude-orchestrator session list --instance work --project ~/workspace/api
claude-orchestrator session show 3f2a                     # an id prefix is enough
claude-orchestrator session copy 3f2a --to school         # the source keeps its copy
claude-orchestrator session move 3f2a --to school         # the source copy goes to a backup
claude-orchestrator session last --from work --to school  # move work's latest session
```

- The name `default` means the Claude install outside claude-orchestrator
  (`~/.claude`), so `session copy <id> --instance default --to work` brings in
  an existing session.
- The target must be stopped (or pass `--force`). `move` also needs the source to be
  stopped.
- A session id that already exists in the target is refused unless you pass `--force`.
  So is a project folder that maps to the same directory name as a different path.
- Files are copied to a temporary name and then renamed into place, so an interrupted
  transfer never leaves half a transcript. `move` doesn't delete anything. It moves the
  source files to `~/Library/Application Support/claude-ctl/backups/<time>-<id>/`.
- The transcript, sub-agent transcripts, TODO files and the project's
  `sessions-index.json` entry are all transferred. The session can be resumed with
  `CLAUDE_CONFIG_DIR=<target>/claude-code claude --resume <id>` (`session show` prints
  the exact command).
- **Claude Desktop's sidebar (experimental).** If the source has a Desktop entry for the
  session and the target is signed in, a copy is written to the target's Code tab list.
  Account-specific fields are dropped. The entry appears after the target instance
  restarts. When the target's account is unknown, you get the `--resume` command
  instead.
- Summaries are cached in `~/Library/Application Support/claude-ctl/cache/sessions.json`,
  keyed by file size and modification time. The cache is safe to delete.

Chats in the Chat tab are not transferred. They are stored in your claude.ai account,
not on disk, so an instance signed in to the same account already sees them and an
instance signed in to a different account cannot open them.

## Menu bar agent

```bash
claude-orchestrator agent --install     # login item
claude-orchestrator agent               # run now
```

Each instance gets a menu bar icon (Claude's icon plus a badge). The menu can start a
stopped instance, bring a running one to the front, stop it, open its workdir or profile folder, show its logs and
display the sign-in guide. The agent is a single process; it refreshes every 5 seconds.

## How it works

`claude-orchestrator start` runs exactly this:

```
open -n -a /Applications/Claude.app \
     --env  CLAUDE_CONFIG_DIR=~/Library/Application\ Support/claude-ctl/instances/<name>/claude-code \
     --args --user-data-dir=~/Library/Application\ Support/claude-ctl/instances/<name>/profile
```

`-n` asks macOS for a new application instance, so the second Claude does not join the
first one. The per-instance data path comes from Claude's own Electron profile, and the
Claude Code CLI is redirected with `CLAUDE_CONFIG_DIR`.

`--env` **must** come before `--args`: everything after `--args` is handed to the app as
argv, so a misplaced `--env` would reach Claude as a stray argument instead of being
consumed by `open`.

Before starting, the instance profile is seeded so the Code tab opens in the right project:

- `claude_desktop_config.json` → `preferences.localAgentModeTrustedFolders`
- `ccd-session-presets.json` → a session preset whose `target.cwd` is your workdir

## Where things live

```
~/Library/Application Support/claude-ctl/
├── config.json                     # instance definitions
├── backups/                        # sources of `session move`
├── cache/sessions.json             # session summary cache
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
- **Log files are shared.** Claude writes to `~/Library/Logs/Claude/`; `claude-orchestrator logs`
  filters by the instance's start time, so the separation is approximate.
- **The session preset needs an account.** The workdir is seeded as a *trusted folder*
  immediately, but the "session preset" (the entry the Code tab opens with) is written
  only once the instance knows your Anthropic account — that is, after the first sign-in.
  Run `claude-orchestrator signin <name> --restart` (or restart the instance once) afterwards.
- **One `claude://` handler.** The OAuth deep link is delivered to a single instance;
  use `claude-orchestrator signin <name> --exclusive`. It also warns when the regular,
  non-instance Claude is open, since that one can catch the link too.
- **Disk usage.** Each instance keeps its own Claude Code CLI download (~500 MB) plus
  its profile.
- **The Claude Code directory fills up after sign-in.** The per-instance
  `claude-code/` folder stays empty until the instance is signed in, because the CLI
  only starts once you use a Claude Code session in that instance.
- Claude Desktop itself enforces some single-instance behaviour; if an instance refuses
  to start, `claude-orchestrator doctor <name>` explains why.

## Development

```bash
swift build
swift test
./Scripts/smoke.sh     # live end-to-end check (starts real Claude instances)
```

## License

MIT — see [LICENSE](LICENSE).
