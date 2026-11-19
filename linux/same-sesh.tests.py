import importlib.util
import json
import os
from pathlib import Path
import pty
import shutil
import subprocess
import tempfile
import time
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[1]
FIRST = "d72f6333-cc42-4cf4-8f20-896a1e46c500"
SECOND = "c3fc9da0-6c66-4a56-90cf-af0130413bf1"


class PathInstallTests(unittest.TestCase):
    def test_bash_path_setup_respects_consent_and_can_be_repeated(self):
        spec = importlib.util.spec_from_file_location("same_sesh", ROOT / "linux" / "same-sesh.py")
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            checkout = base / "checkout with ' quote"
            profile = base / ".bash_profile"
            profile.write_text("# existing profile\n")
            with patch.object(module, "HOME", base), \
                    patch.object(module, "__file__", str(checkout / "linux" / "same-sesh.py")), \
                    patch.dict(os.environ, {"PATH": "/usr/bin:/bin", "SHELL": "/bin/bash"}), \
                    patch("sys.stdin.isatty", return_value=True), patch("builtins.input", return_value="n"):
                module.install_on_path(yes=False)
                self.assertEqual(profile.read_text(), "# existing profile\n")
                self.assertFalse((base / ".bashrc").exists())
                module.install_on_path(yes=True)
                configured = profile.read_text()
                module.install_on_path(yes=True)
                self.assertEqual(profile.read_text(), configured)
                result = subprocess.run(
                    ["/bin/bash", "-c", 'source "$1"; source "$2"; printf "%s" "$PATH"',
                     "fixture", str(profile), str(base / ".bashrc")],
                    check=True, capture_output=True, text=True,
                )
                self.assertEqual(result.stdout.split(":"), ["/usr/bin", "/bin", str(checkout.resolve())])


class TmuxTests(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.root = Path(tmp.name)
        self.socket = self.root / "tmux.sock"
        self.state = self.root / "snapshots"
        self.home = self.root / "copilot-home"
        self.cwd = self.root / "working dir's #S"
        self.cwd.mkdir()
        self.exe = self.root / "copilot"
        shutil.copy("/bin/bash", self.exe)
        self.env = dict(os.environ, SAME_SESH_STATE_DIR=str(self.state),
                        SAME_SESH_TMUX_SOCKET=str(self.socket), COPILOT_HOME=str(self.home))
        self.env.pop("TMUX", None)
        self.addCleanup(self.tmux, "kill-server", check=False)

    def tmux(self, *args, check=True):
        result = subprocess.run(["tmux", "-S", str(self.socket), "-f", "/dev/null", *args],
                                env=self.env, text=True, capture_output=True, check=False)
        if check:
            self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout.strip()

    def cli(self, *args, error=None):
        result = subprocess.run(["/bin/sh", ROOT / "same-sesh", *args],
                                env=self.env, text=True, capture_output=True, check=False)
        if error is not None:
            self.assertNotEqual(result.returncode, 0)
            self.assertIn(error, result.stderr)
            return
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout

    def pane(self, command, *args):
        return self.tmux("new-session", "-dP", "-F", "#{pane_pid}", "/bin/sh", "-c",
                         'cd -- "$1" && shift && exec "$@"', "fixture", str(self.cwd),
                         str(command), *args)

    def session(self, pid, session_id, message):
        folder = self.home / "session-state" / session_id
        folder.mkdir(parents=True, exist_ok=True)
        (folder / f"inuse.{pid}.lock").touch()
        (folder / "events.jsonl").write_text(json.dumps({
            "type": "user.message", "data": {"content": message}
        }) + "\n")

    def snapshot(self):
        self.cli("snapshot")
        return json.loads((self.state / "last.json").read_text())

    def test_snapshot_attributes_two_same_folder_conversations(self):
        for session_id, message in [(FIRST, "First fixture"), (SECOND, "Second fixture")]:
            pid = self.pane(self.exe, "-c", "while :; do sleep 60; done")
            self.session(pid, session_id, message)
        deadline = time.monotonic() + 3
        while time.monotonic() < deadline:
            snap = self.snapshot()
            if all(tab["sessionId"] for tab in snap["tabs"]):
                break
            time.sleep(0.05)
        self.assertEqual(snap["version"], 1)
        self.assertCountEqual(
            [(tab["sessionId"], tab["cwd"], tab["lastPrompt"]) for tab in snap["tabs"]],
            [(FIRST, str(self.cwd), "First fixture"), (SECOND, str(self.cwd), "Second fixture")],
        )

    def test_named_snapshots_stay_separate_from_automatic_history(self):
        self.cli("snapshot", "--name", "Empty", error="No supported live terminals")
        self.pane("/bin/sh")
        self.assertIn('Saved snapshot "Before deploy"', self.cli("snapshot", "--name", "Before deploy"))
        listing = self.cli("list")
        self.assertEqual(self.cli(), listing)
        self.assertIn("Named snapshots:\n  Before deploy", listing)
        self.assertNotIn("No snapshot saved.", listing)
        previous = self.snapshot()
        self.assertIn("Named snapshots:\n  Before deploy", self.cli("list"))
        self.cli("snapshot", "--name", "BEFORE DEPLOY", error="already exists")
        self.cli("restore", "--name", "../outside", error="Use 1-64")
        self.cli("restore", "--name", "missing", error="No snapshot named")
        self.cli("restore", "--name", "Before deploy", "--index", "0", error="not allowed")
        history = self.cli("history")
        self.assertEqual(len([line for line in history.splitlines() if line.startswith("0:")]), 1)
        self.assertIn("Named snapshots:\n  Before deploy", history)
        self.assertEqual(json.loads((self.state / "last.json").read_text()), previous)
        self.tmux("kill-server")
        self.assertIn("Would open 1", self.cli("restore", "--name", "BEFORE DEPLOY", "--dry-run"))
        self.assertIn("Opened 1", self.cli("restore", "--name", "Before deploy"))
        self.assertFalse((self.state / "restored-epoch.json").exists())

    def test_restore_prefers_previous_instance_and_passes_folder_as_data(self):
        self.exe.unlink()
        self.exe.write_text("#!/bin/sh\nprintf '%s\\n' \"$PATH\" > \"$COPILOT_HOME/launch-path\"\n"
                            "printf '%s\\n' \"$PWD\" \"$@\" > \"$COPILOT_HOME/launch\"\n"
                            "exec sleep 60\n")
        self.exe.chmod(0o700)
        self.home.mkdir()
        self.env["PATH"] = f":relative:{self.root}:{self.env['PATH']}"
        self.state.mkdir(mode=0o700)
        stored = dict(version=1, takenAt="2025-01-01T00:00:00Z", epoch="previous-instance",
                      tabs=[dict(tool="copilot", cwd=str(self.cwd), sessionId=FIRST,
                                 toolHome=str(self.home), resume="must not run")])
        latest = self.state / "last.json"
        latest.write_text(json.dumps(stored))
        self.cli("snapshot")
        self.assertEqual(json.loads(latest.read_text()), stored)
        self.pane("/bin/sh")
        self.snapshot()
        self.assertIn("Would open 1", self.cli("restore", "--dry-run"))
        self.assertEqual(len(self.tmux("list-panes", "-a").splitlines()), 1)
        self.assertFalse((self.home / "launch").exists())
        self.assertIn("Opened 1", self.cli("restore"))
        deadline = time.monotonic() + 3
        while not (self.home / "launch").exists() and time.monotonic() < deadline:
            time.sleep(0.05)
        self.assertEqual((self.home / "launch").read_text().splitlines(),
                         [str(self.cwd), "-C", str(self.cwd), f"--resume={FIRST}"])
        self.assertTrue(all(Path(entry).is_absolute() for entry in
                            (self.home / "launch-path").read_text().strip().split(":")))
        self.assertIn("Opened 0", self.cli("restore", "--index", "1"))
        self.tmux("kill-server")
        self.assertIn("Opened 1", self.cli("restore", "--index", "1"))
        self.assertIn("Opened 0", self.cli("restore", "--index", "1"))

    def test_snapshot_uses_latest_foreground_registration_not_lock_order(self):
        logfile = self.root / "logs with spaces"
        logfile.mkdir()
        pid = self.pane(self.exe, "-c",
                        'exec 9>"$1/process-$(date +%s%3N)-$$.log"; while :; do sleep 60; done',
                        "fixture", str(logfile))
        deadline = time.monotonic() + 3
        while not list(logfile.iterdir()) and time.monotonic() < deadline:
            time.sleep(0.05)
        log, = logfile.iterdir()
        self.session(pid, FIRST, "First fixture")
        self.session(pid, SECOND, "Second fixture")
        self.assertIsNone(self.snapshot()["tabs"][0]["sessionId"])
        with log.open("a") as out:
            out.write(f"[INFO] Registering foreground session: {FIRST}\n")
        self.assertEqual(self.snapshot()["tabs"][0]["sessionId"], FIRST)
        with log.open("a") as out:
            out.write(f"[INFO] Registering foreground session: {SECOND}\n")
        self.assertEqual(self.snapshot()["tabs"][0]["sessionId"], SECOND)
        for session_id in (FIRST, SECOND):
            (self.home / "session-state" / session_id / f"inuse.{pid}.lock").unlink()
        self.assertEqual(self.snapshot()["tabs"][0]["sessionId"], SECOND)
        with log.open("a") as out:
            out.write(f"[INFO] Unregistering foreground session: {SECOND}\n")
        self.session(pid, FIRST, "First fixture")
        self.assertIsNone(self.snapshot()["tabs"][0]["sessionId"])

    def test_snapshot_captures_direct_windows_terminal_but_not_vscode(self):
        self.env.pop("SAME_SESH_TMUX_SOCKET")
        for session, term in [(FIRST, ""), (SECOND, "vscode")]:
            env = dict(self.env, WT_SESSION="603aeeac-94b6-4f4a-b73e-8aa8208455aa",
                       WSL_DISTRO_NAME="fixture", TERM_PROGRAM=term)
            pid, master = pty.fork()
            if not pid:
                os.chdir(self.cwd)
                os.execve(self.exe, [str(self.exe), "-c", "read -r"], env)
            def cleanup(pid=pid, master=master):
                os.close(master)
                os.waitpid(pid, 0)
            self.addCleanup(cleanup)
            deadline = time.monotonic() + 3
            while time.monotonic() < deadline:
                if Path(f"/proc/{pid}/exe").resolve() == self.exe:
                    break
                time.sleep(0.02)
            self.session(pid, session, "Direct fixture")
        snap = self.snapshot()
        direct = [tab for tab in snap["tabs"] if tab.get("terminal") == "windows-terminal"]
        self.assertEqual([(tab["sessionId"], tab["cwd"]) for tab in direct], [(FIRST, str(self.cwd))])

    def test_restore_routes_direct_session_to_windows_terminal(self):
        windows = self.root / "powershell.exe"
        receipt = self.root / "windows-invocation"
        windows.write_text('#!/bin/sh\nprintf "%s\\n" "$@" > "$TEST_WINDOWS_INVOCATION"\n')
        windows.chmod(0o700)
        self.env.update(PATH=f"{self.root}:{self.env['PATH']}", WSL_DISTRO_NAME="Fixture distro",
                        TEST_WINDOWS_INVOCATION=str(receipt))
        self.state.mkdir(mode=0o700)
        (self.state / "last.json").write_text(json.dumps(dict(
            version=1, takenAt="2025-01-01T00:00:00Z", epoch="previous-instance",
            tabs=[dict(tool="copilot", terminal="windows-terminal", cwd=str(self.cwd),
                       sessionId=FIRST, toolHome=str(self.home))],
        )))
        self.assertIn("in Windows Terminal", self.cli("restore", "--dry-run"))
        self.assertFalse(receipt.exists())
        self.assertIn("Opened 1", self.cli("restore"))
        self.assertIn("-EncodedCommand", receipt.read_text())
        self.assertIn("Opened 0", self.cli("restore"))
        self.assertEqual(self.tmux("list-panes", "-a", check=False), "")

    def test_state_commands_require_private_directories(self):
        self.state.mkdir(mode=0o700)
        self.state.chmod(0o777)
        self.cli("snapshot", error="Unsafe state directory")
        self.state.chmod(0o700)
        outside = self.root / "other-directory"
        outside.mkdir(mode=0o700)
        (self.state / "history").symlink_to(outside, target_is_directory=True)
        self.cli("history", error="Unsafe state directory")

    def test_snapshot_labels_display_invisible_characters_as_text(self):
        self.state.mkdir(mode=0o700)
        (self.state / "last.json").write_text(json.dumps(dict(
            version=1, takenAt="2025-01-01T00:00:00Z", epoch="previous-instance",
            tabs=[dict(tool="fixture\u200blabel", cwd=str(self.cwd))],
        )))
        for args in [("list",), ("restore", "--dry-run")]:
            with self.subTest(command=args[0]):
                output = self.cli(*args)
                self.assertIn(r"fixture\u200blabel", output)
                self.assertNotIn("\u200b", output)


if __name__ == "__main__":
    unittest.main()
