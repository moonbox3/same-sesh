# same-sesh

**Reopen your AI terminal sessions after a restart on macOS or Windows.**

Your coding assistant keeps the conversation. same-sesh remembers which
conversations were open, where you were working, and the last prompt when it’s
available. A background watcher saves that information about every 30 seconds.
After a restart, one command reopens the sessions it can identify.

![Illustrated macOS and Windows previews showing a saved coding assistant, working folder, and last prompt. All sessions are synthetic.](assets/same-sesh-preview.png)

## Quick start

With a GitHub account that has access, clone the repository and open the checkout
in the terminal you want to use.

```sh
git clone git@github.com:moonbox3/same-sesh.git
cd same-sesh
```

| | macOS (preview) | Windows |
| --- | --- | --- |
| Terminals | cmux, Terminal.app, iTerm2, Ghostty | Windows Terminal |
| Start saving automatically | `./same-sesh setup` | `.\same-sesh.cmd install` |
| See the saved sessions | `same-sesh` | `.\same-sesh.cmd` |
| Preview restore | `same-sesh restore --dry-run` | `.\same-sesh.cmd restore -DryRun` |
| Restore | `same-sesh restore` | `.\same-sesh.cmd restore` |

On **macOS**, guided setup detects installed terminals, remembers your selection,
and checks that the watcher can capture sessions. It installs a native copy in
`~/.local/share/same-sesh` and a command in `~/.local/bin`. If your current shell
can’t find it yet, follow the PATH instruction printed by setup or use
`./same-sesh` from the checkout. Terminal.app, iTerm2, and Ghostty may prompt for
Automation permission on restore. cmux requires socket access for automation.

On **Windows**, install starts the watcher and registers it to run at login.
Keep the checkout in place and run commands through `same-sesh.cmd` using the
built-in Windows PowerShell 5.1 runtime.

Both platforms use their built-in runtimes and run as your user.

## Session support

| Session | macOS | Windows |
| --- | --- | --- |
| Claude Code | Exact resume when same-sesh identifies the session. Otherwise, opens the picker. | Exact resume when same-sesh identifies the session. Otherwise, continues the latest conversation in that folder. |
| GitHub Copilot CLI | Exact foreground session when identifiable. Otherwise, opens the picker. | Same. |
| Codex CLI | Reopens the working folder and launches the Codex session picker. | Uses the session ID when visible in a running `codex resume <id>` command. Otherwise, opens the picker. Exact restore is unverified. |
| Shell or other command | Reopens the folder and displays what was running. | Same. |

On macOS, same-sesh captures one selected terminal app. Restore opens a new cmux
workspace or native terminal window for each entry. Windows opens tabs in one
Windows Terminal window. Tools redraw their own conversation history on resume.
Pane layout and scrollback are outside the snapshot.

## Everyday commands

Use the platform command shown above with these arguments.

| Command | What it does |
| --- | --- |
| `snapshot` | Save the current sessions immediately. |
| `history` | List snapshots, numbered from newest at index 0. |
| `restore --index N` / `restore -Index N` | Restore a specific snapshot on macOS / Windows. |
| `watch` | Save periodically in the current terminal until stopped. |
| `uninstall` | Remove automatic saving and keep the snapshots. |
| `status`, `pause`, `resume` | On macOS, check or control automatic saving. |

Restore skips identifiable sessions that are already open. The first restore
after a new login is designed to prefer the previous login’s snapshot. Empty
captures preserve the last saved sessions. Use `snapshot` before restarting if
you just opened a session and want to save it immediately.

## Local data and restore

Snapshots and watcher errors live in `~/.same-sesh`. Snapshots can contain
working paths, session IDs, titles, and parts of your prompts. Keep them private.
The shared JSON format works on both platforms, but saved folders must make
sense on the machine where you restore.

Restore builds commands for supported tools from the tool name and session ID.
Other recorded commands are shown as text. On macOS, restoring a session with a
custom tool home requires the corresponding `COPILOT_HOME` or
`CLAUDE_CONFIG_DIR` to be set in the shell running same-sesh.

## macOS installer options

From the checkout, `./install.sh` runs guided setup. The optional npm launcher
uses Node only to start setup. You can try it locally with
`npm exec --yes --package=. -- same-sesh setup`. The npm package is unpublished.

For a GitHub release with a standalone `same-sesh` asset, run
`./install.sh --release VERSION SHA256` with the expected digest from the
trusted release announcement. The installer verifies the download before running it.

## Development

- macOS: `./same-sesh.tests.js`
- Windows: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\same-sesh.tests.ps1`

Live close-and-restore was verified for Claude and Copilot in cmux and for
Copilot in Terminal.app, iTerm2, and Ghostty. An actual macOS logout and login
test is pending. Linux/tmux support is planned. See [AGENTS.md](AGENTS.md) for
adapter guidance.
