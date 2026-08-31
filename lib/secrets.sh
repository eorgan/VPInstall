#!/usr/bin/env bash
# .env creation and idempotent secret generation. bash 3.2 compatible.

# Hex, not base64: these values are embedded in postgresql:// URIs and
# base64's "/" and "+" silently corrupt the DSN.
gen_secret() {
  local s
  s=$(openssl rand -hex 32) || die "openssl rand failed"
  # Verify we got 64 hex characters
  case "${#s}" in
    64) case "$s" in
          *[!0-9a-f]*) die "gen_secret: openssl produced non-hex output" ;;
          *) printf '%s' "$s" ;;
        esac ;;
    *) die "gen_secret: openssl produced ${#s} bytes, expected 64" ;;
  esac
}

env_init() {
  local f="$1"
  if [ ! -e "$f" ]; then
    umask 077
    : > "$f"
  fi
  chmod 600 "$f"
}

env_load() {
  local f="$1" _had_a
  [ -e "$f" ] || return 0
  case "$-" in *a*) _had_a=1 ;; *) _had_a=0 ;; esac
  set -a
  # shellcheck disable=SC1090
  . "$f"
  [ "$_had_a" = "1" ] || set +a
}

env_get() {
  local f="$1" k="$2"
  [ -e "$f" ] || { printf ''; return 0; }
  # Last occurrence wins, mirroring shell sourcing semantics.
  sed -n "s/^${k}=//p" "$f" | tail -1
}

_env_mktemp() {
  # Create temp file at mode 600, independently testable
  local t="$1"
  ( umask 077; : > "$t" ) || die "failed to create $t"
  printf '%s' "$t"
}

env_set() {
  local f="$1" k="$2" v="$3" tmp
  env_init "$f"
  tmp="${f}.tmp.$$"
  # Create temp file with secure permissions before writing
  _env_mktemp "$tmp" >/dev/null
  # Write content to temp file, cleanup on error
  if ! { grep -v "^${k}=" "$f" > "$tmp" 2>/dev/null || : > "$tmp"; }; then
    rm -f "$tmp"
    die "failed to write $f"
  fi
  if ! printf '%s=%s\n' "$k" "$v" >> "$tmp"; then
    rm -f "$tmp"
    die "failed to write $f"
  fi
  if ! mv "$tmp" "$f"; then
    rm -f "$tmp"
    die "failed to write $f"
  fi
  chmod 600 "$f"
}

env_ensure_secret() {
  local f="$1" k="$2" current value
  current=$(env_get "$f" "$k")
  [ -n "$current" ] && return 0
  value=$(gen_secret) || die "failed to generate a secret for $k"
  [ -n "$value" ] || die "failed to generate a secret for $k"
  env_set "$f" "$k" "$value"
}
