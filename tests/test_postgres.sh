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

printf '%s run, %s failed\n' "$TESTS_RUN" "$TESTS_FAILED"
[ "$TESTS_FAILED" -eq 0 ]
