# same-sesh

**Pick up your AI terminal sessions after a restart.**

same-sesh saves which conversations you have open and where you’re working.
After a restart, run `restore` to reopen them in their original folders. The
watcher checks for open sessions about every 30 seconds.

![same-sesh illustration of terminal sessions reopening after a restart, with macOS, Windows, and Linux badges.](assets/same-sesh-hero.png)

## Quick start

Clone the repo with a GitHub account that has access. Run the commands from
the checkout. For WSL2, clone and run them **inside Ubuntu** in its Linux filesystem.

```sh
git clone git@github.com:moonbox3/same-sesh.git
cd same-sesh
```

| Task | macOS (preview) | Windows | Linux on WSL2 (preview) |
| --- | --- | --- | --- |
| Terminal | cmux, Terminal.app, iTerm2, Ghostty | Windows Terminal | Windows Terminal tabs running WSL, or tmux inside WSL |
| Set up automatic saves | `./same-sesh setup` | `.\same-sesh.cmd install` | `./same-sesh install` |
| Check watcher and last save | `./same-sesh status` | `.\same-sesh.cmd status` | `./same-sesh status` |
| List saved sessions and named snapshots | `./same-sesh list` | `.\same-sesh.cmd list` | `./same-sesh list` |
| Preview restore | `./same-sesh restore --dry-run` | `.\same-sesh.cmd restore -DryRun` | `./same-sesh restore --dry-run` |
| Restore after a restart | `./same-sesh restore` | `.\same-sesh.cmd restore` | `./same-sesh restore` |
| [Save a named snapshot](#save-a-named-snapshot) | `./same-sesh snapshot --name release` | `.\same-sesh.cmd snapshot -Name release` | `./same-sesh snapshot --name release` |
| Restore by name | `./same-sesh restore --name release` | `.\same-sesh.cmd restore -Name release` | `./same-sesh restore --name release` |

- **macOS:** Setup asks which terminal app to watch and installs a copy in
  `~/.local/share/same-sesh`. Use `same-sesh` from anywhere once
  `~/.local/bin` is on your PATH. Terminal.app, iTerm2, and Ghostty may ask
  for Automation permission when you restore. cmux needs socket access.
- **Windows:** Use `same-sesh.cmd` from PowerShell 7, Windows PowerShell,
  or Command Prompt. The launcher starts the built-in `powershell.exe` for
  the script and login watcher. Keep the checkout where you installed it.
- **Linux on WSL2:** Use Ubuntu’s `python3` and a signed-in **Linux Copilot
  CLI**. Direct Windows Terminal tabs running WSL work without tmux. Keep the
  checkout in place for the systemd user timer. Without a systemd user manager,
  run `./same-sesh watch` in a separate terminal.

## What restores

| Session | macOS | Windows | Linux on WSL2 |
| --- | --- | --- | --- |
| GitHub Copilot CLI | Exact session or picker | Exact native Windows session or picker | Exact Linux session or picker |
| Claude Code | Exact session or picker | Exact session or most recent in the folder | — |
| Codex CLI | Session picker | Session picker or ID from the launch command | — |
| Shell or other command | Reopens the folder and shows what was running | Reopens the folder and shows what was running | tmux panes only. Reopens the folder and shows what was running. |

Exact Codex restore on Windows requires an ID in the running
`codex resume <id>` command and remains unverified.

Restore skips identifiable conversations that are already open. After a new
login or WSL distro restart, the first restore prefers the previous snapshot.
If there’s nothing to capture, the last saved list stays available. Run
`snapshot` before restarting to save changes that haven’t been picked up yet.

The tools redraw their conversation history when they resume. Terminal
scrollback and pane layouts are outside the snapshot. Restore opens new tabs in
Windows Terminal, new workspaces in cmux, new windows in the other macOS
terminals, or new tmux windows for saved tmux panes.

## Save a named snapshot

Use a name for a group of sessions you want to come back to later. Run
`list` (or run same-sesh with no arguments) to see the current restore
preview and your named snapshots. Use `history` for older automatic saves.

Put names with spaces in quotes, as in `"Before deploy"`.
You can add `--dry-run` (Windows: `-DryRun`) to preview a named restore.
Names are case-insensitive and can contain up to 64 letters, numbers, spaces,
hyphens, or underscores. Start with a letter or number and choose a new name
for each save. Named snapshots live in `~/.same-sesh/named` and are kept
separately from rotating history.

## Other commands

Use the same launcher as in the Quick Start.

| Argument | What it does |
| --- | --- |
| `snapshot` | Save the current sessions immediately. |
| `history` | List snapshots, starting at index 0 for the newest. |
| `restore --index N` | Restore an older snapshot. On Windows, use `restore -Index N`. |
| `watch` | Save periodically in the foreground until stopped. |
| `uninstall` | Stop automatic saves and remove the watcher. Snapshots are kept. |
| `pause` / `resume` | Pause or resume automatic saves on macOS. |

## Platform notes

### WSL2 and tmux

Run `install` from **outside tmux** to watch both direct Windows Terminal
sessions and the default tmux server. Installing from inside tmux remembers that
server’s socket. To select a specific server, set `SAME_SESH_TMUX_SOCKET` to its
absolute socket path. Direct Windows Terminal restore needs WSL interop.
VS Code’s integrated terminal falls outside the preview.

The timer runs while the WSL distro is active and starts again after Ubuntu
starts. See timer errors with `journalctl --user -u same-sesh.service`.
If you use a custom `COPILOT_HOME`, set it for capture and restore.

### macOS install options

`./install.sh` starts the same setup as `./same-sesh setup`. To try the
unpublished npm launcher from a checkout, run
`npm exec --yes --package=. -- same-sesh setup`. The installed copy and
watcher run without Node.

For a GitHub release with a standalone `same-sesh` asset, use
`./install.sh --release VERSION SHA256` and the digest from the trusted
release announcement.

## Snapshot privacy

Snapshots in `~/.same-sesh` can contain working paths, session IDs, titles,
and part of your prompts. Keep them private. Restore only launches supported
tools. Other saved commands are displayed as text.

On macOS, set the matching `COPILOT_HOME` or `CLAUDE_CONFIG_DIR` in the shell
running restore if the session used a custom configuration directory. On Linux,
a custom `SAME_SESH_STATE_DIR` must be a user-owned private directory (mode
`0700`). The state directory and its `history` subdirectory must be real
directories.

## Development and validation

- macOS: `./macos/same-sesh.tests.js`
- Windows: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\windows\same-sesh.tests.ps1`
- Linux: `python3 linux/same-sesh.tests.py`

Live restore was verified for Claude and Copilot in cmux, and for Copilot in
Terminal.app, iTerm2, and Ghostty. A full macOS logout and login still needs
testing. On Ubuntu 24.04 under WSL2, two Copilot conversations in the same
directory restored by ID after a distro restart. Other Linux distributions
remain unverified. See [AGENTS.md](AGENTS.md) for adapter guidance.
