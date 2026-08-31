#!/usr/bin/env bash
# PostgreSQL readiness and role/database bootstrap.

# Escapes single quotes for SQL interpolation by doubling them (SQL standard).
# bash 3.2 safe, no external tools beyond sed.
_sql_quote() { # value -> value with ' doubled
  local v="$1" out=""
  out=$(printf '%s' "$v" | sed "s/'/''/g")
  printf '%s' "$out"
}

# Note: assumes a single PostgreSQL container on this node. If adding multi-node
# support or additional postgres services, this substring match must be tightened
# (e.g., exact name or label filter).
pg_container_id() {
  docker ps -q -f name=postgres 2>/dev/null | head -1
}

pg_wait_ready() {
  # 300s by default: a first run must pull a several-hundred-MB postgres image
  # and run initdb while four other images pull concurrently, which routinely
  # exceeds 120s. Override with VPINSTALL_PG_TIMEOUT for slower hosts/links.
  local timeout="${1:-${VPINSTALL_PG_TIMEOUT:-300}}" waited=0 cid
  is_dry_run && return 0

  log_info "waiting for PostgreSQL to accept connections"
  while [ "$waited" -lt "$timeout" ]; do
    cid=$(pg_container_id)
    if [ -n "$cid" ] && docker exec "$cid" pg_isready -U postgres >/dev/null 2>&1; then
      log_ok "PostgreSQL is ready"
      return 0
    fi
    sleep 3
    waited=$((waited + 3))
  done
  die "PostgreSQL did not become ready within ${timeout}s. Check: docker service logs postgres_postgres"
}

# Idempotent: creates the role when absent, and always resets the password so
# that .env and the server cannot drift apart.
pg_role_sql() { # role password
  local role="$(_sql_quote "$1")" password="$(_sql_quote "$2")"
  cat <<SQL
DO \$\$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '$role') THEN
    CREATE ROLE $role LOGIN;
  END IF;
END
\$\$;
ALTER ROLE $role WITH PASSWORD '$password';
SQL
}

pg_db_sql() { # database owner
  local database="$(_sql_quote "$1")" owner="$(_sql_quote "$2")"
  cat <<SQL
SELECT 'CREATE DATABASE $database OWNER $owner'
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = '$database')\gexec
SQL
}

pg_ensure_role_db() { # role password
  local role="$1" password="$2" cid
  [ -n "$role" ]     || die "pg_ensure_role_db: role must not be empty"
  [ -n "$password" ] || die "pg_ensure_role_db: password must not be empty"
  is_dry_run && return 0

  cid=$(pg_container_id)
  [ -n "$cid" ] || die "no running PostgreSQL container found on this node"

  pg_role_sql "$role" "$password" | docker exec -i "$cid" psql -v ON_ERROR_STOP=1 -U postgres -q
  pg_db_sql  "$role" "$role"      | docker exec -i "$cid" psql -v ON_ERROR_STOP=1 -U postgres -q
  log_ok "PostgreSQL role and database '$role' are in place"
}
