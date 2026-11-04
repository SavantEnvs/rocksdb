#!/usr/bin/env bash
#
# mayhem/test.sh — RUN RocksDB's own gtest suites (db_basic_test, env_basic_test) plus a known-answer
# probe (already built by mayhem/build.sh). Counts are mapped to CTRF.
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

# --- RocksDB gtest suites (built by build.sh into build/tests) -------------------------------------------
TESTS_DIR="$SRC/build/tests"
passed=0 failed=0 skipped=0

run_gtest() {
  local bin="$1" out rc p f s
  [ -x "$TESTS_DIR/$bin" ] || { echo "missing $TESTS_DIR/$bin (build.sh must produce it)" >&2; failed=$((failed + 1)); return; }
  out="$(cd "$TESTS_DIR" && timeout 1500 "./$bin" 2>&1)"; rc=$?
  printf '%s\n' "$out" | tail -n 8
  p="$(printf '%s\n' "$out" | sed -n 's/^\[  PASSED  \] \([0-9][0-9]*\) test.*/\1/p' | tail -n 1)"
  f="$(printf '%s\n' "$out" | sed -n 's/^\[  FAILED  \] \([0-9][0-9]*\) test.*/\1/p' | tail -n 1)"
  s="$(printf '%s\n' "$out" | sed -n 's/^\[  SKIPPED \] \([0-9][0-9]*\) test.*/\1/p' | tail -n 1)"
  passed=$((passed + ${p:-0})); failed=$((failed + ${f:-0})); skipped=$((skipped + ${s:-0}))
  # a crash, timeout or missing summary is a failure even though no "[  FAILED  ]" line was printed
  if [ "$rc" -ne 0 ] && [ -z "${f:-}" ]; then failed=$((failed + 1)); fi
  if [ -z "${p:-}" ]; then failed=$((failed + 1)); fi
}

run_gtest db_basic_test
run_gtest env_basic_test

# --- Known-answer probe: a real DB and SST round trip, asserted value for value ---------------------------
# (a gtest binary alone can be defeated by a runner that merely exits 0, so the stdout is compared exactly)
EXPECTED='get c: 3
get b: not found
iter: a=1;c=3;
reopened: a=1;c=3;
sst entries: 3 smallest=k1 largest=k3
sst iter: k1=v1;k2=v2;k3=v3;'
if [ -x "$TESTS_DIR/rocksdb_kat" ]; then
  ACTUAL="$(timeout 300 "$TESTS_DIR/rocksdb_kat" 2>&1)"; kat_rc=$?
else
  ACTUAL="missing $TESTS_DIR/rocksdb_kat"; kat_rc=127
fi
if [ "$kat_rc" -eq 0 ] && [ "$ACTUAL" = "$EXPECTED" ]; then
  passed=$((passed + 1)); echo "KAT ok"
else
  failed=$((failed + 1)); echo "KAT FAILED (rc=$kat_rc)" >&2
  printf 'expected:\n%s\nactual:\n%s\n' "$EXPECTED" "$ACTUAL" >&2
fi

emit_ctrf "rocksdb-gtest+kat" "$passed" "$failed" "$skipped"
