#!/usr/bin/env python3
"""Copy the linked playback libraries into the app and make their paths relocatable."""
import json
import re
import shutil
import subprocess
import sys
from pathlib import Path


def output(*args):
    return subprocess.check_output(args, text=True)


def run(*args):
    result = subprocess.run(args, capture_output=True, text=True)
    if result.returncode:
        sys.stderr.write(result.stdout + result.stderr)
        result.check_returncode()


def dependencies(binary):
    return [line.strip().split(" (", 1)[0] for line in output("otool", "-L", str(binary)).splitlines()[1:]]


def system(path):
    return path.startswith(("/System/Library/", "/usr/lib/"))


def resolve(name, source, executable):
    def expand(path):
        return Path(path.replace("@loader_path", str(source.parent))
                    .replace("@executable_path", str(executable.parent)))

    if name.startswith("@rpath/"):
        rpaths = re.findall(r"cmd LC_RPATH\s+cmdsize \d+\s+path (.*?) \(offset", output("otool", "-l", str(source)))
        for path in rpaths:
            candidate = expand(path) / name.removeprefix("@rpath/")
            if candidate.is_file():
                return candidate.resolve()
        raise RuntimeError(f"Cannot resolve {name} from {source}")
    path = expand(name)
    if not path.is_file():
        raise RuntimeError(f"Missing dependency {path} from {source}")
    return path.resolve()


def bundle(app):
    executable = app / "Contents/MacOS/CRTPlayer"
    framework_dir = app / "Contents/Frameworks"
    framework_dir.mkdir(exist_ok=True)
    licenses = app / "Contents/Resources/ThirdParty"
    licenses.mkdir(exist_ok=True)
    queue = [(executable, executable)]
    copied = {}
    packages = {}
    while queue:
        source, destination = queue.pop(0)
        for name in dependencies(source):
            if system(name):
                continue
            library = resolve(name, source, executable)
            if library == source.resolve():  # LC_ID_DYLIB is also printed by otool -L.
                continue
            basename = library.name
            if basename in copied and copied[basename] != library:
                raise RuntimeError(f"Conflicting library names: {library} and {copied[basename]}")
            if basename not in copied:
                copied[basename] = library
                target = framework_dir / basename
                shutil.copy2(library, target)
                target.chmod(0o755)
                run("install_name_tool", "-id", f"@rpath/{basename}", str(target))
                queue.append((library, target))
                for parent in library.parents:
                    receipt = parent / "INSTALL_RECEIPT.json"
                    if receipt.is_file():
                        key = f"{parent.parent.name}-{parent.name}"
                        if key not in packages:
                            packages[key] = json.loads(receipt.read_text()).get("source", {})
                            for notice in parent.rglob("*"):
                                if notice.is_file() and notice.name.lower().startswith(("license", "copying", "copyright")):
                                    notice_target = licenses / key / notice.relative_to(parent)
                                    notice_target.parent.mkdir(parents=True, exist_ok=True)
                                    shutil.copy2(notice, notice_target)
                        break
            prefix = "@executable_path/../Frameworks" if destination == executable else "@loader_path"
            run("install_name_tool", "-change", name, f"{prefix}/{basename}", str(destination))
    (licenses / "libraries.json").write_text(json.dumps(packages, indent=2) + "\n")
    for name in copied:
        target = framework_dir / name
        run("codesign", "--force", "--sign", "-", str(target))
    # Reject any forgotten absolute build-machine paths before signing the app.
    for binary in [executable, *(framework_dir / name for name in copied)]:
        for name in dependencies(binary):
            if not system(name) and not name.startswith(("@loader_path/", "@executable_path/", "@rpath/")):
                raise RuntimeError(f"Unbundled dependency in {binary}: {name}")
    print(f"Bundled {len(copied)} playback libraries")


if __name__ == "__main__":
    bundle(Path(sys.argv[1]).resolve())
