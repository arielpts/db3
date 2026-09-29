#!/usr/bin/env python3
"""Embed native dependencies with only bundle-relative or system load paths."""
from pathlib import Path
import shutil
import subprocess
import sys
ROOT = Path(__file__).resolve().parents[1]
app = Path(sys.argv[1])
source = ROOT / "Vendor/PostgreSQL"
destination = app / "Contents/Frameworks"
destination.mkdir(parents=True, exist_ok=True)
for library in (source / "lib").glob("*.dylib"):
    if library.is_symlink(): continue
    shutil.copy2(library, destination / library.name)
resources = app / "Contents/Resources/PostgreSQL"
resources.mkdir(parents=True, exist_ok=True)
shutil.copy2(source / "manifest.json", resources / "manifest.json")
shutil.copytree(source / "licenses", resources / "licenses", dirs_exist_ok=True)
executable = app / "Contents/MacOS/db3"
if executable.exists():
    details = subprocess.check_output(["otool", "-l", str(executable)], text=True).splitlines()
    for index, line in enumerate(details):
        if line.strip() == "cmd LC_RPATH":
            path = details[index + 2].strip().split(" (offset", 1)[0].removeprefix("path ")
            if "Vendor/PostgreSQL" in path:
                subprocess.run(["install_name_tool", "-delete_rpath", path, str(executable)], check=True, capture_output=True)
print(f"Embedded PostgreSQL in {app.name}")
