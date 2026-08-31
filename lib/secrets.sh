#!/usr/bin/env bash
# .env creation and idempotent secret generation. bash 3.2 compatible.

# Hex, not base64: these values are embedded in postgresql:// URIs and
# base64's "/" and "+" silently corrupt the DSN.
gen_secret() { openssl rand -hex 32; }

env_init() {
  local f="$1"
  if [ ! -e "$f" ]; then
    umask 077
    : > "$f"
  fi
  chmod 600 "$f"
}

env_load() {
  local f="$1"
  [ -e "$f" ] || return 0
  set -a
  # shellcheck disable=SC1090
  . "$f"
  set +a
}

env_get() {
  local f="$1" k="$2"
  [ -e "$f" ] || { printf ''; return 0; }
  # Last occurrence wins, mirroring shell sourcing semantics.
  sed -n "s/^${k}=//p" "$f" | tail -1
}

env_set() {
  local f="$1" k="$2" v="$3" tmp
  env_init "$f"
  tmp="${f}.tmp.$$"
  grep -v "^${k}=" "$f" > "$tmp" 2>/dev/null || : > "$tmp"
  printf '%s=%s\n' "$k" "$v" >> "$tmp"
  mv "$tmp" "$f"
  chmod 600 "$f"
}

env_ensure_secret() {
  local f="$1" k="$2" current
  current=$(env_get "$f" "$k")
  [ -n "$current" ] && return 0
  env_set "$f" "$k" "$(gen_secret)"
}
