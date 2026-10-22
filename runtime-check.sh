#!/usr/bin/env bash
# runtime-check.sh: proves this machine can build the runtime and renderer
# that every game project carries as submodules.
#
# Clones N64ModernRuntime and RT64 at the commits in pins.env into a scratch
# folder, builds both with clang + Ninja, then deletes the folder. Nothing is
# kept: game projects build their own copies.
#
#   ./runtime-check.sh          build both, delete the scratch folder
#   ./runtime-check.sh --keep   keep .runtime-check/ for debugging
set -euo pipefail
cd "$(dirname "$(readlink -f "$0")")"
. ./pins.env

keep=0
[[ ${1:-} == --keep ]] && keep=1
scratch=$PWD/.runtime-check
log=$PWD/runtime-check.log
: >"$log"
cleanup() { (( keep )) || rm -rf "$scratch"; }
trap cleanup EXIT

fetch() {  # fetch <url> <commit> <dir>
    if [[ ! -d $3/.git ]]; then
        git clone -q --filter=blob:none "$1" "$3"
    fi
    git -C "$3" -c advice.detachedHead=false checkout -q "$2"
    git -C "$3" submodule update -q --init --recursive
}

build() {  # build <name> <dir> [cmake args...]
    local name=$1 dir=$2; shift 2
    echo "== $name: configure"
    cmake -S "$dir" -B "$dir/build" -G Ninja -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_C_COMPILER=clang -DCMAKE_CXX_COMPILER=clang++ "$@" >>"$log" 2>&1 \
        || { echo "$name: configure FAILED, see $log" >&2; exit 1; }
    echo "== $name: build"
    cmake --build "$dir/build" >>"$log" 2>&1 \
        || { echo "$name: build FAILED, see $log" >&2; exit 1; }
}

mkdir -p "$scratch"
echo "== N64ModernRuntime @ ${N64MODERNRUNTIME_COMMIT:0:7}"
fetch "$N64MODERNRUNTIME_URL" "$N64MODERNRUNTIME_COMMIT" "$scratch/N64ModernRuntime"
build N64ModernRuntime "$scratch/N64ModernRuntime"

echo "== RT64 @ ${RT64_COMMIT:0:7}"
fetch "$RT64_URL" "$RT64_COMMIT" "$scratch/rt64"
build RT64 "$scratch/rt64"

echo "runtime-check.sh: N64ModernRuntime ${N64MODERNRUNTIME_COMMIT:0:7} and RT64 ${RT64_COMMIT:0:7} both build. Log: $log"
