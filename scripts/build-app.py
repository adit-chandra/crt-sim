#!/usr/bin/env python3
"""Build or install CRT Sim with timed, observable stages."""

import argparse
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import tempfile
import time

from build_support import Progress, duration, run


def build():
    config = os.environ.get("CONFIG", "release")
    app = Path("build/CRT Sim.app")
    progress = Progress(7)
    progress.line(f"CRT Sim · Build · {config}", "1")
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
        shutil.copy2("Apps/macOS/CRTPlayer/Info.plist", app / "Contents/Info.plist")
        shutil.copy2("Resources/Demo.mp4", resources / "Demo.mp4")

    with progress.stage("Bundle playback libraries"):
        run(sys.executable, "-u", "scripts/bundle-libraries.py", app)

    with progress.stage("Compile app icon"):
        # actool emits both Assets.car and an .icns fallback from the Composer icon.
        with tempfile.TemporaryDirectory(prefix="crt-sim-icon-") as temporary:
            run("xcrun", "actool", Path("Resources/AppIcon.icon").resolve(), "--compile", resources.resolve(),
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
    app = Path("build/CRT Sim.app")
    destination = install_dir / app.name
    progress = Progress(3)
    progress.line("CRT Sim · Install", "1")
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
