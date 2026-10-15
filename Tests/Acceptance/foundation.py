"""The accepted #1 examples, exercised at the shipped CLI boundary.

Only fixture records reach assertions. Never print or persist a full window listing.
"""
import ctypes
import json
import os
from pathlib import Path
import re
import signal
import socket
import subprocess
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


def resources(pid):
    usage = RUsage()
    libproc = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
    if libproc.proc_pid_rusage(pid, 0, ctypes.byref(usage)):
        raise OSError(ctypes.get_errno(), "cannot read tessel resource usage")
    return usage.user_time + usage.system_time, usage.resident_size


class FoundationAcceptance(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if not CLI.exists() or not FIXTURE_BIN.exists():
            raise RuntimeError("Run scripts/build first; signed app and fixture bundles are required")
        if process_ids(APP / "Contents/MacOS/TesselApp"):
            raise RuntimeError("This worktree's development app is already running; stop it before verification")
        cls.temporary = tempfile.TemporaryDirectory(prefix="tessel-verify-")
        cls.directory = Path(cls.temporary.name)
        cls.config_home = cls.directory / "config"
        cls.config_file = cls.config_home / "tessel/tessel.toml"
        cls.config_file.parent.mkdir(parents=True)
        cls.env = {**os.environ, "XDG_CONFIG_HOME": str(cls.config_home)}
        cls.fixture = FixtureSession(cls.directory, 0)
        cls.other_fixtures = []
        cls.start_app()

    @classmethod
    def start_app(cls):
        subprocess.run(["open", "-n", "-g", "--stdout", "/dev/null", "--stderr", "/dev/null", "--env", "XDG_CONFIG_HOME=" + str(cls.config_home), str(APP)], check=True)
        pids = eventually(lambda: process_ids(APP / "Contents/MacOS/TesselApp"), 5)
        if not pids:
            raise RuntimeError("signed development app did not launch")
        cls.app_pid = pids[0]
        # Launch readiness is separate from the 500 ms event deadlines.
        eventually(lambda: cls.invoke("status", "--json").returncode == 0, 5)

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
        cls.stop_app()
        cls.fixture.stop()
        for fixture in cls.other_fixtures:
            fixture.stop()
        cls.temporary.cleanup()

    @classmethod
    def invoke(cls, *arguments):
        return subprocess.run([str(CLI), *arguments], env=cls.env, capture_output=True, text=True, timeout=1.2)

    def status(self):
        result = self.invoke("status", "--json")
        self.assertEqual(result.returncode, 0, "status command failed (window data withheld)")
        value = json.loads(result.stdout)
        self.assertIsInstance(value, dict)
        return value

    def rows(self):
        result = self.invoke("windows", "--json")
        self.assertEqual(result.returncode, 0, "windows command failed; check Accessibility using tessel status")
        value = json.loads(result.stdout)
        self.assertIsInstance(value, list, "window listing is not implemented")
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
        command = [str(FIXTURE_BIN), "--probe", str(self.fixture.pid)]
        if resize_id:
            command.append(str(resize_id))
        result = subprocess.run(command, capture_output=True, text=True, timeout=2)
        self.assertEqual(result.returncode, 0, "independent fixture AX probe needs Accessibility")
        return json.loads(result.stdout)["windows"]

    def setUp(self):
        self.fixture.command("reset")
        self.config_file.unlink(missing_ok=True)
        eventually(lambda: self.status().get("config", {}).get("state") == "defaults", 1)

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

    def test_E05_native_tabs_remain_one_entry_through_switch_add_and_close(self):
        reply = self.fixture.command("open", kind="tabs", key="tabs", count=3)
        first = reply["windows"]["tabs0"]
        self.assertTrue(eventually(lambda: len(self.rows()) == 1 and self.rows()[0]["tabs"] == 3))
        row = self.rows()[0]
        self.assertIn("3 native tabs", row["reason"])
        observed = self.probe()
        self.assertEqual(len(observed), 1, "fixture must match Terminal's one-front-tab AX signature")
        self.assertEqual(observed[0]["tabs"], 3)
        before = observed[0]["id"]
        second = reply["windows"]["tabs1"]
        self.fixture.command("tab", key="tabs1")
        self.assertTrue(eventually(lambda: len(self.rows()) == 1 and self.rows()[0]["id"] == second))
        observed = self.probe()
        self.assertEqual(len(observed), 1)
        self.assertNotEqual(observed[0]["id"], before)
        self.fixture.command("addTab", key="tabs3", reference="tabs1")
        self.assertTrue(eventually(lambda: len(self.rows()) == 1 and self.rows()[0]["tabs"] == 4))
        self.fixture.command("close", key="tabs3")
        self.assertTrue(eventually(lambda: len(self.rows()) == 1 and self.rows()[0]["tabs"] == 3))
        self.fixture.command("tab", key="tabs0")
        self.assert_state(first, "tiled")
        self.fixture.command("minimize", key="tabs0")
        self.assertTrue(eventually(lambda: len(self.rows()) == 1 and self.rows()[0]["state"] == "minimized"))
        self.fixture.command("restore", key="tabs0")
        self.assertTrue(eventually(lambda: len(self.rows()) == 1 and self.rows()[0]["state"] == "tiled"))
        for key in ("tabs0", "tabs1", "tabs2"):
            self.fixture.command("close", key=key)
        self.assertTrue(eventually(lambda: not self.rows()))

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
        self.assertTrue(eventually(lambda: len(self.rows()) == len(ids) and all(row["state"] == "hidden" for row in self.rows())))
        self.fixture.command("show")
        self.assertTrue(eventually(lambda: len(self.rows()) == len(ids) and all(row["state"] not in ("hidden", "minimized") for row in self.rows())))

    def test_E07_new_window_converges_within_500ms_and_stays_classified(self):
        window = self.open_window("noFullscreen")
        expected = self.assert_state(window, "tiled")
        time.sleep(0.5)
        for _ in range(20):
            self.assertEqual(self.row(window), expected)

    def test_E08_closed_windows_and_terminated_apps_disappear_within_500ms(self):
        window = self.open_window()
        self.assert_state(window, "tiled")
        self.fixture.command("close")
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
            reply = self.fixture.command("open", kind="tabs", key="existingTabs", count=3)
            expected[reply["windows"]["existingTabs0"]] = "tiled"
            self.start_app()
            for window, state in expected.items():
                self.assert_state(window, state)
            self.assertEqual(sum(row["tabs"] == 3 for row in self.rows()), 1)
            before = self.rows()
            self.stop_app()
            self.start_app()
            self.assertTrue(eventually(lambda: self.rows() == before))
        finally:
            if not process_ids(APP / "Contents/MacOS/TesselApp"):
                self.start_app()

    def test_E10_neither_cli_format_exposes_window_titles(self):
        window = self.open_window(title="Fixture secret 1234")
        self.assert_state(window, "tiled")
        for flags in ((), ("--json",)):
            result = self.invoke("windows", *flags)
            self.assertEqual(result.returncode, 0)
            self.assertFalse("Fixture secret 1234" in result.stdout + result.stderr, "CLI leaked a fixture window title")
        row = self.row(window)
        self.assertEqual(set(row), {"id", "app", "bundleId", "state", "reason", "tabs"})

    def test_E11_absent_app_fails_in_under_one_second(self):
        self.stop_app()
        try:
            started = time.monotonic()
            result = self.invoke("windows")
            self.assertLess(time.monotonic() - started, 1)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("tessel is not running", result.stderr)
        finally:
            self.start_app()

    def test_E12_status_reports_permission_config_path_error_line_and_version(self):
        status = self.status()
        self.assertEqual(status.get("permission"), "granted")
        self.assertEqual(status.get("config", {}).get("path"), str(self.config_file))
        self.assertEqual(status["config"]["state"], "defaults")
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
        for value in (None, "-", "Sign to run locally"):
            with self.subTest(identity=value):
                config = self.directory / "NoIdentity.local.xcconfig"
                config.unlink(missing_ok=True)
                if value is not None:
                    config.write_text("CODE_SIGN_IDENTITY = " + value + "\n")
                output = self.directory / "unsigned-output"
                result = subprocess.run([str(ROOT / "scripts/build"), "--signing-config", str(config), "--output-dir", str(output)], capture_output=True, text=True, timeout=2)
                self.assertNotEqual(result.returncode, 0)
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
                           ("\u00a0[experiments]\n", 1)]:
            with self.subTest(config=text):
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
        expected = self.assert_state(window, "tiled")
        self.fixture.command("hang")
        other = FixtureSession(self.directory, 2)
        self.other_fixtures.append(other)
        try:
            for index in range(3):
                key = "responsive" + str(index)
                new_id = other.command("open", kind="standard", key=key)["windows"][key]
                self.assert_state(new_id, "tiled")
                started = time.monotonic()
                self.assertEqual(self.row(window), expected)
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
        result = {"measurements": measurements, "cpuNanoseconds": min(100_000_000, maximum * 3), "residentBytes": 50_000_000}
        destination = ROOT / ".work/resource-calibration.json"
        destination.parent.mkdir(exist_ok=True)
        destination.write_text(json.dumps(result, indent=2) + "\n")
        print(f"\nE22 calibration: {result['cpuNanoseconds']} ns (3 × maximum of ten CI runs)", flush=True)
