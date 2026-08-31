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
