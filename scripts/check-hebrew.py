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

runtime = json.loads(Path("JustUs/Resources/he.json").read_text(encoding="utf-8"))
if set(runtime) != seen:
    missing_runtime = sorted(seen - set(runtime))
    extra_runtime = sorted(set(runtime) - seen)
    if missing_runtime:
        print(f"he.json missing: {', '.join(missing_runtime)}")
    if extra_runtime:
        print(f"he.json extra: {', '.join(extra_runtime)}")
    failed = True
else:
    for key in seen:
        catalog_value = (
            strings[key].get("localizations", {}).get("he", {}).get("stringUnit", {}).get("value", "")
        )
        if runtime[key] != catalog_value:
            print(f"he.json drift: {key}")
            failed = True

ui_literal = re.compile(r'(?:\bText|\bButton|\bLabel|\.navigationTitle)\s*\(\s*"')
for path in Path("JustUs").rglob("*.swift"):
    for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), start=1):
        if line.strip().startswith("//"):
            continue
        if ui_literal.search(line):
            print(f"hardcoded copy: {path}:{number}: {line.strip()}")
            failed = True

calendar = Path("JustUs/Domain/CalendarFile.swift").read_text(encoding="utf-8")
if not re.search(r"summary[^\n]*L10n\.", calendar) or not re.search(r"details[^\n]*L10n\.", calendar):
    print("CalendarFile summary or details are not localized")
    failed = True
if re.search(r"(summary|details)\s*(?::\s*String\s*)?=\s*\"", calendar):
    print("CalendarFile hardcodes summary or details")
    failed = True

push = Path("supabase/proposed/functions/send-push/push.mjs").read_text(encoding="utf-8")
if re.search(r"[מל]\$\{", push):
    print("send-push attaches מ or ל to a name")
    failed = True
for phrase in ("מאת ${who}", "עבור ${who}", "הודעה חדשה"):
    if phrase not in push:
        print(f"send-push missing Hebrew copy: {phrase}")
        failed = True

if failed:
    sys.exit(1)
print(f"Hebrew covers {len(seen)} strings, the permission prompts, CalendarFile, and send-push.")
