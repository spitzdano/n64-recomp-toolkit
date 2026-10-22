#!/usr/bin/env bash
# get-upscaler.sh: fetch Real-ESRGAN (ncnn/Vulkan build) into opt/realesrgan, checked against pins.env.
# Safe to rerun; does nothing when the pinned build is already there. Needs a Vulkan GPU to run.
set -euo pipefail
TOOLKIT=$(dirname "$(dirname "$(readlink -f "$0")")")
. "$TOOLKIT/pins.env"
dest=$TOOLKIT/opt/realesrgan
if [[ -f $dest/.sha256 && $(cat "$dest/.sha256") == "$REALESRGAN_SHA256" ]]; then
    echo "get-upscaler.sh: $dest is up to date"; exit 0
fi
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
curl -fsSL -o "$tmp/esr.zip" "$REALESRGAN_URL"
got=$(sha256sum "$tmp/esr.zip" | cut -d' ' -f1)
[[ $got == "$REALESRGAN_SHA256" ]] || { echo "get-upscaler.sh: checksum mismatch ($got)" >&2; exit 1; }
rm -rf "$dest"; mkdir -p "$dest"
(cd "$dest" && unzip -q "$tmp/esr.zip" realesrgan-ncnn-vulkan 'models/*')
chmod +x "$dest/realesrgan-ncnn-vulkan"
echo "$REALESRGAN_SHA256" >"$dest/.sha256"
echo "get-upscaler.sh: $dest/realesrgan-ncnn-vulkan"
