# VPInstall — install.sh Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build `install.sh`, which takes a single root domain, generates every
credential, renders the stack files, and deploys them to Docker Swarm in
dependency order — idempotently, so re-running it is also the update path.

**Architecture:** A `.env` file is the single source of truth for domain and
secrets. Stack YAMLs are templates containing `${VAR}` placeholders; they are
rendered with `envsubst` into a gitignored `dist/`, validated so no unresolved
variable can ever reach the cluster, then deployed tier by tier. Each stack
declares itself through a small shell fragment (`*.stack`) that the installer
discovers, so adding a stack never means editing `install.sh`.

**Tech Stack:** bash (3.2-compatible), envsubst (gettext), openssl, docker,
Docker Swarm.

**Spec:** `docs/superpowers/specs/2026-08-30-vpinstall-design.md`

## Global Constraints

- **bash 3.2 compatible.** macOS ships bash 3.2 and local `--dry-run` testing
  must work. Forbidden: `declare -A`, `mapfile`, `readarray`, `${var,,}`,
  `${var^^}`, `local -n`. Use `#!/usr/bin/env bash`.
- Every script starts with `set -Eeuo pipefail`.
- **No secret ever reaches stdout or stderr.** Summaries print paths, never values.
- `.env` is created `chmod 600`; `dist/` is created `chmod 700`.
- `.gitignore` must contain `.env` and `dist/` before any code lands.
- Secrets are `openssl rand -hex 32`. **Hex, never base64** — the Postgres
  password is embedded in a `postgresql://user:pass@host/db` URI and base64
  emits `/` and `+`, which silently corrupt the DSN.
- The installer must be safe on an already-provisioned host (Gabriel's VPS
  already ran ubinkaze): existing networks, volumes and stacks are detected and
  reused, never recreated or clobbered.
- Repo is public and derives from `felipefontoura/bento` (MIT): `LICENSE` must
  carry Felipe Fontoura's copyright alongside ours.

---

### Task 1: Repository skeleton, license, and test harness

**Files:**
- Create: `LICENSE`, `.gitignore`, `tests/helpers.sh`, `tests/run.sh`

**Interfaces:**
- Consumes: nothing
- Produces: `tests/run.sh` (runs every `tests/test_*.sh`); assertion functions
  `assert_eq <expected> <actual> <message>`, `assert_contains <haystack>
  <needle> <message>`, `assert_fails <command...>`, `assert_file_mode <mode>
  <path>`; `pass`/`fail` counters via `TESTS_RUN`, `TESTS_FAILED`.

- [ ] **Step 1: Create `.gitignore`**

```
.env
.env.*
!.env.example
dist/
```

- [ ] **Step 2: Create `LICENSE`**

Copy the MIT text, with both copyright lines:

```
MIT License

Copyright (c) 2026 Felipe Fontoura
Copyright (c) 2026 Eliezer Organ

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to furnish persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

- [ ] **Step 3: Create `tests/helpers.sh`**

```bash
#!/usr/bin/env bash
# Zero-dependency assertions. Sourced by every tests/test_*.sh.

TESTS_RUN=0
TESTS_FAILED=0

_ok()   { TESTS_RUN=$((TESTS_RUN + 1)); printf '  ok   %s\n' "$1"; }
_notok(){ TESTS_RUN=$((TESTS_RUN + 1)); TESTS_FAILED=$((TESTS_FAILED + 1))
          printf '  FAIL %s\n' "$1"; }

assert_eq() { # expected actual message
  if [ "$1" = "$2" ]; then _ok "$3"
  else _notok "$3"; printf '       expected: %s\n       actual:   %s\n' "$1" "$2"; fi
}

assert_contains() { # haystack needle message
  case "$1" in
    *"$2"*) _ok "$3" ;;
    *) _notok "$3"; printf '       missing: %s\n' "$2" ;;
  esac
}

assert_not_contains() { # haystack needle message
  case "$1" in
    *"$2"*) _notok "$3"; printf '       unexpectedly present: %s\n' "$2" ;;
    *) _ok "$3" ;;
  esac
}

assert_fails() { # command...
  local msg="$1"; shift
  if "$@" >/dev/null 2>&1; then _notok "$msg (command unexpectedly succeeded)"
  else _ok "$msg"; fi
}

assert_file_mode() { # mode path message
  local actual
  actual=$(ls -l "$2" | cut -c1-10)
  case "$1" in
    600) [ "$actual" = "-rw-------" ] && _ok "$3" || { _notok "$3"; printf '       mode: %s\n' "$actual"; } ;;
    700) [ "$actual" = "drwx------" ] && _ok "$3" || { _notok "$3"; printf '       mode: %s\n' "$actual"; } ;;
    *) _notok "$3 (unsupported mode $1)" ;;
  esac
}

# Each test file creates its own sandbox and cleans it up.
make_tmpdir() { mktemp -d "${TMPDIR:-/tmp}/vpinstall.XXXXXX"; }
```

- [ ] **Step 4: Create `tests/run.sh`**

```bash
#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "$0")/.."

total=0
failed=0
for t in tests/test_*.sh; do
  [ -e "$t" ] || continue
  printf '%s\n' "$t"
  # Each test file prints its own results and exits non-zero on failure.
  if bash "$t"; then :; else failed=$((failed + 1)); fi
  total=$((total + 1))
done

printf '\n%s test file(s), %s failed\n' "$total" "$failed"
[ "$failed" -eq 0 ]
```

- [ ] **Step 5: Make them executable and verify the harness runs green when empty**

```bash
chmod +x tests/run.sh
./tests/run.sh
```

Expected: `0 test file(s), 0 failed` and exit status 0.

- [ ] **Step 6: Commit**

```bash
git add LICENSE .gitignore tests/
git commit -m "chore: repository skeleton, MIT license and test harness"
```

---

### Task 2: lib/common.sh — logging, failure, preflight

**Files:**
- Create: `lib/common.sh`
- Test: `tests/test_common.sh`

**Interfaces:**
- Consumes: nothing
- Produces: `log_info <msg>`, `log_warn <msg>`, `log_ok <msg>`, `die <msg>`
  (prints to stderr, exits 1), `require_cmd <name...>` (dies listing every
  missing command), `is_dry_run` (returns 0 when `DRY_RUN` is `1`),
  `run_cmd <command...>` (echoes and skips when dry-run, else executes).

- [ ] **Step 1: Write the failing test — `tests/test_common.sh`**

```bash
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
```

- [ ] **Step 2: Run it to confirm it fails**

Run: `bash tests/test_common.sh`
Expected: FAIL — `lib/common.sh: No such file or directory`

- [ ] **Step 3: Write `lib/common.sh`**

```bash
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
```

- [ ] **Step 4: Run the test to confirm it passes**

Run: `bash tests/test_common.sh`
Expected: all assertions `ok`, exit 0.

- [ ] **Step 5: Commit**

```bash
git add lib/common.sh tests/test_common.sh
git commit -m "feat(lib): add logging, failure and dry-run helpers"
```

---

### Task 3: lib/secrets.sh — idempotent .env generation

**Files:**
- Create: `lib/secrets.sh`
- Test: `tests/test_secrets.sh`

**Interfaces:**
- Consumes: `die` from `lib/common.sh`
- Produces:
  - `gen_secret` — echoes 64 hex characters
  - `env_load <envfile>` — sources the file if it exists (no-op otherwise)
  - `env_get <envfile> <key>` — echoes the value or empty string
  - `env_set <envfile> <key> <value>` — replaces the key in place, or appends
  - `env_ensure_secret <envfile> <key>` — generates and stores only when the
    key is absent or empty; never overwrites an existing value
  - `env_init <envfile>` — creates the file `chmod 600` if missing

- [ ] **Step 1: Write the failing test — `tests/test_secrets.sh`**

```bash
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
```

- [ ] **Step 2: Run it to confirm it fails**

Run: `bash tests/test_secrets.sh`
Expected: FAIL — `lib/secrets.sh: No such file or directory`

- [ ] **Step 3: Write `lib/secrets.sh`**

```bash
#!/usr/bin/env bash
# .env creation and idempotent secret generation. bash 3.2 compatible.

# Hex, not base64: these values are embedded in postgresql:// URIs and
# base64's "/" and "+" silently corrupt the DSN.
gen_secret() { openssl rand -hex 32; }

env_init() {
  local f="$1"
  if [ ! -e "$f" ]; then
    umask 077
    : > "$f"
  fi
  chmod 600 "$f"
}

env_load() {
  local f="$1"
  [ -e "$f" ] || return 0
  set -a
  # shellcheck disable=SC1090
  . "$f"
  set +a
}

env_get() {
  local f="$1" k="$2"
  [ -e "$f" ] || { printf ''; return 0; }
  # Last occurrence wins, mirroring shell sourcing semantics.
  sed -n "s/^${k}=//p" "$f" | tail -1
}

env_set() {
  local f="$1" k="$2" v="$3" tmp
  env_init "$f"
  tmp="${f}.tmp.$$"
  grep -v "^${k}=" "$f" > "$tmp" 2>/dev/null || : > "$tmp"
  printf '%s=%s\n' "$k" "$v" >> "$tmp"
  mv "$tmp" "$f"
  chmod 600 "$f"
}

env_ensure_secret() {
  local f="$1" k="$2" current
  current=$(env_get "$f" "$k")
  [ -n "$current" ] && return 0
  env_set "$f" "$k" "$(gen_secret)"
}
```

- [ ] **Step 4: Run the test to confirm it passes**

Run: `bash tests/test_secrets.sh`
Expected: all assertions `ok`, exit 0.

- [ ] **Step 5: Commit**

```bash
git add lib/secrets.sh tests/test_secrets.sh
git commit -m "feat(lib): idempotent .env handling and hex secret generation"
```

---

### Task 4: Stack manifests and discovery

**Files:**
- Create: `stacks/infra/traefik.stack`, `stacks/infra/portainer.stack`,
  `stacks/db/postgres.stack`, `stacks/db/redis.stack`,
  `stacks/app/evolution-api.stack`
- Create: `lib/manifest.sh`
- Test: `tests/test_manifest.sh`

**Interfaces:**
- Consumes: `die` from `lib/common.sh`
- Produces:
  - `manifest_list` — echoes every `stacks/*/*.stack` path, sorted by
    `STACK_TIER` ascending then by path, one per line
  - `manifest_load <path>` — resets then sources one manifest, exporting
    `STACK_NAME`, `STACK_FILE`, `STACK_TIER`, `STACK_SUBDOMAIN`,
    `STACK_SECRETS`, `STACK_VOLUMES`; dies if `STACK_NAME` or `STACK_FILE` is
    empty, or if `STACK_FILE` does not exist
  - `manifest_all_secrets` — echoes every distinct secret name across manifests
  - `manifest_all_volumes` — echoes every distinct volume name across manifests

Manifests may define an optional `stack_pre_deploy` function; `manifest_load`
unsets any previous definition before sourcing so it never leaks between stacks.

- [ ] **Step 1: Write the five manifests**

`stacks/infra/traefik.stack`:

```sh
STACK_NAME="traefik"
STACK_FILE="stacks/infra/traefik.yml"
STACK_TIER=10
STACK_SUBDOMAIN=""
STACK_SECRETS=""
STACK_VOLUMES="volume_swarm_certificates volume_swarm_shared"
```

`stacks/infra/portainer.stack`:

```sh
STACK_NAME="portainer"
STACK_FILE="stacks/infra/portainer.yml"
STACK_TIER=10
STACK_SUBDOMAIN="portainer"
STACK_SECRETS=""
STACK_VOLUMES="portainer_data"
```

`stacks/db/postgres.stack`:

```sh
STACK_NAME="postgres"
STACK_FILE="stacks/db/postgres.yml"
STACK_TIER=20
STACK_SUBDOMAIN=""
STACK_SECRETS="POSTGRES_PASSWORD"
STACK_VOLUMES=""
```

`stacks/db/redis.stack`:

```sh
STACK_NAME="redis"
STACK_FILE="stacks/db/redis.yml"
STACK_TIER=20
STACK_SUBDOMAIN=""
STACK_SECRETS=""
STACK_VOLUMES=""
```

`stacks/app/evolution-api.stack`:

```sh
STACK_NAME="evolution"
STACK_FILE="stacks/app/evolution-api.yml"
STACK_TIER=30
STACK_SUBDOMAIN="evo"
STACK_SECRETS="EVOLUTION_API_KEY EVOLUTION_DB_PASSWORD"
STACK_VOLUMES="evolution_instances evolution_store"

stack_pre_deploy() {
  pg_ensure_role_db evolution "$EVOLUTION_DB_PASSWORD"
}
```

- [ ] **Step 2: Write the failing test — `tests/test_manifest.sh`**

```bash
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

printf '%s run, %s failed\n' "$TESTS_RUN" "$TESTS_FAILED"
[ "$TESTS_FAILED" -eq 0 ]
```

- [ ] **Step 3: Run it to confirm it fails**

Run: `bash tests/test_manifest.sh`
Expected: FAIL — `lib/manifest.sh: No such file or directory`

- [ ] **Step 4: Write `lib/manifest.sh`**

```bash
#!/usr/bin/env bash
# Stack manifest discovery and loading. bash 3.2 compatible (no assoc arrays).

manifest_list() {
  local f tier
  for f in stacks/*/*.stack; do
    [ -e "$f" ] || continue
    tier=$(sed -n 's/^STACK_TIER=//p' "$f" | tail -1)
    [ -n "$tier" ] || tier=99
    printf '%s\t%s\n' "$tier" "$f"
  done | sort -n -k1,1 -k2,2 | cut -f2
}

manifest_load() {
  local f="$1"
  [ -e "$f" ] || die "manifest not found: $f"

  STACK_NAME=""; STACK_FILE=""; STACK_TIER=""
  STACK_SUBDOMAIN=""; STACK_SECRETS=""; STACK_VOLUMES=""
  unset -f stack_pre_deploy 2>/dev/null || true

  # shellcheck disable=SC1090
  . "$f"

  [ -n "$STACK_NAME" ] || die "manifest $f does not set STACK_NAME"
  [ -n "$STACK_FILE" ] || die "manifest $f does not set STACK_FILE"
  [ -e "$STACK_FILE" ] || die "manifest $f points at a missing file: $STACK_FILE"
}

_manifest_collect() { # field name
  local field="$1" f
  for f in $(manifest_list); do
    manifest_load "$f"
    case "$field" in
      secrets) printf '%s\n' $STACK_SECRETS ;;
      volumes) printf '%s\n' $STACK_VOLUMES ;;
    esac
  done | grep -v '^$' | sort -u
}

manifest_all_secrets() { _manifest_collect secrets; }
manifest_all_volumes() { _manifest_collect volumes; }
```

- [ ] **Step 5: Run the test to confirm it passes**

Run: `bash tests/test_manifest.sh`
Expected: all assertions `ok`, exit 0.

- [ ] **Step 6: Commit**

```bash
git add lib/manifest.sh stacks/
git commit -m "feat(stacks): add per-stack manifests and discovery"
```

---

### Task 5: lib/render.sh — templating with an allowlist and validation

**Files:**
- Create: `lib/render.sh`
- Test: `tests/test_render.sh`

**Interfaces:**
- Consumes: `die`, `log_ok` from `lib/common.sh`
- Produces:
  - `render_varlist <name...>` — echoes an envsubst allowlist string, e.g.
    `'${DOMAIN} ${POSTGRES_PASSWORD}'`
  - `render_file <src> <dst> <allowlist>` — renders one file, creating parent
    directories
  - `render_validate <path>` — dies if any `${` remains in the rendered file,
    naming the file and the offending lines

The allowlist matters: bare `envsubst` substitutes every `${...}` it recognises,
which will corrupt future stacks (n8n, Chatwoot) whose configuration contains
legitimate `$`.

- [ ] **Step 1: Write the failing test — `tests/test_render.sh`**

```bash
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
```

- [ ] **Step 2: Run it to confirm it fails**

Run: `bash tests/test_render.sh`
Expected: FAIL — `lib/render.sh: No such file or directory`

- [ ] **Step 3: Write `lib/render.sh`**

```bash
#!/usr/bin/env bash
# Template rendering with an explicit allowlist, plus post-render validation.

render_varlist() {
  local out="" n
  for n in "$@"; do
    out="$out\${$n} "
  done
  # Trim the trailing space without bash 4 expansions.
  printf '%s' "${out% }"
}

render_file() { # src dst allowlist
  local src="$1" dst="$2" allow="$3"
  [ -e "$src" ] || die "template not found: $src"
  mkdir -p "$(dirname "$dst")"
  envsubst "$allow" < "$src" > "$dst"
}

render_validate() { # path
  local f="$1" hits
  hits=$(grep -n '\${' "$f" || true)
  if [ -n "$hits" ]; then
    printf 'error: unresolved variables in %s\n' "$f" >&2
    printf '%s\n' "$hits" >&2
    exit 1
  fi
  return 0
}
```

- [ ] **Step 4: Run the test to confirm it passes**

Run: `bash tests/test_render.sh`
Expected: all assertions `ok`, exit 0.

- [ ] **Step 5: Commit**

```bash
git add lib/render.sh tests/test_render.sh
git commit -m "feat(lib): render templates with an allowlist and validate output"
```

---

### Task 6: Migrate the stack YAMLs into templates

**Files:**
- Create: `stacks/infra/traefik.yml`, `stacks/infra/portainer.yml`,
  `stacks/db/postgres.yml`, `stacks/db/redis.yml`, `stacks/app/evolution-api.yml`
- Create: `.env.example`
- Test: `tests/test_templates.sh`

**Interfaces:**
- Consumes: `render_file`, `render_validate`, `render_varlist`, `manifest_list`
- Produces: templates whose only `${...}` placeholders are `DOMAIN`,
  `ACME_EMAIL`, `POSTGRES_PASSWORD`, `EVOLUTION_API_KEY`,
  `EVOLUTION_DB_PASSWORD`

Copy each file from `eorgan/quickstack` at commit `65a3f07` (which already has
the Traefik v3 fixes, the updated images and no published database ports), then
replace the hardcoded values. The full contents are below — use them verbatim.

- [ ] **Step 1: Create `stacks/infra/traefik.yml`**

```yaml
services:
  traefik:
    image: traefik:v3.7.12
    command:
      - "--api.dashboard=true"
      - "--providers.swarm.endpoint=unix:///var/run/docker.sock"
      - "--providers.swarm.exposedbydefault=false"
      - "--providers.swarm.network=network_public"
      - "--entrypoints.web.address=:80"
      - "--entrypoints.web.http.redirections.entryPoint.to=websecure"
      - "--entrypoints.web.http.redirections.entryPoint.scheme=https"
      - "--entrypoints.web.http.redirections.entrypoint.permanent=true"
      - "--entrypoints.websecure.address=:443"
      - "--certificatesresolvers.letsencryptresolver.acme.httpchallenge=true"
      - "--certificatesresolvers.letsencryptresolver.acme.httpchallenge.entrypoint=web"
      - "--certificatesresolvers.letsencryptresolver.acme.email=${ACME_EMAIL}"
      - "--certificatesresolvers.letsencryptresolver.acme.storage=/etc/traefik/letsencrypt/acme.json"
      - "--log.level=INFO"
      - "--log.format=common"
      - "--log.filePath=/var/log/traefik/traefik.log"
      - "--accesslog=true"
      - "--accesslog.filepath=/var/log/traefik/access-log"
    deploy:
      placement:
        constraints:
          - node.role == manager
      labels:
        - "traefik.enable=true"
        - "traefik.http.middlewares.redirect-https.redirectscheme.scheme=https"
        - "traefik.http.middlewares.redirect-https.redirectscheme.permanent=true"
        - "traefik.http.routers.http-catchall.rule=HostRegexp(`.+`)"
        - "traefik.http.routers.http-catchall.entrypoints=web"
        - "traefik.http.routers.http-catchall.middlewares=redirect-https@swarm"
        - "traefik.http.routers.http-catchall.priority=1"
    volumes:
      - "/var/run/docker.sock:/var/run/docker.sock:ro"
      - "vol_certificates:/etc/traefik/letsencrypt"
    networks:
      - network_public
    ports:
      - target: 80
        published: 80
        mode: host
      - target: 443
        published: 443
        mode: host
volumes:
  vol_shared:
    external: true
    name: volume_swarm_shared
  vol_certificates:
    external: true
    name: volume_swarm_certificates
networks:
  network_public:
    external: true
    name: network_public
```

- [ ] **Step 2: Create `stacks/infra/portainer.yml`**

```yaml
services:
  agent:
    image: portainer/agent:2.45.0
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - /var/lib/docker/volumes:/var/lib/docker/volumes
    networks:
      - network_public
    deploy:
      mode: global
      placement:
        constraints: [node.platform.os == linux]
  portainer:
    image: portainer/portainer-ce:2.45.0
    command: -H tcp://tasks.agent:9001 --tlsskipverify
    volumes:
      - portainer_data:/data
    networks:
      - network_public
    deploy:
      mode: replicated
      replicas: 1
      placement:
        constraints: [node.role == manager]
      labels:
        - "traefik.enable=true"
        - "traefik.swarm.network=network_public"
        - "traefik.http.routers.portainer.rule=Host(`portainer.${DOMAIN}`)"
        - "traefik.http.routers.portainer.entrypoints=websecure"
        - "traefik.http.routers.portainer.priority=1"
        - "traefik.http.routers.portainer.tls.certresolver=letsencryptresolver"
        - "traefik.http.routers.portainer.service=portainer"
        - "traefik.http.services.portainer.loadbalancer.server.port=9000"
networks:
  network_public:
    external: true
    attachable: true
    name: network_public
volumes:
  portainer_data:
    external: true
    name: portainer_data
```

- [ ] **Step 3: Create `stacks/db/postgres.yml`**

```yaml
services:
  postgres:
    image: pgvector/pgvector:0.8.6-pg17
    networks:
      - network_public
    entrypoint: docker-entrypoint.sh
    command: [postgres, --max_connections=200]
    volumes:
      - postgres-data:/var/lib/postgresql/data
    environment:
      - POSTGRES_PASSWORD=${POSTGRES_PASSWORD}
      - POSTGRES_INITDB_ARGS="--auth-host=scram-sha-256"
    deploy:
      mode: replicated
      replicas: 1
      placement:
        constraints:
          - node.role == manager
      resources:
        limits:
          cpus: "0.5"
          memory: 256M
networks:
  network_public:
    external: true
    name: network_public
volumes:
  postgres-data:
    driver: local
```

- [ ] **Step 4: Create `stacks/db/redis.yml`**

```yaml
services:
  redis:
    image: redis:8.10.1
    networks:
      - network_public
    volumes:
      - redis-data:/data
    command: redis-server --appendonly yes --port 6379
    deploy:
      mode: replicated
      replicas: 1
      placement:
        constraints:
          - node.role == manager
      resources:
        limits:
          cpus: "0.5"
          memory: 128M
networks:
  network_public:
    external: true
    name: network_public
volumes:
  redis-data:
    driver: local
```

- [ ] **Step 5: Create `stacks/app/evolution-api.yml`**

```yaml
services:
  evolution:
    image: evoapicloud/evolution-api:v2.3.7
    command: ["node", "./dist/src/main.js"]
    networks:
      - network_public
    volumes:
      - evolution_instances:/evolution/instances
      - evolution_store:/evolution/store
    environment:
      - SERVER_URL=https://evo.${DOMAIN}
      - SERVER_PORT=8080
      - DOCKER_ENV=true

      - DEL_INSTANCE=false

      - CONFIG_SESSION_PHONE_CLIENT=EvolutionAPI
      - CONFIG_SESSION_PHONE_NAME=Chrome

      - STORE_MESSAGES=true
      - STORE_MESSAGE_UP=true
      - STORE_CONTACTS=true
      - STORE_CHATS=true

      - CLEAN_STORE_CLEANING_INTERVAL=7200
      - CLEAN_STORE_MESSAGES=true
      - CLEAN_STORE_MESSAGE_UP=true
      - CLEAN_STORE_CONTACTS=true
      - CLEAN_STORE_CHATS=true

      - AUTHENTICATION_TYPE=apikey
      - AUTHENTICATION_API_KEY=${EVOLUTION_API_KEY}
      - AUTHENTICATION_EXPOSE_IN_FETCH_INSTANCES=true

      - QRCODE_LIMIT=30

      - RABBITMQ_ENABLED=false

      - CHATWOOT_ENABLED=true

      - DATABASE_ENABLED=true
      - DATABASE_PROVIDER=postgresql
      - DATABASE_CONNECTION_URI=postgresql://evolution:${EVOLUTION_DB_PASSWORD}@postgres:5432/evolution?schema=public
      - DATABASE_SAVE_DATA_INSTANCE=true
      - DATABASE_SAVE_DATA_NEW_MESSAGE=true
      - DATABASE_SAVE_MESSAGE_UPDATE=true
      - DATABASE_SAVE_DATA_CONTACTS=true
      - DATABASE_SAVE_DATA_CHATS=true

      - CACHE_REDIS_ENABLED=true
      - CACHE_REDIS_URI=redis://redis:6379/2
    deploy:
      mode: replicated
      replicas: 1
      placement:
        constraints:
          - node.role == manager
      resources:
        limits:
          cpus: "0.5"
          memory: 256M
      labels:
        - traefik.enable=true
        - traefik.http.routers.evolution.rule=Host(`evo.${DOMAIN}`)
        - traefik.http.routers.evolution.entrypoints=websecure
        - traefik.http.routers.evolution.tls.certresolver=letsencryptresolver
        - traefik.http.routers.evolution.priority=1
        - traefik.http.routers.evolution.service=evolution
        - traefik.http.services.evolution.loadbalancer.server.port=8080
        - traefik.http.services.evolution.loadbalancer.passHostHeader=true
volumes:
  evolution_instances:
    external: true
    name: evolution_instances
  evolution_store:
    external: true
    name: evolution_store
networks:
  network_public:
    name: network_public
    external: true
```

- [ ] **Step 6: Create `.env.example`**

```
# Copy to .env, or let install.sh create it for you.
# install.sh generates every secret; you only ever supply DOMAIN and ACME_EMAIL.
DOMAIN=exemplo.com.br
ACME_EMAIL=voce@exemplo.com.br

# Generated automatically — never commit real values.
POSTGRES_PASSWORD=
EVOLUTION_API_KEY=
EVOLUTION_DB_PASSWORD=
```

- [ ] **Step 7: Write the test — `tests/test_templates.sh`**

```bash
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
  ruby -ryaml -e "YAML.load_file('$tmp/$STACK_NAME.yml')" >/dev/null 2>&1 && rc=0 || rc=1
  assert_eq "0" "$rc" "$STACK_NAME renders to valid YAML"
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
```

- [ ] **Step 8: Run the test**

Run: `bash tests/test_templates.sh`
Expected: every stack renders, parses as YAML, and no hardcoded value remains.

- [ ] **Step 9: Commit**

```bash
git add stacks/ .env.example tests/test_templates.sh
git commit -m "feat(stacks): migrate quickstack YAMLs into domain/secret templates"
```

---

### Task 7: lib/postgres.sh — readiness gate and role bootstrap

**Files:**
- Create: `lib/postgres.sh`
- Test: `tests/test_postgres.sh`

**Interfaces:**
- Consumes: `die`, `log_info`, `log_ok`, `is_dry_run` from `lib/common.sh`
- Produces:
  - `pg_container_id` — echoes the local Postgres container id, empty if none
  - `pg_wait_ready [timeout_seconds]` — polls `pg_isready`, default timeout 120,
    dies with a clear message on timeout, returns 0 immediately under dry-run
  - `pg_ensure_role_db <role> <password>` — creates the role and its database if
    absent and always resets the password, so `.env` and the server cannot drift;
    no-op under dry-run

This closes the bug inherited from quickstack: `postgres.yml` only ever creates
the `postgres` superuser, while Evolution connects as `evolution` to database
`evolution`, which nothing created.

- [ ] **Step 1: Write the failing test — `tests/test_postgres.sh`**

Docker is not assumed present in tests, so the tests cover the dry-run contract
and the generated SQL, not a live server.

```bash
#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "$0")/.."
. tests/helpers.sh
. lib/common.sh
. lib/postgres.sh

DRY_RUN=1

pg_wait_ready 1 >/dev/null 2>&1 && rc=0 || rc=$?
assert_eq "0" "$rc" "pg_wait_ready short-circuits under dry-run"

pg_ensure_role_db evolution secret123 >/dev/null 2>&1 && rc=0 || rc=$?
assert_eq "0" "$rc" "pg_ensure_role_db is a no-op under dry-run"

sql=$(pg_role_sql evolution "secret123")
assert_contains "$sql" "CREATE ROLE evolution" "SQL creates the role"
assert_contains "$sql" "ALTER ROLE evolution WITH PASSWORD" "SQL resets the password"
assert_contains "$sql" "secret123" "SQL carries the password"

sql=$(pg_db_sql evolution evolution)
assert_contains "$sql" "CREATE DATABASE evolution" "SQL creates the database"
assert_contains "$sql" "OWNER evolution" "database is owned by the role"

out=$( (pg_ensure_role_db "" pw) 2>&1 || true )
assert_contains "$out" "role" "pg_ensure_role_db rejects an empty role"

out=$( (pg_ensure_role_db evolution "") 2>&1 || true )
assert_contains "$out" "password" "pg_ensure_role_db rejects an empty password"

printf '%s run, %s failed\n' "$TESTS_RUN" "$TESTS_FAILED"
[ "$TESTS_FAILED" -eq 0 ]
```

- [ ] **Step 2: Run it to confirm it fails**

Run: `bash tests/test_postgres.sh`
Expected: FAIL — `lib/postgres.sh: No such file or directory`

- [ ] **Step 3: Write `lib/postgres.sh`**

```bash
#!/usr/bin/env bash
# PostgreSQL readiness and role/database bootstrap.

pg_container_id() {
  docker ps -q -f name=postgres 2>/dev/null | head -1
}

pg_wait_ready() {
  local timeout="${1:-120}" waited=0 cid
  is_dry_run && return 0

  log_info "waiting for PostgreSQL to accept connections"
  while [ "$waited" -lt "$timeout" ]; do
    cid=$(pg_container_id)
    if [ -n "$cid" ] && docker exec "$cid" pg_isready -U postgres >/dev/null 2>&1; then
      log_ok "PostgreSQL is ready"
      return 0
    fi
    sleep 3
    waited=$((waited + 3))
  done
  die "PostgreSQL did not become ready within ${timeout}s. Check: docker service logs <stack>_postgres"
}

# Idempotent: creates the role when absent, and always resets the password so
# that .env and the server cannot drift apart.
pg_role_sql() { # role password
  cat <<SQL
DO \$\$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '$1') THEN
    CREATE ROLE $1 LOGIN;
  END IF;
END
\$\$;
ALTER ROLE $1 WITH PASSWORD '$2';
SQL
}

pg_db_sql() { # database owner
  cat <<SQL
SELECT 'CREATE DATABASE $1 OWNER $2'
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = '$1')\gexec
SQL
}

pg_ensure_role_db() { # role password
  local role="$1" password="$2" cid
  [ -n "$role" ]     || die "pg_ensure_role_db: role must not be empty"
  [ -n "$password" ] || die "pg_ensure_role_db: password must not be empty"
  is_dry_run && return 0

  cid=$(pg_container_id)
  [ -n "$cid" ] || die "no running PostgreSQL container found on this node"

  pg_role_sql "$role" "$password" | docker exec -i "$cid" psql -v ON_ERROR_STOP=1 -U postgres -q
  pg_db_sql  "$role" "$role"      | docker exec -i "$cid" psql -v ON_ERROR_STOP=1 -U postgres -q
  log_ok "PostgreSQL role and database '$role' are in place"
}
```

- [ ] **Step 4: Run the test to confirm it passes**

Run: `bash tests/test_postgres.sh`
Expected: all assertions `ok`, exit 0.

- [ ] **Step 5: Commit**

```bash
git add lib/postgres.sh tests/test_postgres.sh
git commit -m "feat(lib): PostgreSQL readiness gate and idempotent role bootstrap"
```

---

### Task 8: install.sh — orchestration, flags and dry-run

**Files:**
- Create: `install.sh`
- Test: `tests/test_install.sh`

**Interfaces:**
- Consumes: everything from `lib/`
- Produces: the `install.sh` entry point, supporting `--domain <d>`,
  `--email <e>`, `--dry-run`, `--help`

Deploy uses `docker stack deploy --prune --resolve-image always -c dist/<n>.yml
<STACK_NAME>`. Existing networks and volumes are detected before creation, so a
host already provisioned by ubinkaze is safe.

- [ ] **Step 1: Write the failing test — `tests/test_install.sh`**

```bash
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

rm -rf "$tmp"
printf '%s run, %s failed\n' "$TESTS_RUN" "$TESTS_FAILED"
[ "$TESTS_FAILED" -eq 0 ]
```

- [ ] **Step 2: Run it to confirm it fails**

Run: `bash tests/test_install.sh`
Expected: FAIL — `./install.sh: No such file or directory`

- [ ] **Step 3: Write `install.sh`**

```bash
#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

. lib/common.sh
. lib/secrets.sh
. lib/manifest.sh
. lib/render.sh
. lib/postgres.sh

ENV_FILE="${VPINSTALL_ENV_FILE:-$ROOT/.env}"
DIST="${VPINSTALL_DIST:-$ROOT/dist}"
ARG_DOMAIN=""
ARG_EMAIL=""

usage() {
  cat <<'USAGE'
Usage: ./install.sh [options]

Deploys every stack to Docker Swarm. Safe to re-run: existing secrets are
reused, so this is also the update path.

Options:
  --domain <domain>   Root domain for every service (asked once, then stored)
  --email <email>     Email for Let's Encrypt registration
  --dry-run           Render and validate everything, deploy nothing
  --help              Show this message
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --domain)  ARG_DOMAIN="$2"; shift 2 ;;
    --email)   ARG_EMAIL="$2";  shift 2 ;;
    --dry-run) DRY_RUN=1;       shift ;;
    --help|-h) usage; exit 0 ;;
    *) usage; die "unknown option: $1" ;;
  esac
done

# --- preflight -------------------------------------------------------------
require_cmd openssl envsubst sed grep
is_dry_run || require_cmd docker
if ! is_dry_run; then
  [ "$(docker info -f '{{.Swarm.LocalNodeState}}' 2>/dev/null)" = "active" ] \
    || die "Docker Swarm is not active on this node. Run: docker swarm init"
fi

# --- domain, email, secrets ------------------------------------------------
env_init "$ENV_FILE"

[ -n "$ARG_DOMAIN" ] && env_set "$ENV_FILE" DOMAIN     "$ARG_DOMAIN"
[ -n "$ARG_EMAIL" ]  && env_set "$ENV_FILE" ACME_EMAIL "$ARG_EMAIL"

if [ -z "$(env_get "$ENV_FILE" DOMAIN)" ]; then
  printf 'Root domain (e.g. exemplo.com.br): ' >&2
  read -r reply
  [ -n "$reply" ] || die "a domain is required"
  env_set "$ENV_FILE" DOMAIN "$reply"
fi
if [ -z "$(env_get "$ENV_FILE" ACME_EMAIL)" ]; then
  printf "Email for Let's Encrypt: " >&2
  read -r reply
  [ -n "$reply" ] || die "an email is required"
  env_set "$ENV_FILE" ACME_EMAIL "$reply"
fi

for s in $(manifest_all_secrets); do
  env_ensure_secret "$ENV_FILE" "$s"
done

env_load "$ENV_FILE"
log_ok "configuration ready ($ENV_FILE)"

# --- networks and volumes --------------------------------------------------
if ! is_dry_run; then
  if docker network inspect network_public >/dev/null 2>&1; then
    log_ok "network network_public already exists"
  else
    run_cmd docker network create --driver overlay --attachable network_public
  fi
  for v in $(manifest_all_volumes); do
    if docker volume inspect "$v" >/dev/null 2>&1; then
      log_ok "volume $v already exists"
    else
      run_cmd docker volume create "$v"
    fi
  done
else
  log_info "[dry-run] would ensure network_public and volumes: $(manifest_all_volumes | tr '\n' ' ')"
fi

# --- render ----------------------------------------------------------------
mkdir -p "$DIST"; chmod 700 "$DIST"
ALLOW=$(render_varlist DOMAIN ACME_EMAIL $(manifest_all_secrets))

for m in $(manifest_list); do
  manifest_load "$m"
  render_file "$STACK_FILE" "$DIST/$STACK_NAME.yml" "$ALLOW"
  render_validate "$DIST/$STACK_NAME.yml"
done
log_ok "all stacks rendered and validated into $DIST"

# --- deploy ----------------------------------------------------------------
for m in $(manifest_list); do
  manifest_load "$m"

  if [ "$STACK_TIER" -ge 30 ]; then
    pg_wait_ready
  fi
  if type stack_pre_deploy >/dev/null 2>&1; then
    stack_pre_deploy
  fi

  run_cmd docker stack deploy --prune --resolve-image always \
    -c "$DIST/$STACK_NAME.yml" "$STACK_NAME"
  log_ok "deployed $STACK_NAME"
done

# --- summary ---------------------------------------------------------------
printf '\nDone. Point these DNS records at this server:\n' >&2
for m in $(manifest_list); do
  manifest_load "$m"
  [ -n "$STACK_SUBDOMAIN" ] && printf '  %s.%s\n' "$STACK_SUBDOMAIN" "$DOMAIN" >&2
done
printf '\nCredentials are in %s (never commit it).\n' "$ENV_FILE" >&2
```

- [ ] **Step 4: Make it executable and run the test**

```bash
chmod +x install.sh
bash tests/test_install.sh
```

Expected: all assertions `ok`, exit 0.

- [ ] **Step 5: Run the whole suite**

Run: `./tests/run.sh`
Expected: every test file passes, `0 failed`.

- [ ] **Step 6: Commit**

```bash
git add install.sh tests/test_install.sh
git commit -m "feat: add install.sh with idempotent secrets, rendering and tiered deploy"
```

---

### Task 9: README

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Replace `README.md`**

```markdown
# VPInstall

Instalador de VPS: prepara o servidor e sobe as stacks em Docker Swarm atrás do
Traefik com TLS, a partir de um único domínio raiz e sem digitar senhas.

## Uso

Numa máquina que já tenha Docker e Swarm ativos:

```bash
git clone https://github.com/eorgan/VPInstall.git
cd VPInstall
./install.sh --domain exemplo.com.br --email voce@exemplo.com.br
```

O script gera todas as credenciais, guarda em `.env` (modo 600) e implanta as
stacks na ordem de dependência. Rodar de novo é seguro: os segredos existentes
são reaproveitados, então este é também o caminho de atualização.

Para ver o que seria feito, sem tocar no cluster:

```bash
./install.sh --dry-run --domain exemplo.com.br --email voce@exemplo.com.br
```

## Stacks

| Stack | Host | Tier |
|---|---|---|
| Traefik | — | 10 |
| Portainer | `portainer.<domínio>` | 10 |
| PostgreSQL (pgvector) | — | 20 |
| Redis | — | 20 |
| Evolution API | `evo.<domínio>` | 30 |

Aponte os registros DNS para o servidor **antes** de rodar, senão o Let's
Encrypt não consegue emitir os certificados.

## Adicionar uma stack

Crie dois arquivos e nada mais — `install.sh` não muda:

- `stacks/<categoria>/<nome>.yml` — o compose, com `${DOMAIN}` e `${SEGREDO}`
- `stacks/<categoria>/<nome>.stack` — o manifesto (nome, tier, subdomínio,
  segredos, volumes e um `stack_pre_deploy` opcional)

## Testes

```bash
./tests/run.sh
```

Rodam sem Docker e sem dependências externas.

## Licença

[MIT](LICENSE). Os arquivos de stack derivam de
[felipefontoura/bento](https://github.com/felipefontoura/bento).
```

- [ ] **Step 2: Commit**

```bash
git add README.md
git commit -m "docs: document usage, stacks and how to add one"
```

---

## Self-Review

**Spec coverage.** Every section maps to a task: two entry points (this plan
covers `install.sh`; `setup-server.sh` gets its own plan) · file structure
(Tasks 1–8) · manifests (Task 4) · domain (Tasks 6, 8) · secrets (Task 3) ·
rendering and validation (Task 5) · deploy sequence (Task 8) · security —
modes, no secrets on stdout, no published DB ports (Tasks 1, 3, 6, 8) ·
license and provenance (Task 1) · tests including the idempotency check
(Tasks 1–8).

**Known deviations from the spec, deliberate:**

1. **No DNS pre-check.** The spec called for a non-fatal DNS warning. It is
   dropped here to keep Task 8 focused; the README instead states the DNS
   requirement plainly. Worth adding once the installer has run for real.
2. **`docker stack config` validation** is not used — it is unavailable on
   older Docker and the `grep '\${'` gate plus the YAML parse in the tests
   already cover the failure it would catch.
3. **One stack per `docker stack deploy`.** Each manifest deploys under its own
   stack name rather than one combined stack, which makes per-stack redeploy
   and rollback possible. `--prune` is therefore scoped per stack.

**Open risk:** `pg_container_id` matches `docker ps -f name=postgres`, which
would also match an unrelated container whose name contains "postgres". The
Postgres service is constrained to the manager node, so this holds for the
single-node setup, but it must be tightened before any multi-node use.
