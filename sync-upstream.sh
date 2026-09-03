#!/usr/bin/env bash

# Sync this fork with upstream while keeping our patch series on top.
#
# This fork carries local commits (networking fixes, image rename) that must
# always ride on top of upstream. This script fetches upstream, rebases the
# patch series onto upstream/main, and force-pushes the result to the fork.
#
# Usage: ./sync-upstream.sh
#
# Notes:
#   - Do NOT use GitHub's "Sync fork" button; it merges/resets the fork's main
#     and fights this rebase workflow. All syncing goes through this script or
#     the sync-upstream.yml workflow.
#   - If the workflow synced first, remote main was rewritten; this script
#     detects that and rebases onto origin/main before pulling upstream
#     (content-identical patches are skipped automatically).
#   - git rerere replays previously-resolved conflicts. If a new conflict
#     appears, the rebase is left in progress for manual resolution.
#   - origin/main is only adopted as-is if it still contains .fork-marker;
#     otherwise it's treated as clobbered (e.g. by a fork-sync bot) and
#     overwritten rather than rebased onto.

set -euo pipefail

UPSTREAM_URL="https://github.com/dciancu/unifi-protect-unvr-docker-arm64.git"

SCRIPT_DIR="$(dirname "$0")"
cd "$SCRIPT_DIR"

if [ -n "$(git status --porcelain)" ]; then
    echo "ERROR: working tree is not clean; commit or stash first." >&2
    exit 1
fi

if [ "$(git rev-parse --abbrev-ref HEAD)" != "main" ]; then
    echo "ERROR: not on main." >&2
    exit 1
fi

if ! git remote get-url upstream >/dev/null 2>&1; then
    git remote add upstream "$UPSTREAM_URL"
    git remote set-url --push upstream DISABLED
fi
git config rerere.enabled true
git config rerere.autoupdate true

git fetch upstream
git fetch origin

FORK_MARKER=".fork-marker"
CLOBBERED=0

if git merge-base --is-ancestor upstream/main main && [ "$(git rev-parse origin/main)" = "$(git rev-parse main)" ]; then
    echo "Already up to date with upstream; nothing to do."
    exit 0
fi

backup="backup/pre-sync-$(date +%Y%m%d-%H%M%S)"
git branch "$backup" main
echo "Backup branch: $backup"

# If the sync workflow already rewrote origin/main, rebase onto it first;
# patches that are already in origin/main are skipped as content-identical.
# Only adopt origin/main if it still carries our fork marker: a bot (e.g.
# GitHub's "Sync fork" or pull[bot]) can hard-reset origin/main to upstream
# and wipe our patch series, and we must not rebase onto that.
if ! git merge-base --is-ancestor origin/main main; then
    if git cat-file -e "origin/main:$FORK_MARKER" 2>/dev/null; then
        echo "origin/main has moved (workflow sync?); rebasing onto it first."
        git rebase origin/main
    else
        echo "WARNING: origin/main lacks $FORK_MARKER — it was clobbered (bot/Sync fork?). Not adopting it; will force-push our series back." >&2
        CLOBBERED=1
    fi
fi

if ! git merge-base --is-ancestor upstream/main main; then
    if ! git rebase upstream/main; then
        if [ ! -d "$(git rev-parse --git-path rebase-merge)" ] && \
           [ ! -d "$(git rev-parse --git-path rebase-apply)" ]; then
            echo "ERROR: git rebase failed without leaving a rebase in progress." >&2
            exit 1
        fi
        # rerere may have auto-resolved and staged the conflict; keep continuing
        # until the rebase finishes or a conflict rerere could not handle remains.
        tries=0
        while [ -d "$(git rev-parse --git-path rebase-merge)" ] || [ -d "$(git rev-parse --git-path rebase-apply)" ]; do
            if [ -n "$(git diff --name-only --diff-filter=U)" ] || [ "$tries" -ge 20 ]; then
                cat >&2 <<'EOF'

Rebase stopped on a conflict rerere could not resolve. Fix it manually:
  1. Edit the conflicted files (git status shows them)
  2. git add <files> && git rebase --continue
  3. git push --force-with-lease origin main
Or abort with: git rebase --abort
EOF
                exit 1
            fi
            GIT_EDITOR=true git rebase --continue || true
            tries=$((tries + 1))
        done
    fi
fi

if [ "$CLOBBERED" -eq 1 ]; then
    git push --force-with-lease=main:"$(git rev-parse origin/main)" origin main
else
    git push --force-with-lease origin main
fi
git push --force origin main:refs/heads/sync/last-good
echo "Synced with upstream and pushed to origin/main."
