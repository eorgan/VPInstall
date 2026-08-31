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
  if ! envsubst "$allow" < "$src" > "$dst"; then
    rm -f "$dst"
    die "envsubst failed while rendering $src"
  fi
}

render_validate() { # path
  local f="$1" hits lineno rest vars var
  hits=$(grep -n '\${' "$f" || true)
  if [ -n "$hits" ]; then
    while IFS=: read -r lineno rest; do
      vars=$(printf '%s\n' "$rest" | grep -o '\${[A-Za-z_][A-Za-z0-9_]*}' || true)
      if [ -n "$vars" ]; then
        printf '%s\n' "$vars" | while read -r var; do
          printf '%s:%s: unresolved %s\n' "$f" "$lineno" "$var" >&2
        done
      else
        printf '%s:%s: unresolved placeholder (not a simple ${NAME})\n' "$f" "$lineno" >&2
      fi
    done <<< "$hits"
    return 1
  fi
  return 0
}
