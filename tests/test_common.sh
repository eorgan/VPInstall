#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "$0")/.."
. tests/helpers.sh
. lib/common.sh

out=$(log_info "hello" 2>&1)
assert_contains "$out" "hello" "log_info prints the message"

out=$( (die "boom") 2>&1 || true )
assert_contains "$out" "boom" "die prints the message"

( die "boom" ) >/dev/null 2>&1 && rc=0 || rc=$?
assert_eq "1" "$rc" "die exits 1"

out=$( (require_cmd definitely_not_a_real_command_xyz) 2>&1 || true )
assert_contains "$out" "definitely_not_a_real_command_xyz" "require_cmd names the missing command"

require_cmd ls && rc=0 || rc=$?
assert_eq "0" "$rc" "require_cmd succeeds for existing commands"

DRY_RUN=1
is_dry_run && rc=0 || rc=$?
assert_eq "0" "$rc" "is_dry_run true when DRY_RUN=1"

marker=$(make_tmpdir)/touched
DRY_RUN=1 run_cmd touch "$marker" >/dev/null 2>&1
[ -e "$marker" ] && rc=0 || rc=1
assert_eq "1" "$rc" "run_cmd does not execute under dry-run"

DRY_RUN=0 run_cmd touch "$marker" >/dev/null 2>&1
[ -e "$marker" ] && rc=0 || rc=1
assert_eq "0" "$rc" "run_cmd executes when not dry-run"

printf '%s run, %s failed\n' "$TESTS_RUN" "$TESTS_FAILED"
[ "$TESTS_FAILED" -eq 0 ]
