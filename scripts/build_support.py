"""Timed build stages shared by the macOS and iOS entry points."""

from contextlib import contextmanager
import os
import subprocess
import sys
import threading
import time


def duration(seconds):
    seconds = int(seconds)
    minutes, seconds = divmod(seconds, 60)
    return f"{minutes}m {seconds:02d}s" if minutes else f"{seconds}s"


class Progress:
    def __init__(self, total, heartbeat=10):
        self.total = total
        self.current = 0
        self.heartbeat = heartbeat
        self.started = time.monotonic()
        self.color = sys.stderr.isatty() and "NO_COLOR" not in os.environ and os.environ.get("TERM") != "dumb"

    def line(self, message, color="36"):
        if self.color:
            message = f"\033[{color}m{message}\033[0m"
        print(message, file=sys.stderr, flush=True)

    @contextmanager
    def stage(self, label):
        self.current += 1
        prefix = f"[{self.current}/{self.total}] {label}"
        self.line(f"\n{prefix}", "1;36")
        started = time.monotonic()
        stopped = threading.Event()

        def heartbeat():
            while not stopped.wait(self.heartbeat):
                self.line(f"\n  ... {label} still working ({duration(time.monotonic() - started)})", "2")

        worker = threading.Thread(target=heartbeat, daemon=True)
        worker.start()
        try:
            yield
        except BaseException as error:
            stopped.set()
            worker.join()
            status = "cancelled" if isinstance(error, KeyboardInterrupt) else "failed"
            self.line(f"  {status.upper()} {label} after {duration(time.monotonic() - started)}", "31")
            raise
        else:
            stopped.set()
            worker.join()
            self.line(f"  OK {label} ({duration(time.monotonic() - started)})", "32")


def run(*args):
    subprocess.run([str(arg) for arg in args], check=True)
