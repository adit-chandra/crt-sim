"""Exercise quiet stages and failures without building or installing an app."""

from contextlib import redirect_stderr
import importlib.util
import io
import os
from pathlib import Path
import subprocess
import tempfile
import threading
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("build_app", ROOT / "scripts/build-app.py")
build_app = importlib.util.module_from_spec(spec)
spec.loader.exec_module(build_app)


class HeartbeatOutput(io.StringIO):
    def __init__(self):
        super().__init__()
        self.heartbeat = threading.Event()

    def write(self, text):
        result = super().write(text)
        if "still working" in text:
            self.heartbeat.set()
        return result


class BuildOutputTests(unittest.TestCase):
    def test_quiet_stage_reports_activity_and_stops_after_completion(self):
        output = HeartbeatOutput()
        with redirect_stderr(output):
            progress = build_app.Progress(1, heartbeat=0.01)
            with progress.stage("Quiet command"):
                self.assertTrue(output.heartbeat.wait(2), "No heartbeat for a quiet stage")
            completed = output.getvalue()
            output.heartbeat.clear()
            self.assertFalse(output.heartbeat.wait(0.05), "Heartbeat survived stage completion")
        self.assertIn("OK Quiet command", completed)
        self.assertNotIn("\033", completed)

    def test_failure_and_cancellation_never_report_success(self):
        for error, status in [(RuntimeError("broken"), "FAILED"), (KeyboardInterrupt(), "CANCELLED")]:
            with self.subTest(status=status):
                output = HeartbeatOutput()
                with redirect_stderr(output):
                    progress = build_app.Progress(1, heartbeat=0.01)
                    with self.assertRaises(type(error)):
                        with progress.stage("Broken command"):
                            raise error
                    self.assertFalse(output.heartbeat.wait(0.05))
                self.assertIn(status + " Broken command", output.getvalue())
                self.assertNotIn("OK", output.getvalue())

    def test_color_requires_terminal_and_respects_no_color(self):
        for terminal, environment, expected in [
            (True, {"TERM": "xterm-256color"}, True),
            (False, {"TERM": "xterm-256color"}, False),
            (True, {"TERM": "dumb"}, False),
            (True, {"TERM": "xterm-256color", "NO_COLOR": ""}, False),
        ]:
            with self.subTest(terminal=terminal, environment=environment):
                output = io.StringIO()
                with patch.object(output, "isatty", return_value=terminal), redirect_stderr(output), patch.dict(os.environ, environment, clear=True):
                    build_app.Progress(1).line("Stage")
                self.assertEqual("\033[" in output.getvalue(), expected)

    def test_command_failure_preserves_diagnostics_and_exit_status(self):
        with tempfile.TemporaryDirectory(prefix="crt-build-test-") as temporary:
            tools = Path(temporary)
            for name, body in [("pkg-config", "exit 0"), ("swift", "echo 'compiler diagnostic' >&2\nexit 23")]:
                executable = tools / name
                executable.write_text("#!/bin/sh\n" + body + "\n")
                executable.chmod(0o755)
            result = subprocess.run(
                [str(ROOT / "scripts/build-app.sh")], cwd=temporary,
                env={**os.environ, "PATH": f"{tools}:/usr/bin:/bin", "CONFIG": "debug"},
                capture_output=True, text=True,
            )
        self.assertEqual(result.returncode, 23)
        self.assertIn("compiler diagnostic", result.stderr)
        self.assertIn("FAILED Compile Swift app", result.stderr)
        self.assertIn("swift build -c debug --product CRTPlayer", result.stderr)
        self.assertNotIn("Assemble app bundle", result.stderr)
        self.assertNotIn("\033", result.stderr)


if __name__ == "__main__":
    unittest.main()
