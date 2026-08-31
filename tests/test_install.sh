#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "$0")/.."
. tests/helpers.sh

tmp=$(make_tmpdir)
env="$tmp/.env"

out=$(./install.sh --help 2>&1)
assert_contains "$out" "--domain" "help mentions --domain"
assert_contains "$out" "--dry-run" "help mentions --dry-run"

# A dry run must render everything without touching Docker.
VPINSTALL_ENV_FILE="$env" VPINSTALL_DIST="$tmp/dist" \
  ./install.sh --dry-run --domain exemplo.com.br --email voce@exemplo.com.br >"$tmp/log1" 2>&1 \
  && rc=0 || rc=$?
assert_eq "0" "$rc" "dry run succeeds"

assert_eq "exemplo.com.br" "$(grep '^DOMAIN=' "$env" | cut -d= -f2)" "dry run stores DOMAIN"
[ -f "$tmp/dist/evolution.yml" ] && rc=0 || rc=1
assert_eq "0" "$rc" "dry run renders every stack"
assert_file_mode 600 "$env" ".env is mode 600"
assert_file_mode 700 "$tmp/dist" "dist/ is mode 700"

log=$(cat "$tmp/log1")
assert_not_contains "$log" "$(grep '^POSTGRES_PASSWORD=' "$env" | cut -d= -f2)" "no secret is printed to the log"

# Second run must reuse every secret.
before=$(cat "$env")
VPINSTALL_ENV_FILE="$env" VPINSTALL_DIST="$tmp/dist" \
  ./install.sh --dry-run >"$tmp/log2" 2>&1
after=$(cat "$env")
assert_eq "$before" "$after" "re-running preserves every generated secret"

# Domain is remembered, so it need not be supplied again.
assert_eq "exemplo.com.br" "$(grep '^DOMAIN=' "$env" | cut -d= -f2)" "domain persists across runs"

# --- Addition 1: DOMAIN and ACME_EMAIL must be validated before ever being
# written to .env, because .env is sourced as shell code on the next run.

rm -f /tmp/pwned
tmp2=$(make_tmpdir)
env2="$tmp2/.env"
VPINSTALL_ENV_FILE="$env2" VPINSTALL_DIST="$tmp2/dist" \
  ./install.sh --dry-run --domain 'evil$(touch /tmp/pwned).com' --email a@b.c >"$tmp2/log" 2>&1 \
  && rc=0 || rc=$?
assert_eq "1" "$rc" "malicious domain is rejected"
if [ -f "$env2" ]; then
  domain_written=$(grep '^DOMAIN=' "$env2" | cut -d= -f2 || true)
else
  domain_written=""
fi
assert_eq "" "$domain_written" "malicious domain is never written to .env"
[ -f /tmp/pwned ] && rc=0 || rc=1
assert_eq "1" "$rc" "malicious domain is never executed"
rm -rf "$tmp2"
rm -f /tmp/pwned

tmp3=$(make_tmpdir)
env3="$tmp3/.env"
VPINSTALL_ENV_FILE="$env3" VPINSTALL_DIST="$tmp3/dist" \
  ./install.sh --dry-run --domain exemplo.com.br --email 'evil$(touch /tmp/pwned)@b.c' >"$tmp3/log" 2>&1 \
  && rc=0 || rc=$?
assert_eq "1" "$rc" "malicious email is rejected"
if [ -f "$env3" ]; then
  email_written=$(grep '^ACME_EMAIL=' "$env3" | cut -d= -f2 || true)
else
  email_written=""
fi
assert_eq "" "$email_written" "malicious email is never written to .env"
[ -f /tmp/pwned ] && rc=0 || rc=1
assert_eq "1" "$rc" "malicious email is never executed"
rm -rf "$tmp3"
rm -f /tmp/pwned

# A plain, valid domain/email must still work.
tmp4=$(make_tmpdir)
env4="$tmp4/.env"
VPINSTALL_ENV_FILE="$env4" VPINSTALL_DIST="$tmp4/dist" \
  ./install.sh --dry-run --domain exemplo.com.br --email voce@exemplo.com.br >"$tmp4/log" 2>&1 \
  && rc=0 || rc=$?
assert_eq "0" "$rc" "valid domain and email are accepted"
rm -rf "$tmp4"

# --- fix round 1, finding 1: option-value parsing must not crash on a
# missing value, and must not silently swallow the following flag as its
# value (which would drop --dry-run and head toward a real deploy).

tmp5=$(make_tmpdir)
out5=$(./install.sh --domain 2>&1) && rc=0 || rc=$?
assert_eq "1" "$rc" "--domain with no value exits non-zero"
assert_contains "$out5" "--domain" "--domain-with-no-value error names --domain"
assert_not_contains "$out5" "unbound variable" "--domain with no value fails cleanly, not with unbound variable"
rm -rf "$tmp5"

tmp6=$(make_tmpdir)
env6="$tmp6/.env"
VPINSTALL_ENV_FILE="$env6" VPINSTALL_DIST="$tmp6/dist" \
  ./install.sh --domain --dry-run --email x@y.com </dev/null >"$tmp6/log" 2>&1 \
  && rc=0 || rc=$?
assert_eq "1" "$rc" "--domain --dry-run --email x@y.com is rejected rather than swallowing --dry-run"
if [ -f "$env6" ]; then
  domain6=$(grep '^DOMAIN=' "$env6" | cut -d= -f2 || true)
else
  domain6=""
fi
assert_eq "" "$domain6" "--dry-run is never taken as the value of --domain"
rm -rf "$tmp6"

# --- fix round 2, finding 1 (critical): `docker stack deploy` defaults to
# --detach=true, which returns 0 even when a service can never be scheduled
# (e.g. something else already holds :80/:443). install.sh must pass
# --detach=false so a convergence failure surfaces as a non-zero exit.

tmp7=$(make_tmpdir)
env7="$tmp7/.env"
deploy_lines=$(VPINSTALL_ENV_FILE="$env7" VPINSTALL_DIST="$tmp7/dist" \
  ./install.sh --dry-run --domain exemplo.com.br --email voce@exemplo.com.br 2>&1 \
  | grep 'docker stack deploy')
[ -n "$deploy_lines" ] && rc=0 || rc=1
assert_eq "0" "$rc" "dry-run prints at least one docker stack deploy command"
line_count=$(printf '%s\n' "$deploy_lines" | wc -l | tr -d ' ')
detach_count=$(printf '%s\n' "$deploy_lines" | grep -c -- '--detach=false' || true)
assert_eq "$line_count" "$detach_count" "every docker stack deploy invocation passes --detach=false"
rm -rf "$tmp7"

# --- fix round 2, finding 2 (important): dist/*.yml must be written 600 on
# EVERY run, not just the first (where umask 077 only applies by accident,
# because env_init's `if [ ! -e "$f" ]` branch that sets it is skipped once
# .env already exists). Reproduce the real update path: .env pre-exists
# (as if copied in, or left from an earlier install), dist/ does not, and the
# ambient umask is the permissive login default (022).

tmp8=$(make_tmpdir)
env8="$tmp8/.env"
touch "$env8"; chmod 600 "$env8"
{
  printf 'DOMAIN=exemplo.com.br\n'
  printf 'ACME_EMAIL=voce@exemplo.com.br\n'
  printf 'POSTGRES_PASSWORD=%s\n' "$(openssl rand -hex 32)"
  printf 'EVOLUTION_API_KEY=%s\n' "$(openssl rand -hex 32)"
  printf 'EVOLUTION_DB_PASSWORD=%s\n' "$(openssl rand -hex 32)"
} >> "$env8"
(
  umask 022
  VPINSTALL_ENV_FILE="$env8" VPINSTALL_DIST="$tmp8/dist" ./install.sh --dry-run >/dev/null 2>&1
  VPINSTALL_ENV_FILE="$env8" VPINSTALL_DIST="$tmp8/dist" ./install.sh --dry-run >/dev/null 2>&1
)
all_600=1
for f in "$tmp8/dist"/*.yml; do
  mode=$(ls -ld "$f" | cut -c1-10)
  [ "$mode" = "-rw-------" ] || { all_600=0; printf '       %s is %s (want -rw-------)\n' "$f" "$mode"; }
done
assert_eq "1" "$all_600" "every dist/*.yml is mode 600 on a re-run against a pre-existing .env, ambient umask 022"
rm -rf "$tmp8"

# --- fix round 2, finding 4 (important): .env.example must not ship a
# working DOMAIN/ACME_EMAIL, or `cp .env.example .env && ./install.sh` would
# silently deploy against a fake domain against PRODUCTION Let's Encrypt.

example_domain=$(sed -n 's/^DOMAIN=//p' .env.example)
example_email=$(sed -n 's/^ACME_EMAIL=//p' .env.example)
assert_eq "" "$example_domain" ".env.example does not set an active DOMAIN"
assert_eq "" "$example_email" ".env.example does not set an active ACME_EMAIL"

tmp9=$(make_tmpdir)
cp .env.example "$tmp9/.env"
chmod 600 "$tmp9/.env"
out9=$(VPINSTALL_ENV_FILE="$tmp9/.env" VPINSTALL_DIST="$tmp9/dist" \
  ./install.sh --dry-run </dev/null 2>&1) && rc=0 || rc=$?
assert_eq "1" "$rc" "a copied .env.example with no --domain/--email and no stdin fails rather than deploying"
assert_contains "$out9" "Root domain" "a copied .env.example still prompts for DOMAIN instead of using a placeholder"
rm -rf "$tmp9"

# --- fix round 2, finding 9 (minor): a non-interactive run with no --domain
# and no stdin must die with a clear message, not exit 1 silently (errexit
# on the failing `read`).

tmp10=$(make_tmpdir)
env10="$tmp10/.env"
out10=$(VPINSTALL_ENV_FILE="$env10" VPINSTALL_DIST="$tmp10/dist" \
  ./install.sh --dry-run </dev/null 2>&1) && rc=0 || rc=$?
assert_eq "1" "$rc" "no domain, no stdin: install.sh exits non-zero"
assert_contains "$out10" "no domain supplied" "no domain, no stdin: install.sh explains the failure rather than dying silently"
rm -rf "$tmp10"

rm -rf "$tmp"
printf '%s run, %s failed\n' "$TESTS_RUN" "$TESTS_FAILED"
[ "$TESTS_FAILED" -eq 0 ]
