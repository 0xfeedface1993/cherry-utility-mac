#!/bin/zsh
# Packs CherryUtility.app into the installer DMG: volume icon, Finder window with the designed background, the app and
# an Applications link at the positions the background's arrow points between. Signing is left to the caller.
#
#   Scripts/make-dmg.sh <CherryUtility.app> <out.dmg>
#
# Layout is written by dmgbuild (pinned, installed once into .release/tools/dmgbuild-venv from PyPI), so no Finder window
# opens and no Automation permission is needed. Background: Design/icons/DMGBackground{,@2x}.png, rendered from
# DMGBackground.svg by Scripts/render-dmg-background.swift.
set -euo pipefail

repo="${0:A:h:h}"
(( $# == 2 )) || { print -u2 "usage: $0 <CherryUtility.app> <out.dmg>"; exit 64; }
app="${1:A}"; dmg="${2:A}"
[[ -d "$app" ]] || { print -u2 "missing $app"; exit 66; }

venv="$repo/.release/tools/dmgbuild-venv"
if [[ ! -x "$venv/bin/dmgbuild" ]]; then
  python3 -m venv "$venv"
  "$venv/bin/pip" install --quiet --disable-pip-version-check "dmgbuild==1.6.7" "ds_store==1.3.3" "mac_alias==2.2.3"
fi

background="$repo/Design/icons/DMGBackground.png"
[[ -f "$background" && -f "${background:r}@2x.png" ]] || { print -u2 "missing DMG background PNGs; run: swift Scripts/render-dmg-background.swift"; exit 66; }

work="$(mktemp -d "${dmg:h}/.make-dmg.XXXXXX")"
trap 'rm -rf "$work"' EXIT
iconset="$work/VolumeIcon.iconset"
mkdir -p "$iconset"
src_icons="$repo/App/Resources/Assets.xcassets/AppIcon.appiconset"
for size in 16 32 128 256 512; do
  cp "$src_icons/icon_$size.png" "$iconset/icon_${size}x${size}.png"
  cp "$src_icons/icon_$((size * 2)).png" "$iconset/icon_${size}x${size}@2x.png" 2>/dev/null \
    || sips -z $((size * 2)) $((size * 2)) "$src_icons/icon_1024.png" --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$iconset" -o "$work/VolumeIcon.icns"

rm -f "$dmg"
"$venv/bin/dmgbuild" -s "$repo/Scripts/dmg-settings.py" \
  -D app="$app" -D icon="$work/VolumeIcon.icns" -D background="$background" \
  "CHERRY Utility" "$dmg"
