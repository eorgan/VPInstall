#!/usr/bin/env bash
# PostgreSQL readiness and role/database bootstrap.

pg_container_id() {
  docker ps -q -f name=postgres 2>/dev/null | head -1
}

pg_wait_ready() {
  local timeout="${1:-120}" waited=0 cid
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
  die "PostgreSQL did not become ready within ${timeout}s. Check: docker service logs <stack>_postgres"
}

# Idempotent: creates the role when absent, and always resets the password so
# that .env and the server cannot drift apart.
pg_role_sql() { # role password
  cat <<SQL
DO \$\$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '$1') THEN
    CREATE ROLE $1 LOGIN;
  END IF;
END
\$\$;
ALTER ROLE $1 WITH PASSWORD '$2';
SQL
}

pg_db_sql() { # database owner
  cat <<SQL
SELECT 'CREATE DATABASE $1 OWNER $2'
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = '$1')\gexec
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
