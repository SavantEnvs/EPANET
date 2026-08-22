#!/usr/bin/env bash
#
# mayhem/test.sh — RUN EPANET's own upstream functional test suite (Boost.Test via ctest),
# already built by mayhem/build.sh into $SRC/build-tests. This is the authors' assertion
# suite (test_toolkit, test_net_builder, test_reent, test_output, test_filemanager,
# test_errormanager, ...); it asserts computed values / known-answer results, so a no-op
# or exit(0) sabotage of the library FAILS it. Emits a CTRF summary + non-zero iff failed>0.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${MAYHEM_JOBS:=$(nproc)}"
cd "$SRC"

BUILD_TESTS="$SRC/build-tests"

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

if [ ! -d "$BUILD_TESTS" ]; then
  echo "ERROR: $BUILD_TESTS missing — mayhem/build.sh did not build the test suite" >&2
  emit_ctrf "cmake-ctest" 0 1 0
  exit 1
fi

# Run the suite VERBOSELY so each test's stdout (the Boost.Test assertion report) is captured.
# We do NOT trust ctest's exit code alone: a no-op/exit(0) sabotage of a test binary would exit 0
# and fool a count-of-return-codes oracle. Instead we assert each test emitted its BEHAVIORAL
# success marker — Boost.Test's "No errors detected" (the assert-suite modules) or, for the
# multithread reentrancy test, "program completed". A neutered binary prints neither → it fails here.
OUT="$(cd "$BUILD_TESTS" && ctest -V -j"$MAYHEM_JOBS" 2>&1)" || true
echo "$OUT"

# Total registered tests, e.g. "Total Test time ... out of 6" — take the ctest summary count.
total="$(printf '%s\n' "$OUT" | sed -n 's/.*failed out of \([0-9][0-9]*\).*/\1/p' | tail -1)"
: "${total:=0}"

# Behavioral pass count: number of tests whose captured output carries a real success marker.
marker_re='No errors detected|program completed'
passed="$(printf '%s\n' "$OUT" | grep -cE "$marker_re")"
: "${passed:=0}"

if [ "$total" -eq 0 ]; then
  echo "ERROR: ctest reported no tests" >&2
  emit_ctrf "cmake-ctest" 0 1 0
  exit 1
fi

failed=$(( total - passed ))
(( failed < 0 )) && failed=0

emit_ctrf "cmake-ctest" "$passed" "$failed" 0
