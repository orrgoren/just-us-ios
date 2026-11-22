#!/usr/bin/env python3
"""Fail when a user-facing string has no Hebrew, or its placeholders drifted."""

import json
import re
import sys
from pathlib import Path

specifiers = re.compile(r"%(?:\d+\$)?(?:lld|@)")
call = re.compile(r'text\(\s*"([^"]+)"\s*,\s*"((?:\\.|[^"\\])*)"', re.S)

source = Path("JustUs/Localization/L10n.swift").read_text(encoding="utf-8")
pairs = call.findall(source)
catalog = json.loads(Path("JustUs/Resources/Localizable.xcstrings").read_text(encoding="utf-8"))
strings = catalog.get("strings", {})
failed = False

if not pairs:
    print("No L10n keys were found.")
    sys.exit(1)

seen = set()
for key, english in pairs:
    if key in seen:
        print(f"duplicate L10n key: {key}")
        failed = True
    seen.add(key)
    entry = strings.get(key, {})
    hebrew = (
        entry.get("localizations", {})
        .get("he", {})
        .get("stringUnit", {})
        .get("value", "")
    )
    if not hebrew.strip():
        print(f"missing Hebrew: {key}")
        failed = True
        continue
    catalog_english = (
        entry.get("localizations", {})
        .get("en", {})
        .get("stringUnit", {})
        .get("value", "")
    )
    expected = english.replace(r"\n", "\n").replace(r"\"", '"').replace(r"\\", "\\")
    if catalog_english != expected:
        print(f"English catalog drift: {key}")
        failed = True
    if specifiers.findall(expected) != specifiers.findall(hebrew):
        print(f"placeholder mismatch: {key}")
        failed = True

info = json.loads(Path("JustUs/InfoPlist.xcstrings").read_text(encoding="utf-8"))
for key in (
    "NSCameraUsageDescription",
    "NSPhotoLibraryUsageDescription",
    "NSCalendarsFullAccessUsageDescription",
    "CFBundleDisplayName",
):
    value = (
        info.get("strings", {})
        .get(key, {})
        .get("localizations", {})
        .get("he", {})
        .get("stringUnit", {})
        .get("value", "")
    )
    if not value.strip():
        print(f"missing Hebrew Info.plist string: {key}")
        failed = True

if failed:
    sys.exit(1)
print(f"Hebrew covers {len(seen)} strings and the permission prompts.")
