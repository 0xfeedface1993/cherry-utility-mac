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
# 另有独立命令行 cherry-<version>.zip（只含通用二进制 cherry）及其 .sha256，与 DMG 分别提交公证；命令行二进制不能
# staple，公证记录在 Apple 服务器端，用 spctl --assess --type open（主签名）与 codesign --check-notarization 核对。按 Packaging/homebrew/ 的模板渲染
# cherry-utility.rb 与 cherry-cli.rb（版本与 sha256 已填好），可用 Scripts/verify-cask.sh 校验。
# CHERRY_RELEASE_OUTPUT overrides that folder; CHERRY_DERIVED_DATA reuses an earlier run's build cache
# (default <output>/DerivedData, a clean universal build that takes several minutes).
# --resume keeps the DMG of an interrupted run and continues at notarization; an accepted submission recorded in
# notary-submission.json for the same DMG hash is not uploaded again (stapler still checks the ticket against the DMG).
# zip 同理（notary-submission-cli.json）；中断前还没打出 zip 时，用归档里已签名的 cherry 补打。
# --skip-notarize 是试跑：照常产出 DMG、zip 和 cask，但不提交公证、不写 releases.json。
# Publish afterwards with: Scripts/deploy-website.sh --artifacts .release/<version>-<build>
# A missing credential stops the script; it never reports a release that was not signed and notarized.
set -euo pipefail

repo="${0:A:h:h}"
env_file="${CHERRY_RELEASE_ENV:-$HOME/Documents/开发密钥/CherryUtility-release.env}"
[[ -f "$env_file" ]] && source "$env_file"

version="${1:-}"; build="${2:-}"
[[ "$version" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' && "$build" =~ '^[0-9]+$' ]] || { sed -n '2,19p' "$0"; exit 64; }
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
cli="$app/Contents/MacOS/cherry"
cli_zip_name="cherry-$version.zip"
cli_zip="$out/$cli_zip_name"
cli_check="$out/.cli-check"
mkdir -p "$out"

step() { print "\n==> $*"; }

# 独立命令行的 zip 只放一个文件 cherry（归档 App 里已用 Developer ID 重签的那份），不带资源分叉和扩展属性，
# Homebrew 的 binary "cherry" 直接指向它。
pack_cli() {
  rm -f "$cli_zip"
  ditto -c -k --norsrc --noextattr "$cli" "$cli_zip"
}

# 解出 zip 再核对：签名、公证与 Gatekeeper 看的都是用户实际拿到的那一份，并确认它就是归档里的 cherry。
unpack_cli() {
  [[ "$(zipinfo -1 "$cli_zip")" == cherry ]] || { print -u2 "${cli_zip:t} must contain only cherry"; exit 1; }
  rm -rf "$cli_check"
  mkdir -p "$cli_check"
  ditto -x -k "$cli_zip" "$cli_check"
  cmp -s "$cli" "$cli_check/cherry" || { print -u2 "${cli_zip:t} does not hold the archived cherry"; exit 1; }
  codesign --verify --strict --verbose=2 "$cli_check/cherry"
}

# 提交公证并等结果：<文件> <提交记录> <失败日志>。记录里同一 SHA-256 已 Accepted 的提交不再上传。
notarize_file() {
  local file="$1" record="$2" log="$3" file_sha notary_id result notary_status
  file_sha="$(shasum -a 256 "$file" | cut -d' ' -f1)"
  notary_id="$(python3 - "$record" "$file_sha" <<'PY'
import json, os, sys
path, sha = sys.argv[1:]
r = json.load(open(path)) if os.path.exists(path) else {}
print(r.get("id", "") if r.get("sha256") == sha and r.get("status") == "Accepted" else "")
PY
  )"
  if [[ -n "$notary_id" ]]; then
    result="$(xcrun notarytool info "$notary_id" "${notary_auth[@]}" --output-format json)"
  else
    result="$(xcrun notarytool submit "$file" "${notary_auth[@]}" --wait --output-format json)"
  fi
  # zsh reserves $status, hence notary_status.
  notary_status="$(python3 - "$record" "$file_sha" "$result" <<'PY'
import json, sys
path, sha, result = sys.argv[1:]
r = json.loads(result)
json.dump({"id": r.get("id"), "status": r.get("status"), "sha256": sha}, open(path, "w"), indent=2)
print(r.get("status") or "")
PY
  )"
  notary_id="$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["id"] or "")' "$record")"
  print "${file:t}: $notary_status $notary_id"
  if [[ "$notary_status" != "Accepted" ]]; then
    [[ -n "$notary_id" ]] && xcrun notarytool log "$notary_id" "${notary_auth[@]}" "$log" || true
    print -u2 "notarization of ${file:t} failed ($notary_status); log: $log"; exit 1
  fi
}

# 按 Packaging/homebrew/<名称>.rb.template 渲染 cask：<名称> <sha256>。顶格的 # 说明行不进入结果。
render_cask() {
  sed -e '/^#/d' -e "s|{{VERSION}}|$version|g" -e "s|{{SHA256}}|$2|g" "$repo/Packaging/homebrew/$1.rb.template" > "$out/$1.rb"
  if grep -q '{{' "$out/$1.rb"; then print -u2 "unfilled placeholder in $1.rb"; exit 1; fi
  print "$out/$1.rb"
}

if (( resume )); then
  step "继续 $version ($build)：沿用 ${dmg:t}"
  [[ -f "$dmg" && -d "$app" ]] || { print -u2 "nothing to resume in $out"; exit 1; }
  codesign --verify --verbose=2 "$dmg"
  [[ -x "$cli" ]] || { print -u2 "missing command-line tool: $cli"; exit 2; }
  if [[ ! -f "$cli_zip" ]]; then
    print "缺少 ${cli_zip:t}：用归档里已签名的 cherry 补打"
    pack_cli
  fi
  unpack_cli
else
  rm -rf "$archive" "$dmg" "$dmg.sha256" "$out/notary-submission.json" \
         "$cli_zip" "$cli_zip.sha256" "$out/notary-submission-cli.json" "$cli_check" "$out/cherry-utility.rb" "$out/cherry-cli.rb"

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
  # 命令行工具（Contents/MacOS/cherry）：公证要求每个可执行文件都有 Developer ID、安全时间戳和 Hardened Runtime。
  [[ -x "$cli" ]] || { print -u2 "missing command-line tool: $cli"; exit 2; }
  cli_archs="$(lipo -archs "$cli")"
  [[ "$cli_archs" == *arm64* && "$cli_archs" == *x86_64* ]] || { print -u2 "expected a universal cherry, got: $cli_archs"; exit 1; }
  codesign --force --options runtime --timestamp --sign "$DEVELOPER_ID_APPLICATION" --identifier online.odeployer.CherryUtility.cli "$cli"
  codesign --force --options runtime --timestamp --sign "$DEVELOPER_ID_APPLICATION" --preserve-metadata=identifier,entitlements,flags "$app"
  codesign --verify --deep --strict --verbose=2 "$app"
  # Capture before matching: with pipefail, `codesign | grep -q` fails (SIGPIPE) exactly when grep finds a match.
  entitlements="$(codesign -d --entitlements - --xml "$app" 2>/dev/null || true)"
  [[ "$entitlements" != *get-task-allow* ]] || { print -u2 "release build carries get-task-allow"; exit 1; }
  signature_info="$(codesign -dv "$app" 2>&1)"
  [[ "$signature_info" == *"flags=0x10000(runtime)"* ]] || { print -u2 "hardened runtime flag missing"; exit 1; }
  cli_signature="$(codesign -dv "$cli" 2>&1)"
  [[ "$cli_signature" == *"flags=0x10000(runtime)"* ]] || { print -u2 "hardened runtime flag missing on cherry"; exit 1; }

  step "制作 DMG"
  "$repo/Scripts/make-dmg.sh" "$app" "$dmg"
  codesign --force --timestamp --sign "$DEVELOPER_ID_APPLICATION" "$dmg"
  codesign --verify --verbose=2 "$dmg"

  step "打包独立命令行 ${cli_zip:t}"
  pack_cli
  unpack_cli
fi

if (( notarize )); then
  step "公证（Apple notary service）"
  if (( resume )) && xcrun stapler validate -q "$dmg" 2>/dev/null; then
    print "DMG 已附公证票据，跳过提交"
  else
    notarize_file "$dmg" "$out/notary-submission.json" "$out/notary-log.json"
    xcrun stapler staple "$dmg"
    xcrun stapler validate "$dmg"
  fi
  spctl --assess --type open --context context:primary-signature --verbose=2 "$dmg"

  # 命令行二进制不能 staple：公证记录只在 Apple 服务器端，Gatekeeper 联网查询；刚通过时可能要稍等才查得到。
  # `spctl --type execute` 只评估 App 包，对单独的可执行文件总是报「does not seem to be an app」；
  # 用 open 类型按主签名评估（要求来源是 Notarized Developer ID），再由 codesign 向 Apple 查询公证记录。
  notarize_file "$cli_zip" "$out/notary-submission-cli.json" "$out/notary-log-cli.json"
  for attempt in 1 2 3 4 5 6; do
    # 先取得输出再匹配：脚本开了 pipefail，`spctl | grep -q` 在 grep 提前退出时整条管道会算失败。
    assessment="$(spctl --assess --type open --context context:primary-signature --verbose=2 "$cli_check/cherry" 2>&1 || true)"
    print -r -- "$assessment"
    [[ "$assessment" == *"source=Notarized Developer ID"* ]] \
      && codesign --verify -R=notarized --check-notarization "$cli_check/cherry" && break
    (( attempt < 6 )) || { print -u2 "Gatekeeper does not accept the notarized cherry"; exit 1; }
    print "Gatekeeper 暂未查到 cherry 的公证记录，10 秒后重试"
    sleep 10
  done
fi
rm -rf "$cli_check"

step "校验值与 Sparkle 签名"
(cd "$out" && shasum -a 256 "$dmg_name" > "$dmg_name.sha256" && shasum -a 256 "$cli_zip_name" > "$cli_zip_name.sha256")
sha256="$(cut -d' ' -f1 "$dmg.sha256")"
cli_sha256="$(cut -d' ' -f1 "$cli_zip.sha256")"
cli_length="$(stat -f%z "$cli_zip")"
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

step "渲染 Homebrew cask"
render_cask cherry-utility "$sha256"
render_cask cherry-cli "$cli_sha256"

if (( ! notarize )); then
  print "\n试跑完成（未公证，不写入 releases.json）：$dmg"
  print "命令行：$cli_zip"
  exit 0
fi

step "写入 Website/releases.json"
python3 - "$repo/Website/releases.json" "$version" "$build" "$dmg_name" "$length" "$sha256" "$ed_signature" "$notarize" \
  "$cli_zip_name" "$cli_length" "$cli_sha256" "${notes[@]}" <<'PY'
import json, sys
from datetime import datetime, timezone
path, version, build, dmg, length, sha, sig, notarized, cli_zip, cli_length, cli_sha, *notes = sys.argv[1:]
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
    "cliZip": cli_zip, "cliLength": int(cli_length), "cliSha256": cli_sha,
    "minimumSystemVersion": data["minimumSystemVersion"], "notarized": notarized == "1",
})
data["releases"].sort(key=lambda r: int(r.get("build", 0)), reverse=True)
json.dump(data, open(path, "w"), ensure_ascii=False, indent=2)
open(path, "a").write("\n")
PY

print "\n完成：$dmg"
print "SHA-256 $sha256 · $length 字节"
print "命令行：$cli_zip"
print "SHA-256 $cli_sha256 · $cli_length 字节"
print "核对 cask：Scripts/verify-cask.sh --release ${dmg#$repo/} ${cli_zip#$repo/}"
print "发布：Scripts/deploy-website.sh --artifacts ${out#$repo/}"
