# env.sh: `source` this to put the toolkit on PATH (bash or zsh).
#   bin/      N64Recomp, RSPRecomp
#   scripts/  rominfo.py, romconvert.py, ucode_scan.py, new-game.sh
#   .venv/    python3 with the pinned splat (python3 -m splat ...)
if [ -n "${BASH_SOURCE[0]:-}" ]; then
    N64RECOMP_TOOLKIT=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
elif [ -n "${ZSH_VERSION:-}" ]; then
    N64RECOMP_TOOLKIT=$(cd "$(dirname "${(%):-%x}")" && pwd)
else
    echo "env.sh: source it from bash or zsh" >&2
    return 1
fi
export N64RECOMP_TOOLKIT
export VIRTUAL_ENV=$N64RECOMP_TOOLKIT/.venv
for _d in "$VIRTUAL_ENV/bin" "$N64RECOMP_TOOLKIT/scripts" "$N64RECOMP_TOOLKIT/bin" "$N64RECOMP_TOOLKIT"; do
    case ":$PATH:" in *":$_d:"*) ;; *) PATH=$_d:$PATH ;; esac
done
unset _d
export PATH
