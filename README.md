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

Or run `claude-orchestrator` with no arguments and do all of it from a menu (see
[Interactive mode](#interactive-mode)).

> **Renamed in v0.2.0:** `claude-ctl` is now `claude-orchestrator`, because the tool
> manages sessions as well as instances. The data directory stays at
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

## Interactive mode

Run the command with no arguments in a terminal:

```bash
claude-orchestrator
```

Everything day-to-day can be done from the menu. You don't need to remember commands,
session ids or file paths:

```
Claude Orchestrator
───────────────────────────────────────
❯ Work        ● running
  Personal    ● running
  School      ○ stopped   not logged in
───────────────────────────────────────
  + New profile
  Projects…
```

### What you can do

| Screen | Options |
|---|---|
| **Home** | Every profile with **running / stopped**, and a warning when it is not logged in. Below them: **+ New profile** and **Projects…** |
| **Profile** (logged in) | **Start**, or **Stop** / **Restart** when it is running · **Sessions…** · **Log in again…** |
| **Profile** (not logged in) | **Log in** only. The other options appear after you log in |
| **Sessions…** | The profile's sessions, newest first. Type to fuzzy-filter by title, account or project folder |
| **A session** | Its details (account, project, start, last activity, messages, size, id) · **Copy to…** · **Move to…** |
| **+ New profile** | Asks for a name, creates the profile and opens its menu so you can log in right away |
| **Projects…** | The registered projects and their state in each profile · **+ Add project** · **Apply a projects.json…** · **Export to a projects.json…** · **Sync all profiles** · **Import from a profile…** |
| **A project** | Its folders, permission mode and per-profile state · **Remove…** |

**Keys:** ↑/↓ (or Ctrl-P / Ctrl-N) to move, Enter to choose, Esc to go back (in a
search box, Esc clears the text first), `q` on the home screen to quit, Ctrl-U to clear
a search or text field, Ctrl-C to cancel.

**What happens behind the screens:**

- **Log in** / **Log in again…** run the `signin --exclusive` flow. After you confirm,
  the other running instances are closed while you log in, so the browser's
  `claude://` link comes back to the right window. They are reopened when you press
  Enter. Use **Log in again…** when a login has expired or the profile should use a
  different account.
- **Copy to…** / **Move to…** ask for the target account (skipped when there is only
  one other account), then show what will happen and wait for `y`. Instances that
  have to be closed are shut down one after the other, the session is transferred,
  and they are reopened even if the transfer fails. A copy closes only the target and
  the source keeps its session. A move closes both and keeps the original as a backup.
- Anything that writes (logging in, transfers, project changes) asks for confirmation
  first, then prints the same report as the matching command and waits for Enter.
- The menu refuses to close an instance it is running inside (for example a terminal
  in Claude's Code tab), because that would end the menu halfway through. Run it from
  a regular terminal such as Terminal or iTerm.

### Setting up projects from a JSON file

A project is a folder that shows up as an environment in the Code tab of **every**
profile. Instead of adding them one by one, describe them in a file and apply it:

1. Copy the example file and edit the paths:

   ```bash
   mkdir -p ~/.config/claude-orchestrator
   cp examples/projects.json ~/.config/claude-orchestrator/projects.json
   ```

   [`examples/projects.json`](examples/projects.json) shows every option: a minimal
   entry, a custom name, extra folders, a per-project permission mode and shared
   `defaults`. If you already have projects, **Projects… → Export to a projects.json…**
   writes them to the file so you can start from there.

2. Open **Projects… → Apply a projects.json…**. The default path is already filled
   in. Press Enter.

3. Check the preview. The file is checked as a whole first, and every problem (a
   missing folder, a duplicate name, a misspelled key) is listed at once. Nothing
   changes until the file is clean.

   ```
   Apply ~/.config/claude-orchestrator/projects.json

     + website  ~/workspace/website
     + Mobile app  ~/workspace/mobile/app
     ~ api → API
     - old-project  (not in the file)

   ❯ Apply changes
     Apply and remove the 1 not in the file
     Cancel
   ```

   `+` is added, `~` is changed or renamed, and `-` is registered but missing from the
   file. **Apply changes** keeps those. **Apply and remove…** deletes them, which makes
   the registry match the file exactly.

4. The projects are written to every profile. A profile that has not logged in yet
   gets them on its first start after login. The **Projects…** list shows where each
   project stands: ✓ in sync, ✗ missing (fix it with **Sync all profiles**), … waiting
   for the first login.

The same file works without the menu (`project apply --dry-run`, `project apply`,
`project apply --prune`). See [Keeping the list in a file](#keeping-the-list-in-a-file)
for the full format and the details of how Claude Desktop stores environments.

### Trying it safely

Set `CLAUDE_ORCHESTRATOR_HOME` to point any command, the menu included, at a separate
data directory. You can then experiment without touching your real profiles:

```bash
CLAUDE_ORCHESTRATOR_HOME=/tmp/co-test claude-orchestrator
```

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

### Install script (recommended)

```bash
curl -fsSL https://raw.githubusercontent.com/Yuix-Networks/claude-orchestrator/main/install.sh | sh
```

The script downloads the latest release and checks its SHA-256 against the published
value. It installs into `/usr/local/bin` when that is writable and into `~/.local/bin`
otherwise. It never uses `sudo`.

- To pick a version or a directory, set `CLAUDE_ORCHESTRATOR_VERSION=0.2.2` or
  `CLAUDE_ORCHESTRATOR_DIR=~/bin` in front of `sh`.
- To uninstall, run `curl -fsSL …/install.sh | sh -s -- --uninstall`. Instance data is
  kept.

### Homebrew

Recent Homebrew versions refuse to load formulae from a third-party tap until you trust
it. Trust the tap **before** installing:

```bash
brew tap yuix-networks/tap
brew trust yuix-networks/tap
brew install yuix-networks/tap/claude-orchestrator
```

The formula lives in [Yuix-Networks/homebrew-tap](https://github.com/Yuix-Networks/homebrew-tap).
Upgrade later with `brew upgrade claude-orchestrator`.

### From a release

Download `claude-orchestrator-<version>.tar.gz` from
[Releases](https://github.com/Yuix-Networks/claude-orchestrator/releases), extract it and
put the binary on your `PATH`.

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
| `claude-orchestrator` | Interactive menu: profiles, sessions, projects (see [Interactive mode](#interactive-mode)) |
| `claude-orchestrator version` | Print the version |
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
| `claude-orchestrator project apply [<file>]` | Apply a hand-edited `projects.json` to every instance |
| `claude-orchestrator memory link\|unlink\|status` | Share `~/.claude/CLAUDE.md` with every instance |
| `claude-orchestrator project …` (alias `env`) | Projects shared by every instance — Claude Desktop calls them environments (see below) |
| `claude-orchestrator session …` | List, inspect, copy and move Claude Code sessions (see below) |
| `claude-orchestrator remove <name> [--purge [--permanent]] [--force] [--yes]` | Delete the instance (alias `delete`, `rm`). `--purge` moves its data to the Trash and `--permanent` deletes it for good. A running instance is stopped after you confirm, or right away with `--force` |
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

### Keeping the list in a file

You can edit the list by hand in a JSON file and apply it, from the menu
(**Projects… → Apply a projects.json…**, see
[Setting up projects from a JSON file](#setting-up-projects-from-a-json-file)) or with
`project apply`. The default file is `~/.config/claude-orchestrator/projects.json`. A
fully commented example is in [`examples/projects.json`](examples/projects.json). The
smallest useful file:

```json
{
  "projects": [
    { "name": "shop", "path": "~/workspace/shop/shop-backend",
      "folders": ["~/workspace/shop/shop-frontend"] },
    { "path": "~/workspace/blog" }
  ]
}
```

```bash
claude-orchestrator project export ~/.config/claude-orchestrator/projects.json  # start from what you have
claude-orchestrator project apply --dry-run    # show the plan, change nothing
claude-orchestrator project apply              # add, update and rename projects
claude-orchestrator project apply --prune      # also delete projects that are no longer in the file
```

- `name` and `folders` are optional. Paths may use `~` or be relative to the file.
- `defaults` applies to every project. `defaults.folders` is added to each project's
  extra folders (for example a knowledge-base repo every session should see), and
  `defaults.permissionMode` is used where a project doesn't set its own:

  ```json
  {
    "defaults": { "folders": ["~/workspace/notes"], "permissionMode": "bypassPermissions" },
    "projects": [ { "path": "~/workspace/blog", "permissionMode": "acceptEdits" } ]
  }
  ```

- `permissionMode` sets the default permission mode for sessions started in that
  project's folder. It can be `default`, `acceptEdits`, `plan`, `auto` or
  `bypassPermissions`. Claude Desktop stores this per account and per folder. For
  `bypassPermissions`, apply also turns on "allow bypass mode" and records the
  account's opt-in.
  - An organization policy that disables bypass mode is left alone, and the output
    names the affected accounts.
  - Removing `permissionMode` from the file clears it from Desktop. A change that only
    touches the mode keeps the environment's other settings.
- `//` comments and trailing commas are accepted.
- The whole file is checked first: every missing folder, duplicate name and misspelled
  key is reported together, and nothing changes until the file is clean.
- Without `--prune`, projects missing from the file stay registered. The plan lists
  them.
- A project whose folder, extra folders or name changed has its environment rewritten
  in every instance. That resets Desktop settings such as the model for that
  environment.
- An environment belongs to an account, so before the first sign-in only the folder is
  trusted. The environment itself is written on the first `start` after you sign in.
  In a profile that has seen several accounts, every account gets the project.
- An environment that already exists for the same folder is left alone, including its
  name, model and other settings.
- **Claude reads the list file only once per account.** Claude Desktop keeps
  environments in its own UI storage (the profile's `Local Storage`). It imports
  `ccd-session-presets.json` the first time the account opens in that profile, then
  overwrites the file with its own list. So:
  - Projects written before the first sign-in show up on their own.
  - In an instance that has already been opened, stop it and run
    `claude-orchestrator project sync --reset-desktop` (or
    `project apply --reset-desktop`). This moves the profile's `Local Storage` to
    `Local Storage.bak-<time>` and writes the full list, and Claude imports it on the
    next start.
  - Sign-in is not affected, since cookies live elsewhere. The instance does lose its
    UI preferences, such as sidebar layout and dismissed tips.
  - Instances that are running are refused, because a running Claude would write its
    list back.
  - `apply` and `sync` warn when they add environments to an instance that needs this.
- `project remove` keeps a folder trusted if another project or the instance's workdir
  still uses it.

## Shared CLAUDE.md

Each instance has its own Claude Code config directory, so it doesn't read your
`~/.claude/CLAUDE.md`. `memory` links that file into every instance, so your global
instructions are the same everywhere and you edit them in one place:

```bash
claude-orchestrator memory status          # which instances are linked
claude-orchestrator memory link            # link every instance
claude-orchestrator memory link --force    # also replace an instance's own CLAUDE.md (kept as a backup)
claude-orchestrator memory unlink          # remove the links
```

New instances, and instances started without a CLAUDE.md, are linked automatically. An
instance's own CLAUDE.md is never overwritten without `--force`.

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

### Interactive move

Run `session move` with no arguments to pick everything on screen:

```bash
claude-orchestrator session move
```

1. **Pick the session.** Type to fuzzy-filter by title, account or project folder
   (case and Turkish letters are ignored), move with ↑/↓ (or Ctrl-P/Ctrl-N), press Enter.
2. **Pick the target account.** Every account except the session's owner is listed. This
   screen is skipped when there is only one other account.
3. **Confirm.** The Claude instances of both accounts that are running are shut down one
   after the other, the session is moved, and they are reopened. Press `y` to go ahead;
   Esc goes back a screen.

`session move <id>` opens only the screens it still needs, and `--to` / `--instance`
narrow the choice; `--yes` skips the confirmation. Passing both an id and `--to` keeps
the old, non-interactive behaviour. Run it from a regular terminal: started from inside
an instance it would have to shut down (a Code tab terminal), it refuses.

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
