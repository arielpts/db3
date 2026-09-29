#!/usr/bin/env python3
"""Generate editor fixtures beside this script; never opens a UI."""
from pathlib import Path

root = Path(__file__).resolve().parent
target = 1024 * 1024
statement = "SELECT id, name FROM example WHERE id > 42; -- editor fixture\n"
script = (statement * (target // len(statement) + 1))[:target]
(root / "editor-1mib.sql").write_text(script, encoding="utf-8")
(root / "editor-long-line.sql").write_text(
    "SELECT '" + "x" * target + "' AS pathological_long_line;\n", encoding="utf-8"
)
print(f"Wrote editor-1mib.sql and editor-long-line.sql in {root}")
