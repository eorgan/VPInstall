#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

. lib/common.sh
. lib/secrets.sh
. lib/manifest.sh
. lib/render.sh
. lib/postgres.sh

ENV_FILE="${VPINSTALL_ENV_FILE:-$ROOT/.env}"
DIST="${VPINSTALL_DIST:-$ROOT/dist}"
ARG_DOMAIN=""
ARG_EMAIL=""

usage() {
  cat <<'USAGE'
Usage: ./install.sh [options]

Deploys every stack to Docker Swarm. Safe to re-run: existing secrets are
reused, so this is also the update path.

Options:
  --domain <domain>   Root domain for every service (asked once, then stored)
  --email <email>     Email for Let's Encrypt registration
  --dry-run           Render and validate everything, deploy nothing
  --help              Show this message
USAGE
}

# .env is sourced as shell code by env_load on every future run, so DOMAIN and
# ACME_EMAIL (both user-supplied, via flag or prompt) must be validated before
# they are ever handed to env_set. A value containing shell metacharacters
# would otherwise be a command-execution path the next time install.sh runs.
validate_domain() { # domain
  local d="$1"
  [ -n "$d" ] || die "a domain is required"
  case "$d" in
    *[!a-zA-Z0-9.-]* | .* | -* | *. | *- | *..* ) die "invalid domain: $d" ;;
  esac
  case "$d" in
    *.*) : ;;
    *) die "invalid domain: $d" ;;
  esac
}

validate_email() { # email
  local e="$1"
  [ -n "$e" ] || die "an email is required"
  case "$e" in
    *[[:space:]]*) die "invalid email: $e" ;;
  esac
  case "$e" in
    *'$'*|*'`'*|*';'*|*'&'*|*'|'*|*'<'*|*'>'*|*'('*|*')'*|*"'"*|*'"'*)
      die "invalid email: $e" ;;
  esac
  case "$e" in
    *@*@*) die "invalid email: $e" ;;
  esac
  case "$e" in
    *@*) : ;;
    *) die "invalid email: $e" ;;
  esac
}

while [ $# -gt 0 ]; do
  case "$1" in
    --domain)  ARG_DOMAIN="$2"; shift 2 ;;
    --email)   ARG_EMAIL="$2";  shift 2 ;;
    --dry-run) DRY_RUN=1;       shift ;;
    --help|-h) usage; exit 0 ;;
    *) usage; die "unknown option: $1" ;;
  esac
done

# --- preflight -------------------------------------------------------------
require_cmd openssl envsubst sed grep
is_dry_run || require_cmd docker
if ! is_dry_run; then
  [ "$(docker info -f '{{.Swarm.LocalNodeState}}' 2>/dev/null)" = "active" ] \
    || die "Docker Swarm is not active on this node. Run: docker swarm init"
fi

# --- domain, email, secrets ------------------------------------------------
env_init "$ENV_FILE"

if [ -n "$ARG_DOMAIN" ]; then
  validate_domain "$ARG_DOMAIN"
  env_set "$ENV_FILE" DOMAIN "$ARG_DOMAIN"
fi
if [ -n "$ARG_EMAIL" ]; then
  validate_email "$ARG_EMAIL"
  env_set "$ENV_FILE" ACME_EMAIL "$ARG_EMAIL"
fi

if [ -z "$(env_get "$ENV_FILE" DOMAIN)" ]; then
  printf 'Root domain (e.g. exemplo.com.br): ' >&2
  read -r reply
  validate_domain "$reply"
  env_set "$ENV_FILE" DOMAIN "$reply"
fi
if [ -z "$(env_get "$ENV_FILE" ACME_EMAIL)" ]; then
  printf "Email for Let's Encrypt: " >&2
  read -r reply
  validate_email "$reply"
  env_set "$ENV_FILE" ACME_EMAIL "$reply"
fi

for s in $(manifest_all_secrets); do
  env_ensure_secret "$ENV_FILE" "$s"
done

env_load "$ENV_FILE"
log_ok "configuration ready ($ENV_FILE)"

# --- networks and volumes ---------------------------------------------------
# A host already provisioned (e.g. by ubinkaze) may already have these; detect
# and reuse them rather than recreating. Dry-run never touches Docker.
if ! is_dry_run; then
  if docker network inspect network_public >/dev/null 2>&1; then
    log_ok "network network_public already exists"
  else
    run_cmd docker network create --driver overlay --attachable network_public
  fi
  for v in $(manifest_all_volumes); do
    if docker volume inspect "$v" >/dev/null 2>&1; then
      log_ok "volume $v already exists"
    else
      run_cmd docker volume create "$v"
    fi
  done
else
  log_info "[dry-run] would ensure network_public and volumes: $(manifest_all_volumes | tr '\n' ' ')"
fi

# --- render ------------------------------------------------------------------
mkdir -p "$DIST"; chmod 700 "$DIST"
ALLOW=$(render_varlist DOMAIN ACME_EMAIL $(manifest_all_secrets))

for m in $(manifest_list); do
  manifest_load "$m"
  render_file "$STACK_FILE" "$DIST/$STACK_NAME.yml" "$ALLOW"
  render_validate "$DIST/$STACK_NAME.yml"
done
log_ok "all stacks rendered and validated into $DIST"

# --- deploy ------------------------------------------------------------------
for m in $(manifest_list); do
  manifest_load "$m"

  if [ "$STACK_TIER" -ge 30 ]; then
    pg_wait_ready
  fi
  if type stack_pre_deploy >/dev/null 2>&1; then
    stack_pre_deploy
  fi

  run_cmd docker stack deploy --prune --resolve-image always \
    -c "$DIST/$STACK_NAME.yml" "$STACK_NAME"
  log_ok "deployed $STACK_NAME"
done

# --- summary -----------------------------------------------------------------
printf '\nDone. Point these DNS records at this server:\n' >&2
for m in $(manifest_list); do
  manifest_load "$m"
  [ -n "$STACK_SUBDOMAIN" ] && printf '  %s.%s\n' "$STACK_SUBDOMAIN" "$DOMAIN" >&2
done
printf '\nCredentials are in %s (never commit it).\n' "$ENV_FILE" >&2
