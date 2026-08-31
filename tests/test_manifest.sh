#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "$0")/.."
. tests/helpers.sh
. lib/common.sh
. lib/manifest.sh

list=$(manifest_list)
assert_contains "$list" "stacks/infra/traefik.stack" "manifest_list finds traefik"
assert_contains "$list" "stacks/app/evolution-api.stack" "manifest_list finds evolution"
assert_eq "5" "$(printf '%s\n' "$list" | grep -c '.stack$')" "manifest_list finds all five manifests"

first=$(printf '%s\n' "$list" | head -1)
manifest_load "$first"
assert_eq "10" "$STACK_TIER" "lowest tier sorts first"

last=$(printf '%s\n' "$list" | tail -1)
manifest_load "$last"
assert_eq "30" "$STACK_TIER" "highest tier sorts last"
assert_eq "evolution" "$STACK_NAME" "evolution is the last stack"

# stack_pre_deploy must not leak from a stack that defines it to one that does not
manifest_load stacks/app/evolution-api.stack
type stack_pre_deploy >/dev/null 2>&1 && rc=0 || rc=1
assert_eq "0" "$rc" "evolution defines stack_pre_deploy"

manifest_load stacks/db/redis.stack
type stack_pre_deploy >/dev/null 2>&1 && rc=0 || rc=1
assert_eq "1" "$rc" "stack_pre_deploy does not leak into redis"

secrets=$(manifest_all_secrets)
assert_contains "$secrets" "POSTGRES_PASSWORD" "manifest_all_secrets includes POSTGRES_PASSWORD"
assert_contains "$secrets" "EVOLUTION_API_KEY" "manifest_all_secrets includes EVOLUTION_API_KEY"

volumes=$(manifest_all_volumes)
assert_contains "$volumes" "portainer_data" "manifest_all_volumes includes portainer_data"
assert_contains "$volumes" "evolution_instances" "manifest_all_volumes includes evolution_instances"

out=$( (manifest_load /nope/missing.stack) 2>&1 || true )
assert_contains "$out" "missing.stack" "manifest_load dies on a missing manifest"

# --- fix round 2, finding 8 (minor): a manifest missing STACK_TIER must die
# clearly, not fail deep inside install.sh's `[ "$STACK_TIER" -ge 30 ]` with
# "integer expression expected" while still deploying the stack and exiting 0.
tmp=$(make_tmpdir)
cat > "$tmp/no-tier.stack" <<'EOF'
STACK_NAME="no-tier"
STACK_FILE="stacks/db/redis.yml"
STACK_SUBDOMAIN=""
STACK_SECRETS=""
STACK_VOLUMES=""
EOF
out=$( (manifest_load "$tmp/no-tier.stack") 2>&1 ) && rc=0 || rc=$?
assert_eq "1" "$rc" "manifest_load dies on a manifest with no STACK_TIER"
assert_contains "$out" "STACK_TIER" "missing-STACK_TIER error names the field"
assert_not_contains "$out" "integer expression expected" \
  "missing-STACK_TIER error is a clear die(), not the raw '[: : integer expression expected'"
rm -rf "$tmp"

# A non-integer STACK_TIER must be rejected the same way.
tmp=$(make_tmpdir)
cat > "$tmp/bad-tier.stack" <<'EOF'
STACK_NAME="bad-tier"
STACK_FILE="stacks/db/redis.yml"
STACK_TIER="abc"
STACK_SUBDOMAIN=""
STACK_SECRETS=""
STACK_VOLUMES=""
EOF
out=$( (manifest_load "$tmp/bad-tier.stack") 2>&1 ) && rc=0 || rc=$?
assert_eq "1" "$rc" "manifest_load dies on a non-integer STACK_TIER"
assert_contains "$out" "STACK_TIER" "non-integer STACK_TIER error names the field"
rm -rf "$tmp"

printf '%s run, %s failed\n' "$TESTS_RUN" "$TESTS_FAILED"
[ "$TESTS_FAILED" -eq 0 ]
