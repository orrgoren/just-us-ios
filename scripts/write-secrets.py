#!/usr/bin/env python3
"""Write Config/Secrets.xcconfig from the environment. Never prints the key."""

import os
from pathlib import Path

url = os.environ["SUPABASE_URL"].strip().replace("//", "/$()/")
key = os.environ["SUPABASE_ANON_KEY"].strip()
if not url or not key:
    raise SystemExit("SUPABASE_URL and SUPABASE_ANON_KEY are required")
path = Path("Config/Secrets.xcconfig")
path.parent.mkdir(parents=True, exist_ok=True)
path.write_text(f"SUPABASE_URL = {url}\nSUPABASE_ANON_KEY = {key}\n", encoding="utf-8")
os.chmod(path, 0o600)
print("Wrote Config/Secrets.xcconfig")
