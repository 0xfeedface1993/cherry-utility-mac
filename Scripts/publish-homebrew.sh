#!/bin/zsh
# 把 release.sh 渲染好的两个 cask 发布到自建 tap（默认 0xfeedface1993/homebrew-tap），之后用户这样安装：
#
#   brew install --cask 0xfeedface1993/tap/cherry-utility   # App
#   brew install --cask 0xfeedface1993/tap/cherry-cli       # 独立命令行 cherry
#
#   Scripts/publish-homebrew.sh [--dry-run] .release/<版本>-<build>
#
# 1. cask 的下载地址是 GitHub Release v<版本> 的附件：Release 必须已发布（不是草稿或预发布），附件
#    CherryUtility-<版本>.dmg 与 cherry-<版本>.zip 的 digest 与目录里的 .sha256 一致。
# 2. 目录里的 cherry-utility.rb / cherry-cli.rb 必须与按 Packaging/homebrew/ 模板重新渲染的结果一致。
# 3. tap 的本地克隆在 .release/tools/homebrew-tap（CHERRY_TAP_DIR 可改），先 fast-forward 到远端；放进临时 tap 后联网跑
#    brew style、brew audit --cask --strict --online（下载并核对 sha256）和 brew livecheck（最新的 GitHub Release 应是本版本）。
# 4. 提交并推送 tap；cask 没有变化时不提交。--dry-run 只做到第 3 步。
# 临时文件放在 .release/ 下，避开会被定期清理的 $TMPDIR。退出码：0 成功，1 检查失败，64 用法错误。
set -euo pipefail

repo="${0:A:h:h}"
tap_repo="${CHERRY_TAP_REPO:-0xfeedface1993/homebrew-tap}"
tap_dir="${CHERRY_TAP_DIR:-$repo/.release/tools/homebrew-tap}"
dry_run=0
inputs=()
while (( $# )); do
  case "$1" in
    --dry-run) dry_run=1; shift ;;
    -h|--help) sed -n '2,15p' "$0"; exit 0 ;;
    -*) print -u2 "unknown option: $1"; exit 64 ;;
    *) inputs+=("$1"); shift ;;
  esac
done
(( ${#inputs} == 1 )) || { sed -n '2,15p' "$0"; exit 64; }
out="${inputs[1]:A}"
for tool in brew gh git; do command -v "$tool" >/dev/null || { print -u2 "需要 $tool"; exit 69; }; done
export HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_ANALYTICS=1 HOMEBREW_NO_ENV_HINTS=1 HOMEBREW_NO_INSTALL_CLEANUP=1

step() { print "\n==> $*"; }
die() { print -u2 "  ✗ $*"; exit 1; }

casks=(cherry-utility cherry-cli)
for cask in $casks; do [[ -f "$out/$cask.rb" ]] || { print -u2 "missing $out/$cask.rb"; exit 66; }; done
version="$(sed -nE 's/^  version "([^"]+)"$/\1/p' "$out/cherry-utility.rb")"
[[ -n "$version" ]] || die "读不出 cherry-utility.rb 的版本"
[[ "$(sed -nE 's/^  version "([^"]+)"$/\1/p' "$out/cherry-cli.rb")" == "$version" ]] || die "两个 cask 的版本不同"
source_repo="$(sed -nE 's|^  url "https://github.com/([^/]+/[^/]+)/releases/download/.*|\1|p' "$out/cherry-utility.rb")"
[[ -n "$source_repo" ]] || die "cherry-utility.rb 的 url 不是 GitHub Release 附件"
tag="v$version"
files=("CherryUtility-$version.dmg" "cherry-$version.zip")

work="$(mktemp -d "$repo/.release/.publish-homebrew.XXXXXX")"
verify_tap="cherry-verify/publish-$$"
verify_dir=""
cleanup() {
  if [[ -n "$verify_dir" ]]; then
    brew untap --force "$verify_tap" >/dev/null 2>&1 || true
    [[ "$verify_dir" == */Library/Taps/cherry-verify/homebrew-publish-* && -d "$verify_dir" ]] && rm -rf "$verify_dir"
    rmdir "${verify_dir:h}" 2>/dev/null || true
  fi
  rm -rf "$work"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

step "cask 与模板（$version）"
for pair in cherry-utility:"${files[1]}" cherry-cli:"${files[2]}"; do
  cask="${pair%%:*}"; file="${pair#*:}"
  [[ -f "$out/$file.sha256" ]] || die "缺少 $out/$file.sha256"
  sha="$(cut -d' ' -f1 "$out/$file.sha256")"
  # 与 release.sh 的 render_cask 相同：顶格 # 说明行不进入结果。
  sed -e '/^#/d' -e "s|{{VERSION}}|$version|g" -e "s|{{SHA256}}|$sha|g" "$repo/Packaging/homebrew/$cask.rb.template" > "$work/$cask.rb"
  cmp -s "$work/$cask.rb" "$out/$cask.rb" || die "$cask.rb 与按当前模板和 $file.sha256 渲染的结果不同（模板改过就先重新渲染）"
  print "  ✓ $cask.rb（sha256 $sha）"
done

step "GitHub Release $source_repo $tag"
release="$(gh api "repos/$source_repo/releases/tags/$tag" 2>/dev/null)" || die "还没有 Release $tag：先建 Release 并附上 ${files[*]}"
[[ "$(print -r -- "$release" | jq -r '.draft or .prerelease')" == false ]] || die "$tag 是草稿或预发布"
for file in $files; do
  expected="sha256:$(cut -d' ' -f1 "$out/$file.sha256")"
  actual="$(print -r -- "$release" | jq -r --arg name "$file" '.assets[] | select(.name == $name) | .digest')"
  [[ -n "$actual" ]] || die "$tag 没有附件 $file"
  [[ "$actual" == "$expected" ]] || die "$tag 的 $file digest 是 $actual，本地是 $expected"
  print "  ✓ $file 的 digest 与本地一致"
done

step "tap $tap_repo"
if [[ -d "$tap_dir/.git" ]]; then
  [[ -z "$(git -C "$tap_dir" status --porcelain)" ]] || die "$tap_dir 有未提交的改动"
  git -C "$tap_dir" pull --quiet --ff-only
else
  mkdir -p "${tap_dir:h}"
  gh repo clone "$tap_repo" "$tap_dir" -- --quiet
fi
branch="$(git -C "$tap_dir" symbolic-ref --short HEAD)"
print "  本地克隆 ${tap_dir#$repo/}（$branch，$(git -C "$tap_dir" rev-parse --short HEAD)）"
mkdir -p "$tap_dir/Casks"
for cask in $casks; do cp "$out/$cask.rb" "$tap_dir/Casks/$cask.rb"; done

step "联网检查"
brew tap-new --no-git "$verify_tap" >/dev/null
verify_dir="$(brew --repo "$verify_tap")"
mkdir -p "$verify_dir/Casks"
for cask in $casks; do cp "$out/$cask.rb" "$verify_dir/Casks/"; done
targets=("$verify_tap/cherry-utility" "$verify_tap/cherry-cli")
brew style --cask $targets || die "brew style"
print "  ✓ brew style"
HOMEBREW_CACHE="$work/brew-cache" brew audit --cask --strict --online $targets || die "brew audit --online"
print "  ✓ brew audit --cask --strict --online（下载并核对 sha256）"
livecheck="$(brew livecheck --cask --json $targets)" || die "brew livecheck"
latest="$(print -r -- "$livecheck" | jq -r '[.[].version.latest] | unique | join(" ")')"
[[ "$latest" == "$version" ]] || die "livecheck 读到最新版本是 $latest，不是 $version"
print "  ✓ brew livecheck：最新的 GitHub Release 是 $version"

step "提交"
if [[ -z "$(git -C "$tap_dir" status --porcelain -- Casks)" ]]; then
  print "  tap 里已经是 $version，不需要提交"
  exit 0
fi
git -C "$tap_dir" --no-pager diff --stat -- Casks
if (( dry_run )); then
  git -C "$tap_dir" stash push --quiet --include-untracked -- Casks
  git -C "$tap_dir" stash drop --quiet
  print "  --dry-run：没有提交，已还原 tap 的本地克隆"
  exit 0
fi
# tap 与主仓库一样只用 GitHub noreply 邮箱提交。
email="$(git -C "$repo" config user.email)"
[[ "$email" == *@users.noreply.github.com ]] || die "主仓库的 user.email 不是 GitHub noreply 邮箱：$email"
git -C "$tap_dir" config user.name "$(git -C "$repo" config user.name)"
git -C "$tap_dir" config user.email "$email"
git -C "$tap_dir" add -- Casks
git -C "$tap_dir" commit --quiet -m "cherry-utility $version, cherry-cli $version"
git -C "$tap_dir" push --quiet origin "$branch"
print "  ✓ 已推送 $tap_repo $(git -C "$tap_dir" rev-parse --short HEAD)"
print "\n安装：brew install --cask ${tap_repo%%/*}/${${tap_repo#*/}#homebrew-}/cherry-utility"
