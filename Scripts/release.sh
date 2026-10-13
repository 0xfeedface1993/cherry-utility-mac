#!/bin/zsh
# Builds, signs, notarizes and Sparkle-signs a public CHERRY Utility release, then records it in Website/releases.json.
#
#   Scripts/release.sh <version> <build> [--note "…"]... [--skip-notarize] [--resume]
#
# Credentials come from the environment or, by default, from a file kept outside the repository:
#   CHERRY_RELEASE_ENV (default ~/Documents/开发密钥/CherryUtility-release.env) defining
#   DEVELOPMENT_TEAM, DEVELOPER_ID_APPLICATION, NOTARY_API_KEY_FILE, NOTARY_API_KEY_ID, NOTARY_ISSUER_ID
#   (or NOTARY_KEYCHAIN_PROFILE) and SPARKLE_PRIVATE_KEY_FILE.
# Output: .release/<version>-<build>/ with the archive, the stapled DMG, its .sha256 and the Sparkle signature.
# CHERRY_RELEASE_OUTPUT overrides that folder; CHERRY_DERIVED_DATA reuses an earlier run's build cache
# (default <output>/DerivedData, a clean universal build that takes several minutes).
# --resume keeps the DMG of an interrupted run and continues at notarization; an accepted submission recorded in
# notary-submission.json for the same DMG hash is not uploaded again (stapler still checks the ticket against the DMG).
# Publish afterwards with: Scripts/deploy-website.sh --artifacts .release/<version>-<build>
# A missing credential stops the script; it never reports a release that was not signed and notarized.
set -euo pipefail

repo="${0:A:h:h}"
env_file="${CHERRY_RELEASE_ENV:-$HOME/Documents/开发密钥/CherryUtility-release.env}"
[[ -f "$env_file" ]] && source "$env_file"

version="${1:-}"; build="${2:-}"
[[ "$version" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' && "$build" =~ '^[0-9]+$' ]] || { sed -n '2,13p' "$0"; exit 64; }
shift 2
notes=(); notarize=1; resume=0
while (( $# )); do
  case "$1" in
    --note) notes+=("${2:?}"); shift 2 ;;
    --skip-notarize) notarize=0; shift ;;
    --resume) resume=1; shift ;;
    *) print -u2 "unknown option: $1"; exit 64 ;;
  esac
done

: "${DEVELOPMENT_TEAM:?missing DEVELOPMENT_TEAM}"
: "${DEVELOPER_ID_APPLICATION:?missing DEVELOPER_ID_APPLICATION}"
: "${SPARKLE_PRIVATE_KEY_FILE:?missing SPARKLE_PRIVATE_KEY_FILE}"
[[ -f "$SPARKLE_PRIVATE_KEY_FILE" ]] || { print -u2 "SPARKLE_PRIVATE_KEY_FILE does not exist"; exit 2; }
notary_auth=()
if (( notarize )); then
  if [[ -n "${NOTARY_KEYCHAIN_PROFILE:-}" ]]; then
    notary_auth=(--keychain-profile "$NOTARY_KEYCHAIN_PROFILE")
  else
    : "${NOTARY_API_KEY_FILE:?missing NOTARY_API_KEY_FILE}" "${NOTARY_API_KEY_ID:?missing NOTARY_API_KEY_ID}" "${NOTARY_ISSUER_ID:?missing NOTARY_ISSUER_ID}"
    notary_auth=(--key "$NOTARY_API_KEY_FILE" --key-id "$NOTARY_API_KEY_ID" --issuer "$NOTARY_ISSUER_ID")
  fi
fi

# Sparkle compares CFBundleVersion: every release needs a larger build number.
python3 - "$repo/Website/releases.json" "$version" "$build" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
version, build = sys.argv[2], int(sys.argv[3])
for r in data["releases"]:
    if r.get("edSignature") and r["version"] != version and int(r["build"]) >= build:
        sys.exit(f"build {build} must be greater than published {r['version']} ({r['build']})")
PY

out="${CHERRY_RELEASE_OUTPUT:-$repo/.release/$version-$build}"
derived_data="${CHERRY_DERIVED_DATA:-$out/DerivedData}"
archive="$out/CherryUtility.xcarchive"
app="$archive/Products/Applications/CherryUtility.app"
dmg_name="CherryUtility-$version.dmg"
dmg="$out/$dmg_name"
mkdir -p "$out"

step() { print "\n==> $*"; }

if (( resume )); then
  step "继续 $version ($build)：沿用 ${dmg:t}"
  [[ -f "$dmg" && -d "$app" ]] || { print -u2 "nothing to resume in $out"; exit 1; }
  codesign --verify --verbose=2 "$dmg"
else
  rm -rf "$archive" "$out/dmg-root" "$dmg" "$dmg.sha256" "$out/notary-submission.json"

  step "归档 $version ($build)"
  cd "$repo"
  xcodegen generate >/dev/null
  xcodebuild archive \
    -project CherryUtility.xcodeproj -scheme CherryUtility -configuration Release \
    -destination "generic/platform=macOS" -archivePath "$archive" \
    -derivedDataPath "$derived_data" -skipMacroValidation \
    MARKETING_VERSION="$version" CURRENT_PROJECT_VERSION="$build" \
    CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$DEVELOPER_ID_APPLICATION" DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" \
    OTHER_CODE_SIGN_FLAGS="--timestamp" ENABLE_HARDENED_RUNTIME=YES \
    | grep -E "error:|warning: .*signing|ARCHIVE (SUCCEEDED|FAILED)" || true
  [[ -d "$app" ]] || { print -u2 "archive failed"; exit 1; }

  archs="$(lipo -archs "$app/Contents/MacOS/CherryUtility")"
  [[ "$archs" == *arm64* && "$archs" == *x86_64* ]] || { print -u2 "expected a universal binary, got: $archs"; exit 1; }
  plist="$app/Contents/Info.plist"
  [[ "$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$plist")" == "$version" ]]
  [[ "$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$plist")" == "$build" ]]
  [[ "$(/usr/libexec/PlistBuddy -c 'Print SUPublicEDKey' "$plist")" =~ '^[A-Za-z0-9+/]{43}=$' ]] \
    || { print -u2 "SUPublicEDKey missing or malformed"; exit 1; }

  step "签名 Sparkle 内嵌组件与 App（Developer ID + 安全时间戳 + Hardened Runtime）"
  sparkle="$app/Contents/Frameworks/Sparkle.framework"
  for nested in "$sparkle/Versions/B/Autoupdate" "$sparkle/Versions/B/Updater.app" \
                "$sparkle/Versions/B/XPCServices/Downloader.xpc" "$sparkle/Versions/B/XPCServices/Installer.xpc"; do
    [[ -e "$nested" ]] || { print -u2 "missing Sparkle component: $nested"; exit 2; }
    codesign --force --options runtime --timestamp --sign "$DEVELOPER_ID_APPLICATION" --preserve-metadata=identifier,entitlements,flags "$nested"
  done
  for lib in "$app"/Contents/Frameworks/*.dylib(N); do
    codesign --force --options runtime --timestamp --sign "$DEVELOPER_ID_APPLICATION" "$lib"
  done
  codesign --force --options runtime --timestamp --sign "$DEVELOPER_ID_APPLICATION" --preserve-metadata=identifier,entitlements,flags "$sparkle"
  codesign --force --options runtime --timestamp --sign "$DEVELOPER_ID_APPLICATION" --preserve-metadata=identifier,entitlements,flags "$app"
  codesign --verify --deep --strict --verbose=2 "$app"
  # Capture before matching: with pipefail, `codesign | grep -q` fails (SIGPIPE) exactly when grep finds a match.
  entitlements="$(codesign -d --entitlements - --xml "$app" 2>/dev/null || true)"
  [[ "$entitlements" != *get-task-allow* ]] || { print -u2 "release build carries get-task-allow"; exit 1; }
  signature_info="$(codesign -dv "$app" 2>&1)"
  [[ "$signature_info" == *"flags=0x10000(runtime)"* ]] || { print -u2 "hardened runtime flag missing"; exit 1; }

  step "制作 DMG"
  staging="$out/dmg-root"
  mkdir -p "$staging"
  ditto "$app" "$staging/CherryUtility.app"
  ln -s /Applications "$staging/Applications"
  iconset="$out/VolumeIcon.iconset"
  rm -rf "$iconset"; mkdir -p "$iconset"
  src_icons="$repo/App/Resources/Assets.xcassets/AppIcon.appiconset"
  for size in 16 32 128 256 512; do
    cp "$src_icons/icon_$size.png" "$iconset/icon_${size}x${size}.png"
    cp "$src_icons/icon_$((size * 2)).png" "$iconset/icon_${size}x${size}@2x.png" 2>/dev/null \
      || sips -z $((size * 2)) $((size * 2)) "$src_icons/icon_1024.png" --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
  done
  iconutil -c icns "$iconset" -o "$staging/.VolumeIcon.icns"
  rw="$out/rw.dmg"
  rm -f "$rw"
  hdiutil create -quiet -volname "CHERRY Utility" -srcfolder "$staging" -fs HFS+ -format UDRW -ov "$rw"
  mountpoint="$(hdiutil attach -nobrowse -noautoopen -readwrite "$rw" | awk -F'\t' '/\/Volumes\// {print $NF}')"
  SetFile -a C "$mountpoint"
  SetFile -a V "$mountpoint/.VolumeIcon.icns"
  if [[ -n "${CHERRY_DMG_LAYOUT:-}" ]]; then "$CHERRY_DMG_LAYOUT" "$mountpoint"; fi
  sync
  hdiutil detach -quiet "$mountpoint"
  hdiutil convert -quiet "$rw" -format UDZO -imagekey zlib-level=9 -o "$dmg"
  rm -f "$rw"
  codesign --force --timestamp --sign "$DEVELOPER_ID_APPLICATION" "$dmg"
  codesign --verify --verbose=2 "$dmg"
fi

if (( notarize )); then
  step "公证（Apple notary service）"
  if (( resume )) && xcrun stapler validate -q "$dmg" 2>/dev/null; then
    print "DMG 已附公证票据，跳过提交"
  else
    record="$out/notary-submission.json"
    dmg_sha="$(shasum -a 256 "$dmg" | cut -d' ' -f1)"
    notary_id="$(python3 - "$record" "$dmg_sha" <<'PY'
import json, os, sys
path, sha = sys.argv[1:]
r = json.load(open(path)) if os.path.exists(path) else {}
print(r.get("id", "") if r.get("sha256") == sha and r.get("status") == "Accepted" else "")
PY
    )"
    if [[ -n "$notary_id" ]]; then
      result="$(xcrun notarytool info "$notary_id" "${notary_auth[@]}" --output-format json)"
    else
      result="$(xcrun notarytool submit "$dmg" "${notary_auth[@]}" --wait --output-format json)"
    fi
    # zsh reserves $status, hence notary_status.
    notary_status="$(python3 - "$record" "$dmg_sha" "$result" <<'PY'
import json, sys
path, sha, result = sys.argv[1:]
r = json.loads(result)
json.dump({"id": r.get("id"), "status": r.get("status"), "sha256": sha}, open(path, "w"), indent=2)
print(r.get("status") or "")
PY
    )"
    notary_id="$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["id"] or "")' "$record")"
    print "$notary_status $notary_id"
    if [[ "$notary_status" != "Accepted" ]]; then
      [[ -n "$notary_id" ]] && xcrun notarytool log "$notary_id" "${notary_auth[@]}" "$out/notary-log.json" || true
      print -u2 "notarization failed ($notary_status); log: $out/notary-log.json"; exit 1
    fi
    xcrun stapler staple "$dmg"
    xcrun stapler validate "$dmg"
  fi
  spctl --assess --type open --context context:primary-signature --verbose=2 "$dmg"
fi

step "校验值与 Sparkle 签名"
(cd "$out" && shasum -a 256 "$dmg_name" > "$dmg_name.sha256")
sha256="$(cut -d' ' -f1 "$dmg.sha256")"
# Any resolved checkout works (one Package.resolved); a resumed run may not have built into $derived_data.
sign_tools=( "$derived_data"/SourcePackages/artifacts/**/Sparkle/bin/sign_update(N.)
             "$repo"/.release/*/DerivedData/SourcePackages/artifacts/**/Sparkle/bin/sign_update(N.) )
(( ${#sign_tools} )) && [[ -x "${sign_tools[1]}" ]] || { print -u2 "sign_update not found"; exit 2; }
sign_update="${sign_tools[1]}"
signature_line="$("$sign_update" --ed-key-file "$SPARKLE_PRIVATE_KEY_FILE" "$dmg")"
print "$signature_line" > "$dmg.sparkle-signature.txt"
ed_signature="$(print "$signature_line" | sed -nE 's/.*sparkle:edSignature="([^"]+)".*/\1/p')"
length="$(stat -f%z "$dmg")"
[[ -n "$ed_signature" ]] || { print -u2 "could not parse the Sparkle signature"; exit 1; }
"$sign_update" --verify --ed-key-file "$SPARKLE_PRIVATE_KEY_FILE" "$dmg" "$ed_signature"

if (( ! notarize )); then
  print "\n试跑完成（未公证，不写入 releases.json）：$dmg"
  exit 0
fi

step "写入 Website/releases.json"
python3 - "$repo/Website/releases.json" "$version" "$build" "$dmg_name" "$length" "$sha256" "$ed_signature" "$notarize" "${notes[@]}" <<'PY'
import json, sys
from datetime import datetime, timezone
path, version, build, dmg, length, sha, sig, notarized, *notes = sys.argv[1:]
data = json.load(open(path))
now = datetime.now(timezone.utc).replace(microsecond=0)
entry = next((r for r in data["releases"] if r["version"] == version), None)
if entry is None:
    entry = {"version": version, "notes": notes or ["问题修复与改进。"]}
    data["releases"].insert(0, entry)
elif notes:
    entry["notes"] = notes
entry.update({
    "build": int(build), "date": now.astimezone().strftime("%Y-%m-%d"), "published": now.isoformat(),
    "dmg": dmg, "length": int(length), "sha256": sha, "edSignature": sig,
    "minimumSystemVersion": data["minimumSystemVersion"], "notarized": notarized == "1",
})
data["releases"].sort(key=lambda r: int(r.get("build", 0)), reverse=True)
json.dump(data, open(path, "w"), ensure_ascii=False, indent=2)
open(path, "a").write("\n")
PY

print "\n完成：$dmg"
print "SHA-256 $sha256 · $length 字节"
print "发布：Scripts/deploy-website.sh --artifacts ${out#$repo/}"
