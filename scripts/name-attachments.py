#!/usr/bin/env python3
"""Copy xcresulttool attachments to readable names, including failure snapshots."""

import json
import os
import shutil
import sys


def safe(name: str) -> str:
    cleaned = "".join(ch if ch.isalnum() or ch in "-_." else "_" for ch in name)
    return cleaned[:140] or "attachment"


def main() -> None:
    source = sys.argv[1]
    destination = sys.argv[2]
    manifest_path = os.path.join(source, "manifest.json")
    if not os.path.exists(manifest_path):
        print("No attachment manifest")
        return
    os.makedirs(destination, exist_ok=True)
    tests = json.load(open(manifest_path))
    copied = 0
    for test in tests:
        test_name = safe(test.get("testIdentifier") or "test")
        for item in test.get("attachments", []):
            readable = item.get("suggestedHumanReadableName") or item.get("exportedFileName") or "attachment"
            failure = item.get("isAssociatedWithFailure") is True
            src = os.path.join(source, item.get("exportedFileName") or "")
            if not os.path.exists(src):
                continue
            named = any(token in readable for token in ("-light-", "-dark-", "se-", "promax-", "device-", "rtl-"))
            if failure or "hierarchy" in readable.lower():
                prefix = "failure-" if failure else ""
                target = os.path.join(destination, f"{prefix}{test_name}-{safe(readable)}")
                shutil.copy(src, target)
                copied += 1
            elif named:
                filename = safe(readable)
                if "." not in filename:
                    filename += os.path.splitext(src)[1] or ".png"
                shutil.copy(src, os.path.join(source, filename))
                copied += 1
    print(f"Named {copied} attachments")


if __name__ == "__main__":
    main()
