# RLS isolation

Do not run this against production. The script refuses `vowmukhhnfhtnjlswkun`.

Use a separate Supabase project, two users in different couples, and the anon key for that project only. Sign in as couple A and request couple B’s date id. The response must be empty or a permission error. Repeat for `private_date_plans`, `memory_notes`, and `date-photos`. Then sign in as couple B and confirm the same boundary.

```bash
export JUSTUS_RLS_URL="https://your-test-project.supabase.co"
export JUSTUS_RLS_ANON_KEY="test-anon-key"
bash scripts/rls-refuse-production.sh
```

The iOS client also filters by the signed-in membership, and that filter is not the security boundary. RLS is.
