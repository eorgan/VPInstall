#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "$0")/.."
. tests/helpers.sh
. lib/common.sh
. lib/postgres.sh

DRY_RUN=1

pg_wait_ready 1 >/dev/null 2>&1 && rc=0 || rc=$?
assert_eq "0" "$rc" "pg_wait_ready short-circuits under dry-run"

pg_ensure_role_db evolution secret123 >/dev/null 2>&1 && rc=0 || rc=$?
assert_eq "0" "$rc" "pg_ensure_role_db is a no-op under dry-run"

sql=$(pg_role_sql evolution "secret123")
assert_contains "$sql" "CREATE ROLE evolution" "SQL creates the role"
assert_contains "$sql" "ALTER ROLE evolution WITH PASSWORD" "SQL resets the password"
assert_contains "$sql" "secret123" "SQL carries the password"

sql=$(pg_db_sql evolution evolution)
assert_contains "$sql" "CREATE DATABASE evolution" "SQL creates the database"
assert_contains "$sql" "OWNER evolution" "database is owned by the role"

out=$( (pg_ensure_role_db "" pw) 2>&1 || true )
assert_contains "$out" "role" "pg_ensure_role_db rejects an empty role"

out=$( (pg_ensure_role_db evolution "") 2>&1 || true )
assert_contains "$out" "password" "pg_ensure_role_db rejects an empty password"

sql=$(pg_role_sql "ev'il" "pa'ss")
assert_contains "$sql" "ev''il" "pg_role_sql escapes embedded single quotes in role"
assert_contains "$sql" "pa''ss" "pg_role_sql escapes embedded single quotes in password"

sql=$(pg_role_sql "test" 'pass\word')
assert_contains "$sql" 'pass\word' "pg_role_sql preserves backslashes in password"

sql=$(pg_db_sql "db'name" "owner'name")
assert_contains "$sql" "db''name" "pg_db_sql escapes embedded single quotes in database"
assert_contains "$sql" "owner''name" "pg_db_sql escapes embedded single quotes in owner"

# --- fix round 2, finding 6 (important): the default timeout (120s) is
# marginal on a first run, where Postgres must pull a several-hundred-MB
# image and run initdb while four other images pull concurrently; it must be
# raised to 300s, overridable via VPINSTALL_PG_TIMEOUT, and the failure
# message must name the real service (postgres_postgres), not a literal
# "<stack>" placeholder.
assert_contains "$(cat lib/postgres.sh)" 'VPINSTALL_PG_TIMEOUT:-300' \
  "pg_wait_ready defaults to 300s, overridable via VPINSTALL_PG_TIMEOUT"

# Fake docker: no postgres container is ever found, so pg_wait_ready always
# times out. VPINSTALL_PG_TIMEOUT=0 makes that happen immediately (no arg
# is passed, so the function must fall back to the env var), which both
# proves the override plumbing works and keeps this test fast.
fakebin=$(make_tmpdir)
cat > "$fakebin/docker" <<'EOF'
#!/bin/bash
[ "$1" = "ps" ] && exit 0
exit 1
EOF
chmod +x "$fakebin/docker"

out=$(PATH="$fakebin:$PATH" VPINSTALL_PG_TIMEOUT=0 bash -c \
  '. lib/common.sh; . lib/postgres.sh; DRY_RUN=0; pg_wait_ready' 2>&1) && rc=0 || rc=$?
assert_eq "1" "$rc" "pg_wait_ready times out and fails when postgres never becomes ready"
assert_contains "$out" "docker service logs postgres_postgres" \
  "pg_wait_ready timeout message names the real service (postgres_postgres)"
assert_not_contains "$out" "<stack>_postgres" \
  "pg_wait_ready timeout message no longer contains the literal <stack> placeholder"
rm -rf "$fakebin"

printf '%s run, %s failed\n' "$TESTS_RUN" "$TESTS_FAILED"
[ "$TESTS_FAILED" -eq 0 ]
