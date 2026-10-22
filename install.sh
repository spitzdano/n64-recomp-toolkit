#!/usr/bin/env bash
# install.sh: system packages for the N64 recomp toolkit. Safe to run twice:
# it only installs what is missing, and asks before anything runs with sudo.
#
#   ./install.sh        list what is missing, ask, then install
#   ./install.sh -y     install without asking
#   ./install.sh -n     only list what is missing (exit 1 if anything is)
#
# The package list per distro, and how the Debian and Arch names map,
# is in README.md ("System packages").
set -euo pipefail

mode=ask
case "${1:-}" in
    -y) mode=yes ;;
    -n) mode=check ;;
    "") ;;
    *) echo "usage: $0 [-y|-n]" >&2; exit 2 ;;
esac

. /etc/os-release
family=
case " ${ID:-} ${ID_LIKE:-} " in
    *" arch "*)                   family=arch ;;
    *" debian "*|*" ubuntu "*)    family=debian ;;
esac
if [[ -z $family ]]; then
    echo "install.sh: unsupported distro '${ID:-?}'. Supported: Arch-based, Debian/Ubuntu-based." >&2
    echo "Map the packages in README.md by hand." >&2
    exit 1
fi

repo_missing=()
aur_missing=()

if [[ $family == arch ]]; then
    # Debian name                 -> Arch name
    # binutils-mips-linux-gnu      -> mips-linux-gnu-binutils (AUR)
    # python3 python3-venv         -> python (venv is built in)
    # ninja-build                  -> ninja
    # libsdl2-dev                  -> sdl2-compat (headers + sdl2.pc included)
    # libgtk-3-dev                 -> gtk3 (headers included)
    # build-essential (implicit)   -> base-devel (also needed to build AUR packages)
    repo_pkgs=(base-devel git cmake ninja clang lld llvm python pkgconf xxhash
               sdl2-compat gtk3 vulkan-icd-loader vulkan-tools)
    aur_pkgs=(mips-linux-gnu-binutils)
    for p in "${repo_pkgs[@]}"; do pacman -Q "$p" &>/dev/null || repo_missing+=("$p"); done
    for p in "${aur_pkgs[@]}";  do pacman -Q "$p" &>/dev/null || aur_missing+=("$p"); done
else
    repo_pkgs=(binutils-mips-linux-gnu python3 python3-venv git cmake ninja-build
               clang lld llvm libsdl2-dev libgtk-3-dev vulkan-tools pkg-config build-essential xxhash)
    for p in "${repo_pkgs[@]}"; do
        dpkg-query -W -f='${Status}' "$p" 2>/dev/null | grep -q 'install ok installed' || repo_missing+=("$p")
    done
fi

# The Vulkan driver depends on the GPU, so it is checked, not installed.
if ! compgen -G '/usr/share/vulkan/icd.d/*.json' >/dev/null && ! compgen -G '/etc/vulkan/icd.d/*.json' >/dev/null; then
    echo "warning: no Vulkan driver (ICD) found. RT64 needs one once a game renders."
    if [[ $family == arch ]]; then
        echo "         NVIDIA: nvidia-utils   AMD: vulkan-radeon   Intel: vulkan-intel"
    else
        echo "         AMD/Intel: mesa-vulkan-drivers   NVIDIA: the nvidia-driver-* package"
    fi
fi

if (( ${#repo_missing[@]} == 0 && ${#aur_missing[@]} == 0 )); then
    echo "install.sh: all system packages are present ($family)."
    exit 0
fi

echo "install.sh: missing packages ($family):"
(( ${#repo_missing[@]} )) && echo "  repo: ${repo_missing[*]}"
(( ${#aur_missing[@]} ))  && echo "  AUR:  ${aur_missing[*]}  (built from source by yay; PKGBUILD downloads the GNU binutils tarball)"
[[ $mode == check ]] && exit 1

if [[ $mode == ask ]]; then
    read -rp "Install these? This runs sudo. [y/N] " reply
    [[ $reply == [yY]* ]] || { echo "Nothing installed."; exit 1; }
fi

if [[ $family == arch ]]; then
    if (( ${#repo_missing[@]} )); then
        sudo pacman -S --needed --noconfirm "${repo_missing[@]}"
    fi
    if (( ${#aur_missing[@]} )); then
        if command -v yay >/dev/null; then
            # --nocheck skips binutils' own test suite, which only takes time.
            yay -S --needed --noconfirm --mflags --nocheck "${aur_missing[@]}"
        elif command -v paru >/dev/null; then
            paru -S --needed --noconfirm --mflags --nocheck "${aur_missing[@]}"
        else
            echo "No AUR helper found. Build by hand:" >&2
            for p in "${aur_missing[@]}"; do
                echo "  git clone https://aur.archlinux.org/$p.git && cd $p && makepkg -si --nocheck" >&2
            done
            exit 1
        fi
    fi
else
    sudo apt-get update
    sudo apt-get install -y "${repo_missing[@]}"
fi

echo "install.sh: done. Run ./doctor.sh to check."
