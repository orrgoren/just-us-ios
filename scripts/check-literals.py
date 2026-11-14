#!/usr/bin/env python3
"""Fail when a view hardcodes user-facing copy or physical left/right edges."""

import re
import sys
from pathlib import Path

roots = [Path("JustUs/Features"), Path("JustUs/Design")]
patterns = [
    re.compile(r'\bText\(\s*"'),
    re.compile(r'\bButton\(\s*"'),
    re.compile(r'\bLabel\(\s*"'),
    re.compile(r'navigationTitle\(\s*"'),
    re.compile(r'\bToggle\(\s*"'),
    re.compile(r'\.(left|right)\b'),
]
failed = False
for root in roots:
    for path in root.rglob("*.swift"):
        for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), start=1):
            stripped = line.strip()
            if stripped.startswith("//"):
                continue
            for pattern in patterns:
                if pattern.search(line):
                    print(f"{path}:{number}: {stripped}")
                    failed = True
if failed:
    sys.exit(1)
print("No hardcoded view copy or left/right edges.")
