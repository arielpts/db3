#!/usr/bin/env python3
"""Read-only bundle checks; never opens the app or controls the desktop."""
from pathlib import Path
import subprocess
import sys
ROOT = Path(__file__).resolve().parents[1]
app = Path(sys.argv[1]) if len(sys.argv) > 1 else ROOT / "build/DerivedData/Build/Products/Release/db3.app"
binary = app / "Contents/MacOS/db3"
libraries = sorted((app / "Contents/Frameworks").glob("*.dylib"))
assert binary.exists(), f"Missing executable: {binary}"
assert libraries, "PostgreSQL dependencies were not embedded"
for path in [binary, *libraries]:
    details = subprocess.check_output(["otool", "-L", str(path)], text=True)
    for line in details.splitlines()[1:]:
        dependency = line.strip().split(" (", 1)[0]
        assert dependency.startswith(("@rpath/", "@loader_path/", "@executable_path/", "/System/", "/usr/lib/")), f"Nonportable dependency: {dependency}"
    commands = subprocess.check_output(["otool", "-l", str(path)], text=True)
    assert "Vendor/PostgreSQL" not in commands, f"Build-machine rpath remains in {path.name}"
subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], check=True)
signature = subprocess.run(["codesign", "-dvv", str(app)], check=True, text=True, capture_output=True).stderr
assert not ("Signature=adhoc" in signature and "runtime" in signature), "Ad-hoc app plus hardened library validation cannot load the ad-hoc PostgreSQL libraries; use local build settings or sign all code with one Developer ID."
print(f"Valid ad-hoc signature; {len(libraries)} bundled libraries; no Homebrew or workspace load paths.")
