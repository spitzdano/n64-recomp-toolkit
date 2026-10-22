#!/usr/bin/env bash
# tests/run.sh: the scripts' tests, on a synthetic ROM (never a real one).
#
# Writes synthetic .z64/.v64/.n64 files into a temp folder, checks rominfo.py,
# romconvert.py and ucode_scan.py on them, scaffolds a project with new-game.sh,
# runs its split.sh, and (when the MIPS binutils are installed) build_elf.sh,
# recomp.sh cpu and check_recomp.sh on it. The temp folder is deleted at the end.
#
#   tests/run.sh          run everything
#   tests/run.sh --keep   keep the temp folder for a look
set -uo pipefail
TOOLKIT=$(dirname "$(dirname "$(readlink -f "$0")")")
. "$TOOLKIT/pins.env"
PY=$TOOLKIT/.venv/bin/python
S=$TOOLKIT/scripts

keep=0; [[ ${1:-} == --keep ]] && keep=1
tmp=$(mktemp -d -t n64recomp-test.XXXXXX)
(( keep )) && echo "temp folder: $tmp" || trap 'rm -rf "$tmp"' EXIT

pass=0 fail=0
check() {  # check <description> <command...>
    local d=$1; shift
    if out=$("$@" 2>&1); then
        printf '  pass  %s\n' "$d"; pass=$((pass + 1))
    else
        printf '  FAIL  %s\n' "$d"; sed 's/^/          /' <<<"$out" | head -20; fail=$((fail + 1))
    fi
}
refuses() {  # refuses <description> <expected text> <command...>: must fail and say <text>
    local d=$1 want=$2; shift 2
    local out
    if out=$("$@" 2>&1); then
        printf '  FAIL  %s (succeeded)\n' "$d"; fail=$((fail + 1))
    elif ! grep -qF -- "$want" <<<"$out"; then
        printf '  FAIL  %s (no "%s" in: %s)\n' "$d" "$want" "$out"; fail=$((fail + 1))
    else
        printf '  pass  %s\n' "$d"; pass=$((pass + 1))
    fi
}
jf() { "$PY" -I -c 'import json,sys; print(json.load(open(sys.argv[1]))[sys.argv[2]])' "$1" "$2"; }

echo "Synthetic ROM"
check "make_synthetic_rom.py" python3 -I "$TOOLKIT/tests/make_synthetic_rom.py" "$tmp/rom"
R=$tmp/rom
want_sha=$(sha1sum "$R/synthetic.z64" | cut -d' ' -f1)

echo "rominfo.py"
for f in z64 v64 n64; do
    "$PY" -I "$S/rominfo.py" --json "$R/synthetic.$f" >"$tmp/info.$f.json" 2>&1
    check "$f: byte order detected"   test "$(jf "$tmp/info.$f.json" format)" = "$f"
    check "$f: SHA-1 of z64 image"    test "$(jf "$tmp/info.$f.json" sha1)" = "$want_sha"
    check "$f: game code NSYE"        test "$(jf "$tmp/info.$f.json" game_code)" = NSYE
    check "$f: entry 0x80000400"      test "$(jf "$tmp/info.$f.json" entry_point)" = 0x80000400
done
check "z64: version 0, name, size" test "$(jf "$tmp/info.z64.json" version)/$(jf "$tmp/info.z64.json" internal_name)/$(jf "$tmp/info.z64.json" size)" = "0/SYNTHETIC TEST ROM/1048576"
check "unknown CIC is reported"   grep -q 'unknown CIC' "$tmp/info.z64.json"
check "human-readable output"     bash -c "'$S/rominfo.py' '$R/synthetic.z64' | grep -q '^cic .*unknown'"
refuses "non-ROM refused"         "not an N64 ROM magic" "$S/rominfo.py" "$TOOLKIT/pins.env"

echo "romconvert.py"
check "v64 -> z64 matches"        bash -c "'$S/romconvert.py' '$R/synthetic.v64' '$tmp/from-v64.z64' && cmp '$tmp/from-v64.z64' '$R/synthetic.z64'"
check "n64 -> z64 matches"        bash -c "'$S/romconvert.py' '$R/synthetic.n64' '$tmp/from-n64.z64' && cmp '$tmp/from-n64.z64' '$R/synthetic.z64'"
refuses "won't overwrite input"   "output is the input" "$S/romconvert.py" "$R/synthetic.v64" "$R/synthetic.v64"
refuses "won't overwrite output"  "already exists" "$S/romconvert.py" "$R/synthetic.v64" "$tmp/from-v64.z64"
check "input left untouched"      test "$(sha1sum <"$R/synthetic.v64")" = "$(python3 -I "$TOOLKIT/tests/make_synthetic_rom.py" "$tmp/rom2" >/dev/null; sha1sum <"$tmp/rom2/synthetic.v64")"

echo "ucode_scan.py"
for f in z64 n64; do
    check "$f: finds the string at 0x20000" bash -c "'$S/ucode_scan.py' '$R/synthetic.$f' | grep -q '0x20000  RSP Gfx ucode F3DEX'"
done

echo "new-game.sh"
export N64RECOMP_PROJECTS=$tmp/projects
refuses "refuses a .v64 dump"     "romconvert.py" "$S/new-game.sh" "$R/synthetic.v64" synth
refuses "refuses a bad name"      "must be lowercase" "$S/new-game.sh" "$R/synthetic.z64" "Bad Name"
check "scaffolds from .z64"       "$S/new-game.sh" "$R/synthetic.z64" synth
P=$tmp/projects/synth-recomp
check "baserom.z64 is a symlink"  test -L "$P/baserom.z64"
check "no ROM copied in"          bash -c "! find '$P' -path '$P/lib' -prune -o -type f \\( -name '*.z64' -o -name '*.v64' -o -name '*.n64' \\) -print | grep -q ."
check "rom.sha1 verifies"         bash -c "cd '$P' && sha1sum -c --quiet rom.sha1"
check "rominfo.json has no path"  bash -c "! grep -q '\"file\"' '$P/rominfo.json'"
check "files named by tag"        test -f "$P/split/synth.us.yaml" -a -f "$P/synth.us.toml" -a -f "$P/aspMain.us.toml"
check "no placeholders left"      bash -c "! grep -rIl --exclude-dir=lib --exclude-dir=.git -E '__[A-Z][A-Z0-9_]*__' '$P'"
check "tools are executable"      bash -c "for f in '$P'/tools/*.sh; do test -x \"\$f\" || exit 1; done"
check ".gitignore covers C1"      bash -c "cd '$P' && touch x.z64 x.v64 x.n64 && test \$(git check-ignore x.z64 x.v64 x.n64 baserom.z64 build/a RecompiledFuncs/a rsp/a split/asm/a split/bin/a | wc -l) = 9; r=\$?; rm -f x.z64 x.v64 x.n64; exit \$r"
check "runtime submodule at pin"  test "$(git -C "$P/lib/N64ModernRuntime" rev-parse HEAD)" = "$N64MODERNRUNTIME_COMMIT"
check "rt64 submodule at pin"     test "$(git -C "$P/lib/rt64" rev-parse HEAD)" = "$RT64_COMMIT"
check "LICENSE is GPL-3.0"        grep -q 'Version 3, 29 June 2007' "$P/LICENSE"
check "README has AI disclosure"  grep -q 'AI disclosure' "$P/README.md"
check "toml entrypoint filled"    grep -q '^entrypoint = 0x80000400$' "$P/synth.us.toml"
check "shell copied"              test -f "$P/CMakeLists.txt" -a -f "$P/src/main/main.cpp" -a -f "$P/src/game/patches.cpp" -a -x "$P/tools/build_game.sh"
check "shell has the ROM's XXH3"  grep -q "rom_hash = 0x$(xxhsum -H3 "$R/synthetic.z64" | sed -n 's/^XXH3_\([0-9a-f]*\) .*/\1/p' | tr a-f A-F)ULL" "$P/src/main/main.cpp"
check "shell names filled"        bash -c "grep -q '^project(SynthRecomp ' '$P/CMakeLists.txt' && grep -q 'u8\"synth.n64.us.1.0\"' '$P/src/main/main.cpp' && grep -q 'internal_name = \"SYNTHETIC TEST ROM\"' '$P/src/main/main.cpp' && grep -q 'SDL_CreateWindow(\"Synthetic Test Rom\"' '$P/src/main/main.cpp'"
refuses "refuses existing folder" "already exists" "$S/new-game.sh" "$R/synthetic.z64" synth

# clang -fsyntax-only on shell sources, with the project's submodules as include paths (no RT64 build needed).
shell_syntax() {  # shell_syntax <file under src/...>
    local inc=() d
    for d in rt64/include N64ModernRuntime/N64Recomp/include rt64/src/contrib rt64/src/contrib/hlslpp/include \
             rt64/src/contrib/dxc/inc rt64/src rt64/src/rhi rt64/src/render rt64/src/contrib/plume \
             rt64/src/contrib/plume/contrib/volk rt64/src/contrib/plume/contrib/Vulkan-Headers/include \
             rt64/src/contrib/plume/contrib/VulkanMemoryAllocator/include N64ModernRuntime/librecomp/include \
             N64ModernRuntime/ultramodern/include N64ModernRuntime/thirdparty N64ModernRuntime/thirdparty/concurrentqueue; do
        inc+=(-I "$P/lib/$d")
    done
    # shellcheck disable=SC2046
    clang++ -std=c++20 -fsyntax-only -fms-extensions -Wno-nontrivial-memcall -I "$P/src/main" "${inc[@]}" \
        -DHLSL_CPU -DPLUME_SDL_VULKAN_ENABLED -DRT64_SDL_WINDOW_VULKAN $(pkg-config --cflags sdl2) "$P/$1"
}

echo "Runtime shell (syntax only)"
for f in main/main.cpp main/settings.cpp main/input.cpp main/audio.cpp main/rt64_context.cpp game/stubs.cpp game/patches.cpp; do
    check "src/$f" shell_syntax "src/$f"
done

echo "Project tools on the synthetic project"
check "split.sh"                  "$P/tools/split.sh"
check "split output is ignored"   bash -c "cd '$P' && test -z \"\$(git status --porcelain --untracked-files=all | grep -v '^A ')\""
if command -v mips-linux-gnu-as >/dev/null; then
    check "build_elf.sh byte-identical" bash -c "'$P/tools/build_elf.sh' | grep -q 'byte for byte'"
    check "romdiff names the segment" bash -c "cd '$P' && cp build/synth.us.z64 build/bad.z64 && printf '\\xff' | dd of=build/bad.z64 bs=1 seek=\$((0x1064)) conv=notrunc 2>/dev/null && '$PY' -I tools/romdiff.py split/synth.us.yaml baserom.z64 build/bad.z64 | grep -q 'ROM 0x1064' && '$PY' -I tools/romdiff.py split/synth.us.yaml baserom.z64 build/bad.z64 | grep -q 'main (code)'"
    check "recomp.sh cpu"             "$P/tools/recomp.sh" cpu
    check "check_recomp.sh"           "$P/tools/check_recomp.sh"
    check "src/main/register_overlays.cpp" shell_syntax src/main/register_overlays.cpp
    check "find_fallthrough.py"       bash -c "cd '$P' && '$PY' -I tools/find_fallthrough.py"
    check "find_missing_funcs.py"     bash -c "cd '$P' && '$PY' -I tools/find_missing_funcs.py >/dev/null"
else
    echo "  skip  build_elf.sh / recomp.sh / check_recomp.sh / register_overlays.cpp / find_*.py (mips-linux-gnu binutils not installed)"
fi

echo
echo "tests/run.sh: $pass passed, $fail failed."
(( fail == 0 ))
