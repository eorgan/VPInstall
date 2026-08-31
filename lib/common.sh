#!/usr/bin/env bash
# Shared logging, failure and command helpers. bash 3.2 compatible.

: "${DRY_RUN:=0}"

log_info() { printf '  %s\n'    "$1" >&2; }
log_ok()   { printf '  ok  %s\n' "$1" >&2; }
log_warn() { printf '  !   %s\n' "$1" >&2; }

die() { printf 'error: %s\n' "$1" >&2; exit 1; }

require_cmd() {
  local missing=""
  local c
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || missing="$missing $c"
  done
  [ -z "$missing" ] || die "missing required command(s):$missing"
}

is_dry_run() { [ "$DRY_RUN" = "1" ]; }

run_cmd() {
  if is_dry_run; then
    printf '  [dry-run] %s\n' "$*" >&2
    return 0
  fi
  "$@"
}
