#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "$0")/.."
. tests/helpers.sh
. lib/common.sh
. lib/render.sh

tmp=$(make_tmpdir)

list=$(render_varlist DOMAIN POSTGRES_PASSWORD)
assert_contains "$list" '${DOMAIN}' "render_varlist wraps names"
assert_contains "$list" '${POSTGRES_PASSWORD}' "render_varlist includes every name"

printf 'host: ${DOMAIN}\nkeep: ${NOT_IN_LIST}\n' > "$tmp/in.yml"
export DOMAIN="exemplo.com.br"
export NOT_IN_LIST="should-not-appear"

render_file "$tmp/in.yml" "$tmp/out/out.yml" "$(render_varlist DOMAIN)"
got=$(cat "$tmp/out/out.yml")
assert_contains "$got" "host: exemplo.com.br" "render_file substitutes allowlisted vars"
assert_contains "$got" 'keep: ${NOT_IN_LIST}' "render_file leaves non-allowlisted vars untouched"
assert_not_contains "$got" "should-not-appear" "render_file does not substitute outside the allowlist"

out=$( (render_validate "$tmp/out/out.yml") 2>&1 || true )
assert_contains "$out" "NOT_IN_LIST" "render_validate reports the unresolved variable"

( render_validate "$tmp/out/out.yml" ) >/dev/null 2>&1 && rc=0 || rc=$?
assert_eq "1" "$rc" "render_validate exits non-zero when a variable is unresolved"

printf 'clean: yes\n' > "$tmp/clean.yml"
render_validate "$tmp/clean.yml" >/dev/null 2>&1 && rc=0 || rc=$?
assert_eq "0" "$rc" "render_validate passes a fully resolved file"

rm -rf "$tmp"
printf '%s run, %s failed\n' "$TESTS_RUN" "$TESTS_FAILED"
[ "$TESTS_FAILED" -eq 0 ]
