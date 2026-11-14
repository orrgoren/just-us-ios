#!/usr/bin/env python3
"""Print the UDID of an available iPhone SE or the newest iPhone Pro Max."""

import json
import subprocess
import sys

kind = sys.argv[1] if len(sys.argv) > 1 else "se"
raw = subprocess.check_output(["xcrun", "simctl", "list", "devices", "available", "-j"])
listing = json.loads(raw)
found = []
for runtime, devices in listing.get("devices", {}).items():
    if "iOS" not in runtime:
        continue
    for device in devices:
        if not device.get("isAvailable", True):
            continue
        name = device.get("name", "")
        if kind == "se" and "iPhone SE" in name:
            found.append((runtime, name, device["udid"]))
        if kind == "promax" and name.startswith("iPhone") and "Pro Max" in name:
            found.append((runtime, name, device["udid"]))
if not found:
    sys.exit(f"No simulator for {kind}")
found.sort()
print(found[-1][2])
