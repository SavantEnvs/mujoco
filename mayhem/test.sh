#!/usr/bin/env bash
#
# mayhem/test.sh — RUN the NetImgui draw-frame known-answer test (already built by mayhem/build.sh).
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

# Known-answer test: mayhem/netimgui_kat.cc builds draw frames, delta-compresses and decompresses them
# and prints the compressed size and every element it got back. The expected output is compared line by
# line here in the shell (not inside the program), so a patch that makes the program exit 0 early, print
# nothing or change what the codec produces fails.
KAT="$SRC/build/fuzz/netimgui_kat"
[ -x "$KAT" ] || { echo "missing $KAT: mayhem/build.sh did not build the test" >&2; emit_ctrf "netimgui-kat" 0 1; exit 1; }

expected='unchanged packed_bytes=160
indices: 1111000000000000 1111000000000001 1111000000000002
vertices: 2222000000000000 2222000000000001 2222000000000002 2222000000000003 2222000000000004 2222000000000005
draws: 3333000000000000 3333000000000001 3333000000000002 3333000000000003 3333000000000004 3333000000000005 3333000000000006 3333000000000007 3333000000000008 3333000000000009
unchanged roundtrip=same
edited packed_bytes=256
indices: 1111000000000000 1111000000005001 1111000000000002
vertices: 2222000000000000 2222000000005001 2222000000000002 2222000000000003 2222000000005004 2222000000000005
draws: 3333000000000000 3333000000005001 3333000000000002 3333000000000003 3333000000005004 3333000000000005 3333000000000006 3333000000005007 3333000000000008 3333000000000009
edited roundtrip=same
grown packed_bytes=432
indices: 1111000000000077 1111000000000076 1111000000000075 1111000000000074 1111000000000073
vertices: 2222000000000077 2222000000000076 2222000000000075 2222000000000074 2222000000000073 2222000000000072 2222000000000071 2222000000000070 222200000000007f 222200000000007e 222200000000007d
draws: 3333000000000077 3333000000000076 3333000000000075 3333000000000074 3333000000000073 3333000000000072 3333000000000071 3333000000000070 333300000000007f 333300000000007e 333300000000007d 333300000000007c 333300000000007b 333300000000007a 3333000000000079
grown roundtrip=same
shrunk packed_bytes=192
indices: 1111000000000000
vertices: 2222000000000000 2222000000005001
draws: 3333000000000000 3333000000005001 3333000000000002 3333000000000003 3333000000005004
shrunk roundtrip=same
newgroup packed_bytes=312
indices: 1111000000000077 1111000000000076 1111000000000075
vertices: 2222000000000077 2222000000000076 2222000000000075 2222000000000074 2222000000000073 2222000000000072
draws: 3333000000000077 3333000000000076 3333000000000075 3333000000000074 3333000000000073 3333000000000072 3333000000000071 3333000000000070 333300000000007f 333300000000007e
newgroup roundtrip=same'
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
