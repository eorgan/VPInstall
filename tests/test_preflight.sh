#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "$0")/.."
. tests/helpers.sh

# These tests drive the real install.sh (not dry-run) against fake `docker`
# binaries placed first on PATH, so they exercise the actual preflight logic
# without touching a real Docker daemon.
#
# Sets OUT (combined stdout+stderr) and RC (exit code) as globals. Must NOT
# be called inside a command substitution, or both would be lost to a
# subshell.
run_with_fake_docker() { # fake_docker_script
  local script="$1" dir tmp outfile
  dir=$(make_tmpdir)
  cat > "$dir/docker" <<EOF
#!/bin/bash
$script
EOF
  chmod +x "$dir/docker"
  tmp=$(make_tmpdir)
  outfile="$tmp/out"
  PATH="$dir:$PATH" VPINSTALL_ENV_FILE="$tmp/.env" VPINSTALL_DIST="$tmp/dist" \
    ./install.sh --domain exemplo.com.br --email voce@exemplo.com.br >"$outfile" 2>&1 \
    && RC=0 || RC=$?
  OUT=$(cat "$outfile")
  rm -rf "$dir" "$tmp"
}

# --- FIX 3a: docker daemon unreachable (permission denied) must be reported
# as a daemon/permission problem, not misdiagnosed as "swarm is not active"
# (which sends the operator toward a remedy, `docker swarm init`, that will
# also fail for the same permission reason).
run_with_fake_docker '
if [ "$1" = "info" ]; then
  echo "permission denied while trying to connect to the Docker daemon socket" >&2
  exit 1
fi
exit 1
'
assert_eq "1" "$RC" "unreachable docker daemon: install.sh exits non-zero"
assert_contains "$OUT" "cannot talk to the Docker daemon" "unreachable docker daemon is diagnosed correctly"
assert_not_contains "$OUT" "Swarm is not active" "unreachable docker daemon is not misreported as swarm-inactive"

# --- FIX 3b: a worker node (Swarm active, but ControlAvailable=false) must
# be rejected at preflight, not allowed through to fail confusingly at the
# first `docker stack deploy`.
run_with_fake_docker '
if [ "$1" = "info" ]; then
  echo "active|false"
  exit 0
fi
exit 1
'
assert_eq "1" "$RC" "worker node: install.sh exits non-zero"
assert_contains "$OUT" "not a manager" "worker node is rejected at preflight with a manager message"
assert_not_contains "$OUT" "configuration ready" "worker node is rejected before configuration/deploy proceeds"

# --- FIX 3, control: a real swarm manager must still pass preflight cleanly
# (proven by getting past preflight to the network step, which then fails on
# our fake docker's default 'exit 1' for anything else — proving preflight
# itself raised no error).
run_with_fake_docker '
if [ "$1" = "info" ]; then
  echo "active|true"
  exit 0
fi
exit 1
'
assert_contains "$OUT" "configuration ready" "a real swarm manager passes preflight"

# --- FIX 5: an existing network_public that is not an attachable swarm
# overlay network (e.g. a stray local bridge network of the same name) must
# be rejected with an actionable message, not silently reused.
run_with_fake_docker '
if [ "$1" = "info" ]; then
  echo "active|true"
  exit 0
fi
if [ "$1" = "network" ] && [ "$2" = "inspect" ]; then
  exit 0
fi
exit 1
'
assert_eq "1" "$RC" "mismatched-scope network_public: install.sh exits non-zero"
assert_contains "$OUT" "network_public" "mismatched-scope network_public error names the network"
assert_contains "$OUT" "not an attachable swarm overlay network" "mismatched-scope network_public gives an actionable diagnosis"

printf '%s run, %s failed\n' "$TESTS_RUN" "$TESTS_FAILED"
[ "$TESTS_FAILED" -eq 0 ]
