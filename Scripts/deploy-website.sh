#!/bin/zsh
# Builds the website from Website/releases.json and publishes it atomically on this Mac.
#
#   Scripts/deploy-website.sh [--artifacts DIR] [--release-id ID]
#
# Layout under the deploy root (default ~/Library/Application Support/CherryUtility-Website):
#   releases/<id>/   complete site; downloads/ of the previous release are carried forward (APFS clones)
#   current, previous   symlinks switched with an atomic rename — Caddy serves `current`, no reload needed
#   Caddyfile        generated origin config; import it once from the Homebrew Caddyfile
# The public path /cherry-utility is routed here by frpc (proxy "cherry-utility-website").
set -euo pipefail

repo="${0:A:h:h}"
deploy_root="${CHERRY_WEBSITE_DEPLOY_ROOT:-$HOME/Library/Application Support/CherryUtility-Website}"
port="${CHERRY_WEBSITE_PORT:-7904}"
release_id="$(date -u +%Y%m%dT%H%M%SZ)"
artifacts=""

while (( $# )); do
  case "$1" in
    --artifacts) artifacts="${2:?}"; shift 2 ;;
    --release-id) release_id="${2:?}"; shift 2 ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    *) print -u2 "unknown option: $1"; exit 64 ;;
  esac
done

[[ "$release_id" =~ '^[A-Za-z0-9][A-Za-z0-9._-]*$' ]] || { print -u2 "invalid release id: $release_id"; exit 64; }
[[ "$deploy_root" == /* ]] || { print -u2 "deploy root must be absolute"; exit 64; }
case "${deploy_root:A}" in
  /|/tmp|/var|/usr|/opt|/opt/homebrew|"$HOME"|"${repo:A}") print -u2 "refusing broad deploy root: $deploy_root"; exit 64 ;;
esac

mkdir -p "$deploy_root/releases"
target="$deploy_root/releases/$release_id"
[[ ! -e "$target" ]] || { print -u2 "release already exists: $target"; exit 1; }

staging="$deploy_root/releases/.staging-$release_id"
rm -rf "$staging"
build_args=(--out "$staging")
[[ -n "$artifacts" ]] && build_args+=(--artifacts "${artifacts:A}")
python3 "$repo/Website/build.py" "${build_args[@]}"

# Carry forward published DMGs so earlier appcast enclosures and download links keep working.
if [[ -d "$deploy_root/current/downloads" ]]; then
  for f in "$deploy_root/current/downloads"/*(N); do
    name="${f:t}"
    [[ -e "$staging/downloads/$name" ]] || cp -c "$f" "$staging/downloads/$name" 2>/dev/null || cp "$f" "$staging/downloads/$name"
  done
fi

# Every file the manifest promises must exist before the switch.
python3 - "$staging" <<'PY'
import json, pathlib, sys
root = pathlib.Path(sys.argv[1])
latest = json.loads((root / "releases/latest.json").read_text())
if latest["status"] == "published":
    dmg = root / "downloads" / latest["dmg"].rsplit("/", 1)[1]
    if not dmg.is_file() or dmg.stat().st_size != latest["length"]:
        sys.exit(f"missing or wrong-size DMG for the published release: {dmg.name}")
# 页面和 cask cherry-cli 的 livecheck 指向的命令行 zip 也必须在。
cli = latest.get("cli")
if cli:
    zip_path = root / "downloads" / cli["zip"].rsplit("/", 1)[1]
    if not zip_path.is_file() or zip_path.stat().st_size != cli["length"]:
        sys.exit(f"missing or wrong-size command-line zip: {zip_path.name}")
for required in ("index.html", "appcast.xml", "styles.css"):
    if not (root / required).is_file():
        sys.exit(f"missing {required}")
PY

mv "$staging" "$target"

# Atomic switch: previous ← old current, current ← new release.
python3 - "$deploy_root" "releases/$release_id" <<'PY'
import os, sys
root, new = sys.argv[1], sys.argv[2]
cur = os.path.join(root, "current")
if os.path.islink(cur):
    old = os.readlink(cur)
    tmp = os.path.join(root, ".previous.tmp")
    if os.path.lexists(tmp): os.remove(tmp)
    os.symlink(old, tmp)
    os.replace(tmp, os.path.join(root, "previous"))
tmp = os.path.join(root, ".current.tmp")
if os.path.lexists(tmp): os.remove(tmp)
os.symlink(new, tmp)
os.replace(tmp, cur)
PY

sed -e "s|{{DEPLOY_ROOT}}|$deploy_root|g" -e "s|{{PORT}}|$port|g" "$repo/Website/deploy/Caddyfile.template" > "$deploy_root/Caddyfile.new"
if command -v caddy >/dev/null; then
  caddy validate --config "$deploy_root/Caddyfile.new" --adapter caddyfile >/dev/null 2>&1 || { print -u2 "generated Caddyfile is invalid"; exit 1; }
fi
if ! cmp -s "$deploy_root/Caddyfile.new" "$deploy_root/Caddyfile" 2>/dev/null; then
  mv "$deploy_root/Caddyfile.new" "$deploy_root/Caddyfile"
  print "Caddyfile changed — reload Caddy: caddy reload --config /opt/homebrew/etc/Caddyfile --adapter caddyfile"
else
  rm "$deploy_root/Caddyfile.new"
fi

print "current → releases/$release_id"
print "local check: curl -sI http://127.0.0.1:$port/cherry-utility/"
