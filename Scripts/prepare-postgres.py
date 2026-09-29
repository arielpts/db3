#!/usr/bin/env python3
"""Vendor a pinned local libpq build and its non-system dependencies.

Run once on the build machine. The packaged application never needs Homebrew.
The manifest records hashes/versions so binary inputs can be audited.
"""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
DEST = ROOT / "Vendor/PostgreSQL"
EXPECTED = "17.9"

def output(*args):
    return subprocess.check_output(args, text=True).strip()

config = os.environ.get("PG_CONFIG", "pg_config")
version = output(config, "--version")
if not version.startswith("PostgreSQL " + EXPECTED):
    sys.exit(f"Expected PostgreSQL {EXPECTED}; got {version}. Set PG_CONFIG to the pinned build.")
include = Path(output(config, "--includedir"))
lib = Path(output(config, "--libdir"))
(DEST / "include").mkdir(parents=True, exist_ok=True)
(DEST / "lib").mkdir(parents=True, exist_ok=True)
for name in ("libpq-fe.h", "postgres_ext.h", "pg_config_ext.h"):
    shutil.copy2(include / name, DEST / "include" / name)
pending = [lib / "libpq.5.dylib"]
copied = {}
while pending:
    source = pending.pop().resolve()
    if source.name in copied:
        continue
    dependencies = [line.strip().split(" (", 1)[0] for line in output("otool", "-L", str(source)).splitlines()[1:]]
    source_id = output("otool", "-D", str(source)).splitlines()[-1]
    target = DEST / "lib" / source.name
    shutil.copy2(source, target)
    target.chmod(0o755)
    subprocess.run(["install_name_tool", "-id", "@rpath/" + source.name, str(target)], check=True, capture_output=True)
    for dependency in dependencies:
        if dependency == source_id or dependency.startswith(("/usr/lib/", "/System/")):
            continue
        dep = Path(dependency)
        if not dep.is_absolute() or not dep.exists():
            sys.exit(f"Unresolved dependency: {dependency}")
        pending.append(dep)
        subprocess.run(["install_name_tool", "-change", dependency, "@loader_path/" + dep.resolve().name, str(target)], check=True, capture_output=True)
    subprocess.run(["codesign", "--force", "--sign", "-", str(target)], check=True, capture_output=True)
    copied[source.name] = {"source": str(source), "sourceSHA256": hashlib.sha256(source.read_bytes()).hexdigest(), "bundledSHA256": hashlib.sha256(target.read_bytes()).hexdigest()}
link = DEST / "lib/libpq.dylib"
if link.is_symlink() or link.exists(): link.unlink()
link.symlink_to("libpq.5.dylib")

# Include dependency license notices from their installed, versioned distributions.
notices = DEST / "licenses"
notices.mkdir(exist_ok=True)
for entry in copied.values():
    source = Path(entry["source"])
    prefix = next((parent for parent in source.parents if (parent / "INSTALL_RECEIPT.json").exists()), None)
    if prefix:
        out = notices / (prefix.parent.name + "-" + prefix.name)
        out.mkdir(exist_ok=True)
        for name in ("COPYRIGHT", "LICENSE", "LICENSE.txt", "COPYING", "NOTICE", "INSTALL_RECEIPT.json"):
            if (prefix / name).is_file(): shutil.copy2(prefix / name, out / name)
lock = {"postgresql": version, "architecture": output("uname", "-m"), "libraries": {name: entry["sourceSHA256"] for name, entry in sorted(copied.items())}}
lock_path = ROOT / "Dependencies.lock.json"
if lock_path.exists() and "--update-lock" not in sys.argv:
    if json.loads(lock_path.read_text()) != lock:
        sys.exit("Native dependency inputs differ from Dependencies.lock.json. Audit the changes, then use --update-lock intentionally.")
else:
    lock_path.write_text(json.dumps(lock, indent=2) + "\n")
(DEST / "manifest.json").write_text(json.dumps({"postgresql": version, "architecture": output("uname", "-m"), "libraries": copied}, indent=2) + "\n")
print(f"Prepared {len(copied)} libraries in {DEST}")
