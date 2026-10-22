#!/usr/bin/env bash
# doctor.sh: checks every toolkit tool runs, and prints its version.
# Exit 0 when everything required passes. A missing Vulkan GPU is only a
# warning: Phases 0-3 don't need one.
set -uo pipefail
cd "$(dirname "$(readlink -f "$0")")"
. ./pins.env

fails=0 warns=0
ok()   { printf '  ok    %-22s %s\n' "$1" "$2"; }
bad()  { printf '  FAIL  %-22s %s\n' "$1" "$2"; fails=$((fails + 1)); }
warn() { printf '  warn  %-22s %s\n' "$1" "$2"; warns=$((warns + 1)); }

tool() {  # tool <name> <command...>: first line of its output is the version
    local name=$1; shift
    local out
    if out=$("$@" 2>&1); then ok "$name" "$(head -n1 <<<"$out")"; else bad "$name" "$(head -n1 <<<"$out")"; fi
}

echo "System tools"
for t in mips-linux-gnu-as mips-linux-gnu-ld mips-linux-gnu-objcopy; do
    if command -v "$t" >/dev/null; then tool "$t" "$t" --version; else bad "$t" "not installed (./install.sh)"; fi
done
tool clang      clang --version
tool clang++    clang++ --version
if command -v ld.lld >/dev/null; then tool ld.lld ld.lld --version; else bad ld.lld "not installed (./install.sh)"; fi
tool cmake      cmake --version
tool ninja      ninja --version
tool git        git --version
tool python3    python3 --version
if command -v xxhsum >/dev/null; then tool xxhsum xxhsum --version; else bad xxhsum "not installed (./install.sh): new-game.sh hashes the ROM with it"; fi

echo "Python venv (.venv)"
if [[ -x .venv/bin/python ]]; then
    if .venv/bin/python -m splat --help >/dev/null 2>&1; then
        ok "splat" "$(.venv/bin/python -I -c 'from importlib.metadata import version as v; print("splat64", v("splat64"), "/ spimdisasm", v("spimdisasm"), "/ rabbitizer", v("rabbitizer"))')"
    else
        bad "splat" "python -m splat --help failed"
    fi
    if diff -q <(.venv/bin/pip freeze 2>/dev/null) requirements.txt >/dev/null; then
        ok "requirements.txt" "venv matches the pins"
    else
        bad "requirements.txt" "venv differs from the pins (rerun ./build.sh)"
    fi
else
    bad ".venv" "missing (./build.sh)"
fi

echo "Recompilers (bin/)"
for t in N64Recomp RSPRecomp; do
    out=$(bin/$t 2>&1); rc=$?
    if [[ -x bin/$t && $rc == 0 && $out == Usage:* ]]; then ok "$t" "$out"; else bad "$t" "missing or broken (./build.sh)"; fi
done
head=$(git -C src/N64Recomp rev-parse HEAD 2>/dev/null)
if [[ $head == "$N64RECOMP_COMMIT" ]]; then
    ok "src/N64Recomp" "at pin ${N64RECOMP_COMMIT:0:7}"
else
    bad "src/N64Recomp" "at ${head:-nothing}, pin is ${N64RECOMP_COMMIT:0:7} (./build.sh)"
fi
if [[ src/N64Recomp/build/N64Recomp -nt bin/N64Recomp ]]; then
    warn "bin/" "older than the last N64Recomp build (./build.sh copies it)"
fi

echo "Vulkan (needed once a game renders)"
if ! command -v vulkaninfo >/dev/null; then
    warn "vulkaninfo" "not installed (vulkan-tools)"
elif sum=$(vulkaninfo --summary 2>/dev/null) && grep -q deviceName <<<"$sum"; then
    while read -r line; do ok "GPU" "$line"; done < <(
        awk '/deviceName/ {sub(/.*= /, ""); name=$0} /driverInfo/ {sub(/.*= /, ""); print name " (driver " $0 ")"}' <<<"$sum" | sort -u)
else
    warn "vulkaninfo" "no Vulkan device found"
fi

echo "Environment"
if [[ -n ${N64RECOMP_TOOLKIT:-} ]]; then
    want=$(pwd -P)
    [[ $(command -v N64Recomp) == "$want/bin/N64Recomp" ]] && ok "env.sh" "bin/ on PATH" || bad "env.sh" "N64Recomp on PATH is $(command -v N64Recomp || echo none)"
    [[ $(command -v python3) == "$want/.venv/bin/python3" ]] && ok "env.sh" "venv python3 on PATH" || bad "env.sh" "python3 on PATH is $(command -v python3)"
    [[ $(command -v new-game.sh) == "$want/scripts/new-game.sh" ]] && ok "env.sh" "scripts/ on PATH" || bad "env.sh" "scripts/ not on PATH"
else
    echo "  info  env.sh                 not sourced in this shell (source ./env.sh)"
fi

if [[ -f versions.lock ]]; then
    echo "Drift since VERSIONS.md was recorded"
    drift=0
    while IFS='=' read -r k v; do
        [[ -z $k || $k == \#* ]] && continue
        now=$(scripts/record-versions.sh --get "$k" 2>/dev/null)
        if [[ $now != "$v" ]]; then warn "$k" "recorded '$v', now '$now'"; drift=1; fi
    done < versions.lock
    (( drift )) || echo "  ok    none"
fi

echo
if (( fails )); then
    echo "doctor.sh: $fails check(s) failed, $warns warning(s)."
    exit 1
fi
echo "doctor.sh: all checks passed ($warns warning(s))."
