#!/usr/bin/env bash
#
# mayhem/test.sh — RUN this repo's OWN functional test suite (already built by mayhem/build.sh).
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
: "${MAYHEM_JOBS:=$(nproc)}"   # build parallelism; env-overridable, falls back to nproc (use -j"$MAYHEM_JOBS")
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

# Run the gtest binaries mayhem/build.sh produced (normal flags, no sanitizers) from test/, where the
# fixtures expect to find their data, and read each binary's own gtest summary. A binary that prints no
# summary at all (crashed, or killed by a no-op patch) counts as a failure, so the exit status alone is
# never trusted.
BIN="$SRC/build/tests/bin"
[ -d "$BIN" ] || { echo "missing $BIN: mayhem/build.sh did not build the test suite" >&2; emit_ctrf "mujoco-gtest" 0 1; exit 1; }

passed=0 failed=0 skipped=0
cd "$SRC/test"
shopt -s nullglob
for t in "$BIN"/*_test; do
  name=$(basename "$t")
  out=$("$t" --gtest_color=no 2>&1); rc=$?
  p=$(printf '%s\n' "$out" | sed -n 's/^\[  PASSED  \] \([0-9][0-9]*\) test.*/\1/p' | tail -1)
  f=$(printf '%s\n' "$out" | sed -n 's/^\[  FAILED  \] \([0-9][0-9]*\) test.*/\1/p' | tail -1)
  s=$(printf '%s\n' "$out" | sed -n 's/^\[  SKIPPED \] \([0-9][0-9]*\) test.*/\1/p' | tail -1)
  if [ -z "$p" ] || [ "$rc" -ne 0 ] || [ "${p:-0}" -eq 0 ]; then
    echo "FAIL $name (exit $rc, passed='${p:-}', failed='${f:-}')"
    printf '%s\n' "$out" | tail -15
    failed=$((failed + ${f:-1}))
  else
    echo "ok   $name: $p passed${s:+, $s skipped}"
  fi
  passed=$((passed + ${p:-0})); skipped=$((skipped + ${s:-0}))
done
[ -n "$(ls "$BIN"/*_test 2>/dev/null)" ] || { echo "no test binaries in $BIN" >&2; failed=$((failed + 1)); }

# Known-answer probe: fixed model and inputs, exact expected output. Compared line by line here in
# the shell (not inside the probe), so a patch that makes the probe exit 0 early or print nothing fails.
cd "$SRC"
expected='nq=7 nv=6 nbody=2 ngeom=2
time=1.000
x=1.000 y=2.000 z=5.085
vz=-9.810
ray dist=4.5000 geom=0
dot=12.0 cross=27.0,6.0,-13.0 norm=3.7417
rot=0.0000,1.0000,0.0000'
actual=$("$BIN/kat_probe" 2>&1)
while IFS= read -r line; do
  if printf '%s\n' "$actual" | grep -qxF -- "$line"; then
    passed=$((passed + 1))
  else
    echo "FAIL kat_probe: missing expected line: $line"
    failed=$((failed + 1))
  fi
done <<< "$expected"
[ "$(printf '%s\n' "$actual" | wc -l)" -eq 7 ] || { echo "FAIL kat_probe: unexpected output:"; printf '%s\n' "$actual"; failed=$((failed + 1)); }

emit_ctrf "mujoco-gtest+kat" "$passed" "$failed" "$skipped"
