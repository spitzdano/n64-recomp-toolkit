#!/usr/bin/env bash
# new-game.sh <rom> <name>: scaffold a recompilation project for one N64 ROM.
#
# Creates $N64RECOMP_PROJECTS/<name>-recomp (default ~/Work/<name>-recomp) and:
#   - checks the ROM with rominfo.py; refuses .v64/.n64 dumps (convert with romconvert.py)
#   - symlinks the ROM in as baserom.z64 (never copies it) and records rom.sha1 + rominfo.json
#   - runs splat's create_config and moves its yaml to split/<name>.<region>.yaml
#   - copies template/ and shell-template/files/ (the runtime shell: src/, CMakeLists.txt) with the placeholders
#     filled in; the shell's executable is <Name>Recomp, its data folder ~/.local/share/<Name>Recomp
#   - git init, and adds N64ModernRuntime and RT64 as submodules at the pins.env commits
#   - prints a warning for each sign the game needs more than the standard path
# Refuses to touch a folder that already exists.
set -euo pipefail
TOOLKIT=$(dirname "$(dirname "$(readlink -f "$0")")")
. "$TOOLKIT/pins.env"
PY=$TOOLKIT/.venv/bin/python

die() { echo "new-game.sh: $*" >&2; exit 1; }

(( $# == 2 )) || die "usage: new-game.sh <rom> <name>   (name: lowercase letters, digits, - or _)"
rom=$1 name=$2
[[ $name =~ ^[a-z0-9][a-z0-9_-]*$ ]] || die "name '$name' must be lowercase letters, digits, - or _"
[[ -f $rom ]] || die "$rom is not a file"
[[ -x $PY && -x $TOOLKIT/bin/N64Recomp ]] || die "toolkit not built: run $TOOLKIT/build.sh"
command -v xxhsum >/dev/null || die "xxhsum not found (package xxhash): the shell needs the ROM's XXH3 hash"

projects=${N64RECOMP_PROJECTS:-$HOME/Work}
dest=$projects/$name-recomp
[[ -e $dest || -L $dest ]] && die "$dest already exists; refusing to touch it"

info=$("$PY" -I "$TOOLKIT/scripts/rominfo.py" --json "$rom")
field() { "$PY" -I -c 'import json,sys; print(json.loads(sys.argv[1])[sys.argv[2]])' "$info" "$1"; }
fmt=$(field format)
if [[ $fmt != z64 ]]; then
    die "$rom is a $(field format_name) dump. Convert it first:
  $TOOLKIT/scripts/romconvert.py '$rom' '${rom%.*}.z64'"
fi

code=$(field game_code)
case ${code: -1} in
    E) region=us ;; J) region=jp ;; P) region=eu ;; U) region=au ;;
    D) region=de ;; F) region=fr ;; I) region=it ;; S) region=es ;;
    *) region=$(tr '[:upper:]' '[:lower:]' <<<"${code: -1}") ;;
esac
tag=$name.$region

echo "== $(field internal_name) ($code v$(field version), $(field region)) -> $dest"
mkdir -p "$projects"
mkdir "$dest"
ln -s "$(readlink -f "$rom")" "$dest/baserom.z64"
echo "$(field sha1)  baserom.z64" >"$dest/rom.sha1"
# Hash and header fields only (no ROM bytes, no local path).
"$PY" -I -c 'import json,sys; d=json.loads(sys.argv[1]); d.pop("file"); print(json.dumps(d, indent=2))' "$info" >"$dest/rominfo.json"

echo "== splat create_config"
mkdir -p "$dest/split" "$dest/build"
(
    cd "$dest"
    "$PY" -m splat create_config baserom.z64 >build/create_config.log 2>&1 \
        || { cat build/create_config.log >&2; exit 1; }
    yaml=$(sed -n 's/^Writing config to //p' build/create_config.log)
    [[ -f $yaml ]] || { echo "create_config wrote no yaml" >&2; exit 1; }
    mv "$yaml" "split/$tag.yaml"
    for f in symbol_addrs.txt reloc_addrs.txt; do
        if [[ -f $f ]]; then mv "$f" split/; else : >"split/$f"; fi
    done
    rm -rf include  # splat regenerates its asm macros into split/include on every split
    "$PY" -I "$TOOLKIT/scripts/splat_relocate.py" "split/$tag.yaml" "$tag"
)

echo "== template"
values=$dest/build/template-values.json
xxh3=$(xxhsum -H3 "$dest/baserom.z64" | sed -n 's/^XXH3_\([0-9a-f]\{16\}\) .*/\1/p')
[[ -n $xxh3 ]] || die "xxhsum -H3 gave no XXH3 hash for $rom"
"$PY" -I -c '
import json, re, sys
info = json.loads(sys.argv[1])
name, tag, region, toolkit, commit, has_main, xxh3, rom = sys.argv[2:10]

# The header name as librecomp compares it (raw bytes at 0x20), as a C string: octal escapes for anything else.
raw = open(rom, "rb").read(0x34)[0x20:0x34].rstrip(b" \0")
header_c = "".join(chr(b) if 0x20 <= b < 0x7F and chr(b) not in "\"\\?" else f"\\{b:03o}" for b in raw)
# Shown to the player (window title, messages): the header name in words, safe inside a C string and printf.
words = re.sub(r"[^A-Za-z0-9 .:!&+\x27-]+", " ", info["internal_name"].replace("_", " ")).split()
title = " ".join(w.capitalize() if w.isupper() or w.islower() else w for w in words) or name
exe = "".join(w.capitalize() for w in re.split(r"[-_]+", name) if w) + "Recomp"
version = info["version"]
print(json.dumps({
    "__GAME__": name,
    "__TAG__": tag,
    "__REGION__": region,
    "__ENTRYPOINT__": info["entry_point"],
    "__GAMECODE__": info["game_code"],
    "__VERSION__": str(info["version"]),
    "__INTERNAL_NAME__": info["internal_name"],
    "__ROM_SHA1__": info["sha1"],
    "__TOOLKIT__": toolkit,
    "__N64RECOMP_SHORT__": commit[:7],
    "__RENAMED__": "[\"main\"]" if has_main == "1" else "[]",
    "__TITLE__": title,
    "__EXE__": exe,
    "__GAME_ID__": f"{name}.n64.{region}.1.{version}",
    "__ROM_XXH3__": "0x" + xxh3.upper(),
    "__HEADER_NAME_C__": header_c,
}, indent=2))' "$info" "$name" "$tag" "$region" "$TOOLKIT" "$N64RECOMP_COMMIT" \
    "$(grep -qE 'symbol:main( |$)|^main *=' "$dest"/split/{reloc,symbol}_addrs.txt && echo 1 || echo 0)" \
    "$xxh3" "$dest/baserom.z64" >"$values"
"$PY" -I "$TOOLKIT/scripts/fill_template.py" "$TOOLKIT/template" "$dest" "$values"
"$PY" -I "$TOOLKIT/scripts/fill_template.py" "$TOOLKIT/shell-template/files" "$dest" "$values"
exe=$("$PY" -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["__EXE__"])' "$values")
rm -f "$values"

echo "== git + submodules"
(
    cd "$dest"
    git init -q
    add_sub() {  # add_sub <url> <commit> <path>
        git -c advice.detachedHead=false submodule add -q "$1" "$3"
        git -C "$3" -c advice.detachedHead=false checkout -q "$2"
        git -C "$3" submodule update -q --init --recursive
        git add "$3"
    }
    add_sub "$N64MODERNRUNTIME_URL" "$N64MODERNRUNTIME_COMMIT" lib/N64ModernRuntime
    add_sub "$RT64_URL" "$RT64_COMMIT" lib/rt64
    head -c 200 lib/N64ModernRuntime/COPYING | grep -q 'GNU GENERAL PUBLIC LICENSE' \
        || { echo "lib/N64ModernRuntime/COPYING is not the GPL text" >&2; exit 1; }
    cp lib/N64ModernRuntime/COPYING LICENSE
    git add -A
)

# Signs this game needs more than the standard path.
warn=$("$PY" -I -c 'import json,sys; [print(w) for w in json.loads(sys.argv[1])["warnings"]]' "$info")
grep -q 'non-traditional entrypoint' "$dest/split/$tag.yaml" \
    && warn+=$'\n'"create_config: non-traditional entrypoint (see split/$tag.yaml)"
if [[ -n ${warn//[$'\n ']/} ]]; then
    echo
    echo "Warnings (this game may need more than the standard path):"
    sed '/^$/d; s/^/  - /' <<<"$warn"
fi

cat <<EOF

new-game.sh: $dest is ready (git initialised, nothing committed).
  ROM      baserom.z64 -> $(readlink -f "$rom")
  config   split/$tag.yaml (create_config's first guess: replace it if a decomp has a better one)
  shell    src/ + CMakeLists.txt (from shell-template): executable $exe
  next     cd $dest && tools/split.sh && tools/build_elf.sh
           then tools/recomp.sh && tools/build_game.sh
EOF
