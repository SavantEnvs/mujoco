#!/usr/bin/env bash
#
# mayhem/build.sh — build the NetImgui receive-path fuzz harness (sanitized, instrumented) and its
# known-answer test (normal flags). Runs inside the commit image as `mayhem` in /mayhem; offline (Dear
# ImGui comes from the in-image cache that mayhem/fetch-deps.sh filled at image-build time); safe to
# re-run.
set -euo pipefail

[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${SRC:=/mayhem}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE

cd "$SRC"

sha=$(tr '\n' ' ' < cmake/third_party_deps/dear_imgui.cmake \
      | grep -oE "MUJOCO_DEP_VERSION_dear_imgui[[:space:]]+[0-9a-f]{40}" | head -1 | awk '{print $2}')
IMGUI="/opt/toolchains/deps/imgui-$sha/src"
[ -f "$IMGUI/imgui.h" ] || { echo "missing $IMGUI (run mayhem/fetch-deps.sh as root at image build)" >&2; exit 1; }

NETIMGUI=python/mujoco/experimental/netimgui
INC=(-I"$NETIMGUI" -I"$NETIMGUI/Code/Client" -I"$NETIMGUI/Code/Client/Private" -I"$IMGUI")
PRIV="$NETIMGUI/Code/Client/Private"
NETIMGUI_SRCS=("$PRIV/NetImgui_Api.cpp" "$PRIV/NetImgui_Client.cpp" "$PRIV/NetImgui_NetworkPosix.cpp"
               "$PRIV/NetImgui_CmdPackets_DrawFrame.cpp")
OUT=build/fuzz
mkdir -p "$OUT"

# Dear ImGui is a dependency: uninstrumented, normal flags. NetImgui allocates through its allocator
# hooks, so the fuzzed code needs it linked.
IMGUI_OBJS=()
for f in imgui imgui_draw imgui_tables imgui_widgets; do
  "$CXX" -O1 $DEBUG_FLAGS -c "$IMGUI/$f.cpp" -I"$IMGUI" -o "$OUT/$f.o"
  IMGUI_OBJS+=("$OUT/$f.o")
done

# The sanitized, SanCov-instrumented fuzz binary, and its standalone run-once reproducer. The standalone
# driver is compiled as C first so its LLVMFuzzerTestOneInput reference keeps C linkage.
FUZZ_FLAGS="$SANITIZER_FLAGS -fsanitize=fuzzer-no-link $DEBUG_FLAGS -O1"
NETIMGUI_OBJS=()
for src in "${NETIMGUI_SRCS[@]}"; do
  obj="$OUT/netimgui_$(basename "${src%.cpp}").o"
  "$CXX" $FUZZ_FLAGS -std=c++17 "${INC[@]}" -c "$src" -o "$obj"
  NETIMGUI_OBJS+=("$obj")
done
"$CXX" $FUZZ_FLAGS -std=c++17 "${INC[@]}" -c mayhem/fuzz_netimgui_recv.cc -o "$OUT/fuzz_netimgui_recv.o"
"$CXX" $SANITIZER_FLAGS $DEBUG_FLAGS -c mayhem/lsan_off.cc -o "$OUT/lsan_off.o"
"$CC" $SANITIZER_FLAGS $DEBUG_FLAGS -c "$STANDALONE_FUZZ_MAIN" -o "$OUT/standalone_main.o"

"$CXX" $FUZZ_FLAGS "$OUT/fuzz_netimgui_recv.o" "${NETIMGUI_OBJS[@]}" "$OUT/lsan_off.o" \
  "${IMGUI_OBJS[@]}" $LIB_FUZZING_ENGINE -o fuzz_netimgui_recv
"$CXX" $SANITIZER_FLAGS $DEBUG_FLAGS "$OUT/fuzz_netimgui_recv.o" "${NETIMGUI_OBJS[@]}" "$OUT/lsan_off.o" \
  "${IMGUI_OBJS[@]}" "$OUT/standalone_main.o" -o fuzz_netimgui_recv-standalone

# The test program, built with normal flags (no sanitizers, no coverage) for mayhem/test.sh.
"$CXX" -O1 $DEBUG_FLAGS -std=c++17 "${INC[@]}" mayhem/netimgui_kat.cc "${NETIMGUI_SRCS[@]}" \
  "${IMGUI_OBJS[@]}" -o "$OUT/netimgui_kat"
