#!/usr/bin/env python3
"""Write Config/Secrets.xcconfig from the environment. Never prints the key.

Xcode Cloud and GitHub Actions both set:
  SUPABASE_URL
  SUPABASE_ANON_KEY
No other variable is read. The Apple and APNs keys are not build inputs.
"""

import os
from pathlib import Path

try:
    url = os.environ["SUPABASE_URL"].strip().replace("//", "/$()/")
    key = os.environ["SUPABASE_ANON_KEY"].strip()
except KeyError as missing:
    raise SystemExit(
        "Set SUPABASE_URL and SUPABASE_ANON_KEY. "
        "Xcode Cloud: workflow → Environment → those two secrets."
    ) from missing
if not url or not key:
    raise SystemExit("SUPABASE_URL and SUPABASE_ANON_KEY are required")
path = Path("Config/Secrets.xcconfig")
path.parent.mkdir(parents=True, exist_ok=True)
path.write_text(f"SUPABASE_URL = {url}\nSUPABASE_ANON_KEY = {key}\n", encoding="utf-8")
os.chmod(path, 0o600)
print("Wrote Config/Secrets.xcconfig")
