#!/usr/bin/env python3
"""Public docs name the Apple and APNs settings and do not carry the values."""

from pathlib import Path
import hashlib
import re
import sys

docs = [Path("README.md"), Path("ARCHITECTURE.md"), Path("docs")]
files = []
for item in docs:
    if item.is_dir():
        files.extend(item.rglob("*.md"))
    else:
        files.append(item)

text = "\n".join(path.read_text(encoding="utf-8") for path in files)
# sha256 of the team id, the key id, and the App ID resource. The values are not stored here.
banned = {
    "e7d7f16b6c82b8e9a417e7347283468fdc858879d42eff87a5d6e47b0ab8bf76",
    "f8ad73960cc4b32a5ad57e9b0f60d38faa3a231279f6a3a6069dea3c42d7ca3f",
    "1bb90b97241dd98793e4c3e8a3ba2ebcdab4ab313c8ad02edf14b6f7eb56389b",
}
leaked = [token for token in re.findall(r"\b[A-Z0-9]{10}\b", text) if hashlib.sha256(token.encode()).hexdigest() in banned]
if leaked or "BEGIN PRIVATE KEY" in text or "BEGIN EC PRIVATE KEY" in text:
    print("Public docs still contain an Apple identifier or a private key.")
    sys.exit(1)

guide = Path("docs/supabase-apple-and-apns.md").read_text(encoding="utf-8")
required = ["APNS_KEY_ID", "APNS_KEY_P8", "APNS_TEAM_ID", "APNS_BUNDLE_ID", "APNS_USE_SANDBOX", "com.orrgoren.justus"]
missing = [item for item in required if item not in guide]
if missing:
    print("Missing from docs/supabase-apple-and-apns.md: " + ", ".join(missing))
    sys.exit(1)
print("Apple and APNs docs name the secrets and omit the values.")
