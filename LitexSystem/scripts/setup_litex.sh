#!/bin/bash
#---------------------------------------------------------------------------
# setup_litex.sh : the LiteX workspace build_soc.sh needs, at the versions
#                  mmRISC-2 is built with
#
#   ./scripts/setup_litex.sh [destination]      (default: <repository>/LitexRocket)
#
# What comes out:
#   <destination>/.venv       Python virtual environment with LiteX installed
#   <destination>/litex_ws    the LiteX repositories (litex, litex-boards,
#                             migen, litedram, liteeth, litesdcard, ...)
#
# Every repository is cloned at the sha1 written in litex_repos.py (frozen
# from the workspace used for the board), then litex_setup.py installs them
# into the venv (editable). litex_setup.py is run with --dev: without it, it
# replaces itself and litex_repos.py with the latest ones of LiteX master,
# which would undo the pinning. --dev would also turn the clone URLs into
# SSH ones, so the clones are done here and litex_setup.py only installs.
#
# A repository that is already there is left as it is.
#---------------------------------------------------------------------------
set -e

HERE=$(cd "$(dirname "$0")" && pwd)
LITEX_SYSTEM=$(dirname "$HERE")
REPO=$(dirname "$LITEX_SYSTEM")
DEST=${1:-$REPO/LitexRocket}
WS="$DEST/litex_ws"
VENV="$DEST/.venv"

mkdir -p "$WS"
[ -d "$VENV" ] || python3 -m venv "$VENV"
source "$VENV/bin/activate"

cp "$HERE/litex_repos.py" "$WS/litex_repos.py"
cd "$WS"

echo "== clone at the frozen commits =="
python3 - <<'PY'
import os, subprocess, sys
sys.path.insert(0, ".")
import litex_repos as r
for name in r.frozen_repos:
    repo = r.git_repos[name]
    if os.path.isdir(name):
        print(f"{name}: already there, left as it is")
        continue
    clone = ["git", "clone"] + (["--recursive"] if repo.clone == "recursive" else [])
    subprocess.check_call(clone + [repo.url + name + ".git", name])
    subprocess.check_call(["git", "-C", name, "checkout", "--quiet", repo.sha1])
    if repo.clone == "recursive":
        subprocess.check_call(["git", "-C", name, "submodule", "update", "--init", "--recursive"])
PY

echo "== install into $VENV =="
cp litex/litex_setup.py .
python3 litex_setup.py --dev --install --config=full
pip install meson ninja                # the LiteX BIOS is built with them

echo "== done =="
python3 - <<'PY'
import subprocess, sys
sys.path.insert(0, ".")
import litex_repos as r
bad = [n for n in r.frozen_repos
       if subprocess.check_output(["git", "-C", n, "rev-parse", "HEAD"]).decode().strip()
          != r.git_repos[n].sha1]
print("all repositories at the frozen commits" if not bad else f"NOT at the frozen commit: {bad}")
PY
