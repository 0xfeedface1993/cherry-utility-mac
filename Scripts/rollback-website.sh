#!/bin/zsh
# Swaps `current` and `previous` under the website deploy root (atomic renames; Caddy needs no reload).
set -euo pipefail
deploy_root="${CHERRY_WEBSITE_DEPLOY_ROOT:-$HOME/Library/Application Support/CherryUtility-Website}"
[[ -L "$deploy_root/current" && -L "$deploy_root/previous" ]] || { print -u2 "need both current and previous symlinks in $deploy_root"; exit 1; }
python3 - "$deploy_root" <<'PY'
import os, sys
root = sys.argv[1]
cur, prev = os.readlink(os.path.join(root, "current")), os.readlink(os.path.join(root, "previous"))
for name, target in (("current", prev), ("previous", cur)):
    tmp = os.path.join(root, f".{name}.tmp")
    if os.path.lexists(tmp): os.remove(tmp)
    os.symlink(target, tmp)
    os.replace(tmp, os.path.join(root, name))
print(f"current → {prev}\nprevious → {cur}")
PY
