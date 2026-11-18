# same-sesh Linux/WSL2 handoff

## Goal

Build and live-test the first Linux adapter for same-sesh. Start with GitHub
Copilot CLI inside Ubuntu 24.04 on WSL2, in tmux panes. Show that Copilot
conversations survive restarting the distro and reopen by session ID in their
original working directories.

Repo: https://github.com/moonbox3/same-sesh. Pull current main and read
`AGENTS.md` and `README.md`. At this handoff main is `b6b4816` and contains
macOS and Windows implementations. Linux and WSL capture have yet to be
implemented. Native Windows Copilot already has a separate adapter. Some old
clones predate a history rewrite. If Git reports unrelated histories, use a
fresh clone or preserve local changes before updating the checkout.

## Test host

The Windows machine already shows `Ubuntu2404` at version 2 in
`wsl --list --verbose`. The user is setting up tmux and native Linux Copilot
inside that distro. From PowerShell, open it with `wsl -d Ubuntu2404`. In Ubuntu,
check:

```sh
tmux -V
command -v copilot
copilot --version
ps -p 1 -o comm=
systemctl --user list-timers --no-pager
```

Use the Linux Copilot binary and sign in inside Ubuntu. Keep the test checkout
and fixtures in the distro's Linux home. A Windows Copilot binary launched
through WSL interop does not exercise the Linux adapter. Use a dedicated tmux
server or session and an isolated same-sesh state directory. Never use
`~/.same-sesh` for fixtures, inspect real conversations, or put real session IDs
or prompts in commits or logs. Ask the user to close any live test terminals
when needed, per `AGENTS.md`.

## Implementation order

1. **Capture from tmux.** Put the runtime and tests in `linux/`. Use tmux's
   pane ID, TTY, PID, path, and foreground metadata. On Linux, inspect the
   process tree and foreground process group to locate the real Copilot process
   under a pane. Account for npm wrappers, nonselected panes, and nested
   processes. Determine the Copilot PID and directory from live evidence.
   Test against the intended tmux server explicitly when using a separate
   socket. Keep the runtime standalone and follow the repo's dependency
   constraint. Verify tools available on the target, and discuss a runtime
   dependency only if one proves necessary.
2. **Resolve Copilot sessions.** Use `Resolve-Copilot` in
   `windows/same-sesh.ps1` and `resolveTool` / `copilotIdentity` in
   `macos/same-sesh` as references. Confirm the Linux CLI's actual PID records,
   lock files and foreground registration logs with synthetic sessions. Check
   PID lifetime before trusting a record, and identify the log belonging to
   the live process, including custom log directories if supported. Exercise a
   fresh session and switching within the same process. When identity is
   ambiguous, open Copilot's picker. Folder and timestamp cannot disambiguate
   two conversations in the same directory.
3. **Save and restore.** Follow the existing v1 snapshot semantics in macOS
   `save` / `select` and Windows `Save-Snapshot` / `Select-Snapshot`. Keep
   terminal handles out of portable tab records. Preserve the most recent
   nonempty snapshot, archive changes, and select the previous instance's
   snapshot on the first restore after restart. Verify the instance boundary
   on WSL before choosing how to identify it. Rebuild resume from allowlisted
   tool names and validated IDs. Pass folders and session inputs as data.
   Preserve custom tool configuration trust rules. Arbitrary recorded
   commands are display text. Implement `snapshot`, `list`, `history`,
   `restore --dry-run`, `restore`, and deduplication.
4. **Add watcher once manual restore works.** Aim for `watch`, `status`,
   `install` and `uninstall` using a user-level systemd timer for periodic
   captures. Keep foreground `watch` usable when the user service manager
   is unavailable. Verify that captures can find the selected tmux server from
   outside an interactive shell, and that status distinguishes whether automatic
   saving is running from when the latest nonempty snapshot was saved. Document
   the behavior on WSL, where systemd services do not keep the distro alive.

Keep Windows and macOS entry points compatible. Scope the first working
implementation to tmux and Copilot. Treat direct WSL tabs without tmux, Claude,
Codex, and broader Linux testing as follow-up coverage unless the user asks
otherwise. Update README only with support you actually validated.

## Live acceptance checks

- Start two Copilot conversations with distinct harmless prompts in separate
  tmux panes in the **same Linux directory**. Add a third in a different
  directory if available. Capture and verify the IDs, directories, and last
  prompts. Check at least one session launched without an explicit resume ID.
- Switch one Copilot pane to a different synthetic conversation without
  restarting its process. Confirm capture follows the foreground conversation
  or falls back to the picker when the signal is ambiguous.
- Dry-run restore and confirm no new panes appear. After the user closes the
  test panes, restore them, verify exact IDs and working directories, and
  confirm a second restore opens zero duplicates. Use a fixture directory with
  spaces and an apostrophe to exercise quoting.
- Check that capture leaves the previous snapshot intact when tmux has no live
  test panes. Repeated watcher installation should leave one timer. Confirm
  uninstall stops automatic saving and preserves snapshots.
- For the restart test, record a baseline and verify a background save. Ask the
  user to save work and terminate **only** the test distro when ready. From
  Windows PowerShell the command is `wsl --terminate Ubuntu2404`. Reopen with
  `wsl -d Ubuntu2404`. Before reinstalling or manually starting the watcher,
  inspect whether the user timer started, allow a new shell to be captured,
  then verify that first restore still selects the pre-restart conversations.
  Verify duplicate skipping again. Report this as a WSL distro restart test.

Use synthetic regression tests for capture attribution, same-folder matching,
ambiguous IDs, quoting and empty snapshot preservation. Run them through the
normal Linux entry point and report any live checks still pending.

## References

- Repo behavior and security requirements: `AGENTS.md` and `README.md`
- [tmux format reference](https://github.com/tmux/tmux/wiki/Formats)
- [systemd timer reference](https://freedesktop.org/software/systemd/man/latest/systemd.timer.html)
- [Microsoft's WSL systemd guide](https://learn.microsoft.com/en-us/windows/wsl/systemd)
- [Microsoft's WSL command reference](https://learn.microsoft.com/en-us/windows/wsl/basic-commands)

## Suggested skills

- `diagnosing-bugs` if real tmux process ownership or watcher startup differs
  from the portable test fixtures.
- `handoff` if the implementation and live WSL checks need to continue in
  separate chats.
