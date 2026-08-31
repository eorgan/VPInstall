#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "$0")/.."
. tests/helpers.sh
. lib/common.sh
. lib/secrets.sh

tmp=$(make_tmpdir)
envfile="$tmp/.env"

s=$(gen_secret)
assert_eq "64" "${#s}" "gen_secret returns 64 characters"
case "$s" in
  *[!0-9a-f]*) assert_eq "hex" "not-hex" "gen_secret is hex only" ;;
  *) _ok "gen_secret is hex only" ;;
esac

a=$(gen_secret); b=$(gen_secret)
[ "$a" != "$b" ] && _ok "gen_secret differs between calls" || _notok "gen_secret differs between calls"

env_init "$envfile"
assert_file_mode 600 "$envfile" ".env is created with mode 600"

env_set "$envfile" DOMAIN "exemplo.com.br"
assert_eq "exemplo.com.br" "$(env_get "$envfile" DOMAIN)" "env_set then env_get round-trips"

env_set "$envfile" DOMAIN "outro.com"
assert_eq "outro.com" "$(env_get "$envfile" DOMAIN)" "env_set replaces in place"
assert_eq "1" "$(grep -c '^DOMAIN=' "$envfile")" "env_set does not duplicate the key"

env_ensure_secret "$envfile" PG_PASSWORD
first=$(env_get "$envfile" PG_PASSWORD)
assert_eq "64" "${#first}" "env_ensure_secret generates a secret"

env_ensure_secret "$envfile" PG_PASSWORD
assert_eq "$first" "$(env_get "$envfile" PG_PASSWORD)" "env_ensure_secret preserves an existing secret"

assert_eq "" "$(env_get "$envfile" NEVER_SET)" "env_get returns empty for a missing key"

rm -rf "$tmp"
printf '%s run, %s failed\n' "$TESTS_RUN" "$TESTS_FAILED"
[ "$TESTS_FAILED" -eq 0 ]
