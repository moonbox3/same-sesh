# Guide for agents working on same-sesh

Read `README.md` for what the tool does. If `HANDOFF.md` exists, it describes
the task currently in progress: read it before starting.

## Layout

The Windows implementation is in `same-sesh.ps1`; `same-sesh.cmd` only launches it. The script
is organised in the order below, and each part is meant to be replaceable.

- **Terminal adapter, capture side** (`$TerminalHosts`, `Get-LiveTabs`): which
  processes host tabs. A tab is a direct child of a terminal host process.
- **Tool adapters** (`Resolve-Claude`, `Resolve-Copilot`, `Resolve-Codex`):
  given a process, return `$null` or a hashtable with `tool`, `sessionId`,
  `cwd`, `title`, `resume`, `lastPrompt`, `lastActive`. `resume` is the exact
  command that reopens the session.
- **Snapshot storage** (`Save-Snapshot`, `Select-Snapshot`): JSON in
  `~/.same-sesh` (`last.json` plus `history/`).
- **Terminal adapter, restore side** (`ConvertTo-WtTab`, `Restore-Snapshot`):
  builds one `wt` command line.

To add a tool, write a `Resolve-<Tool>` function and call it in the adapter
chain inside `Get-LiveTabs`. Nothing else should need to change.

The macOS implementation is the executable `same-sesh`, one JavaScript for
Automation file using built-in osascript/Foundation. `inventory` chooses cmux API inventory or native macOS process/TTY ownership;
`capture` consumes that common surface inventory; `foreground` excludes nested/background agents;
`resolveTool` reads session metadata. `save`/`select` share version-1 snapshot
semantics, `restoreArgs` constructs recognized commands, and `service` manages
the launchd agent. `setup` installs a stable native copy and checks watcher
health; the optional npm launcher only bootstraps this native runtime.
Terminal.app/iTerm2/Ghostty capture must remain process-only: Apple events can
block under launchd even when they work interactively. Restore uses native
scripting APIs and may require the user to approve macOS Automation access. `same-sesh.tests.js` contains synthetic macOS checks.

## Constraints

- Windows code must run on **Windows PowerShell 5.1**: no `&&`, `||`, `?:`, `??` or `?.`,
  and no `ConvertFrom-Json -AsHashtable`.
- No additional runtime dependencies and no install step. One script file per platform.
- The snapshot format stays OS-neutral. Do not put Windows-only concepts in it;
  macOS (cmux) shares it; Linux (tmux) is planned to share it.
- Never re-run an arbitrary recorded command on restore. Only known tools'
  resume commands are run; everything else is shown, not executed.
- Never record an empty state. That is what the machine looks like right after
  a restart, and it would overwrite the snapshot the user needs.

## Things already learned the hard way

- **State lives in the home folder, not AppData.** Packaged (MSIX) apps get a
  private copy of AppData, so a snapshot written from a shell running inside
  one is invisible to a normal terminal.
- **Claude writes `~/.claude/sessions/<pid>.json` late**, only once the session
  is interactive. The adapter falls back to the `--resume <id>` on the command
  line, then to `claude --continue`.
- **Those PID files go stale** after the process exits, and PIDs are reused.
  Compare `procStart` with the process creation time before trusting one.
- **`return , $array` from a helper breaks pipelines**: the whole array arrives
  as one item. Emit arrays unwrapped when the caller pipes them.
- **A PowerShell shell's own working directory is its startup folder**; `cd`
  does not change it. A child process does get the real current folder, so read
  the working directory from the tool process, not the shell.
- **Restore commands are passed with `-EncodedCommand`** so that `wt` cannot
  split them on `;` and no quoting can go wrong.

## Testing

On macOS run `./same-sesh.tests.js`. Use `SAME_SESH_STATE_DIR` for isolated live
checks; never replace the user's real snapshots with test-only data. cmux socket
access must allow Automation for the launchd watcher. One captured terminal is
one live terminal surface, not a direct child of the cmux app. Claude macOS PID
records use a UTC text `procStart`; `startedAt` is the later interactive-session
time and cannot validate the process lifetime. Copilot may log outside its home
directory; inspect the owning process's open log, never a child process's log.
Do not close test terminals automatically: ask the user, then verify restore.

Run `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\same-sesh.tests.ps1`
for dependency-free checks with synthetic sessions. Also test against live tabs:

1. Open Windows Terminal tabs with the tool under test running in them.
2. `.\same-sesh.cmd snapshot` and check each tab's tool, folder, session ID and
   last prompt. The raw result is `~/.same-sesh/last.json`.
3. `.\same-sesh.cmd restore -DryRun` prints the `wt` command without running it.
4. Close the tabs, then `.\same-sesh.cmd restore`.

Do not kill `WindowsTerminal.exe` to simulate a restart: it is a single process
for every window and takes the user's real tabs with it. Ask the user to close
the test tabs.

Sessions on the machine are the user's real conversations. Read session files
only as far as needed, and do not paste their contents into commits or docs.
