#!/usr/bin/env bash
# build.sh: sets up the pinned Python venv and builds the recompilers.
#
#   1. .venv/ from requirements.txt (splat64[mips] and its pinned deps)
#   2. src/N64Recomp at N64RECOMP_COMMIT (pins.env), with submodules, plus patches/n64recomp-*.patch
#   3. Release build with clang + Ninja; N64Recomp and RSPRecomp -> bin/
#
# Safe to rerun: it reuses the checkout and only rebuilds what changed.
set -euo pipefail
cd "$(dirname "$(readlink -f "$0")")"
. ./pins.env

echo "== Python venv"
[[ -x .venv/bin/python ]] || python3 -m venv .venv
.venv/bin/pip install -q --require-virtualenv -r requirements.txt

echo "== N64Recomp @ ${N64RECOMP_COMMIT:0:7}"
src=src/N64Recomp
if [[ ! -d $src/.git ]]; then
    git clone -q "$N64RECOMP_URL" "$src"
fi
if ! git -C "$src" cat-file -e "$N64RECOMP_COMMIT^{commit}" 2>/dev/null; then
    git -C "$src" fetch -q origin
fi
git -C "$src" -c advice.detachedHead=false checkout -q "$N64RECOMP_COMMIT"
git -C "$src" submodule update -q --init --recursive
# Local fixes on top of the pin (patches/n64recomp-*.patch), reapplied from a clean tree each build.
git -C "$src" checkout -q -- .
for p in patches/n64recomp-*.patch; do
    [[ -e $p ]] || continue
    echo "   applying $p"
    git -C "$src" apply "$PWD/$p"
done

cmake -S "$src" -B "$src/build" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_C_COMPILER=clang -DCMAKE_CXX_COMPILER=clang++ >/dev/null
cmake --build "$src/build" --target N64RecompCLI RSPRecomp

mkdir -p bin
install -m 755 "$src/build/N64Recomp" "$src/build/RSPRecomp" bin/
echo "build.sh: bin/N64Recomp and bin/RSPRecomp built from N64Recomp ${N64RECOMP_COMMIT:0:7}."
