# TODO

Work planned after `claude-ctl` v0.1.0 (2026-11-08). **Update 2026-11-08:**
§1 and §2 are done (the tool is now `claude-orchestrator`); what remains open is the §3
research topics and the distribution work in §4. Each item notes what was done or why it
was not done. Sections are ordered by
dependency, not priority: §1 is the backbone of the roadmap, §2–§4 is work that
complements it or is unblocked by it.

Status markers: `[ ]` not done · `[~]` partly done · `[x]` done

---

## 1. Session management: moving conversations between instances

Today `claude-ctl` manages **instances**; each instance has its own Claude Code config
directory, but sessions are locked inside that instance. Goal: make sessions portable
between instances — the "send instance 1's last session to instance 2" scenario.

### 1.1 Command name: `claude-ctl` → `claude-orchestrator` `[x]`

The tool is no longer just a multi-instance tool but a **session orchestration** tool; its
name should reflect that.

- [x] Make the package/binary/product name `claude-orchestrator` (`Package.swift` `name`/`products`,
      the `ClaudeCtlCore`/`ClaudeCtlAgent` module names, the `ClaudeCtl` type → `Orchestrator`)
      → `OrchestratorCore`, `OrchestratorAgent`, `Orchestrator`, `OrchestratorError`
- [x] Update the `Output`/`Usage` text and the README
- [x] Rename the Homebrew formula (`Formula/claude-orchestrator.rb`) → tap:
      [Yuix-Networks/homebrew-tap](https://github.com/Yuix-Networks/homebrew-tap); plus
      `install.sh` (curl). The tap formula's `url`/`sha256` are updated by hand for every release
- [x] Make the release workflow produce the new name
- [x] **Breaking change**: add a `claude-ctl` → `claude-orchestrator` redirect for v0.1.0
      users (a symlink for the old name, or a "this command has moved" warning)
      → **Decision (v0.2.3): no redirect.** The `claude-ctl` alias was removed; the only
      command is `claude-orchestrator`. The data directory and the LaunchAgent label keep the old name
- [x] Data directory name decision: keep `~/Library/Application Support/claude-ctl/`, or
      switch to `claude-orchestrator/`? (Keeping it → existing instances don't break; changing it
      needs a migration. **Recommendation: keep it.**) → **Kept.** The LaunchAgent label
      `com.claude-ctl.agent` was kept for the same reason.

### 1.2 The session model and where it lives `[x]`

Claude Code sessions live under the instance's `CLAUDE_CONFIG_DIR` (= `claude-code/`):

```
<config-dir>/
├── projects/<cwd-slug>/
│   ├── <session-id>.jsonl              # session transcript (one message per line)
│   ├── <session-id>/subagents/*.jsonl  # subagent transcripts
│   └── sessions-index.json             # project session index
├── history.jsonl                       # command history
└── todos/<session-id>.json             # the session's TODO files
```

- [x] A `SessionStore` type that reads the `<config-dir>` tree and builds the session list
      (id, cwd-slug, real cwd, start/end time, message count, first/last message summary)
      → on a real setup with 3.2 GB / 665 transcripts, full JSON decoding took 39 s; with mmap +
      a byte-pattern filter it took 5 s, and 0.3 s with a path/size/mtime cache. The Desktop title
      comes from `<profile>/claude-code-sessions/<account>/<org>/local_*.json` → matched on `cliSessionId`
- [x] `cwd-slug` resolution: `/Users/x/workspace/vpn` → `-Users-x-workspace-vpn`
      (careful: `a-b` and `a/b` map to the same slug → collisions must be detected)
      → if `originalPath` in the target's `sessions-index.json` differs, the transfer is refused
- [x] Claude Desktop's **own chat history** is a separate topic — it lives in the profile under
      `IndexedDB/https_claude.ai_0.indexeddb.leveldb` and is tied to the account.
      Can it be transferred? (see §1.5) → no, see the §1.5 decision

### 1.3 The `session` command family `[x]`

```
claude-orchestrator session list [--instance <name>] [--project <path>] [--json]
claude-orchestrator session show <session-id> [--instance <name>]
claude-orchestrator session move <session-id> --to <instance> [--force]
claude-orchestrator session copy <session-id> --to <instance>
claude-orchestrator session last --from <instance> --to <instance>
```

- [x] `list`: show the sessions of every instance in one table (instance, project, time,
      message count); default: running instances → **deviation:** the default is *all*
      instances, `--running` shows only running ones (an empty list when no instance was
      running was confusing)
- [x] `show`: details of one session (cwd, message preview, tool calls, duration)
- [x] `move`: **move** the session into the target instance's config directory (the source is removed)
- [x] `copy`: copy it (the source stays)
- [x] `last --from --to`: "move instance 1's last session to instance 2" — a shortcut for the
      requested scenario (`move` + picking the latest); `--copy` copies instead
- [x] Every command supports `--json` (consistent with the existing commands)
- [x] Extra: the name `default` refers to the Claude install outside any instance (`~/.claude`); a new
      instance can't be given this name. A unique prefix is accepted in place of a session id

### 1.4 Transfer mechanics `[x]`

- [x] Files to copy: `projects/<slug>/<session-id>.jsonl`, and if present
      `projects/<slug>/<session-id>/` (subagents), `todos/<session-id>.json`,
      plus adding/updating the entry in the target's `sessions-index.json` (absolute
      config paths in the entry are rewritten for the target). In addition, the Desktop sidebar
      metadata is written to the target's active account/org directory, with the account-bound fields
      dropped — **experimental:** not verified live with two signed-in accounts
- [x] **If the target instance is running**, warn (file lock risk) — either stop it or
      continue with `--force` (`move` also requires the source to be stopped)
- [x] Warn if the target instance's CLI version differs from the source (the transcript format may change)
- [x] Collisions: define clearly what happens if the target already has the same `session-id`
      (default: refuse, overwrite with `--force`)
- [~] Post-transfer check: does `claude --resume <session-id>` work in the target?
      (automated test: `session show` can see the session in the target) → if the target
      `SessionStore` can't find the session at the end of the transfer, it's an error; the smoke test checks
      it with `session show`. A real `claude --resume` needs a signed-in instance, so it wasn't automated
- [x] Copying must be **atomic** (no half-written transcripts): temporary file + rename
- [x] Undo: take a backup before `move`? (`backups/`, similar to Claude Code's own
      `~/.claude/backups` mechanism) → `move` doesn't delete the source; it moves it to
      `backups/<time>-<id>/` (+ `manifest.json`). There is no automatic restore
      command; the files can be put back by hand

### 1.5 Claude Desktop chat history (a separate, hard topic) `[x]` — decision: won't do

- [x] The Chat tab's conversations are in the profile's IndexedDB and tied to the account (claude.ai).
      If the instances are signed in with different accounts, what would moving even mean? Decide
      → Chats live on the claude.ai server; IndexedDB is only a cache. An instance with the same
      account already sees them, and an instance with a different account can't. Moving them is pointless.
- [x] Is moving between two instances with the same account possible? (copying IndexedDB
      while the app is closed, keeping LevelDB intact)
- [x] Alternative: **sharing** (symlink) instead of moving — not needed (reason above) — like what Parall does for Cowork

### 1.6 Instance lifecycle `[x]`

- [x] The `new` command can create an instance **with sessions** instead of "empty"
      ("create a new instance that already has sessions in it") → `new --sessions-from`.
      Also, `--workdir` is now optional (the one-instance-per-account scenario)
- [x] `remove --purge` must delete sessions too (it currently deletes the config directory ✓ verify)
- [x] Instance cloning: `claude-orchestrator clone <instance> --as <new-name>` —
      with profile + config directory + sessions → `clone <name> --as <new>`; refused while the
      source is running; APFS clone (~0 extra disk in a 400 MB trial)

### 1.7 Shared projects (Desktop "environment") `[x]`

- [x] Projects are in a central registry (`config.json` → `projects`); `project add/list/remove/sync/import`
      (alias `env`). Environment = `ccd-session-presets.json` → `byAccount[account].presets[]`
- [x] `new` and every `start` apply the registered projects; before sign in, only the trusted folder
- [x] Written to every account in the profile; settings of an existing environment for the same folder are left untouched
- [ ] Live check: not yet confirmed by eye that a written environment shows up in the Code tab of a
      signed-in instance (the file format matches the environments in a real profile)
- [x] `project apply` / `project export`: a hand-edited `projects.json`
      (`~/.config/claude-orchestrator/`), the whole file is validated first, `--dry-run`, `--prune`
- [x] `defaults` (shared additional folders, permission mode) and per-project `permissionMode`
      (`preferences.epitaxyPrefs` → `epitaxy-folder-permission-mode-v2.<account>`); the org restriction
      (`bypassPermissionsGateByAccount`) is left untouched
- [ ] Not confirmed by eye on a signed-in instance that Desktop actually selects the permission mode
      as the default (the keys have the same format as the entries in a real profile)
- [x] `memory`: `~/.claude/CLAUDE.md` is symlinked into every instance's config directory
- [x] Desktop keeps the environment list in its UI store (`Local Storage` → `ccd-session-presets.<account>`);
      it imports `ccd-session-presets.json` only on the first launch per account
      (`fileMirrored`) and overwrites it after that. `--reset-desktop` backs up `Local Storage` while the profile
      is closed and makes Desktop import the list again (verified live on serdar: 41 environments
      kept after launch, Claude did not rewrite the file)
- [ ] A more precise approach: edit only the `ccd-session-presets.<account>` key in LevelDB
      (keeps UI preferences; depends on Claude's internal format)
- [ ] No instant update for a running instance (Claude keeps the file in memory; a
      restart is needed)

---

## 2. Deferred review findings `[x]`

Small items found in the code review of `claude-ctl v1` and deliberately deferred.
All of them work, but they are low priority.

- [x] `list --json` output uses an `{"instances":[…]}` wrapper; a flat array is expected,
      backward compatibility is needed. (JSON type fixed: `profileSizeBytes` is now a number.)
      → **Decision: the wrapper stays** (the smoke test and scripts depend on the `instances` key;
      the wrapper allows adding new fields). `schemaVersion: 1` added to all JSON output
- [x] With multiple accounts, seeding picks the **alphabetically first** account; there is no logic
      to find the active account → the preset can be written to the wrong account
      (`ProfileSeeder.addSessionPreset`) → `config.json` → `lastKnownAccountUuid`, then
      `bootSideSessions.accountUuid`; if it's ambiguous, no preset is written (no guessing)
- [x] `LogReader` loads the whole `main.log` into memory (unnecessary for the last N lines);
      `logs -f` doesn't follow file rotation, and following silently stops
      → reads backwards from the end in 64 KB blocks; `LogFollower` detects inode/size changes
- [x] A `launchctl bootstrap` failure is swallowed; the CLI says "installed" but the agent may not
      be loaded. Also `KeepAlive: true` + a duplicate launch causes a launchctl respawn loop
      (`LaunchAgentInstaller`, `AgentCommand`) → `bootout` first, a `bootstrap` failure
      is reported; `KeepAlive: {SuccessfulExit: false}` and a second copy exits with 0
- [x] The agent singleton lock is taken with write-then-read instead of `O_EXCL` → a TOCTOU race;
      also a stale PID file makes the agent permanently say "already running"
      (`StatusItemController.acquireSingleton`) → `flock` on `agent.lock`
- [x] No confirmation/backup for `remove --purge`; one command deletes ~500 MB + sessions
      → it asks for confirmation (`--yes` is required without a terminal), Trash by default, `--permanent`
      for permanent deletion
- [x] `ProfileSeeder.seed(instanceName:workdir:)` is dead code → removed
- [x] `StatusItemController.refresh()` mutates the `statusItems` dictionary while iterating
      (safe today, fragile) and rebuilds every menu every 5 seconds (needless UI
      flicker) → iterates over a copy of the keys; a menu is rebuilt only
      when the state changes. Extra: added "Start" to the menu for stopped instances

---

## 3. Removing known limitations

Items documented as "known limitations" in the README. None of them blocked v1.

- [ ] **Separate Dock icon / menu bar name.** Instances share the same Claude icon.
      A separate identity needs the target app's bundle identity to change; that path runs into macOS's
      hardened-runtime / library-validation walls (an Electron clone was tried:
      sandbox extension + helper naming blockers). Parall solved this with reverse
      engineering — reproducing it as open source is a research project of its own.
      Middle ground: badged menu bar icon (exists) + a channel like `app.dock.setBadge`
- [ ] **Shared log files** (`~/Library/Logs/Claude/`). Per-instance logs need
      `app.setPath("logs", …)`; Claude only does this under `CLAUDE_USER_DATA_DIR`
      (ignored in signed builds). `logs` currently filters by start time
      (no exact separation)
- [~] **`claude://` handler conflict.** The deep link goes to a single instance; the measurement
      (which instance it goes to) still hasn't been done → can be solved together with §1.1/§1.3
      → `signin --exclusive` closes the other instances during sign in and reopens them afterwards;
      it warns if a Claude outside any instance is open. Not measured: sending a test URL to the user's
      open main Claude was risky
- [ ] **Each instance downloads its own Claude Code CLI** (~525 MB per instance).
      Sharing (symlink) or a "one CLI, many config dirs" mode could be explored
      → Finding: the CLI is not in `CLAUDE_CONFIG_DIR` but in the **profile** (`<profile>/claude-code/<version>/`).
      Since `clone` uses an APFS clone, a cloned instance takes no extra space; sharing for
      separately created instances is still open (risk of a concurrent-update race)

---

## 4. Infrastructure and maintenance

- [ ] CI: alongside `swift test`, a smoke job on **macOS 13** (Ventura, the minimum version for
      `open --env`) — `open --env` behavior may vary by version
      → GitHub has retired the `macos-13` runners; also the smoke test needs an installed
      Claude Desktop. Not possible without a self-hosted runner
- [ ] CI: the release workflow builds a universal binary with `xcodebuild` ✓; it uses the `macos-15`
      runner (because of an arm64 runner issue) — runner availability should be watched
- [~] Formula checks with `brew audit --strict` / `brew style` → `brew style` is clean;
      `brew audit --strict` needs a tap, and the sha256 is only known after the release
- [ ] Code signing and notarization: distribution works through `brew`, but the directly
      downloaded binary is unsigned — should a signed/notarized build be produced?
- [ ] Multi-arch testing: `swift test` only runs on arm64; separate verification
      for `x86_64` (Intel)
- [x] Version the `doctor` JSON output schema (for future automation) → all JSON
      output has `schemaVersion`
