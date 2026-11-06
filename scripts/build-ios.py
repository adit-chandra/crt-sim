#!/usr/bin/env python3
"""Build or test the iOS app using the checked-in Xcode project."""

import argparse
import json
import os
from pathlib import Path
import re
import shlex
import subprocess
import sys
import time

from build_support import Progress, duration, run


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=["build", "test"], nargs="?", default="build")
    parser.add_argument("--destination", default=os.environ.get("IOS_DESTINATION"))
    args = parser.parse_args()
    os.chdir(Path(__file__).resolve().parent.parent)
    progress = Progress(2)
    try:
        with progress.stage("Select iOS destination"):
            destination = args.destination
            if not destination and args.action == "test":
                devices = json.loads(subprocess.check_output(["xcrun", "simctl", "list", "devices", "available", "--json"], text=True))
                phones = [device for runtime, devices in devices["devices"].items()
                          if (version := re.search(r"iOS-(\d+)", runtime)) and int(version[1]) >= 26
                          for device in devices if device["name"].startswith("iPhone")]
                if not phones:
                    raise RuntimeError("No compatible iPhone simulator is installed. Add an iOS 26 or later runtime in Xcode Settings → Components.")
                device = next((device for device in phones if device["state"] == "Booted"), phones[0])
                destination = f"platform=iOS Simulator,id={device['udid']}"
            destination = destination or "generic/platform=iOS Simulator"
            progress.line(f"  {destination}")
        with progress.stage("Test iOS app" if args.action == "test" else "Build iOS app"):
            run("xcodebuild", "-project", "Apps/iOS/CRTPlayer.xcodeproj", "-scheme", "CRT Sim iOS",
                "-configuration", "Debug", "-destination", destination,
                "-derivedDataPath", "build/iOS", "-parallel-testing-enabled", "NO",
                args.action, "CODE_SIGNING_ALLOWED=NO")
        progress.line(f"\niOS {args.action} finished in {duration(time.monotonic() - progress.started)}", "1;32")
        return 0
    except KeyboardInterrupt:
        print("\nCancelled.", file=sys.stderr)
        return 130
    except subprocess.CalledProcessError as error:
        print(f"\nCommand exited with status {error.returncode}: {shlex.join(error.cmd)}", file=sys.stderr)
        return error.returncode if error.returncode > 0 else 1
    except (OSError, RuntimeError) as error:
        print(f"\nError: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
