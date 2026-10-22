#!/usr/bin/env bash
# tools/build_game.sh: build the native executable (build/cmake/__EXE__) with clang and Ninja.
#
#   tools/build_game.sh            configure if needed, then build
#   tools/build_game.sh --clean    delete build/cmake first
#
# Needs RecompiledFuncs/ and rsp/ from tools/recomp.sh, and the submodules (git submodule update --init --recursive).
set -euo pipefail
cd "$(dirname "$(readlink -f "$0")")/.."

if [[ ${1:-} == --clean ]]; then
    rm -rf build/cmake
elif [[ $# -gt 0 ]]; then
    echo "usage: $0 [--clean]" >&2
    exit 2
fi
[[ -f RecompiledFuncs/recomp_overlays.inl ]] || { echo "RecompiledFuncs/ missing: run tools/recomp.sh first" >&2; exit 1; }
[[ -f rsp/aspMain.cpp ]] || { echo "rsp/aspMain.cpp missing: run tools/recomp.sh rsp first" >&2; exit 1; }
[[ -f lib/rt64/CMakeLists.txt ]] || { echo "lib/rt64 is empty: git submodule update --init --recursive" >&2; exit 1; }

if [[ ! -f build/cmake/build.ninja ]]; then
    cmake -S . -B build/cmake -G Ninja -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_C_COMPILER=clang -DCMAKE_CXX_COMPILER=clang++
fi
cmake --build build/cmake --target __EXE__
echo "build_game.sh: build/cmake/__EXE__ (run it once with --rom <your ROM>)"
