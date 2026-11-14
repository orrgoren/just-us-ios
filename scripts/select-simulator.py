#!/usr/bin/env python3
"""Print the UDID of a compact iPhone or the newest iPhone Pro Max.

GitHub-hosted macOS 26 images do not include an iPhone SE simulator.
The compact choice is an iPhone SE when one exists, otherwise the newest
iPhone *e (17e, 16e), otherwise the base iPhone on the newest runtime.
"""

import json
import re
import subprocess
import sys

RUNTIME_RE = re.compile(r"iOS[- ](\d+)[.-](\d+)")
PHONE_RE = re.compile(r"^iPhone (\d+)")
COMPACT_E_RE = re.compile(r"^iPhone \d+e$")


def runtime_key(name):
    match = RUNTIME_RE.search(name)
    if not match:
        return (0, 0)
    return (int(match.group(1)), int(match.group(2)))


def phone_generation(name):
    match = PHONE_RE.match(name)
    return int(match.group(1)) if match else 0


def compact_rank(name):
    if "iPhone SE" in name:
        return 0
    if COMPACT_E_RE.match(name):
        return 1
    if name.startswith("iPhone ") and not any(token in name for token in ("Pro", "Plus", "Air", "Max")):
        return 2
    return None


def devices_from(listing):
    found = []
    for runtime, devices in listing.get("devices", {}).items():
        if "iOS" not in runtime:
            continue
        version = runtime_key(runtime)
        for device in devices:
            if not device.get("isAvailable", True):
                continue
            name = device.get("name", "")
            udid = device.get("udid")
            if not name.startswith("iPhone") or not udid:
                continue
            found.append({"runtime": runtime, "version": version, "name": name, "udid": udid})
    return found


def choose(listing, kind):
    phones = devices_from(listing)
    if kind == "se":
        ranked = [phone for phone in phones if compact_rank(phone["name"]) is not None]
        ranked.sort(key=lambda phone: (phone["version"], -compact_rank(phone["name"]), phone_generation(phone["name"])))
    elif kind == "promax":
        ranked = [phone for phone in phones if "Pro Max" in phone["name"]]
        ranked.sort(key=lambda phone: (phone["version"], phone_generation(phone["name"])))
    else:
        raise SystemExit(f"Unknown simulator kind {kind}")
    if not ranked:
        names = ", ".join(sorted({phone["name"] for phone in phones})) or "(none)"
        raise SystemExit(f"No simulator for {kind}. Available iPhones: {names}")
    return ranked[-1]


def self_test():
    listing = {
        "devices": {
            "com.apple.CoreSimulator.SimRuntime.iOS-26-2": [
                {"name": "iPhone 16e", "udid": "se-old", "isAvailable": True},
                {"name": "iPhone 17 Pro Max", "udid": "max-old", "isAvailable": True},
            ],
            "com.apple.CoreSimulator.SimRuntime.iOS-26-5": [
                {"name": "iPhone 17", "udid": "base", "isAvailable": True},
                {"name": "iPhone 17 Pro", "udid": "pro", "isAvailable": True},
                {"name": "iPhone 17 Pro Max", "udid": "max-new", "isAvailable": True},
                {"name": "iPhone 17e", "udid": "compact", "isAvailable": True},
                {"name": "iPhone Air", "udid": "air", "isAvailable": True},
                {"name": "iPhone SE (3rd generation)", "udid": "unavailable-se", "isAvailable": False},
            ],
        }
    }
    compact = choose(listing, "se")
    promax = choose(listing, "promax")
    if compact["udid"] != "compact" or promax["udid"] != "max-new":
        raise SystemExit(f"selector self-test failed: {compact} {promax}")
    with_se = {
        "devices": {
            "com.apple.CoreSimulator.SimRuntime.iOS-26-5": [
                {"name": "iPhone SE (3rd generation)", "udid": "se", "isAvailable": True},
                {"name": "iPhone 17e", "udid": "e", "isAvailable": True},
            ]
        }
    }
    if choose(with_se, "se")["udid"] != "se":
        raise SystemExit("iPhone SE should win when it is available")
    print("select-simulator self-test passed")


def ensure_compact_se(listing):
    """Create a 375pt iPhone SE when the runtime has that device type."""
    if any("iPhone SE" in phone["name"] for phone in devices_from(listing)):
        return listing
    try:
        types = json.loads(subprocess.check_output(["xcrun", "simctl", "list", "devicetypes", "-j"]))
        runtimes = json.loads(subprocess.check_output(["xcrun", "simctl", "list", "runtimes", "-j"]))
    except (subprocess.CalledProcessError, json.JSONDecodeError):
        return listing
    device_type = next((item.get("identifier") for item in types.get("devicetypes", []) if "iPhone SE" in item.get("name", "")), None)
    available = [item for item in runtimes.get("runtimes", []) if item.get("isAvailable") and "iOS" in item.get("name", "")]
    if not device_type or not available:
        print("No 375pt iPhone SE device type on this runtime", file=sys.stderr)
        return listing
    runtime = sorted(available, key=lambda item: item.get("identifier", ""))[-1]
    try:
        subprocess.check_call([
            "xcrun", "simctl", "create", "iPhone SE (3rd generation)", device_type, runtime["identifier"],
        ])
    except subprocess.CalledProcessError:
        print("Could not create a 375pt iPhone SE; using the compact iPhone", file=sys.stderr)
        return listing
    raw = subprocess.check_output(["xcrun", "simctl", "list", "devices", "available", "-j"])
    return json.loads(raw)


def main():
    if len(sys.argv) > 1 and sys.argv[1] == "--self-test":
        self_test()
        return
    kind = sys.argv[1] if len(sys.argv) > 1 else "se"
    raw = subprocess.check_output(["xcrun", "simctl", "list", "devices", "available", "-j"])
    listing = json.loads(raw)
    if kind == "se":
        listing = ensure_compact_se(listing)
    chosen = choose(listing, kind)
    print(f"selected {kind}: {chosen['name']} ({chosen['runtime']})", file=sys.stderr)
    print(chosen["udid"])


if __name__ == "__main__":
    main()
