#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "$0")/.."
. tests/helpers.sh
. lib/common.sh
. lib/manifest.sh
. lib/render.sh

tmp=$(make_tmpdir)

export DOMAIN="exemplo.com.br"
export ACME_EMAIL="voce@exemplo.com.br"
export POSTGRES_PASSWORD="pgpass"
export EVOLUTION_API_KEY="apikey"
export EVOLUTION_DB_PASSWORD="evopass"

allow=$(render_varlist DOMAIN ACME_EMAIL POSTGRES_PASSWORD EVOLUTION_API_KEY EVOLUTION_DB_PASSWORD)

for m in $(manifest_list); do
  manifest_load "$m"
  render_file "$STACK_FILE" "$tmp/$STACK_NAME.yml" "$allow"
  render_validate "$tmp/$STACK_NAME.yml" >/dev/null 2>&1 && rc=0 || rc=1
  assert_eq "0" "$rc" "$STACK_NAME renders with no unresolved variables"
  if command -v ruby >/dev/null 2>&1; then
    ruby -ryaml -e "YAML.load_file('$tmp/$STACK_NAME.yml')" >/dev/null 2>&1 && rc=0 || rc=1
    assert_eq "0" "$rc" "$STACK_NAME renders to valid YAML"
  else
    printf 'SKIPPED: ruby not found; skipping YAML validation for %s\n' "$STACK_NAME"
  fi
done

got=$(cat "$tmp/evolution.yml")
assert_contains "$got" "Host(\`evo.exemplo.com.br\`)" "evolution router uses the root domain"
assert_contains "$got" "postgresql://evolution:evopass@postgres:5432/evolution" "evolution DSN is assembled correctly"

got=$(cat "$tmp/portainer.yml")
assert_contains "$got" "Host(\`portainer.exemplo.com.br\`)" "portainer router uses the root domain"

# No hardcoded values may survive anywhere in the templates.
leftovers=$(grep -rn "bravatec\|website.com\|example@example.com" stacks/ || true)
assert_eq "" "$leftovers" "no hardcoded domains remain in the templates"

# Neither may any real secret.
leftovers=$(grep -rnE "PASSWORD=[a-f0-9]{16}|API_KEY=[a-f0-9]{16}" stacks/ || true)
assert_eq "" "$leftovers" "no hardcoded secrets remain in the templates"

rm -rf "$tmp"
printf '%s run, %s failed\n' "$TESTS_RUN" "$TESTS_FAILED"
[ "$TESTS_FAILED" -eq 0 ]
