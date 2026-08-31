#!/usr/bin/env bash
# Stack manifest discovery and loading. bash 3.2 compatible (no assoc arrays).

manifest_list() {
  local f tier
  for f in stacks/*/*.stack; do
    [ -e "$f" ] || continue
    tier=$(sed -n 's/^STACK_TIER=//p' "$f" | tail -1)
    [ -n "$tier" ] || tier=99
    printf '%s\t%s\n' "$tier" "$f"
  done | sort -n -k1,1 -k2,2 | cut -f2
}

manifest_load() {
  local f="$1"
  [ -e "$f" ] || die "manifest not found: $f"

  STACK_NAME=""; STACK_FILE=""; STACK_TIER=""
  STACK_SUBDOMAIN=""; STACK_SECRETS=""; STACK_VOLUMES=""
  unset -f stack_pre_deploy 2>/dev/null || true

  # shellcheck disable=SC1090
  . "$f"

  [ -n "$STACK_NAME" ] || die "manifest $f does not set STACK_NAME"
  [ -n "$STACK_FILE" ] || die "manifest $f does not set STACK_FILE"
  case "$STACK_TIER" in
    ''|*[!0-9]*) die "manifest $f: STACK_TIER must be a non-empty integer, got: '$STACK_TIER'" ;;
  esac
}

_manifest_collect() { # field name
  local field="$1" f
  for f in $(manifest_list); do
    manifest_load "$f"
    case "$field" in
      secrets) printf '%s\n' $STACK_SECRETS ;;
      volumes) printf '%s\n' $STACK_VOLUMES ;;
    esac
  done | grep -v '^$' | sort -u
}

manifest_all_secrets() { _manifest_collect secrets; }
manifest_all_volumes() { _manifest_collect volumes; }
