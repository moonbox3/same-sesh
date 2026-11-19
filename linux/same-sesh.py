import argparse
import base64
from contextlib import contextmanager
from datetime import datetime, timezone
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import secrets
import shlex
import shutil
import stat
import subprocess
import sys
import time


HOME = Path.home()
STATE = Path(os.environ.get("SAME_SESH_STATE_DIR") or HOME / ".same-sesh")
UUID = re.compile(r"[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}", re.I)
PROC = Path("/proc")
TICKS = os.sysconf("SC_CLK_TCK")


def executable_path():
    return os.pathsep.join(part for part in os.get_exec_path() if Path(part).is_absolute()) or os.defpath


def tmux(*args):
    socket = os.environ.get("SAME_SESH_TMUX_SOCKET")
    command = ["tmux", "-S", socket] if socket else ["tmux"]
    return subprocess.run(command + list(args), capture_output=True, text=True, timeout=10,
                          env=dict(os.environ, LC_ALL="C", PATH=executable_path()))


def process(pid):
    fields = (PROC / str(pid) / "stat").read_text(errors="replace").rsplit(")", 1)[1].split()
    return tuple(int(fields[i]) for i in (1, 2, 4, 5, 19))  # PPID, PGID, TTY, TPGID, start


def epoch():
    # WSL distros can restart independently while sharing a running kernel.
    return f"linux:{(PROC / 'sys/kernel/random/boot_id').read_text().strip()}:{process(1)[4]}"


def argv_for(path):
    return [os.fsdecode(arg) for arg in (path / "cmdline").read_bytes().rstrip(b"\0").split(b"\0")]


def is_copilot(exe, args):
    return exe == "copilot" or (exe in ("node", "nodejs") and len(args) > 1
                               and (Path(args[1]).name == "copilot"
                                    or "/node_modules/@github/copilot/" in args[1]))


def last_line(path, parse):
    try:
        with path.open("rb") as stream:
            pos = stream.seek(0, os.SEEK_END)
            partial = b""
            while pos:
                count = min(pos, 65536)
                pos -= count
                stream.seek(pos)
                partial, *lines = (stream.read(count) + partial).split(b"\n")
                for line in reversed(lines):
                    if value := parse(line):
                        return value
            return parse(partial)
    except FileNotFoundError:
        return None


def prompt(line):
    if b'"user.message"' in line:
        try:
            event = json.loads(line)
        except (ValueError, UnicodeError):
            return None
        if isinstance(event, dict) and event.get("type") == "user.message":
            data = event.get("data")
            if isinstance(data, dict) and isinstance(data.get("content"), str):
                return (data["content"][:500],)
    return None


def process_env(path, *names):
    prefixes = tuple(os.fsencode(name + "=") for name in names)
    return dict(os.fsdecode(item).split("=", 1)
                for item in (path / "environ").read_bytes().split(b"\0")
                if item.startswith(prefixes))


def copilot_tab(pid, p, tab):
    path = PROC / str(pid)
    env = process_env(path, "COPILOT_HOME", "HOME", "PWD")
    if tab["cwd"] == "/var/lib/snapd/void":
        args = argv_for(path)
        logical = next((value for flag, value in zip(args, args[1:]) if flag == "-C"),
                       env.get("PWD", ""))
        if Path(logical).is_absolute() and Path(logical).is_dir():
            tab["cwd"] = logical
    override = env.get("COPILOT_HOME")
    home = Path(env.get("HOME") or HOME) / ".copilot"
    if override:
        home = (Path(tab["cwd"]) / override).resolve()
        tab["toolHome"] = str(home)
    start = time.time() - time.clock_gettime(time.CLOCK_BOOTTIME) + p[4] / TICKS
    sessions = home / "session-state"
    locks = set()
    for folder in sessions.glob("*"):
        if not UUID.fullmatch(folder.name):
            continue
        try:
            if (folder / f"inuse.{pid}.lock").stat().st_mtime >= start:
                locks.add(folder.name)
        except FileNotFoundError:
            continue

    logs = []
    for fd in (path / "fd").iterdir():
        try:
            target = os.readlink(fd)
        except FileNotFoundError:
            continue
        match = re.search(rf"/process-(\d+)-{pid}\.log(?: \(deleted\))?$", target)
        if match and int(match[1]) >= start * 1000:
            # The fd works even when the log path is in a snap mount namespace.
            logs.append((int(match[1]), fd))
    line = last_line(max(logs)[1], lambda raw: re.search(
        rb"\[INFO\] (Registering|Unregistering) foreground session: ([0-9a-fA-F-]+)\s*$",
        raw)) if logs else None
    session = None
    if line:
        candidate = line[2].decode("ascii")
        # Resumed sessions may register in the process log without creating a PID lock.
        if (line[1] == b"Registering" and UUID.fullmatch(candidate)
                and (candidate in locks or
                     (not locks and (sessions / candidate / "events.jsonl").is_file()))):
            session = candidate
    elif len(locks) == 1:
        session = next(iter(locks))
    tab.update(sessionId=session, resume=f"copilot --resume={session}" if session else "copilot --resume")
    if session:
        events = sessions / session / "events.jsonl"
        message = last_line(events, prompt)
        try:
            tab["lastActive"] = iso(events.stat().st_mtime)
        except FileNotFoundError:
            pass
        if message:
            tab["lastPrompt"] = message[0]
    return tab


def tmux_panes():
    if not shutil.which("tmux", path=executable_path()) and not os.environ.get("SAME_SESH_TMUX_SOCKET"):
        return []
    result = tmux("list-panes", "-a", "-F", "#{pane_id}:#{pane_pid}:#{pane_dead}")
    if result.returncode:
        if re.search(r"^no server running on |^error connecting to .+ \(No such file or directory\)\s*$",
                     result.stderr):
            return []
        raise ValueError(result.stderr.strip())
    return [line.split(":") for line in result.stdout.splitlines()]


def capture():
    panes = tmux_panes()
    processes = {}
    for path in PROC.iterdir():
        if path.name.isdecimal():
            try:
                processes[int(path.name)] = process(path.name)
            except (FileNotFoundError, ProcessLookupError, PermissionError):
                continue
    children = {}
    for pid, row in processes.items():
        children.setdefault(row[0], []).append(pid)
    tabs = []
    tmux_ttys = set()
    for pane, root, dead in panes:
        root = int(root)
        if dead != "0" or root not in processes:
            continue
        _, _, tty, foreground, _ = processes[root]
        if not tty or foreground <= 0:
            continue
        tmux_ttys.add(tty)
        todo, candidates = [root], []
        while todo:
            pid = todo.pop()
            p = processes[pid]
            if p[1:3] == (foreground, tty):
                path = PROC / str(pid)
                try:
                    exe = Path(os.readlink(path / "exe")).name
                    if is_copilot(exe, argv_for(path)):
                        candidates.append(pid)
                        continue  # Do not mistake a nested agent for the pane's Copilot.
                except (FileNotFoundError, ProcessLookupError, PermissionError):
                    pass
            todo.extend(children.get(pid, []))
        pid = candidates[0] if len(candidates) == 1 else root
        try:
            path = PROC / str(pid)
            cwd = os.readlink(path / "cwd")
            tab = new_tab(cwd)
            if len(candidates) == 1:
                tab.update(tool="copilot", resume="copilot --resume")
                try:
                    copilot_tab(pid, processes[pid], tab)
                except PermissionError:
                    tab.update(sessionId=None, resume="copilot --resume")
                    print(f"Cannot read Copilot metadata for {pane}; using picker.", file=sys.stderr)
            else:
                leader = processes.get(foreground)
                running = foreground if leader and leader[2] == tty else root
                tab["wasRunning"] = Path(os.readlink(PROC / str(running) / "exe")).name
            if process(pid)[4] == processes[pid][4]:
                tabs.append((pane, tab))
        except (FileNotFoundError, ProcessLookupError, PermissionError):
            continue
    if not os.environ.get("SAME_SESH_TMUX_SOCKET"):
        tabs.extend(windows_terminal_tabs(processes, tmux_ttys))
    return tabs


def new_tab(cwd):
    return dict(tool=None, sessionId=None, cwd=cwd, title=None, resume=None,
                lastPrompt=None, lastActive=None)


def windows_terminal_tabs(processes, tmux_ttys):
    candidates = {}
    for pid, row in processes.items():
        _, group, tty, foreground, _ = row
        if not tty or tty in tmux_ttys or foreground != group or foreground <= 0:
            continue
        path = PROC / str(pid)
        try:
            if path.stat().st_uid != os.geteuid():
                continue
            if not is_copilot(Path(os.readlink(path / "exe")).name, argv_for(path)):
                continue
            env = process_env(path, "WT_SESSION", "WSL_DISTRO_NAME", "TERM_PROGRAM",
                              "VSCODE_IPC_HOOK_CLI", "TMUX", "COPILOT_HOME")
            home = os.environ.get("COPILOT_HOME")
            if (not UUID.fullmatch(env.get("WT_SESSION", "")) or not env.get("WSL_DISTRO_NAME")
                    or env.get("TMUX") or env.get("TERM_PROGRAM") == "vscode"
                    or env.get("VSCODE_IPC_HOOK_CLI")
                    or (home and env.get("COPILOT_HOME") != home)):
                continue
            candidates.setdefault(tty, []).append(pid)
        except (FileNotFoundError, ProcessLookupError, PermissionError):
            continue
    for tty, pids in candidates.items():
        # Ignore nested agents in a foreground tool's process tree.
        roots = []
        for pid in pids:
            parent = processes[pid][0]
            while parent in processes and parent not in pids:
                parent = processes[parent][0]
            if parent not in pids:
                roots.append(pid)
        if len(roots) != 1:
            continue
        pid = roots[0]
        try:
            tab = new_tab(os.readlink(PROC / str(pid) / "cwd"))
            tab.update(tool="copilot", resume="copilot --resume", terminal="windows-terminal")
            copilot_tab(pid, processes[pid], tab)
            if process(pid)[4] == processes[pid][4]:
                yield f"wt:{tty}", tab
        except (FileNotFoundError, ProcessLookupError):
            continue
        except PermissionError:
            print("Cannot read Copilot metadata for a Windows Terminal tab.", file=sys.stderr)


def iso(seconds=None):
    return datetime.fromtimestamp(time.time() if seconds is None else seconds,
                                  timezone.utc).isoformat(timespec="microseconds")


@contextmanager
def state_directory(path, *, create=False):
    root = Path(os.path.abspath(STATE))
    path = Path(os.path.abspath(path))
    owner = os.geteuid()
    flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
    components = path.parts
    fd = os.open(path.anchor, flags)
    try:
        if root == Path(root.anchor):
            raise ValueError(f"Unsafe state directory: {str(root)!r}")
        for i, name in enumerate(components[1:], 2):
            current = Path(*components[:i])
            private = current == root or root in current.parents
            if private and create:
                try:
                    os.mkdir(name, mode=0o700, dir_fd=fd)
                except FileExistsError:
                    pass
            try:
                child = os.open(name, flags, dir_fd=fd)
            except (NotADirectoryError, PermissionError) as error:
                raise ValueError(f"Unsafe state directory: {str(current)!r}") from error
            os.close(fd)
            fd = child
            info = os.fstat(fd)
            if private:
                safe = info.st_uid == owner and not info.st_mode & 0o077
            else:
                # Sticky ancestors such as /tmp protect entries owned by their trusted owners.
                safe = info.st_uid in (0, owner) and (
                    not info.st_mode & 0o022 or info.st_mode & stat.S_ISVTX)
            if not safe:
                raise ValueError(f"Unsafe state directory: {str(current)!r}")
        yield fd
    finally:
        os.close(fd)


@contextmanager
def state_file(parent, name, flags=os.O_RDONLY):
    fd = os.open(name, flags | os.O_NOFOLLOW | os.O_NONBLOCK, 0o600, dir_fd=parent)
    try:
        info = os.fstat(fd)
        if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.geteuid()
                or info.st_mode & 0o022 or info.st_nlink != 1):
            raise ValueError(f"Unsafe state file: {name!r}")
        yield fd
    finally:
        os.close(fd)


def read_json(path, default=None):
    try:
        with state_directory(path.parent) as parent, state_file(parent, path.name) as fd:
            with open(fd, encoding="utf-8-sig", closefd=False) as stream:
                return json.load(stream)
    except FileNotFoundError:
        return default


def write_json(path, value):
    with state_directory(path.parent, create=True) as parent:
        name = f".snapshot-{secrets.token_hex(16)}"
        fd = os.open(name, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600, dir_fd=parent)
        try:
            with open(fd, "w", encoding="utf-8") as stream:
                json.dump(value, stream, indent=2)
            os.replace(name, path.name, src_dir_fd=parent, dst_dir_fd=parent)
        except BaseException:
            os.unlink(name, dir_fd=parent)
            raise


def history_names(parent):
    return sorted((name for name in os.listdir(parent) if name.endswith(".json")), reverse=True)


def named_path(name):
    if (not re.fullmatch(r"[a-zA-Z0-9][a-zA-Z0-9 _-]{0,63}", name)
            or name.endswith(" ")):
        raise ValueError("Use 1-64 letters, numbers, spaces, hyphens or underscores, starting with a letter or number and with no trailing space.")
    return STATE / "named" / f"snapshot-{name.lower()}.json"


def named_snapshots():
    directory = STATE / "named"
    try:
        with state_directory(directory) as parent:
            paths = [directory / name for name in history_names(parent) if name.startswith("snapshot-")]
    except FileNotFoundError:
        return []
    return sorted(filter(None, map(load_snapshot, paths)), key=timestamp, reverse=True)


def show_named_snapshots(named):
    if named:
        print("Named snapshots:")
        for snap in named:
            print(f'  {terminal_text(snap.get("name", ""))} | {snap["takenAt"]} ({len(snap["tabs"])} panes)')


def snapshot(name=None):
    path = named_path(name) if name is not None else None
    if path is not None:
        missing = object()
        if read_json(path, missing) is not missing:
            raise ValueError(f"Snapshot name already exists: {name}")
    tabs = [tab for _, tab in capture()]
    if not tabs:
        if path is not None:
            raise ValueError("No supported live terminals; named snapshot was not saved.")
        print("No supported live terminals; kept previous snapshot.")
        return
    hosts = {tab.get("terminal", "tmux") for tab in tabs}
    snap = dict(version=1, takenAt=iso(), epoch=epoch(), os="linux",
                terminal=next(iter(hosts)) if len(hosts) == 1 else "mixed", tabs=tabs)
    if path is not None:
        snap["name"] = name
        write_json(path, snap)
        print(f'Saved snapshot "{name}" ({len(tabs)} panes).')
        return
    previous = load_snapshot(STATE / "last.json")
    if previous and (previous["epoch"] != snap["epoch"] or
                     sorted(map(surface_key, previous["tabs"])) != sorted(map(surface_key, tabs))):
        history = STATE / "history"
        stamp = re.sub(r"\D", "", previous["takenAt"])
        write_json(history / f"{stamp}.json", previous)
        with state_directory(history) as parent:
            for old in history_names(parent)[40:]:
                os.unlink(old, dir_fd=parent)
    write_json(STATE / "last.json", snap)
    print(f"Saved {len(tabs)} panes.")


def load_snapshot(path):
    snap = read_json(path)
    if snap is None:
        return None
    if (not isinstance(snap, dict) or snap.get("version") != 1
            or not isinstance(snap.get("tabs"), list)
            or not all(isinstance(tab, dict) for tab in snap["tabs"])
            or not isinstance(snap.get("takenAt"), str)):
        raise ValueError(f"Invalid snapshot: {path}")
    try:
        timestamp(snap)
    except ValueError as error:
        raise ValueError(f"Invalid snapshot date: {path}") from error
    return snap


def timestamp(snap):
    return datetime.fromisoformat(snap["takenAt"]).timestamp()


def snapshots():
    history = STATE / "history"
    paths = [STATE / "last.json"]
    try:
        with state_directory(history) as parent:
            paths.extend(history / name for name in history_names(parent))
    except FileNotFoundError:
        pass
    return sorted(filter(None, map(load_snapshot, paths)), key=timestamp, reverse=True)


def identity(tab):
    session = tab.get("sessionId")
    if tab.get("tool") == "copilot" and isinstance(session, str) and UUID.fullmatch(session):
        return ["copilot", session.lower(), tab.get("toolHome") or ""]
    return None


def key(tab):
    fields = identity(tab) or [tab.get("tool"), None, tab.get("toolHome"), tab.get("cwd")]
    return hashlib.sha256(json.dumps(fields).encode()).hexdigest()


def surface_key(tab):
    return tab.get("terminal", "tmux"), key(tab)


def select(all_snapshots, current, index):
    if index is not None:
        if not 0 <= index < len(all_snapshots):
            raise ValueError(f"No snapshot #{index}")
        return all_snapshots[index]
    if not all_snapshots:
        return None
    pick = all_snapshots[0]
    if read_json(STATE / "restored-epoch.json") != current:
        pick = next((snap for snap in all_snapshots if snap.get("epoch") != current), pick)
    for candidate in all_snapshots:
        if (candidate.get("epoch") == pick.get("epoch")
                and abs(timestamp(candidate) - timestamp(pick)) <= 180
                and len(candidate["tabs"]) > len(pick["tabs"])
                and {surface_key(tab) for tab in pick["tabs"]} <=
                {surface_key(tab) for tab in candidate["tabs"]}):
            pick = candidate
    return pick


def terminal_text(value):
    return "".join(char if char.isprintable() else repr(char)[1:-1] for char in str(value))


def show(snap):
    if not snap:
        print("No snapshot saved.")
        return
    print(f'{len(snap["tabs"])} panes, recorded {snap["takenAt"]}')
    for i, tab in enumerate(snap["tabs"], 1):
        label = terminal_text(tab.get("tool") or "shell")
        print(f'{i}. {label}  {tab.get("cwd")!r}')
        if tab.get("lastPrompt"):
            print(f'   you: {" ".join(str(tab["lastPrompt"]).split())[:120]!r}')
        if tab.get("tool") == "copilot" and not identity(tab):
            print("   session not identified; opens picker")


def restore_command(tab):
    cwd = tab.get("cwd")
    if not isinstance(cwd, str) or "\0" in cwd or not Path(cwd).is_absolute() or not Path(cwd).is_dir():
        raise ValueError(f"Restore folder unavailable on Linux: {cwd!r}")
    direct = tab.get("terminal") == "windows-terminal"
    path = executable_path()
    if direct:
        path = os.pathsep.join(filter(None, (path, "/snap/bin")))
    command = "export PATH=" + shlex.quote(path) + "; cd -- " + shlex.quote(cwd) + " && "
    if tab.get("tool") == "copilot":
        saved = tab.get("toolHome")
        explicit = os.environ.get("COPILOT_HOME")
        current = str(Path(explicit).resolve()) if explicit else None
        if saved and current != saved:
            raise ValueError(f"COPILOT_HOME must match the saved Copilot configuration: {saved!r}")
        session = identity(tab)
        environment = [f"COPILOT_HOME={current}"] if saved else ["-u", "COPILOT_HOME"]
        copilot = shutil.which("copilot", path=path)
        if not copilot:
            raise ValueError("Copilot was not found on the absolute entries of PATH.")
        args = ["/usr/bin/env", *environment, copilot, "-C", cwd,
                "--resume=" + session[1] if session else "--resume"]
        return command + "exec " + shlex.join(args)
    display = f'same-sesh: was running: {tab.get("wasRunning") or tab.get("tool") or "(idle shell)"}'
    shell = os.environ.get("SHELL", "")
    if not Path(shell).is_absolute():
        shell = "/bin/sh"
    return command + "printf '%s\\n' " + shlex.quote(repr(display)) + "; exec " + shlex.quote(shell)


def open_windows_terminal(command):
    distro = os.environ.get("WSL_DISTRO_NAME")
    if not distro:
        raise ValueError("Restore Windows Terminal tabs from inside their WSL distro.")
    powershell = shutil.which("powershell.exe", path=executable_path()) or (
        "/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe")
    if not Path(powershell).is_file():
        raise ValueError("Windows PowerShell is unavailable from WSL; check Windows interop.")
    # Keep Linux shell syntax and paths out of Windows Terminal's command parser.
    payload = base64.b64encode(command.encode()).decode()
    runner = ("__import__('os').execl('/bin/sh','sh','-c',"
              "__import__('base64').b64decode(__import__('sys').argv[1]).decode())")
    args = subprocess.list2cmdline(["-w", "0", "new-tab", "wsl.exe", "-d", distro, "--exec",
                                   "/usr/bin/python3", "-c", runner, payload])
    script = ("$ErrorActionPreference = 'Stop'; "
              "Start-Process -FilePath (Get-Command wt.exe).Source -ArgumentList '"
              + args.replace("'", "''") + "'")
    encoded = base64.b64encode(script.encode("utf-16-le")).decode()
    result = subprocess.run([powershell, "-NoProfile", "-NonInteractive", "-EncodedCommand", encoded],
                            capture_output=True, timeout=15)
    if result.returncode:
        error = result.stderr.decode(errors="replace").strip()
        raise ValueError(f"Unable to launch Windows Terminal: {error or result.returncode}")


def restore(snap, current, dry, *, mark_epoch=True):
    if not snap:
        show(snap)
        return
    live = dict(capture())
    exact = {key(tab) for tab in live.values() if identity(tab)}
    tmux_live = {pane: tab for pane, tab in live.items() if not pane.startswith("wt:")}
    available = {}
    for pane, tab in live.items():
        if pane.startswith("wt:") and not identity(tab):
            value = surface_key(tab)
            available[value] = available.get(value, 0) + 1
    receipt_path = STATE / "windows-terminal-pending.json"
    pending = read_json(receipt_path)
    had_receipts = pending is not None
    pending = pending or {}
    pending = {key_: deadline for key_, deadline in pending.get("entries", {}).items()
               if key_ not in exact and deadline > time.time()} if pending.get("epoch") == current else {}
    if tmux_live:
        receipts = tmux("list-panes", "-a", "-F", "#{pane_id}:#{@same-sesh-restore}")
        if receipts.returncode:
            raise ValueError(receipts.stderr.strip())
        for line in receipts.stdout.splitlines():
            pane, receipt = line.split(":", 1)
            tab = tmux_live.get(pane)
            if not tab or identity(tab):
                continue
            match = re.fullmatch(r"([0-9a-f]{64}),(\d+),(exact|other)", receipt)
            if match and (match[3] == "other" or time.time() - int(match[2]) < 30):
                value = match[1]
            else:
                value = key(tab)
            available[("tmux", value)] = available.get(("tmux", value), 0) + 1
    plan = []
    for tab in snap["tabs"]:
        host, value = surface_key(tab)
        if value in exact or (host == "windows-terminal" and value in pending):
            continue
        if available.get((host, value), 0):
            available[(host, value)] -= 1
            if identity(tab):
                exact.add(value)
            continue
        plan.append((tab, value, restore_command(tab)))
        if identity(tab):
            exact.add(value)
    for tab, value, command in plan:
        direct = tab.get("terminal") == "windows-terminal"
        if dry:
            host = "Windows Terminal" if direct else "tmux"
            label = terminal_text(tab.get("tool") or "shell")
            print(f'Would open {label} in {host}: {tab["cwd"]!r}')
            continue
        if direct:
            open_windows_terminal(command)
            if identity(tab):
                pending[value] = time.time() + 20
                write_json(receipt_path, dict(epoch=current, entries=pending))
            continue
        kind = "exact" if identity(tab) else "other"
        # Set the receipt in the same tmux command queue as the pane creation.
        create = "new-window" if tmux_live else "new-session"
        result = tmux(create, "-dP", "-F", "#{pane_id}", "/bin/sh", "-c", command,
                      ";", "set-option", "-p", "@same-sesh-restore",
                      f"{value},{int(time.time())},{kind}")
        if result.returncode:
            if create == "new-window":
                raise ValueError(result.stderr.strip())
            raise ValueError(f"Unable to create tmux session: {result.stderr.strip()}")
        tmux_live[result.stdout.strip()] = tab
    if not dry:
        if had_receipts:
            write_json(receipt_path, dict(epoch=current, entries=pending))
        if mark_epoch:
            write_json(STATE / "restored-epoch.json", current)
    print(f'{"Would open" if dry else "Opened"} {len(plan)} panes.')


def locked(action):
    with state_directory(STATE, create=True) as parent, \
            state_file(parent, "write.lock", os.O_WRONLY | os.O_CREAT) as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        action()


TIMER = "same-sesh.timer"
SERVICE = "same-sesh.service"
UNIT_DIR = Path(os.environ.get("XDG_CONFIG_HOME") or HOME / ".config") / "systemd" / "user"
MANAGED = "# Managed by same-sesh\n"


def systemctl(*args, check=True):
    result = subprocess.run(["systemctl", "--user", "--no-pager", *args],
                            capture_output=True, text=True, timeout=30)
    if check and result.returncode:
        raise ValueError(result.stderr.strip() or result.stdout.strip())
    return result


def systemd_arg(value):
    return '"' + str(value).replace("\\", "\\\\").replace('"', '\\"').replace(
        "%", "%%").replace("\n", "\\n").replace("\r", "\\r").replace("\t", "\\t") + '"'


def install_on_path(yes):
    checkout = str(Path(__file__).resolve().parents[1])
    if checkout in os.get_exec_path():
        return
    shell = Path(os.environ.get("SHELL") or "/bin/bash").name
    profiles = {
        "bash": [HOME / ".bashrc", next(
            (HOME / name for name in (".bash_profile", ".bash_login", ".profile") if (HOME / name).is_file()),
            HOME / ".profile")],
        "zsh": [Path(os.environ.get("ZDOTDIR") or HOME) / ".zshrc"],
        "sh": [HOME / ".profile"],
        "dash": [HOME / ".profile"],
        "fish": [Path(os.environ.get("XDG_CONFIG_HOME") or HOME / ".config") / "fish" / "config.fish"],
    }.get(shell)
    manual = f"To run same-sesh from any folder, add {checkout} to your PATH manually."
    if not profiles or any(character in checkout for character in ":\r\n"):
        print(manual)
        return
    if shell == "fish":
        quoted = "'" + checkout.replace("\\", "\\\\").replace("'", "\\'") + "'"
        line = f"contains -- {quoted} $PATH; or set -gx PATH $PATH {quoted}"
    else:
        quoted = shlex.quote(checkout)
        line = f'case ":$PATH:" in *:{quoted}:*) ;; *) export PATH="${{PATH:+$PATH:}}"{quoted} ;; esac'
    content = ("\n# same-sesh command\n" + line + "\n").encode()
    updates = []
    for profile in profiles:
        try:
            if line.encode() in profile.read_bytes().splitlines():
                continue
        except FileNotFoundError:
            pass
        updates.append(profile)
    if not updates:
        print("PATH is already configured. Open a new shell to use same-sesh.")
        return
    if not yes:
        print("If you decline, using same-sesh from any folder requires manual PATH setup.")
        try:
            answer = input("Add same-sesh to your PATH? [Y/n] ") if sys.stdin.isatty() else "no"
        except EOFError:
            answer = "no"
        if answer.strip().lower() not in ("", "y", "yes"):
            print(manual)
            return
    for profile in updates:
        profile.parent.mkdir(parents=True, exist_ok=True)
        with profile.open("ab") as stream:
            stream.write(content)
    print("Added same-sesh to your PATH. Open a new shell to use it.")


def manage_watcher(install):
    paths = [UNIT_DIR / unit for unit in (SERVICE, TIMER)]
    for path in paths:
        if path.exists() and not path.read_text().startswith(MANAGED):
            raise ValueError(f"Refusing to modify unmanaged unit: {path}")
    if not install and not any(path.exists() for path in paths):
        print("Watcher is not installed.")
        return
    systemctl("show-environment")
    if install:
        socket = os.environ.get("SAME_SESH_TMUX_SOCKET")
        if not socket and os.environ.get("TMUX"):
            result = tmux("display-message", "-p", "#{socket_path}")
            if result.returncode:
                raise ValueError(result.stderr.strip())
            socket = result.stdout.rstrip("\n")
        tmux_path = shutil.which("tmux", path=executable_path())
        if socket and not tmux_path:
            raise ValueError("tmux is not on PATH")
        with state_directory(STATE, create=True):
            pass
        args = ["/usr/bin/env", f"SAME_SESH_STATE_DIR={os.path.abspath(STATE)}", "TMUX=",
                f"SAME_SESH_TMUX_SOCKET={Path(socket).resolve() if socket else ''}",
                f"PATH={Path(tmux_path).absolute().parent if tmux_path else '/usr/bin'}:/usr/bin:/bin"]
        if home := os.environ.get("COPILOT_HOME"):
            args.append(f"COPILOT_HOME={Path(home).resolve()}")
        args.extend([sys.executable, Path(__file__).resolve(), "snapshot"])
        service = ("[Unit]\nDescription=Capture same-sesh Linux sessions\n\n"
                   "[Service]\nType=oneshot\nExecStart=:" + " ".join(map(systemd_arg, args)) + "\n")
        timer = ("[Unit]\nDescription=Save same-sesh sessions every 30 seconds\n\n"
                 "[Timer]\nOnStartupSec=10s\nOnUnitActiveSec=30s\nAccuracySec=1s\n\n"
                 "[Install]\nWantedBy=timers.target\n")
        UNIT_DIR.mkdir(mode=0o700, parents=True, exist_ok=True)
        for path, content in zip(paths, (service, timer)):
            path.write_text(MANAGED + content)
        systemctl("daemon-reload")
        systemctl("enable", "--now", TIMER)
        systemctl("start", SERVICE)
        print("Automatic snapshots enabled.")
    else:
        if paths[1].exists():
            systemctl("disable", "--now", TIMER)
        if paths[0].exists():
            systemctl("stop", SERVICE)
        for path in paths:
            path.unlink(missing_ok=True)
        systemctl("daemon-reload")
        print("Automatic snapshots disabled; snapshots kept.")


def status():
    if shutil.which("systemctl"):
        result = systemctl("is-active", TIMER, check=False)
        if result.stderr:
            print(f"Automatic saving: unavailable ({terminal_text(result.stderr.strip())})")
        else:
            print(f"Automatic saving: {terminal_text(result.stdout.strip())}")
    else:
        print("Automatic saving: systemctl unavailable")
    snap = load_snapshot(STATE / "last.json")
    print(f'Last nonempty snapshot: {snap["takenAt"]}' if snap else "No snapshot saved.")


def main():
    parser = argparse.ArgumentParser(prog="same-sesh")
    commands = parser.add_subparsers(dest="command")
    for name in ("list", "history", "watch", "status", "uninstall"):
        commands.add_parser(name)
    commands.add_parser("install").add_argument("--yes", action="store_true",
                                                   help="add same-sesh to PATH without prompting")
    commands.add_parser("snapshot").add_argument("--name")
    restore_parser = commands.add_parser("restore")
    restore_parser.add_argument("--dry-run", action="store_true")
    target = restore_parser.add_mutually_exclusive_group()
    target.add_argument("--index", type=int)
    target.add_argument("--name")
    args = parser.parse_args()
    try:
        if args.command == "snapshot":
            locked(lambda: snapshot(args.name))
        elif args.command == "watch":
            while True:
                locked(snapshot)
                sys.stdout.flush()
                time.sleep(30)
        elif args.command == "status":
            status()
        elif args.command in ("install", "uninstall"):
            manage_watcher(args.command == "install")
            if args.command == "install":
                install_on_path(args.yes)
        elif args.command == "history":
            for i, snap in enumerate(snapshots()):
                print(f'{i}: {snap["takenAt"]} ({len(snap["tabs"])} panes)')
            show_named_snapshots(named_snapshots())
        elif args.command == "restore":
            def run():
                named = args.name is not None
                snap = load_snapshot(named_path(args.name)) if named else None
                if named and snap is None:
                    raise ValueError(f"No snapshot named: {args.name}")
                current = epoch()
                if not named:
                    snap = select(snapshots(), current, args.index)
                restore(snap, current, args.dry_run, mark_epoch=not named)

            if args.dry_run:
                run()
            else:
                locked(run)
        else:
            snap = load_snapshot(STATE / "last.json")
            named = named_snapshots()
            if snap or not named:
                show(snap)
            show_named_snapshots(named)
    except KeyboardInterrupt:
        parser.exit(130)
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        parser.exit(1, f"same-sesh: {terminal_text(error)}\n")


if __name__ == "__main__":
    main()
