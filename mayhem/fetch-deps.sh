#!/usr/bin/env bash
#
# mayhem/fetch-deps.sh — image-build-time (online) prefetch of Dear ImGui, the one dependency the
# NetImgui draw-frame code is built against (it uses ImGui's allocator and headers). Runs once from the
# Dockerfile as root; build.sh then builds from the cache with no network, so re-running it offline
# (PATCH tier) works (SPEC §6.2 item 19, §6.5).
#
# The commit is read from upstream's own cmake/third_party_deps/dear_imgui.cmake, and fetched by that
# commit id (git verifies the content against it).
set -euo pipefail

SRC="${SRC:-/mayhem}"
sha=$(tr '\n' ' ' < "$SRC/cmake/third_party_deps/dear_imgui.cmake" \
      | grep -oE "MUJOCO_DEP_VERSION_dear_imgui[[:space:]]+[0-9a-f]{40}" | head -1 | awk '{print $2}')
[ -n "$sha" ] || { echo "no pinned commit for dear_imgui" >&2; exit 1; }

DEP="/opt/toolchains/deps/imgui-$sha"
[ -f "$DEP/src/imgui.h" ] && exit 0

mkdir -p "$DEP.part/src"
git -C "$DEP.part/src" init -q
git -C "$DEP.part/src" fetch -q --depth 1 https://github.com/ocornut/imgui.git "$sha"
git -C "$DEP.part/src" -c advice.detachedHead=false checkout -q FETCH_HEAD
[ "$(git -C "$DEP.part/src" rev-parse HEAD)" = "$sha" ] || { echo "dear_imgui checkout is not $sha" >&2; exit 1; }
rm -rf "$DEP.part/src/.git"
chmod -R a+rX,a-w "$DEP.part"
mv "$DEP.part" "$DEP"
echo "fetched dear_imgui $sha"
