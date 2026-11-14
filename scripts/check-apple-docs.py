#!/usr/bin/env python3
"""The pull request must keep the Supabase Apple and APNs instructions."""

from pathlib import Path
import sys

text = Path("docs/supabase-apple-and-apns.md").read_text(encoding="utf-8")
required = [
    "com.orrgoren.justus",
    "694YR89B4S",
    "S6M487B43U",
    "APNS_KEY_ID",
    "APNS_KEY_P8",
    "APNS_TEAM_ID",
    "APNS_BUNDLE_ID",
    "Client IDs",
]
missing = [item for item in required if item not in text]
if missing:
    print("Missing from docs/supabase-apple-and-apns.md: " + ", ".join(missing))
    sys.exit(1)
if "BEGIN PRIVATE KEY" in text:
    print("The Apple private key must not be committed.")
    sys.exit(1)
print("Apple and APNs instructions are present.")
