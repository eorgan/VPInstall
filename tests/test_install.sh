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

rm -rf "$tmp"
printf '%s run, %s failed\n' "$TESTS_RUN" "$TESTS_FAILED"
[ "$TESTS_FAILED" -eq 0 ]
