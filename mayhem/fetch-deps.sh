#!/usr/bin/env bash
#
# mayhem/fetch-deps.sh — image-build-time (online) prefetch of every CMake dependency MuJoCo would
# otherwise FetchContent at configure time, so build.sh and the air-gapped PATCH re-run resolve them
# from a fixed in-image cache (SPEC §6.5). Runs once from the Dockerfile as root.
#
# The pinned commits are read from upstream's own cmake/*.cmake (so they track upstream on every
# rebase); each is fetched as an immutable GitHub commit tarball named the way
# cmake/FindOrFetch.cmake's MUJOCO_CMAKE_DEP_CACHE expects: <library>-<commit>.tar.gz.
set -euo pipefail

DEPS="${MUJOCO_DEPS:-/opt/toolchains/cmake-deps}"
SRC="${SRC:-/mayhem}"
mkdir -p "$DEPS"

ver() { # ver <MUJOCO_DEP_VERSION suffix> -> commit sha
  local v
  v=$(cat "$SRC/cmake/MujocoDependencies.cmake" "$SRC/cmake/third_party_deps/lodepng.cmake" | tr '\n' ' ' \
      | grep -oE "MUJOCO_DEP_VERSION_$1[[:space:]]+[0-9a-f]{40}" | head -1 | awk '{print $2}')
  [ -n "$v" ] || { echo "no pinned commit for $1" >&2; exit 1; }
  echo "$v"
}

fetch() { # fetch <library name> <github owner/repo> <version suffix>
  local lib="$1" repo="$2" sha out
  sha=$(ver "$3")
  out="$DEPS/$lib-$sha.tar.gz"
  [ -s "$out" ] && return 0
  curl -fsSL --retry 5 --retry-delay 3 -o "$out.part" "https://codeload.github.com/$repo/tar.gz/$sha"
  mv "$out.part" "$out"
  echo "fetched $lib $sha"
}

fetch lodepng      lvandeve/lodepng              lodepng
fetch qhull        qhull/qhull                   qhull
fetch tinyxml2     leethomason/tinyxml2          tinyxml2
fetch tinyobjloader tinyobjloader/tinyobjloader  tinyobjloader
fetch ccd          danfis/libccd                 ccd
fetch miniz        richgel999/miniz              miniz
fetch abseil-cpp   abseil/abseil-cpp             abseil
fetch googletest   google/googletest             gtest
fetch benchmark    google/benchmark              benchmark

# MarchingCubeCpp is fetched by a bespoke FetchContent block that ignores the tarball cache; it is
# redirected to this unpacked tree with -DFETCHCONTENT_SOURCE_DIR_MARCHINGCUBECPP.
mc_sha=$(ver MarchingCubeCpp)
mc="$DEPS/marchingcubecpp-$mc_sha"
if [ ! -d "$mc" ]; then
  mkdir -p "$mc.part"
  curl -fsSL --retry 5 --retry-delay 3 "https://codeload.github.com/aparis69/MarchingCubeCpp/tar.gz/$mc_sha" \
    | tar -xz --strip-components=1 -C "$mc.part"
  mv "$mc.part" "$mc"
  echo "fetched marchingcubecpp $mc_sha"
fi
ln -sfn "$(basename "$mc")" "$DEPS/marchingcubecpp-src"
