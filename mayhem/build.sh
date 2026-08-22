#!/usr/bin/env bash
#
# mayhem/build.sh — build EPANET's fuzz harnesses + the upstream test suite.
#
# Runs inside the commit image (mayhem/Dockerfile) as `mayhem` in /mayhem. The base image
# (ghcr.io/mayhemheroes/base) exports the build contract (CC/CXX/SANITIZER_FLAGS/DEBUG_FLAGS/
# LIB_FUZZING_ENGINE/STANDALONE_FUZZ_MAIN/SRC). Two targets are preserved from the old fork:
#   cstr-isvalid : in-process libFuzzer harness over util/cstr_isvalid()
#   runepanet    : the native runepanet CLI driven with a file input
set -euo pipefail

[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${COVERAGE_FLAGS=}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS COVERAGE_FLAGS

cd "$SRC"

BUILD_FUZZ="$SRC/build-fuzz"
BUILD_TESTS="$SRC/build-tests"

# ---------------------------------------------------------------------------
# 1) Project build for FUZZING — instrument the whole library + CLI with
#    $SANITIZER_FLAGS and DWARF<4 symbols so the fuzzed code (not just the
#    harness) is instrumented. Static lib so the harness links cleanly.
# ---------------------------------------------------------------------------
cmake -S "$SRC" -B "$BUILD_FUZZ" \
  -DCMAKE_BUILD_TYPE=Debug \
  -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="$CXX" \
  -DBUILD_SHARED_LIBS=OFF -DBUILD_TESTS=OFF \
  -DCMAKE_C_FLAGS="$SANITIZER_FLAGS $DEBUG_FLAGS" \
  -DCMAKE_CXX_FLAGS="$SANITIZER_FLAGS $DEBUG_FLAGS" \
  -DCMAKE_EXE_LINKER_FLAGS="$SANITIZER_FLAGS" \
  -DCMAKE_SHARED_LINKER_FLAGS="$SANITIZER_FLAGS"
cmake --build "$BUILD_FUZZ" -j"$MAYHEM_JOBS"

LIBEPANET="$BUILD_FUZZ/lib/libepanet2.a"
[ -f "$LIBEPANET" ] || { echo "ERROR: $LIBEPANET not built" >&2; exit 1; }

# runepanet native CLI target: our own harness (mayhem/fuzz_runepanet_main.c), NOT
# upstream's run/main.c copied verbatim. It wraps ENepanet() with a hard wall-clock cap
# (SIGALRM) so a fuzzer-mutated [TIMES] Duration/Hydraulic-Timestep pair — which EPANET's
# solver walks with no upper bound — can't burn an entire per-exec timeout on legitimate,
# non-crashing but pathologically long simulation work. See the file for the full writeup.
$CC $SANITIZER_FLAGS $DEBUG_FLAGS \
    "$SRC/mayhem/fuzz_runepanet_main.c" -I"$SRC/include" "$LIBEPANET" -lm \
    -o /mayhem/runepanet

# ---------------------------------------------------------------------------
# 2) cstr-isvalid harness: libFuzzer binary + standalone run-once reproducer.
#    C++ harness -> compile the standalone driver as C first so its
#    LLVMFuzzerTestOneInput reference keeps C linkage.
# ---------------------------------------------------------------------------
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS $LIB_FUZZING_ENGINE \
    "$SRC/mayhem/fuzz_cstr_isvalid.cpp" -I"$SRC/src/util" "$LIBEPANET" \
    -o /mayhem/fuzz_cstr_isvalid

$CC $SANITIZER_FLAGS $DEBUG_FLAGS -c "$STANDALONE_FUZZ_MAIN" -o /tmp/standalone_main.o
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS \
    "$SRC/mayhem/fuzz_cstr_isvalid.cpp" /tmp/standalone_main.o -I"$SRC/src/util" "$LIBEPANET" \
    -o /mayhem/fuzz_cstr_isvalid-standalone

# ---------------------------------------------------------------------------
# 3) Upstream TEST suite — clean build with the project's NORMAL flags (Boost
#    unit-test framework). test.sh only RUNS what we build here (via ctest).
#    $COVERAGE_FLAGS is empty by default (appended for optional coverage builds).
# ---------------------------------------------------------------------------
cmake -S "$SRC" -B "$BUILD_TESTS" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="$CXX" \
  -DBUILD_TESTS=ON \
  -DCMAKE_C_FLAGS="$COVERAGE_FLAGS" \
  -DCMAKE_CXX_FLAGS="$COVERAGE_FLAGS" \
  -DCMAKE_EXE_LINKER_FLAGS="$COVERAGE_FLAGS"
cmake --build "$BUILD_TESTS" -j"$MAYHEM_JOBS"

echo "build.sh: done"
