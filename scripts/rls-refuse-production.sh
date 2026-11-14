#!/usr/bin/env bash
set -euo pipefail
url="${JUSTUS_RLS_URL:?Set JUSTUS_RLS_URL to a non-production test project}"
if [[ "$url" == *vowmukhhnfhtnjlswkun* ]]; then
  echo "Refusing the production Supabase project." >&2
  exit 1
fi
echo "Host is not production. Run the queries in docs/rls-isolation.md yourself."
