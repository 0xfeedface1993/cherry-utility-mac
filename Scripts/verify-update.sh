#!/bin/zsh
# Sparkle end-to-end check that never launches CHERRY Utility.
#
#   Scripts/verify-update.sh <old.dmg> <new.dmg>   install <new> over a copy of the app in <old> through a local feed
#   Scripts/verify-update.sh --public <old.dmg>     ask the public appcast (the SUFeedURL baked into the app) what it offers
#
# The app copy lives in .release/update-check/<run>/Applications. Sparkle's own command-line driver (sparkle-cli, built
# once from the resolved Sparkle checkout into .release/tools) runs the real update path: appcast parsing, version
# comparison, download, EdDSA verification against the old app's SUPublicEDKey, code-signing continuity, installation.
# The local appcast is produced by Website/build.py's own generator, so the published format is what gets tested.
# <new.dmg> needs the `<new.dmg>.sparkle-signature.txt` that Scripts/release.sh writes (a --skip-notarize run is enough).
# Sparkle keeps check state in the app's defaults domain and cache folder; whatever this run adds there is removed.
set -euo pipefail

repo="${0:A:h:h}"
bundle_id="online.odeployer.CherryUtility"
public=0
if [[ "${1:-}" == "--public" ]]; then public=1; shift; fi
if (( public )); then
  (( $# == 1 )) || { print -u2 "usage: $0 --public <old.dmg>"; exit 64; }
else
  (( $# == 2 )) || { print -u2 "usage: $0 <old.dmg> <new.dmg> | $0 --public <old.dmg>"; exit 64; }
fi
old_dmg="${1:A}"
[[ -f "$old_dmg" ]] || { print -u2 "missing $old_dmg"; exit 66; }
new_dmg=""
if (( ! public )); then
  new_dmg="${2:A}"
  [[ -f "$new_dmg" && -f "$new_dmg.sparkle-signature.txt" ]] || { print -u2 "missing $new_dmg or its .sparkle-signature.txt"; exit 66; }
fi

step() { print "\n==> $*"; }
plist_value() { /usr/libexec/PlistBuddy -c "Print $2" "$1/Contents/Info.plist"; }

tools="$repo/.release/tools"
cli="$tools/sparkle.app/Contents/MacOS/sparkle"
if [[ ! -x "$cli" ]]; then
  checkouts=( "$repo"/.release/*/DerivedData/SourcePackages/checkouts/Sparkle(N/)
              ~/Library/Developer/Xcode/DerivedData/CherryUtility-*/SourcePackages/checkouts/Sparkle(N/) )
  (( ${#checkouts} )) || { print -u2 "no resolved Sparkle checkout; build the app once first"; exit 2; }
  step "构建 sparkle-cli（${checkouts[1]}）"
  xcodebuild build -quiet -project "${checkouts[1]}/Sparkle.xcodeproj" -scheme sparkle-cli -configuration Release \
    -destination "platform=macOS" -derivedDataPath "$tools/sparkle-cli-dd" \
    CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=
  rm -rf "$tools/sparkle.app"
  ditto "$tools/sparkle-cli-dd/Build/Products/Release/sparkle.app" "$tools/sparkle.app"
fi

run="$repo/.release/update-check/$(date +%Y%m%d-%H%M%S)"
app="$run/Applications/CherryUtility.app"
mkdir -p "$run/Applications"
mounts=()
server_pid=""
defaults_before=""
cache="$HOME/Library/Caches/$bundle_id"
had_cache=0
[[ -e "$cache" ]] && had_cache=1

restore_sparkle_state() {
  [[ -n "$defaults_before" ]] || return 0
  python3 - "$bundle_id" "$defaults_before" <<'PY'
import plistlib, subprocess, sys
from datetime import datetime, timezone
domain, before_path = sys.argv[1:]
before = plistlib.load(open(before_path, "rb"))
out = subprocess.run(["defaults", "export", domain, "-"], capture_output=True, check=True).stdout
after = plistlib.loads(out) if out else {}
for key, value in after.items():
    if not key.startswith("SU") or before.get(key) == value:
        continue
    if key not in before:
        subprocess.run(["defaults", "delete", domain, key], check=True)
        continue
    old = before[key]
    typed = (["-bool", "true" if old else "false"] if isinstance(old, bool) else
             ["-int", str(old)] if isinstance(old, int) else
             ["-float", repr(old)] if isinstance(old, float) else
             ["-string", old] if isinstance(old, str) else
             ["-date", old.astimezone(timezone.utc).strftime("%Y-%m-%d %H:%M:%S +0000")] if isinstance(old, datetime) else None)
    if typed is None:
        print(f"warning: could not restore {key} ({type(old).__name__})", file=sys.stderr)
    else:
        subprocess.run(["defaults", "write", domain, key, *typed], check=True)
PY
  if (( ! had_cache )) && [[ -e "$cache" ]]; then rm -rf "$cache"; fi
}

cleanup() {
  [[ -n "$server_pid" ]] && kill "$server_pid" 2>/dev/null || true
  for m in "${mounts[@]}"; do hdiutil detach -quiet "$m" 2>/dev/null || true; done
  restore_sparkle_state
}
trap cleanup EXIT

mount_dmg() {  # sets REPLY to the mount point
  REPLY="$run/mnt-${#mounts}"
  mkdir -p "$REPLY"
  hdiutil attach -quiet -nobrowse -noautoopen -readonly -mountpoint "$REPLY" "$1"
  mounts+=("$REPLY")
}

step "复制旧版 App（${old_dmg:t}）"
mount_dmg "$old_dmg"
ditto "$REPLY/CherryUtility.app" "$app"
old_version="$(plist_value "$app" CFBundleShortVersionString)"
old_build="$(plist_value "$app" CFBundleVersion)"
old_team="$(codesign -dv "$app" 2>&1 | sed -nE 's/^TeamIdentifier=//p')"
print "旧版 $old_version ($old_build)，Team $old_team，feed $(plist_value "$app" SUFeedURL)"

defaults_before="$run/defaults-before.plist"
defaults export "$bundle_id" "$defaults_before"

if (( public )); then
  step "向公开 appcast 询问（--probe，只读）"
  set +e
  "$cli" "$app" --probe --verbose 2>&1 | tee "$run/sparkle-probe.log"
  rc=${pipestatus[1]}
  set -e
  case $rc in
    0) print "\n结果：公开 appcast 为 $old_version ($old_build) 提供了更新。" ;;
    4) print "\n结果：公开 appcast 可读，$old_version ($old_build) 已是最新。" ;;
    *) print -u2 "\nsparkle-cli exited with $rc"; exit 1 ;;
  esac
  exit 0
fi

step "准备本地 feed（${new_dmg:t}）"
mount_dmg "$new_dmg"
new_version="$(plist_value "$REPLY/CherryUtility.app" CFBundleShortVersionString)"
new_build="$(plist_value "$REPLY/CherryUtility.app" CFBundleVersion)"
min_os="$(plist_value "$REPLY/CherryUtility.app" LSMinimumSystemVersion)"
(( new_build > old_build )) || { print -u2 "new build $new_build is not newer than $old_build"; exit 1; }
signature_line="$(<"$new_dmg.sparkle-signature.txt")"
ed_signature="$(print "$signature_line" | sed -nE 's/.*sparkle:edSignature="([^"]+)".*/\1/p')"
length="$(stat -f%z "$new_dmg")"
mkdir -p "$run/feed/downloads"
cp -c "$new_dmg" "$run/feed/downloads/${new_dmg:t}"
port="$(python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')"
feed_url="http://127.0.0.1:$port/appcast.xml"
python3 - "$repo/Website/build.py" "$run/feed/appcast.xml" "http://127.0.0.1:$port/" "$new_version" "$new_build" \
  "${new_dmg:t}" "$length" "$ed_signature" "$min_os" <<'PY'
import importlib.util, sys
source, out, base, version, build, dmg, length, signature, min_os = sys.argv[1:]
spec = importlib.util.spec_from_file_location("site_build", source)
site = importlib.util.module_from_spec(spec)
spec.loader.exec_module(site)
release = {"version": version, "build": int(build), "notes": ["本地更新链路检查。"], "dmg": dmg, "length": int(length),
           "sha256": "-", "edSignature": signature, "notarized": True, "minimumSystemVersion": min_os}
open(out, "w").write(site.appcast({"product": "CHERRY Utility", "baseURL": base, "minimumSystemVersion": min_os,
                                    "releases": [release]}))
PY
python3 -m http.server "$port" --bind 127.0.0.1 --directory "$run/feed" >"$run/http.log" 2>&1 &
server_pid=$!
for _ in {1..50}; do curl -fsS -o /dev/null "$feed_url" 2>/dev/null && break; sleep 0.1; done

step "Sparkle 检查、下载、校验并安装 $new_version ($new_build)（不启动 App）"
set +e
"$cli" "$app" --check-immediately --feed-url "$feed_url" --verbose 2>&1 | tee "$run/sparkle-install.log"
rc=${pipestatus[1]}
set -e
(( rc == 0 )) || { print -u2 "sparkle-cli exited with $rc"; exit 1; }
for _ in {1..100}; do [[ "$(plist_value "$app" CFBundleVersion)" == "$new_build" ]] && break; sleep 0.2; done

step "验证安装结果"
installed="$(plist_value "$app" CFBundleShortVersionString) ($(plist_value "$app" CFBundleVersion))"
[[ "$installed" == "$new_version ($new_build)" ]] || { print -u2 "app is still $installed"; exit 1; }
codesign --verify --deep --strict "$app"
new_team="$(codesign -dv "$app" 2>&1 | sed -nE 's/^TeamIdentifier=//p')"
[[ "$new_team" == "$old_team" ]] || { print -u2 "team changed: $old_team -> $new_team"; exit 1; }
grep -q "GET /downloads/${new_dmg:t}" "$run/http.log" || { print -u2 "the update was not downloaded from the feed"; exit 1; }
set +e
"$cli" "$app" --probe --feed-url "$feed_url" >"$run/sparkle-reprobe.log" 2>&1
rc=$?
set -e
(( rc == 4 )) || { print -u2 "after installing, Sparkle still offers an update (exit $rc)"; exit 1; }
print "\n通过：$old_version ($old_build) → $installed；签名有效，Team $new_team 一致；再次检查无更新。记录在 ${run#$repo/}"
