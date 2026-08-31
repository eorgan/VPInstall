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
