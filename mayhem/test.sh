#!/usr/bin/env bash
#
# mayhem/test.sh — RUN the NetImgui receive-path known-answer test (already built by mayhem/build.sh).
# exit 0 = pass. EDIT per repo. PATCH-grade oracle: after an agent patches the source, the grader
# rebuilds (build.sh) then runs this. DELETE this file if the repo has no meaningful tests.
#
# IMPORTANT:
#  * Must assert BEHAVIOR/OUTPUT, not just exit status. The oracle has to check asserted values /
#    golden-output diffs / known-answer results — so a PATCH that "fixes" a bug by making the program
#    exit(0) (or any no-op) FAILS here. Running inputs and checking only "exit 0 / didn't crash" is
#    NOT a functional test (it's trivially reward-hackable) — use the project's real assertion suite.
#  * Do NOT build here — mayhem/build.sh already compiled the test suite (with the project's normal
#    flags). This script only RUNS the pre-built tests and reports counts. If the test runner is
#    missing, that's a build.sh bug — fail loudly rather than silently rebuilding.
#  * REQUIRED OUTPUT — a CTRF (https://ctrf.io) summary so Mayhem/the PATCH grader reads the counts:
#      - writes a CTRF JSON report to ${CTRF_REPORT:-$SRC/ctrf-report.json}, and
#      - prints a one-line `CTRF {...}` marker to stdout (same JSON, compact).
#    Only `results.summary` (with tests/passed/failed/pending/skipped/other) is required.
#    Use the emit_ctrf helper below; it computes tests = passed+failed+skipped and sets the exit
#    code (0 iff failed==0). Map your framework's output to passed/failed/skipped.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
cd "$SRC"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
# Writes a CTRF report (file + stdout `CTRF {...}` marker) and returns non-zero iff failed>0.
emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

# Known-answer test: mayhem/netimgui_kat.cc talks to the NetImgui client over a real loopback TCP
# connection (an input command whole and byte by byte, three handshakes) and prints what the client
# ended up with. The expected output is compared line by line here in the shell (not inside the
# program), so a patch that makes the program exit 0 early, print nothing or change what the client
# receives fails.
KAT="$SRC/build/fuzz/netimgui_kat"
[ -x "$KAT" ] || { echo "missing $KAT: mayhem/build.sh did not build the test" >&2; emit_ctrf "netimgui-kat" 0 1; exit 1; }

expected='input whole: received=yes size=616 fps=60 keys=3 ring=0061 0062 263a disconnect=0
input bytewise: received=yes size=616 fps=60 keys=3 ring=0061 0062 263a disconnect=0
handshake good: connected=1 coms=1 answer=120 type=0 size=120 name=kat
handshake wchar: connected=0 coms=0 answer=120 type=0 size=120 name=kat
handshake short: connected=0 coms=0 answer=120 type=0 size=120 name=kat'
actual=$("$KAT" 2>&1)
rc=$?
passed=0 failed=0
while IFS= read -r line; do
  if printf '%s\n' "$actual" | grep -qxF -- "$line"; then
    passed=$((passed + 1))
  else
    echo "FAIL netimgui_kat: missing expected line: $line"
    failed=$((failed + 1))
  fi
done <<< "$expected"
if [ "$(printf '%s\n' "$actual" | wc -l)" -ne "$(printf '%s\n' "$expected" | wc -l)" ] || [ "$rc" -ne 0 ]; then
  echo "FAIL netimgui_kat: unexpected output (exit $rc):"
  printf '%s\n' "$actual" | tail -20
  failed=$((failed + 1))
fi

emit_ctrf "netimgui-kat" "$passed" "$failed"
