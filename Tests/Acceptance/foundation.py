"""The accepted #1 examples, exercised at the shipped CLI boundary.

Only fixture records reach assertions. Never print or persist a full window listing.
"""
import ctypes
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import signal
import socket
import stat
import subprocess
import sys
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[2]
APPS = ROOT / ".build/apps"
APP = APPS / "Tessel Dev.app"
CLI = APP / "Contents/MacOS/tessel"
FIXTURE = APPS / "Tessel Fixture.app"
FIXTURE_BIN = FIXTURE / "Contents/MacOS/TesselFixture"
FIXTURE_ID = "com.taecontrol.tessel.fixture"
CALIBRATE = False


def eventually(predicate, timeout=0.5):
    deadline = time.monotonic() + timeout
    while True:
        result = predicate()
        if result:
            return result if time.monotonic() <= deadline else None
        if time.monotonic() >= deadline:
            return None
        time.sleep(0.015)


def process_ids(executable):
    result = subprocess.run(["pgrep", "-f", "^" + re.escape(str(executable)) + "( |$)"], capture_output=True, text=True)
    return [int(pid) for pid in result.stdout.split()]


class FixtureSession:
    def __init__(self, directory, number):
        self.path = str(directory / f"f{number}.sock")
        self.client_path = str(directory / f"c{number}.sock")
        self.client = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
        self.client.bind(self.client_path)
        self.client.settimeout(3)
        subprocess.run(["open", "-n", "-g", "--stdout", "/dev/null", "--stderr", "/dev/null", str(FIXTURE), "--args", "--socket", self.path], check=True)
        if not eventually(lambda: Path(self.path).exists(), 5):
            raise RuntimeError("fixture did not launch")
        self.pid = self.command("ping")["pid"]

    def command(self, action, **kwargs):
        self.client.sendto(json.dumps({"action": action, **kwargs}).encode(), self.path)
        response = json.loads(self.client.recv(65536))
        if "error" in response:
            raise RuntimeError(response["error"])
        return response

    def stop(self):
        try:
            os.kill(self.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        self.client.close()


class RUsage(ctypes.Structure):
    _fields_ = [("uuid", ctypes.c_byte * 16)] + [(name, ctypes.c_uint64) for name in (
        "user_time", "system_time", "pkg_idle_wkups", "interrupt_wkups", "pageins",
        "wired_size", "resident_size", "phys_footprint", "proc_start_abstime", "proc_exit_abstime")]


class MachTimebase(ctypes.Structure):
    _fields_ = [("numer", ctypes.c_uint32), ("denom", ctypes.c_uint32)]


TIMEBASE = MachTimebase()
if ctypes.CDLL("/usr/lib/libSystem.B.dylib").mach_timebase_info(ctypes.byref(TIMEBASE)) != 0 or not TIMEBASE.denom:
    raise RuntimeError("cannot determine the Mach CPU timebase")


def resources(pid):
    usage = RUsage()
    libproc = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
    if libproc.proc_pid_rusage(pid, 0, ctypes.byref(usage)):
        raise OSError(ctypes.get_errno(), "cannot read tessel resource usage")
    ticks = usage.user_time + usage.system_time
    return ticks * TIMEBASE.numer // TIMEBASE.denom, usage.resident_size


class FoundationAcceptance(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if not CLI.exists() or not FIXTURE_BIN.exists():
            raise RuntimeError("Run scripts/build first; signed app and fixture bundles are required")
        if process_ids(APP / "Contents/MacOS/TesselApp"):
            raise RuntimeError("This worktree's development app is already running; stop it before verification")
        if subprocess.run([str(FIXTURE_BIN), "--check-session"], capture_output=True, timeout=2).returncode:
            raise RuntimeError("Wake and unlock the Mac before running GUI verification")
        power = subprocess.Popen(["/usr/bin/caffeinate", "-d", "-i", "-w", str(os.getpid())],
                                 stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        def release_power_assertion():
            if power.poll() is None:
                power.terminate()
            power.wait(timeout=1)
        cls.addClassCleanup(release_power_assertion)
        cls.temporary = tempfile.TemporaryDirectory(prefix="tessel-verify-")
        cls.addClassCleanup(cls.temporary.cleanup)
        cls.directory = Path(cls.temporary.name)
        cls.config_home = cls.directory / "config"
        cls.config_file = cls.config_home / "tessel/tessel.toml"
        cls.config_file.parent.mkdir(parents=True)
        cls.env = {**os.environ, "XDG_CONFIG_HOME": str(cls.config_home)}
        cls.fixture = FixtureSession(cls.directory, 0)
        cls.addClassCleanup(lambda: cls.fixture.stop())
        cls.addClassCleanup(cls.stop_app)
        cls.other_fixtures = []
        cls.start_app()

    @classmethod
    def start_app(cls, fixture_ready=True):
        subprocess.run(["open", "-n", "-g", "--stdout", "/dev/null", "--stderr", "/dev/null", "--env", "XDG_CONFIG_HOME=" + str(cls.config_home), str(APP)], check=True)
        pids = eventually(lambda: process_ids(APP / "Contents/MacOS/TesselApp"), 5)
        if not pids:
            raise RuntimeError("signed development app did not launch")
        cls.app_pid = pids[0]
        # Launch readiness is separate from the 500 ms event deadlines.
        if not eventually(lambda: cls.invoke("status", "--json").returncode == 0, 5):
            raise RuntimeError("signed development app did not expose its status endpoint")
        if fixture_ready:
            # Socket readiness does not prove that startup AX subscriptions exist.
            # Exercise one generic window before starting event-specific deadlines.
            health = cls.fixture.command("open", kind="standard", key="startupHealth")["windows"]["startupHealth"]
            def health_is_listed():
                result = cls.invoke("windows", "--json")
                if result.returncode:
                    return None
                return any(row.get("bundleId") == FIXTURE_ID and row.get("id") == health
                           for row in json.loads(result.stdout))
            if not eventually(health_is_listed, 5):
                raise RuntimeError("signed development app did not observe the fixture startup window")
            cls.fixture.command("close", key="startupHealth")
            if not eventually(lambda: health_is_listed() is False, 1):
                raise RuntimeError("signed development app did not retire the fixture startup window")

    @classmethod
    def stop_app(cls):
        for pid in process_ids(APP / "Contents/MacOS/TesselApp"):
            try:
                os.kill(pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
        eventually(lambda: not process_ids(APP / "Contents/MacOS/TesselApp"), 3)

    @classmethod
    def tearDownClass(cls):
        for fixture in cls.other_fixtures:
            fixture.stop()

    @classmethod
    def invoke(cls, *arguments):
        return subprocess.run([str(CLI), *arguments], env=cls.env, capture_output=True, text=True, timeout=1.2)

    def status(self):
        result = self.invoke("status", "--json")
        self.assertEqual(result.returncode, 0, "status command failed (window data withheld)")
        value = json.loads(result.stdout)
        self.assertTrue(isinstance(value, dict), "status is not an object (content withheld)")
        return value

    def rows(self):
        result = self.invoke("windows", "--json")
        self.assertEqual(result.returncode, 0, "windows command failed; check Accessibility using tessel status")
        value = json.loads(result.stdout)
        self.assertTrue(isinstance(value, list), "window listing is not implemented (content withheld)")
        # Do not include other apps in failure output, comparison values, or artifacts.
        return [row for row in value if row.get("bundleId") == FIXTURE_ID]

    def row(self, window_id):
        return next((row for row in self.rows() if row["id"] == window_id), None)

    def assert_state(self, window_id, state, reason=None):
        row = eventually(lambda: (value if value and value["state"] == state else None) if (value := self.row(window_id)) else None)
        self.assertIsNotNone(row, f"fixture window {window_id} did not become {state} within 500 ms")
        if reason:
            self.assertIn(reason, row["reason"])
        return row

    def open_window(self, kind="standard", key="window", **kwargs):
        return self.fixture.command("open", kind=kind, key=key, **kwargs)["windows"][key]

    def probe(self, resize_id=None):
        # LaunchServices must own the probe's TCC identity. A bare binary inherits
        # the terminal host's permission, which need not match the fixture grant.
        with tempfile.NamedTemporaryFile(dir=self.directory, suffix=".json") as output:
            command = ["open", "-n", "-g", "--stdout", output.name, "--stderr", "/dev/null", str(FIXTURE), "--args", "--probe", str(self.fixture.pid)]
            if resize_id:
                command.append(str(resize_id))
            subprocess.run(command, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=3)
            def completed():
                try:
                    return json.loads(Path(output.name).read_text())
                except json.JSONDecodeError:
                    return None
            value = eventually(completed, 2)
            self.assertIsNotNone(value, "independent fixture AX probe did not complete")
            self.assertIn("windows", value, "independent fixture AX probe needs Accessibility")
            return value["windows"]

    def setUp(self):
        self.fixture.command("reset")
        self.config_file.unlink(missing_ok=True)
        self.assertTrue(eventually(lambda: self.status().get("config", {}).get("state") == "defaults", 1))

    def test_E01_standard_resizable_window_tiles_with_reason(self):
        window = self.open_window()
        self.assert_state(window, "tiled", "standard window")

    def test_E02_fullscreen_button_is_not_a_classification_signal(self):
        window = self.open_window("noFullscreen")
        self.assert_state(window, "tiled", "standard window")
        observed = next(item for item in self.probe() if item["id"] == window)
        self.assertEqual(observed["subrole"], "AXStandardWindow")
        self.assertEqual(observed["fullscreen"], "none")
        self.assertTrue(observed["sizeSettable"])

    def test_E03_nonresizable_window_floats_with_fixed_size_reason(self):
        window = self.open_window("fixed")
        self.assert_state(window, "floats", "fixed size")
        observed = next(item for item in self.probe(window) if item["id"] == window)
        self.assertFalse(observed["sizeSettable"])
        self.assertEqual(observed["resizeError"], -25200)

    def test_E04_dialog_panel_and_sheet_float_with_subrole(self):
        for kind in ("dialog", "panel", "sheet"):
            with self.subTest(kind=kind):
                self.fixture.command("reset")
                window = self.open_window(kind)
                self.assert_state(window, "floats")
                observed = self.probe()
                flattened = observed + [sheet for item in observed for sheet in item["sheets"]]
                subrole = next(item["subrole"] for item in flattened if item["id"] == window)
                self.assertNotEqual(subrole, "AXStandardWindow")
                self.assert_state(window, "floats", subrole)
                fixture_ids = set(self.fixture.command("ping")["windows"].values())
                self.assertTrue(eventually(lambda: len(rows := self.rows()) == len(fixture_ids) and
                                           {row["id"] for row in rows} == fixture_ids))

    def test_E05_native_tabs_keep_one_front_entry_and_expose_minimized_ax_entries(self):
        reply = self.fixture.command("open", kind="tabs", key="tabs", count=3)
        first = reply["windows"]["tabs0"]
        self.assertTrue(eventually(lambda: len(rows := self.rows()) == 1 and rows[0]["tabs"] == 3))
        row = self.rows()[0]
        self.assertIn("3 native tabs", row["reason"])
        observed = self.probe()
        self.assertEqual(len(observed), 1, "fixture must match Terminal's one-front-tab AX signature")
        self.assertEqual(observed[0]["tabs"], 3)
        before = observed[0]["id"]
        second = reply["windows"]["tabs1"]
        self.fixture.command("tab", key="tabs1")
        self.assertTrue(eventually(lambda: len(rows := self.rows()) == 1 and rows[0]["id"] == second))
        observed = self.probe()
        self.assertEqual(len(observed), 1)
        self.assertNotEqual(observed[0]["id"], before)
        self.fixture.command("addTab", key="tabs3", reference="tabs1")
        self.assertTrue(eventually(lambda: len(rows := self.rows()) == 1 and rows[0]["tabs"] == 4))
        self.fixture.command("close", key="tabs3")
        self.assertTrue(eventually(lambda: len(rows := self.rows()) == 1 and rows[0]["tabs"] == 3))
        self.fixture.command("tab", key="tabs0")
        self.assert_state(first, "tiled")
        self.fixture.command("hide")
        self.assertTrue(eventually(lambda: len(rows := self.rows()) == 1 and rows[0]["state"] == "hidden" and rows[0]["tabs"] == 3))
        self.fixture.command("show")
        self.assertTrue(eventually(lambda: len(rows := self.rows()) == 1 and rows[0]["state"] == "tiled" and rows[0]["tabs"] == 3))
        self.fixture.command("minimize", key="tabs0")
        group_ids = {reply["windows"]["tabs" + str(index)] for index in range(3)}
        self.assertTrue(eventually(lambda: len(rows := self.rows()) == 3 and {row["id"] for row in rows} == group_ids and all(row["state"] == "minimized" for row in rows)))
        self.assertEqual(sorted(row["tabs"] for row in self.rows()), [1, 1, 3])
        self.assertEqual({item["id"] for item in self.probe()}, group_ids)
        # An unrelated minimized window must never be guessed into the group.
        separate = self.open_window(key="separate")
        self.fixture.command("minimize", key="separate")
        self.assertTrue(eventually(lambda: len(rows := self.rows()) == 4 and {row["id"] for row in rows} == group_ids | {separate} and all(row["state"] == "minimized" for row in rows)))
        self.fixture.command("close", key="separate")
        self.fixture.command("restore", key="tabs0")
        self.assertTrue(eventually(lambda: len(rows := self.rows()) == 1 and rows[0]["state"] == "tiled" and rows[0]["tabs"] == 3))
        for key in ("tabs0", "tabs1", "tabs2"):
            self.fixture.command("close", key=key)
        self.assertTrue(eventually(lambda: not self.rows()))

    def test_E05_content_tabs_do_not_count_as_native_window_tabs(self):
        window = self.open_window("contentTabs")
        row = self.assert_state(window, "tiled", "standard window")
        self.assertEqual(row["tabs"], 1)
        self.assertNotIn("native tabs", row["reason"])

    def test_E06_minimized_and_hidden_take_precedence_and_restore(self):
        ids = {}
        for kind in ("standard", "noFullscreen", "fixed", "dialog", "panel"):
            window = self.open_window(kind, key=kind)
            ids[kind] = window
            expected = "tiled" if kind in ("standard", "noFullscreen") else "floats"
            self.assert_state(window, expected)
            self.fixture.command("minimize", key=kind)
            self.assert_state(window, "minimized")
            self.fixture.command("restore", key=kind)
            self.assert_state(window, expected)
        self.fixture.command("hide")
        self.assertTrue(eventually(lambda: len(rows := self.rows()) == len(ids) and all(row["state"] == "hidden" for row in rows)))
        self.fixture.command("show")
        restored = {window_id: "tiled" if key in ("standard", "noFullscreen") else "floats"
                    for key, window_id in ids.items()}
        self.assertTrue(eventually(lambda: {row["id"]: row["state"] for row in self.rows()} == restored))
        self.fixture.command("minimize", key="fixed")
        self.assert_state(ids["fixed"], "minimized")
        self.fixture.command("hide")
        hidden = {window_id: "hidden" for key, window_id in ids.items() if key != "fixed"}
        def hidden_snapshot():
            rows = self.rows()
            return rows if {row["id"]: row["state"] for row in rows if row["id"] != ids["fixed"]} == hidden else None
        rows = eventually(hidden_snapshot)
        self.assertIsNotNone(rows, "fixture did not reach the hidden state within 500 ms")
        self.assertEqual({row["id"]: row["state"] for row in rows}, {**hidden, ids["fixed"]: "minimized"})
        self.fixture.command("show")
        self.fixture.command("restore", key="fixed")
        self.assert_state(ids["fixed"], "floats", "fixed size")

    def test_E07_new_window_converges_within_500ms_and_stays_classified(self):
        self.assert_state(self.open_window(key="anchor"), "tiled")
        time.sleep(0.55)  # Earlier settling must not observe the new window.
        window = self.open_window("noFullscreen", key="background", background=True)
        expected = self.assert_state(window, "tiled")
        time.sleep(0.5)
        for _ in range(20):
            self.assertEqual(self.row(window), expected)

    def test_E08_closed_windows_and_terminated_apps_disappear_within_500ms(self):
        self.assert_state(self.open_window(key="anchor"), "tiled")
        window = self.open_window(key="background", background=True)
        self.assert_state(window, "tiled")
        time.sleep(0.55)  # A settling or focus event must not replace destruction.
        self.fixture.command("close", key="background")
        self.assertTrue(eventually(lambda: self.row(window) is None))
        other = FixtureSession(self.directory, 1)
        self.other_fixtures.append(other)
        window = other.command("open", kind="standard", key="quit")["windows"]["quit"]
        self.assert_state(window, "tiled")
        other.stop()
        self.other_fixtures.remove(other)
        self.assertTrue(eventually(lambda: self.row(window) is None))

    def test_E09_startup_discovers_existing_windows_and_native_tab_groups(self):
        self.stop_app()
        try:
            expected = {}
            for kind in ("standard", "noFullscreen", "fixed", "dialog", "panel", "sheet"):
                window = self.open_window(kind, key=kind)
                expected[window] = "tiled" if kind in ("standard", "noFullscreen") else "floats"
                if kind == "sheet":
                    expected[self.fixture.command("ping")["windows"]["sheetParent"]] = "tiled"
            reply = self.fixture.command("open", kind="tabs", key="existingTabs", count=3)
            expected[reply["windows"]["existingTabs0"]] = "tiled"
            self.start_app(fixture_ready=False)
            for window, state in expected.items():
                self.assert_state(window, state)
            self.assertEqual(sum(row["tabs"] == 3 for row in self.rows()), 1)
            before = self.rows()
            self.stop_app()
            self.start_app(fixture_ready=False)
            self.assertTrue(eventually(lambda: self.rows() == before))
            self.stop_app()
            self.fixture.command("minimize", key="fixed")
            self.fixture.command("minimize", key="existingTabs0")
            self.fixture.command("hide")
            self.start_app(fixture_ready=False)
            minimized = {self.fixture.command("ping")["windows"]["fixed"]}
            tab_ids = {reply["windows"]["existingTabs" + str(index)] for index in range(3)}
            minimized.update(tab_ids)
            states = {row["id"]: "hidden" for row in before}
            states.update({window_id: "minimized" for window_id in minimized})
            self.assertTrue(eventually(lambda: {row["id"]: row["state"] for row in self.rows()} == states))
            self.assertEqual(sorted(row["tabs"] for row in self.rows() if row["id"] in tab_ids), [1, 1, 3])
        finally:
            if not process_ids(APP / "Contents/MacOS/TesselApp"):
                self.start_app(fixture_ready=False)

    def test_E10_neither_cli_format_exposes_window_titles(self):
        window = self.open_window(title="Fixture secret 1234")
        self.assert_state(window, "tiled")
        for flags in ((), ("--json",)):
            with self.subTest(format="json" if flags else "text"):
                result = self.invoke("windows", *flags)
                self.assertEqual(result.returncode, 0)
                self.assertFalse("Fixture secret 1234" in result.stdout + result.stderr, "CLI leaked a fixture window title")
        row = self.row(window)
        self.assertEqual(set(row), {"id", "app", "bundleId", "state", "reason", "tabs"})

    def test_E11_absent_app_fails_in_under_one_second(self):
        os.kill(self.app_pid, signal.SIGSTOP)
        try:
            started = time.monotonic()
            result = self.invoke("windows")
            self.assertLess(time.monotonic() - started, 1)
            self.assertNotEqual(result.returncode, 0, "a stalled server must not hang the CLI")
        finally:
            os.kill(self.app_pid, signal.SIGCONT)
        self.stop_app()
        try:
            started = time.monotonic()
            result = self.invoke("windows")
            self.assertLess(time.monotonic() - started, 1)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("tessel is not running", result.stderr)
        finally:
            self.start_app()

    def test_cli_rejects_unsupported_commands_and_arguments(self):
        for arguments in ((), ("move",), ("windows", "--titles"), ("status", "--json", "extra")):
            with self.subTest(arguments=arguments):
                result = self.invoke(*arguments)
                self.assertEqual(result.returncode, 2)
                self.assertIn("Usage: tessel", result.stderr)

    def test_transport_is_private_to_the_current_user(self):
        result = subprocess.run(["/usr/sbin/lsof", "-a", "-p", str(self.app_pid), "-U", "-Fn"], capture_output=True, text=True, check=True)
        paths = [Path(line[1:]) for line in result.stdout.splitlines() if line.startswith("n/") and line.endswith(".sock")]
        self.assertEqual(len(paths), 1)
        endpoint = paths[0]
        self.assertEqual(endpoint.stat().st_uid, os.getuid())
        self.assertEqual(stat.S_IMODE(endpoint.stat().st_mode), 0o600)
        self.assertEqual(endpoint.parent.stat().st_uid, os.getuid())
        self.assertEqual(stat.S_IMODE(endpoint.parent.stat().st_mode), 0o700)
        if os.environ.get("GITHUB_ACTIONS") == "true":
            attempt = "import socket,sys\ns=socket.socket(socket.AF_UNIX)\ns.settimeout(0.75)\ntry:\n s.connect(sys.argv[1])\nexcept PermissionError:\n sys.exit(0)\nexcept OSError:\n sys.exit(2)\nsys.exit(1)\n"
            denied = subprocess.run(["sudo", "-n", "-u", "nobody", sys.executable, "-c", attempt, str(endpoint)], capture_output=True, timeout=2)
            self.assertEqual(denied.returncode, 0, "a different Unix user must be denied access")

    def test_transport_rejects_mutations_and_stalled_clients_do_not_block_queries(self):
        result = subprocess.run(["/usr/sbin/lsof", "-a", "-p", str(self.app_pid), "-U", "-Fn"], capture_output=True, text=True, check=True)
        paths = [line[1:] for line in result.stdout.splitlines() if line.startswith("n/") and line.endswith(".sock")]
        self.assertEqual(len(paths), 1)
        with self.subTest(command="move"), socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
            client.settimeout(0.9)
            client.connect(paths[0])
            client.sendall(b"move\n")
            response = json.loads(client.makefile("rb").readline(4096))
            self.assertIn("read-only", response.get("error", ""))
        for payload in (b"", b"x" * 33, b"x" * 33 + b"\n", b"\xff\n"):
            with self.subTest(payloadLength=len(payload)), socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
                client.settimeout(0.9)
                client.connect(paths[0])
                client.sendall(payload)
                started = time.monotonic()
                self.assertEqual(self.status()["permission"], "granted")
                self.assertLess(time.monotonic() - started, 1)
                self.assertEqual(client.recv(1), b"", "a malformed or stalled client must be disconnected")

    def test_resource_cpu_measurement_matches_the_process_cpu_clock(self):
        before, _ = resources(os.getpid())
        clock = time.process_time_ns()
        while time.process_time_ns() - clock < 20_000_000:
            pass
        after, _ = resources(os.getpid())
        elapsed = time.process_time_ns() - clock
        self.assertGreater(after - before, elapsed * 0.75)
        self.assertLess(after - before, elapsed * 1.25)

    def test_native_notification_retries_and_symlinked_bundle_namespaces(self):
        # This command-line probe has no tessel bundle ID and never queries AX.
        # It exercises native CF identity and Foundation's bundle resolution.
        executable = self.directory / "NativeContracts"
        sources = [*sorted((ROOT / "Sources/Shared").glob("*.swift")),
                   ROOT / "Sources/App/AXSubscriptions.swift", ROOT / "Tests/Contracts/Main.swift"]
        compiled = subprocess.run(["xcrun", "swiftc", "-parse-as-library", "-swift-version", "6", "-O",
                                   "-target", "arm64-apple-macos27.0", *map(str, sources), "-o", str(executable)],
                                  capture_output=True, text=True, timeout=60)
        self.assertEqual(compiled.returncode, 0, compiled.stderr)
        with self.subTest(contract="transient AX registrations"):
            result = subprocess.run([str(executable)], capture_output=True, text=True, timeout=2)
            self.assertEqual(result.returncode, 0, result.stderr)

        def endpoint(command, env=self.env):
            result = subprocess.run([str(command), "namespace"], env=env, capture_output=True, text=True, timeout=2)
            self.assertEqual(result.returncode, 0, result.stderr)
            return result.stdout.strip()

        namespaces = []
        for index in range(2):
            bundle = self.directory / ("Generic Contract " + str(index) + ".app")
            macos = bundle / "Contents/MacOS"
            macos.mkdir(parents=True)
            (bundle / "Contents/Info.plist").write_bytes(plistlib.dumps({
                "CFBundleIdentifier": "org.example.foundation-contract." + str(index),
                "CFBundleExecutable": "Primary", "CFBundlePackageType": "APPL"}))
            shutil.copy2(executable, macos / "Primary")
            secondary = macos / "Secondary"
            shutil.copy2(executable, secondary)
            alias = self.directory / ("contract-link-" + str(index))
            alias.symlink_to(secondary)
            direct = endpoint(secondary)
            namespaces.append(direct)
            with self.subTest(contract="symlink preserves namespace", bundle=index):
                self.assertEqual(endpoint(alias), direct)
        self.assertNotEqual(*namespaces, "different bundles must have separate endpoints")
        alternate = {**self.env, "XDG_CONFIG_HOME": str(self.directory / "alternate-config")}
        self.assertNotEqual(endpoint(secondary, alternate), namespaces[-1], "different configs must have separate endpoints")

    def test_E12_status_reports_permission_config_path_error_line_and_version(self):
        status = self.status()
        with self.subTest(field="permission"):
            self.assertEqual(status.get("permission"), "granted")
        with self.subTest(field="config.path"):
            self.assertEqual(status.get("config", {}).get("path"), str(self.config_file))
        with self.subTest(field="config.state"):
            self.assertEqual(status["config"]["state"], "defaults")
        with self.subTest(field="version"):
            self.assertRegex(status.get("version", ""), r"^0\.1\.0")
        self.config_file.write_text("[experiments]\nunknown = true\n")
        status = eventually(lambda: (s if s.get("config", {}).get("state") == "error" else None) if (s := self.status()) else None, 1)
        self.assertIsNotNone(status)
        self.assertEqual(status["config"]["error"]["line"], 2)

    def test_E15_signed_rebuild_preserves_accessibility(self):
        self.assertEqual(self.status().get("permission"), "granted")
        before = self.status()["version"]
        window = self.open_window()
        self.assert_state(window, "tiled")
        self.stop_app()
        try:
            subprocess.run([str(ROOT / "scripts/build")], check=True, stdout=subprocess.DEVNULL)
            self.start_app()
            self.assertNotEqual(self.status()["version"], before, "the test must exercise a changed binary")
            self.assertEqual(self.status()["permission"], "granted")
            self.assert_state(window, "tiled")
        finally:
            if not process_ids(APP / "Contents/MacOS/TesselApp"):
                self.start_app()

    def test_E16_missing_or_adhoc_signing_configuration_cannot_produce_a_bundle(self):
        for index, value in enumerate((None, "", "-", "adhoc", "Ad-Hoc", "Sign to run locally", "Unavailable fixture signing identity")):
            with self.subTest(identity=value):
                config = self.directory / "NoIdentity.local.xcconfig"
                config.unlink(missing_ok=True)
                if value is not None:
                    config.write_text("CODE_SIGN_IDENTITY = " + value + "\n")
                output = self.directory / ("unsigned-output-" + str(index))
                result = subprocess.run([str(ROOT / "scripts/build"), "--signing-config", str(config), "--output-dir", str(output)], capture_output=True, text=True, timeout=2)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("docs/development.md", result.stderr)
                if value != "Unavailable fixture signing identity":
                    self.assertIn("Signing.local.xcconfig", result.stderr)
                self.assertFalse(output.exists())

    def test_E17_missing_configuration_uses_defaults_without_an_error(self):
        self.stop_app()
        self.config_file.unlink(missing_ok=True)
        self.start_app()
        config = self.status().get("config", {})
        self.assertEqual(config.get("state"), "defaults")
        self.assertIsNone(config.get("error"))
        self.assertEqual(config.get("effective"), {"experiments": {}})

    def test_E18_valid_save_and_atomic_replace_reload_within_one_second(self):
        before = self.status().get("config", {}).get("revision", 0)
        self.config_file.write_text("# Valid foundation configuration\n[experiments]\n")
        self.assertTrue(eventually(lambda: self.status().get("config", {}).get("state") == "loaded", 1))
        config = self.status()["config"]
        self.assertGreater(config["revision"], before)
        before = config["revision"]
        self.config_file.write_text("[experiments] # edited in place\n")
        self.assertTrue(eventually(lambda: self.status()["config"]["revision"] > before, 1))
        before = self.status()["config"]["revision"]
        replacement = self.config_file.with_suffix(".new")
        replacement.write_text("['experiments'] # saved atomically\n")
        replacement.replace(self.config_file)
        self.assertTrue(eventually(lambda: self.status()["config"]["revision"] > before, 1))
        before = self.status()["config"]["revision"]
        self.config_file.write_text('["\\U00000065xperiments"]\r\n')
        self.assertTrue(eventually(lambda: self.status()["config"]["state"] == "loaded" and self.status()["config"]["revision"] > before, 1))

    def test_E19_invalid_or_unknown_toml_keeps_last_valid_config_and_recovers(self):
        self.config_file.write_text("[experiments]\n")
        self.assertTrue(eventually(lambda: self.status().get("config", {}).get("state") == "loaded", 1))
        valid = self.status()["config"]
        for text, line in [("# bad table\n[experiments\n", 2), ("[experiments]\nunknown = true\n", 2),
                           ("[unknown]\n", 1), ("[experiments]\r\nunknown = true\r\n", 2),
                           ("\u00a0[experiments]\n", 1), ("[experiments]\n[experiments]\n", 2),
                           ("# comment\n# bad\x00comment\n", 2), ("# comment\n# bad\x7fcomment\n", 2),
                           ('["\\qexperiments"]\n', 1), ('["\\uD800"]\n', 1),
                           ('["\\U00110000"]\n', 1), ('["experiments"" ]\n', 1),
                           ("[[experiments]]\n", 1), ("#" * 65_537, 1), (b"\xff", 1)]:
            with self.subTest(config=text[:80], line=line):
                revision = self.status()["config"]["revision"]
                self.config_file.write_text("[experiments] # before malformed input " + str(revision) + "\n")
                self.assertTrue(eventually(lambda: (config := self.status()["config"])["state"] == "loaded" and
                                           config["error"] is None and config["revision"] > revision, 1))
                valid = self.status()["config"]
                if isinstance(text, bytes):
                    self.config_file.write_bytes(text)
                else:
                    self.config_file.write_text(text)
                status = eventually(lambda: (s if s.get("config", {}).get("state") == "error" and s["config"]["error"]["line"] == line else None) if (s := self.status()) else None, 1)
                self.assertIsNotNone(status)
                self.assertEqual(status["config"]["error"]["line"], line)
                self.assertEqual(status["config"]["effective"], valid["effective"])
                self.assertEqual(status["config"]["revision"], valid["revision"])
                self.assertEqual(status["permission"], "granted")
                self.assertTrue(process_ids(APP / "Contents/MacOS/TesselApp"))
        self.config_file.write_text("[experiments] # repaired\n")
        self.assertTrue(eventually(lambda: self.status()["config"]["state"] == "loaded" and self.status()["config"]["error"] is None, 1))
        self.config_file.chmod(0)
        try:
            self.assertTrue(eventually(lambda: self.status()["config"]["state"] == "error", 1))
        finally:
            self.config_file.chmod(0o600)
        self.assertTrue(eventually(lambda: self.status()["config"]["state"] == "loaded" and self.status()["config"]["error"] is None, 1))

    def test_E20_deleting_configuration_returns_to_defaults(self):
        self.config_file.write_text("[experiments]\n")
        self.assertTrue(eventually(lambda: self.status().get("config", {}).get("state") == "loaded", 1))
        self.config_file.unlink()
        self.assertTrue(eventually(lambda: self.status()["config"]["state"] == "defaults", 1))
        self.assertEqual(self.status()["config"]["effective"], {"experiments": {}})

    def test_E21_a_blocked_app_keeps_last_classification_without_blocking_other_apps(self):
        window = self.open_window()
        self.assert_state(window, "tiled")
        for kind in ("noFullscreen", "fixed", "dialog", "panel", "sheet"):
            created = self.open_window(kind, key=kind)
            self.assert_state(created, "tiled" if kind == "noFullscreen" else "floats")
        self.fixture.command("open", kind="tabs", key="hungTabs", count=3)
        self.assertTrue(eventually(lambda: any(row["tabs"] == 3 for row in self.rows())))
        time.sleep(0.55)
        expected = {row["id"]: row for row in self.rows()}
        self.fixture.command("hang")
        other = FixtureSession(self.directory, 2)
        self.other_fixtures.append(other)
        try:
            for index in range(3):
                key = "responsive" + str(index)
                new_id = other.command("open", kind="standard", key=key)["windows"][key]
                self.assert_state(new_id, "tiled")
                started = time.monotonic()
                observed = {row["id"]: row for row in self.rows() if row["id"] in expected}
                self.assertEqual(observed, expected)
                self.assertLess(time.monotonic() - started, 1)
                other.command("close", key=key)
                self.assertTrue(eventually(lambda: self.row(new_id) is None))
        finally:
            self.fixture.stop()
            self.fixture = FixtureSession(self.directory, 3)
            type(self).fixture = self.fixture
            other.stop()
            self.other_fixtures.remove(other)

    def test_E22_twenty_idle_windows_stay_within_cpu_and_memory_budgets(self):
        for index in range(20):
            self.open_window(key="idle" + str(index))
        self.assertTrue(eventually(lambda: len(self.rows()) == 20, 2))
        time.sleep(1)  # Let the bounded new-window settling work finish.
        budget = json.loads((ROOT / "Tests/Acceptance/resource-budget.json").read_text())
        measurements = []
        for index in range(10):
            before, _ = resources(self.app_pid)
            time.sleep(60)
            after, resident = resources(self.app_pid)
            measurement = {"cpuNanoseconds": after - before, "residentBytes": resident}
            measurements.append(measurement)
            print(f"\nE22 run {index + 1}/10: CPU {measurement['cpuNanoseconds'] / 1e6:.3f} ms, RSS {resident / 1e6:.2f} MB", flush=True)
            self.assertLess(resident, budget["residentBytes"])
            self.assertLess(after - before, 100_000_000 if CALIBRATE else budget["cpuNanoseconds"])
        maximum = max(item["cpuNanoseconds"] for item in measurements)
        result = {"measurements": measurements, "cpuNanoseconds": min(100_000_000, maximum * 3), "residentBytes": 50_000_000,
                  "machTimebase": {"numer": TIMEBASE.numer, "denom": TIMEBASE.denom}}
        destination = ROOT / ".work/resource-calibration.json"
        destination.parent.mkdir(exist_ok=True)
        destination.write_text(json.dumps(result, indent=2) + "\n")
        print(f"\nE22 calibration: {result['cpuNanoseconds']} ns (3 × maximum of ten CI runs)", flush=True)
