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

# Test Finding 1: render_validate returns 1 (not exit 1) and caller can guard it
( render_validate "$tmp/out/out.yml" || true ) >/dev/null 2>&1 && rc=0 || rc=$?
assert_eq "0" "$rc" "render_validate returns 1 without killing guarded caller"

# Test Finding 2: render_file fails and cleans up if envsubst fails
mkdir -p "$tmp/bin"
printf '#!/bin/bash\nexit 1\n' > "$tmp/bin/envsubst"
chmod +x "$tmp/bin/envsubst"
orig_path="$PATH"
export PATH="$tmp/bin:$PATH"
printf 'test: ${DOMAIN}\n' > "$tmp/envsubst_fail.yml"
( render_file "$tmp/envsubst_fail.yml" "$tmp/out2/out.yml" "$(render_varlist DOMAIN)" ) >/dev/null 2>&1 && rc=0 || rc=$?
assert_eq "1" "$rc" "render_file returns 1 when envsubst fails"
[ ! -e "$tmp/out2/out.yml" ] || die "render_file left a file after envsubst failure"
_ok "render_file cleans up on envsubst failure"
export PATH="$orig_path"

# Test Finding 3: render_validate does not leak secrets in stderr
export SECRET_PASS="SUPERSECRET123"
export TYPO_VAR="this_is_unused"
printf 'uri: postgresql://user:${SECRET_PASS}@host/${TYPO_VAR}\n' > "$tmp/secret_template.yml"
render_file "$tmp/secret_template.yml" "$tmp/secret_rendered.yml" "$(render_varlist SECRET_PASS)"
got=$(cat "$tmp/secret_rendered.yml")
assert_contains "$got" "SUPERSECRET123" "render_file substitutes the secret value"
assert_contains "$got" "\${TYPO_VAR}" "render_file leaves unresolved variable untouched"
out=$( (render_validate "$tmp/secret_rendered.yml") 2>&1 || true )
assert_contains "$out" "TYPO_VAR" "render_validate reports the unresolved variable name"
assert_not_contains "$out" "SUPERSECRET123" "render_validate does not leak the secret value to stderr"

# Test new breakage: render_validate must not crash on non-identifier placeholders
printf 'positional: ${1}\nempty: ${}\n' > "$tmp/non_identifier.yml"
out=$( (render_validate "$tmp/non_identifier.yml") 2>&1 || true )
assert_contains "$out" "not a simple" "render_validate reports non-identifier placeholder"
( render_validate "$tmp/non_identifier.yml" ) >/dev/null 2>&1 && rc=0 || rc=$?
assert_eq "1" "$rc" "render_validate returns 1 for non-identifier placeholders"
# Verify it doesn't crash an unguarded caller
( render_validate "$tmp/non_identifier.yml" || true ) >/dev/null 2>&1 && rc=0 || rc=$?
assert_eq "0" "$rc" "render_validate with non-identifier placeholder returns 1 without killing guarded caller"

rm -rf "$tmp"
printf '%s run, %s failed\n' "$TESTS_RUN" "$TESTS_FAILED"
[ "$TESTS_FAILED" -eq 0 ]
