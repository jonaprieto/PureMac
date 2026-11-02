#!/usr/bin/env bash
# Brings this fork up to upstream and installs it as /Applications/PureMac.app.
#
# main mirrors upstream and only fast-forwards; fork holds our commits, rebased on main. A rebase conflict stops here:
# fix it, `git rebase --continue`, run again. rerere remembers the fix, so the same conflict never comes back.
#
#   scripts/fork-sync.sh            # sync, build, install
#   scripts/fork-sync.sh --no-sync  # build and install what's checked out
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ "${1:-}" != "--no-sync" ]]; then
  if [[ -n "$(git status --porcelain)" ]]; then echo "Commit or stash your changes first." >&2; exit 1; fi
  if [[ "$(git branch --show-current)" != fork ]]; then echo "Run this from the fork branch." >&2; exit 1; fi
  git config rerere.enabled true
  git fetch upstream
  git fetch . upstream/main:main
  git push origin main
  git rebase main
  git push --force-with-lease origin fork
fi

scripts/install.sh
