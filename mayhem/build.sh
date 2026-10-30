#!/usr/bin/env bash
#
# mayhem/build.sh — build MuJoCo's fuzz harnesses (sanitized, instrumented) and its test suite (normal flags).
# Runs inside the commit image as `mayhem` in /mayhem; offline (CMake dependencies come from the
# in-image cache that mayhem/fetch-deps.sh filled at image-build time); safe to re-run.
set -euo pipefail

[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${COVERAGE_FLAGS=}"
: "${SRC:=/mayhem}"
: "${MUJOCO_DEPS:=/opt/toolchains/cmake-deps}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS COVERAGE_FLAGS

cd "$SRC"

# Without the in-image dependency cache there is nothing to build from offline.
[ -d "$MUJOCO_DEPS" ] || { echo "missing $MUJOCO_DEPS (run mayhem/fetch-deps.sh as root at image build)" >&2; exit 1; }

# Configure options shared by both builds. Examples/simulate/python utilities need GL, GLFW and
# the rest of the desktop stack and are not part of the fuzzed surface. AVX is off so the binaries
# run on any x86-64 host that Mayhem schedules them on.
COMMON=(
  -G Ninja
  -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="$CXX"
  -DMUJOCO_CMAKE_DEP_CACHE="$MUJOCO_DEPS"
  -DFETCHCONTENT_SOURCE_DIR_MARCHINGCUBECPP="$MUJOCO_DEPS/marchingcubecpp-src"
  -DMUJOCO_BUILD_EXAMPLES=OFF -DMUJOCO_BUILD_SIMULATE=OFF -DMUJOCO_TEST_PYTHON_UTIL=OFF
  -DMUJOCO_ENABLE_AVX=OFF -DMUJOCO_ENABLE_AVX_INTRINSICS=OFF
)

# 1) Sanitized + SanCov-instrumented library for the fuzz harnesses. -fsanitize=fuzzer-no-link is
#    appended unconditionally so the library itself carries coverage counters. (build/ is gitignored
#    upstream, so a `git clean -ffdX` tree just reconfigures.)
#    UBSan's nonnull-attribute check is relaxed (-fno-sanitize=nonnull-attribute): the engine's
#    mju_copyInt()/mju_zeroInt() helpers call memcpy/memset(NULL, ..., 0) for every empty model array,
#    so with the check on, nearly every compiled model aborts before reaching any real logic.
FUZZ_FLAGS="$SANITIZER_FLAGS -fno-sanitize=nonnull-attribute -fsanitize=fuzzer-no-link $DEBUG_FLAGS -O1"
# A re-run can see a different compiler path (ccache masquerade dir vs plain clang); CMake would then
# wipe its cache mid-configure and lose -DMUJOCO_CMAKE_DEP_CACHE, so start every configure fresh.
rm -f build/fuzz/CMakeCache.txt
cmake -S . -B build/fuzz "${COMMON[@]}" \
  -DCMAKE_BUILD_TYPE=None -DBUILD_TESTING=OFF -DMUJOCO_BUILD_TESTS=OFF \
  -DCMAKE_C_FLAGS="$FUZZ_FLAGS" -DCMAKE_CXX_FLAGS="$FUZZ_FLAGS" \
  -DCMAKE_SHARED_LINKER_FLAGS="$SANITIZER_FLAGS -fsanitize=fuzzer-no-link"
cmake --build build/fuzz -j"$MAYHEM_JOBS" --target mujoco

FUZZ_LIB="$SRC/build/fuzz/lib"
INC=(-I"$SRC/include" -I"$SRC/mayhem")
LINK=(-L"$FUZZ_LIB" -lmujoco -Wl,-rpath,"$FUZZ_LIB")

# 2) Harnesses: a libFuzzer binary and a standalone run-once reproducer for each. The standalone
#    driver is compiled as C first so its LLVMFuzzerTestOneInput reference keeps C linkage.
"$CC" $SANITIZER_FLAGS $DEBUG_FLAGS -c "$STANDALONE_FUZZ_MAIN" -o build/fuzz/standalone_main.o
"$CXX" $SANITIZER_FLAGS $DEBUG_FLAGS -c mayhem/lsan_off.cc -o build/fuzz/lsan_off.o

# <binary> <source> [extra compile flags]
harness() {
  local out="$1" src="$2"; shift 2
  "$CXX" $SANITIZER_FLAGS $DEBUG_FLAGS -O1 -std=c++17 "$@" "${INC[@]}" "$src" build/fuzz/lsan_off.o \
    $LIB_FUZZING_ENGINE "${LINK[@]}" -o "$SRC/$out"
  "$CXX" $SANITIZER_FLAGS $DEBUG_FLAGS -O1 -std=c++17 "$@" "${INC[@]}" "$src" build/fuzz/lsan_off.o \
    build/fuzz/standalone_main.o "${LINK[@]}" -o "$SRC/$out-standalone"
}

harness fuzz_xml  mayhem/fuzz_xml.cc
harness fuzz_mjb  mayhem/fuzz_mjb.cc
harness fuzz_obj  mayhem/fuzz_asset.cc -DASSET_KIND=1
harness fuzz_stl  mayhem/fuzz_asset.cc -DASSET_KIND=2
harness fuzz_msh  mayhem/fuzz_asset.cc -DASSET_KIND=3
harness fuzz_png  mayhem/fuzz_asset.cc -DASSET_KIND=4
harness fuzz_mjz  mayhem/fuzz_asset.cc -DASSET_KIND=5

# 3) The project's own test suite plus the known-answer probe, with the NORMAL flags (no sanitizers,
#    no instrumentation), so mayhem/test.sh only has to run them.
TEST_TARGETS=(
  engine_util_blas_test engine_util_misc_test engine_util_solve_test engine_util_spatial_test
  engine_util_sparse_test engine_core_util_test engine_forward_test engine_io_test
  xml_native_reader_test user_mesh_test
)
rm -f build/tests/CMakeCache.txt
cmake -S . -B build/tests "${COMMON[@]}" \
  -DCMAKE_BUILD_TYPE=Release -DBUILD_TESTING=ON -DMUJOCO_BUILD_TESTS=ON \
  -DCMAKE_C_FLAGS="$COVERAGE_FLAGS" -DCMAKE_CXX_FLAGS="$COVERAGE_FLAGS" \
  -DCMAKE_EXE_LINKER_FLAGS="$COVERAGE_FLAGS" -DCMAKE_SHARED_LINKER_FLAGS="$COVERAGE_FLAGS"
cmake --build build/tests -j"$MAYHEM_JOBS" --target "${TEST_TARGETS[@]}"

TEST_LIB="$SRC/build/tests/lib"
"$CC" -O2 $COVERAGE_FLAGS -I"$SRC/include" mayhem/kat_probe.c -L"$TEST_LIB" -lmujoco -lm \
  -Wl,-rpath,"$TEST_LIB" -o build/tests/bin/kat_probe
