#!/bin/zsh
# 用本地的 DMG 和 zip 校验 Packaging/homebrew/ 的两个 cask（cherry-utility、cherry-cli），不安装任何东西。
#
#   Scripts/verify-cask.sh [--release] <CherryUtility-<版本>.dmg> <cherry-<版本>.zip>
#
# 1. 产物：DMG 内有 cask 的 app 写的 CherryUtility.app，Finder 里显示为 cask 的 name（CHERRY Utility），zip 里只有 cherry；两份 cherry 字节相同、都是 arm64 + x86_64，
#    codesign --verify 通过，标识 online.odeployer.CherryUtility.cli、带 Hardened Runtime；最低系统与 depends_on 一致。
# 2. cask：按 App 的版本和两个文件的 sha256 渲染模板，在临时本地 tap 里对正式 url 的版本跑 brew style；再把 url 改成
#    file:// 指向本地副本，跑 brew audit --cask --strict（只含离线检查）和 brew fetch（由 Homebrew 自己核对 sha256）。
# 3. Developer ID、公证与 Gatekeeper：与 homebrew/cask 签名审核相同的 gktool scan（带隔离属性）和
#    codesign --check-notarization，再加 spctl。开发签名或尚未公证的产物记为「待发布」，不算失败；
#    --release 时算失败，用于 release.sh 公证后的正式产物。
# 结束时 untap、删除临时 tap 并卸载 DMG；HOMEBREW_CACHE 只在 brew fetch 时指向临时目录。
# 临时文件放在 .release/ 下（CHERRY_VERIFY_WORK 可改），避开会被定期清理的 $TMPDIR。
# 退出码：0 没有失败项（可能有待发布项），1 有失败项，64 用法错误。
set -euo pipefail

repo="${0:A:h:h}"
release=0
inputs=()
while (( $# )); do
  case "$1" in
    --release) release=1; shift ;;
    -h|--help) sed -n '2,15p' "$0"; exit 0 ;;
    -*) print -u2 "unknown option: $1"; exit 64 ;;
    *) inputs+=("$1"); shift ;;
  esac
done
(( ${#inputs} == 2 )) || { sed -n '2,15p' "$0"; exit 64; }
dmg="${inputs[1]:A}"; zip="${inputs[2]:A}"
[[ -f "$dmg" ]] || { print -u2 "missing $dmg"; exit 66; }
[[ -f "$zip" ]] || { print -u2 "missing $zip"; exit 66; }
command -v brew >/dev/null || { print -u2 "需要 Homebrew"; exit 69; }
export HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_ANALYTICS=1 HOMEBREW_NO_ENV_HINTS=1 HOMEBREW_NO_INSTALL_CLEANUP=1

templates="$repo/Packaging/homebrew"
work_root="${CHERRY_VERIFY_WORK:-$repo/.release}"
mkdir -p "$work_root"
work="$(mktemp -d "$work_root/.verify-cask.XXXXXX")"
tap="cherry-verify/local-$$"
tap_dir=""
mounted=""

cleanup() {
  [[ -n "$mounted" ]] && { hdiutil detach -quiet "$mounted" 2>/dev/null || hdiutil detach -quiet -force "$mounted" 2>/dev/null || true; }
  # 挂载成功但没解析出挂载点时，按设备卸载。
  if [[ -z "$mounted" && -s "$work/attach.plist" ]]; then
    for device in $(sed -nE 's|.*<string>(/dev/disk[0-9]+)</string>.*|\1|p' "$work/attach.plist" | sort -u); do
      hdiutil detach -quiet "$device" 2>/dev/null || true
    done
  fi
  if [[ -n "$tap_dir" ]]; then
    brew untap --force "$tap" >/dev/null 2>&1 || true
    [[ "$tap_dir" == */Library/Taps/cherry-verify/homebrew-local-* && -d "$tap_dir" ]] && rm -rf "$tap_dir"
    rmdir "${tap_dir:h}" 2>/dev/null || true
  fi
  rm -rf "$work"
}
# zsh 的 set -e 若由函数的返回值触发，不会执行 EXIT trap：函数里的失败一律显式 exit（见 finish 的调用处）。
trap cleanup EXIT
trap 'exit 130' INT TERM

passed=(); failed=(); pending=(); notes=()
step() { print "\n==> $*"; }
pass() { passed+=("$1"); print "  ✓ $1"; }
fail() { failed+=("$1"); print "  ✗ $1"; }
pend() { pending+=("$1"); print "  … 待发布：$1"; }
note() { notes+=("$1"); print "  ! 注意：$1"; }
indent() { print -r -- "$1" | tr '\r' '\n' | grep -v -e '^Progress:' -e '^[[:space:]]*$' | sed -n '1,12p' | sed 's/^/      /' || true; }

# <描述> <命令…>：命令成功记为通过，否则记为失败并附上输出。
check() {
  local desc="$1" output; shift
  if output="$("$@" 2>&1)"; then pass "$desc"; else fail "$desc"; indent "$output"; fi
}

# 同 check，但只有 Developer ID 签名并公证的产物才能通过：其余情况记为待发布（--release 时为失败）。
gate() {
  local desc="$1" output; shift
  if output="$("$@" 2>&1)"; then pass "$desc"
  elif (( release )); then fail "$desc"; indent "$output"
  else pend "$desc"; indent "$output"
  fi
}

finish() {
  step "结果"
  print "通过 ${#passed} 项 · 失败 ${#failed} 项 · 待发布 ${#pending} 项 · 注意 ${#notes} 项"
  if (( ${#failed} )); then
    print "\n失败："
    for item in "${failed[@]}"; do print "  - $item"; done
  fi
  if (( ${#pending} )); then
    print "\n待发布（需要 release.sh 用 Developer ID 签名、提交公证后的正式产物；届时加 --release 重跑）："
    for item in "${pending[@]}"; do print "  - $item"; done
  fi
  if (( ${#notes} )); then
    print "\n注意："
    for item in "${notes[@]}"; do print "  - $item"; done
  fi
  print "\n发布后才能核对（官网已上线 ${version:-<版本>}，releases/latest.json 带 cli 段）：把渲染好的 cask 放进 tap 或"
  print "homebrew-cask 的 PR 分支后跑 brew audit --cask --new 与 brew livecheck --cask（下载、主页、livecheck、最低系统均需联网）。"
  (( ${#failed} == 0 ))
}

# 签名信息里某个键的值（Authority 取第一条，即签名证书）：<文件> <键>
sig_field() {
  local info line
  info="$(codesign -dv --verbose=2 "$1" 2>&1 || true)"
  for line in "${(@f)info}"; do
    [[ "$line" == "$2="* ]] && { print -r -- "${line#$2=}"; return 0; }
  done
  return 0
}

# 签名者：Developer ID 记为通过；开发签名、ad-hoc 记为待发布并说明。<描述> <文件>
signer() {
  local desc="$1" file="$2" authority
  authority="$(sig_field "$file" Authority)"
  if [[ "$authority" == "Developer ID Application:"* ]]; then
    pass "$desc：$authority"
    if [[ -n "$(sig_field "$file" Timestamp)" ]]; then pass "$desc：带安全时间戳"; else fail "$desc：缺少安全时间戳（公证要求 --timestamp）"; fi
  elif [[ -z "$authority" ]]; then
    gate "$desc：ad-hoc 签名，不是 Developer ID（正式产物由 release.sh 用 Developer ID 重签）" false
  else
    gate "$desc：开发签名（$authority），不是 Developer ID（正式产物由 release.sh 用 Developer ID 重签）" false
  fi
}

# 通用二进制：<描述> <文件>
universal() {
  local archs
  archs="$(lipo -archs "$2" 2>/dev/null | tr ' ' '\n' | sort | xargs || true)"
  if [[ "$archs" == "arm64 x86_64" ]]; then pass "$1：arm64 + x86_64"; else fail "$1：应为 arm64 + x86_64，实际 ${archs:-无法读取}"; fi
}

# cask 的 depends_on macos: 符号对应的系统大版本。
typeset -A macos_major=(big_sur 11 monterey 12 ventura 13 sonoma 14 sequoia 15 tahoe 26)

step "产物"
app_name="$(sed -nE 's/^  app "([^"]+)"$/\1/p' "$templates/cherry-utility.rb.template")"
bin_name="$(sed -nE 's/^  binary "([^"]+)"$/\1/p' "$templates/cherry-cli.rb.template")"
# hdiutil 的弃用警告写在 stderr，只在挂载失败时显示。
hdiutil attach -readonly -nobrowse -noautoopen -plist "$dmg" > "$work/attach.plist" 2> "$work/attach.err" \
  || { cat "$work/attach.err" >&2; exit 1; }
mounted="$(python3 -c '
import plistlib, sys
entities = plistlib.load(open(sys.argv[1], "rb"))["system-entities"]
print(next(e["mount-point"] for e in entities if e.get("mount-point")))' "$work/attach.plist")"
app="$mounted/$app_name"
if [[ -d "$app" ]]; then
  pass "DMG 内有 $app_name（cask 的 app stanza）"
else
  fail "DMG 内没有 $app_name：$(ls "$mounted" | xargs)"; finish || true; exit 1
fi
# Finder 显示的是 App 的本地化显示名（zh-Hans.lproj/InfoPlist.strings），应与 cask 的 name 相同；文件名保持 CherryUtility.app。
cask_name="$(sed -nE 's/^  name "([^"]+)"$/\1/p' "$templates/cherry-utility.rb.template")"
shown="$(osascript -l JavaScript -e 'ObjC.import("Foundation"); function run(argv) { return $.NSFileManager.defaultManager.displayNameAtPath(argv[0]).js }' "$app" 2>/dev/null || true)"
[[ "$shown" == "$cask_name" ]] && pass "Finder 里显示为「$shown」（cask 的 name）" || fail "Finder 里应显示为「$cask_name」，实际「${shown:-无法读取}」"
version="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$app/Contents/Info.plist")"
print "  版本 $version（取自 App 的 CFBundleShortVersionString）"
if [[ "${dmg:t}" == "CherryUtility-$version.dmg" ]]; then pass "DMG 文件名与版本一致"; else fail "DMG 应命名为 CherryUtility-$version.dmg（cask 的 url 按版本拼文件名），实际 ${dmg:t}"; fi
if [[ "${zip:t}" == "cherry-$version.zip" ]]; then pass "zip 文件名与版本一致"; else fail "zip 应命名为 cherry-$version.zip（cask 的 url 按版本拼文件名），实际 ${zip:t}"; fi

entries="$(zipinfo -1 "$zip")"
if [[ "$entries" == "$bin_name" ]]; then pass "zip 里只有 $bin_name（cask 的 binary stanza）"; else fail "zip 里应只有 $bin_name，实际：$(print -r -- "$entries" | xargs)"; fi
mkdir -p "$work/zip"
ditto -x -k "$zip" "$work/zip"
zip_cli="$work/zip/$bin_name"
dmg_cli="$app/Contents/MacOS/cherry"
[[ -f "$zip_cli" ]] || { fail "解压后找不到 $bin_name"; finish || true; exit 1; }
[[ -x "$zip_cli" ]] && pass "zip 里的 cherry 带可执行权限" || fail "zip 里的 cherry 没有可执行权限"
[[ -f "$dmg_cli" ]] || { fail "App 内没有 Contents/MacOS/cherry"; finish || true; exit 1; }
universal "DMG 内 App 的 cherry" "$dmg_cli"
universal "zip 里的 cherry" "$zip_cli"
cmp -s "$dmg_cli" "$zip_cli" && pass "两份 cherry 字节相同" || fail "zip 里的 cherry 与 DMG 内 App 的不是同一个文件"

check "codesign --verify App（--deep --strict）" codesign --verify --deep --strict --verbose=2 "$app"
check "codesign --verify DMG 内 App 的 cherry" codesign --verify --strict --verbose=2 "$dmg_cli"
check "codesign --verify zip 里的 cherry" codesign --verify --strict --verbose=2 "$zip_cli"
if dmg_sig="$(codesign --verify --verbose=2 "$dmg" 2>&1)"; then
  pass "codesign --verify DMG"
elif [[ "$dmg_sig" == *"not signed at all"* ]]; then
  gate "DMG 已签名（正式产物由 release.sh 用 Developer ID 签名）" false
else
  fail "codesign --verify DMG"; indent "$dmg_sig"
fi

cli_id="$(sig_field "$zip_cli" Identifier)"
[[ "$cli_id" == online.odeployer.CherryUtility.cli ]] && pass "cherry 的签名标识 $cli_id" || fail "cherry 的签名标识应为 online.odeployer.CherryUtility.cli，实际 ${cli_id:-无}"
[[ "$(codesign -dv "$zip_cli" 2>&1)" == *"(runtime)"* ]] && pass "cherry 带 Hardened Runtime" || fail "cherry 缺少 Hardened Runtime"
app_team="$(sig_field "$app" TeamIdentifier)"; cli_team="$(sig_field "$zip_cli" TeamIdentifier)"
[[ -n "$cli_team" && "$cli_team" == "$app_team" ]] && pass "App 与 cherry 同一团队 $cli_team" || fail "App（${app_team:-无}）与 cherry（${cli_team:-无}）的团队不同"
signer "App 签名" "$app"
signer "cherry 签名" "$zip_cli"

for cask in cherry-utility cherry-cli; do
  symbol="$(sed -nE 's/^  depends_on macos: :([a-z_]+)$/\1/p' "$templates/$cask.rb.template")"
  if [[ "$cask" == cherry-utility ]]; then
    minos="$(/usr/libexec/PlistBuddy -c 'Print LSMinimumSystemVersion' "$app/Contents/Info.plist" 2>/dev/null || true)"
  else
    minos="$(otool -l "$zip_cli" | awk '/LC_BUILD_VERSION/ { found = 1 } found && $1 == "minos" { print $2; found = 0 }' | sort -V | tail -1)"
  fi
  if [[ -n "$symbol" && "${minos%%.*}" == "${macos_major[$symbol]:-}" ]]; then
    pass "$cask：最低系统 $minos 与 depends_on macos: :$symbol 一致"
  else
    fail "$cask：最低系统 ${minos:-未知} 与 depends_on macos: :${symbol:-无} 不一致"
  fi
done

cli_version="$(launchctl plist __TEXT,__info_plist "$zip_cli" 2>/dev/null | sed -nE 's/^[[:space:]]*"CFBundleShortVersionString" = "([^"]*)";$/\1/p' || true)"
if [[ "$cli_version" == "$version" ]]; then
  pass "独立 cherry 内嵌的版本号 $cli_version"
else
  note "独立 cherry 内嵌的 Info.plist ${cli_version:+版本号为 $cli_version，}${cli_version:-没有 CFBundleShortVersionString}，与 App 的 $version 不符：离开 App 包运行时 cherry --version 显示不出版本"
fi

step "Homebrew cask"
dmg_sha="$(shasum -a 256 "$dmg" | cut -d' ' -f1)"
zip_sha="$(shasum -a 256 "$zip" | cut -d' ' -f1)"
mkdir -p "$work/casks" "$work/downloads"
for cask sha in cherry-utility "$dmg_sha" cherry-cli "$zip_sha"; do
  # 与 release.sh 的 render_cask 相同：顶格 # 说明行不进入结果。
  sed -e '/^#/d' -e "s|{{VERSION}}|$version|g" -e "s|{{SHA256}}|$sha|g" "$templates/$cask.rb.template" > "$work/casks/$cask.rb"
  if grep -q '{{' "$work/casks/$cask.rb"; then fail "$cask.rb 有未填的占位符"; fi
  # 旁边有 release.sh 渲染的 cask 时，确认内容一致。
  if [[ -f "${dmg:h}/$cask.rb" ]]; then
    cmp -s "${dmg:h}/$cask.rb" "$work/casks/$cask.rb" && pass "$cask.rb 与 release.sh 渲染的一致" || fail "${dmg:h}/$cask.rb 与按模板渲染的结果不同"
  fi
done

brew tap-new --no-git "$tap" >/dev/null
tap_dir="$(brew --repo "$tap")"
mkdir -p "$tap_dir/Casks"
cp "$work/casks/cherry-utility.rb" "$work/casks/cherry-cli.rb" "$tap_dir/Casks/"
print "  临时 tap $tap"
check "brew style（正式 url 的 cask）" brew style --cask "$tap/cherry-utility" "$tap/cherry-cli"

# 下载地址改成 file:// 指向本地副本；文件名仍按 #{version} 拼出，所以副本用正式文件名。
cp -c "$dmg" "$work/downloads/CherryUtility-$version.dmg" 2>/dev/null || cp "$dmg" "$work/downloads/CherryUtility-$version.dmg"
cp -c "$zip" "$work/downloads/cherry-$version.zip" 2>/dev/null || cp "$zip" "$work/downloads/cherry-$version.zip"
local_base="$(python3 -c 'import pathlib, sys; print(pathlib.Path(sys.argv[1]).as_uri())' "$work/downloads")/"
for cask in cherry-utility cherry-cli; do
  sed "s|url \"https://odeployer.online/cherry-utility/downloads/|url \"$local_base|" "$work/casks/$cask.rb" > "$tap_dir/Casks/$cask.rb"
  grep -q "url \"$local_base" "$tap_dir/Casks/$cask.rb" || fail "$cask.rb 的 url 没能换成 file://"
done
check "brew audit --cask --strict（file:// 指向本地产物，离线检查）" brew audit --cask --strict "$tap/cherry-utility" "$tap/cherry-cli"
check "brew fetch：Homebrew 下载并核对两个 sha256" env HOMEBREW_CACHE="$work/brew-cache" brew fetch --cask "$tap/cherry-utility" "$tap/cherry-cli"

step "Developer ID、公证与 Gatekeeper"
# homebrew/cask 的签名审核：下载件带隔离属性，App 用 gktool scan，单独的可执行文件用 codesign --check-notarization。
mkdir -p "$work/stage"
ditto "$app" "$work/stage/$app_name"
quarantine="0081;$(printf %x "$(date +%s)");Homebrew Cask;"
xattr -w com.apple.quarantine "$quarantine" "$work/stage/$app_name"
gate "App 通过 Gatekeeper（gktool scan，带隔离属性）" gktool scan "$work/stage/$app_name"
gate "App 已公证（spctl --assess --type execute）" spctl --assess --type execute --verbose=2 "$app"
gate "DMG 附有公证票据（stapler validate）" xcrun stapler validate "$dmg"
gate "DMG 通过 Gatekeeper（spctl --assess --type open）" spctl --assess --type open --context context:primary-signature --verbose=2 "$dmg"
gate "zip 里的 cherry 已公证（codesign --check-notarization，向 Apple 服务器查询）" codesign --verify -R=notarized --check-notarization "$zip_cli"
gate "zip 里的 cherry 通过 Gatekeeper（spctl --assess --type execute）" spctl --assess --type execute --verbose=2 "$zip_cli"

finish || exit 1
