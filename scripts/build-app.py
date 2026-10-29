#!/usr/bin/env python3
"""Build or install CRT Player with timed, observable stages."""

import argparse
from contextlib import contextmanager
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import tempfile
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


def build():
    config = os.environ.get("CONFIG", "release")
    app = Path("build/CRT Player.app")
    progress = Progress(7)
    progress.line(f"CRT Player · Build · {config}", "1")
    progress.line(f"  Output: {app.resolve()}", "2")

    with progress.stage("Check build dependencies"):
        if not shutil.which("pkg-config") or subprocess.run(["pkg-config", "--exists", "mpv"]).returncode:
            raise RuntimeError("libmpv is required. Install build dependencies with: brew install mpv pkg-config")

    with progress.stage("Compile Swift app"):
        run("swift", "build", "-c", config, "--product", "CRTPlayer")
        bin_dir = Path(subprocess.check_output(["swift", "build", "-c", config, "--show-bin-path"], text=True).strip())

    with progress.stage("Assemble app bundle"):
        if app.exists():
            shutil.rmtree(app)
        (app / "Contents/MacOS").mkdir(parents=True)
        resources = app / "Contents/Resources"
        resources.mkdir()
        shutil.copy2(bin_dir / "CRTPlayer", app / "Contents/MacOS/CRTPlayer")
        shutil.copy2("Sources/CRTPlayer/Info.plist", app / "Contents/Info.plist")
        shutil.copy2("Resources/Demo.mp4", resources / "Demo.mp4")

    with progress.stage("Bundle playback libraries"):
        run(sys.executable, "-u", "scripts/bundle-libraries.py", app)

    with progress.stage("Compile app icon"):
        # actool emits both Assets.car and an .icns fallback from the Composer icon.
        with tempfile.TemporaryDirectory(prefix="crt-player-icon-") as temporary:
            run("xcrun", "actool", "Resources/AppIcon.icon", "--compile", resources,
                "--platform", "macosx", "--minimum-deployment-target", "26.0",
                "--app-icon", "AppIcon", "--output-partial-info-plist",
                Path(temporary) / "partial.plist", "--output-format", "human-readable-text",
                "--errors", "--warnings")

    with progress.stage("Sign app bundle"):
        run("codesign", "--force", "--sign", "-", app)

    with progress.stage("Verify app signature"):
        run("codesign", "--verify", "--deep", "--strict", app)

    progress.line(f"\nBuilt {app} in {duration(time.monotonic() - progress.started)}", "1;32")


def install(install_dir):
    app = Path("build/CRT Player.app")
    destination = install_dir / app.name
    progress = Progress(3)
    progress.line("CRT Player · Install", "1")
    progress.line(f"  Source: {app.resolve()}\n  Install: {destination}", "2")

    with progress.stage("Verify source app"):
        if destination.resolve() == app.resolve():
            raise RuntimeError("Install destination must differ from the build output")
        run("codesign", "--verify", "--deep", "--strict", app)

    with progress.stage("Install app bundle"):
        if destination.exists():
            shutil.rmtree(destination)
        run("ditto", app, destination)

    with progress.stage("Verify installed app"):
        run("codesign", "--verify", "--deep", "--strict", destination)

    progress.line(f"\nInstalled {destination} in {duration(time.monotonic() - progress.started)}", "1;32")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--install", action="store_true", help="copy the built app to the install directory")
    parser.add_argument("--install-dir", type=Path, default=Path("/Applications"))
    args = parser.parse_args()
    try:
        install_dir = args.install_dir.expanduser().resolve()
        os.chdir(Path(__file__).resolve().parent.parent)
        if args.install:
            install(install_dir)
        else:
            build()
    except KeyboardInterrupt:
        print("\nCancelled.", file=sys.stderr, flush=True)
        return 130
    except subprocess.CalledProcessError as error:
        print(f"\nCommand exited with status {error.returncode}: {shlex.join(error.cmd)}", file=sys.stderr, flush=True)
        return error.returncode if error.returncode > 0 else 1
    except (OSError, RuntimeError) as error:
        print(f"\nError: {error}", file=sys.stderr, flush=True)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
