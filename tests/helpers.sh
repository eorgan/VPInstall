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
  actual=$(ls -ld "$2" | cut -c1-10)
  case "$1" in
    600) [ "$actual" = "-rw-------" ] && _ok "$3" || { _notok "$3"; printf '       mode: %s\n' "$actual"; } ;;
    700) [ "$actual" = "drwx------" ] && _ok "$3" || { _notok "$3"; printf '       mode: %s\n' "$actual"; } ;;
    *) _notok "$3 (unsupported mode $1)" ;;
  esac
}

# Each test file creates its own sandbox and cleans it up.
make_tmpdir() { mktemp -d "${TMPDIR:-/tmp}/vpinstall.XXXXXX"; }
