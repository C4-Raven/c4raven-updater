#!/usr/bin/env bash
# Single-quoted bash -c snippets take their arguments positionally on purpose.
# shellcheck disable=SC2016
# Tests for lib/common.sh's fedhub_section wiring: the unattended skip
# variables (same precedence as c4raven-server-setup's install.sh) and the
# once-per-run guard that stops update.sh asking twice after it ran
# finish-install.sh.
#
#   bash tests/fedhub-section-unit.sh
#
# No root, no network: install-fedhub.sh is a stub that records its calls,
# and `sudo` is a stub on PATH (the script refuses to run otherwise).
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
T=$(mktemp -d "${TMPDIR:-/tmp}/fedhub-section.XXXXXX")
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/shims" "$T/raven"
printf '#!/bin/sh\n# test stub: never escalates\n"$@"\n' > "$T/shims/sudo"
chmod +x "$T/shims/sudo"
export PATH="$T/shims:$PATH" NO_COLOR=1 RAVEN_HOME="$T/raven" FEDHUB_TTY="$T/no-tty"
[ "$(command -v sudo)" = "$T/shims/sudo" ] || { echo "sudo is not the stub; refusing to run"; exit 1; }
unset RAVEN_FEDHUB_SKIP RAVEN_FEDHUB_ARTIFACT RAVEN_FEDHUB_DEB RAVEN_FEDHUB_SECTION_DONE

STUB="$T/install-fedhub.sh"
CALLS="$T/calls"
# --check says "installed and connected", so a run is just one --check call.
printf '#!/bin/bash\necho "stub $*" >> "%s"\n[ "$1" = --check ] && exit 0\nexit 0\n' "$CALLS" > "$STUB"

PASS=0; FAIL=0
ok_()   { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
fail_() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; }
check() { local d=$1; shift; if "$@"; then ok_ "$d"; else fail_ "$d"; fi; }

# section [VAR=VAL ...] -- one fedhub_section call in a clean subshell, with
# the given environment. Prints its output; the stub's calls go to $CALLS.
section() {
  : > "$CALLS"
  env "$@" FEDHUB_SCRIPT="$STUB" bash -c '. "$1/lib/common.sh"; fedhub_section raven; echo "rc=$?"; echo "done=${RAVEN_FEDHUB_SECTION_DONE:-}"' _ "$REPO" 2>&1
}
calls() { cat "$CALLS"; }

echo "== skip variables"
out=$(section)
check "nothing set: the section runs (--check)" test "$(calls)" = "stub --check"
check "  ... and returns 0" grep -qx 'rc=0' <<< "$out"
out=$(section RAVEN_FEDHUB_SKIP=1)
check "RAVEN_FEDHUB_SKIP=1: skipped" test ! -s "$CALLS"
out=$(section RAVEN_FEDHUB_ARTIFACT=)
check "RAVEN_FEDHUB_ARTIFACT= (set but empty): skipped" test ! -s "$CALLS"
check "  ... and returns 0" grep -qx 'rc=0' <<< "$out"
out=$(section RAVEN_FEDHUB_DEB=)
check "RAVEN_FEDHUB_DEB= (set but empty): skipped" test ! -s "$CALLS"
out=$(section RAVEN_FEDHUB_DEB= RAVEN_FEDHUB_ARTIFACT=/srv/fh.zip)
check "a non-empty RAVEN_FEDHUB_ARTIFACT wins over an empty RAVEN_FEDHUB_DEB" test "$(calls)" = "stub --check"
out=$(section RAVEN_FEDHUB_DEB=/srv/fh.deb RAVEN_FEDHUB_ARTIFACT=)
check "an empty RAVEN_FEDHUB_ARTIFACT wins over a non-empty RAVEN_FEDHUB_DEB (skip)" test ! -s "$CALLS"
out=$(section RAVEN_FEDHUB_DEB=/srv/fh.deb)
check "a non-empty RAVEN_FEDHUB_DEB: not a skip" test "$(calls)" = "stub --check"
out=$(section RAVEN_FEDHUB_SKIP=0)
check "RAVEN_FEDHUB_SKIP=0: not a skip" test "$(calls)" = "stub --check"

echo "== once per run"
out=$(section)
check "a run exports RAVEN_FEDHUB_SECTION_DONE=1" grep -qx 'done=1' <<< "$out"
out=$(section RAVEN_FEDHUB_SECTION_DONE=1)
check "RAVEN_FEDHUB_SECTION_DONE=1: not run again" test ! -s "$CALLS"
out=$(env FEDHUB_SCRIPT="$STUB" bash -c '. "$1/lib/common.sh"; fedhub_section raven; fedhub_section raven' _ "$REPO" 2>&1)
check "two calls in one process: --check runs once" bash -c '[ "$(grep -c "stub --check" "$1")" = 1 ]' _ "$CALLS"

echo "== update.sh / finish-install.sh wiring (static)"
check "update.sh sets RAVEN_FEDHUB_SECTION_DONE=1 right after running finish-install.sh" \
  bash -c 'awk "/\"\\\$HERE\/finish-install.sh\" \|\|/{f=NR} /export RAVEN_FEDHUB_SECTION_DONE=1/{d=NR} END{exit !(f && d && d > f && d - f <= 3)}" "$1"' _ "$REPO/update.sh"
l_done=$(grep -n 'export RAVEN_FEDHUB_SECTION_DONE=1' "$REPO/update.sh" | head -n 1 | cut -d: -f1)
l_sec=$(grep -n 'fedhub_section "\$LAYOUT"' "$REPO/update.sh" | head -n 1 | cut -d: -f1)
check "  ... before update.sh's own fedhub_section call" test -n "$l_done" -a -n "$l_sec" -a "${l_done:-0}" -lt "${l_sec:-0}"
check "finish-install.sh still ends with fedhub_section raven" grep -q '^fedhub_section raven$' "$REPO/finish-install.sh"

echo
echo "fedhub-section-unit: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
