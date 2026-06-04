#!/usr/bin/env bash
#
# refresh-popular.sh
#
# End-to-end "monthly refresh" for the popular-shows surface.
#
#   1. Pull screenqueue-lists from origin so we don't push onto a stale tree.
#   2. Wipe the TopShowsProgram Browse_* cache so top_shows.py re-fetches
#      fresh data from TVmaze instead of replaying yesterday's pages.
#   3. Run top_shows.py --n 500 IN THE FOREGROUND with line-buffered stdout
#      so progress streams live to your terminal (and to run.log via tee).
#   4. Copy TopShowsProgram/output/top_shows.json onto
#      screenqueue-lists/poster-index.json — the iOS poster-matching path
#      reads this file directly.
#   5. Run derive-onboarding-lists.py to mirror the top 99 into
#      onboarding-lists.json as a single "popular-this-month" section.
#   6. Show the diff, prompt for a commit message, prompt before pushing.
#
# Run from anywhere — paths are absolute. Safe to re-run.

set -euo pipefail

LISTS_DIR="$HOME/Documents/screenqueue-lists"
TOP_SHOWS_DIR="$HOME/Documents/TopShowsProgram"
CACHE_DIR="$TOP_SHOWS_DIR/cache"
TOP_SHOWS_OUTPUT="$TOP_SHOWS_DIR/output/top_shows.json"
POSTER_INDEX="$LISTS_DIR/poster-index.json"

# N = how many shows to ask top_shows.py for. Override per-run by passing
# a positional arg, so this file stays git-clean across one-off runs:
#   ./refresh-popular.sh           # default 500
#   ./refresh-popular.sh 50        # quick sample
#   ./refresh-popular.sh 1000      # bigger pull
N="${1:-500}"
if ! [[ "$N" =~ ^[0-9]+$ ]] || [[ "$N" -lt 1 ]]; then
  echo "!! N must be a positive integer; got: '$N'" >&2
  echo "   Usage: $0 [N]    (default 500)" >&2
  exit 1
fi
echo "==> Refreshing popular shows with N=$N"
echo

echo "==> [1/6] Pulling latest screenqueue-lists from origin..."
cd "$LISTS_DIR"

# Pre-flight: refuse to pull if the working tree has uncommitted changes.
# `git pull --rebase` will error mid-step otherwise, leaving the script
# half-done and the user staring at a wall of git text. Almost always
# this is leftover poster-index.json / onboarding-lists.json writes
# from an aborted prior run — safe to discard, since the next steps
# regenerate them. Surface the choice clearly instead of guessing.
if ! git diff --quiet || ! git diff --cached --quiet; then
  echo "!! The screenqueue-lists working tree has uncommitted changes:"
  echo
  git status --short
  echo
  echo "   Most likely: leftover writes from a prior aborted run."
  echo "   Choose one, then re-run this script:"
  echo
  echo "     - DISCARD them (the next run regenerates these files anyway):"
  echo "         git -C \"$LISTS_DIR\" checkout -- ."
  echo
  echo "     - KEEP them (stash now, pop later if you want them back):"
  echo "         git -C \"$LISTS_DIR\" stash"
  echo
  exit 1
fi

git pull --rebase origin main

echo
echo "==> [2/6] Clearing browse_* cache in $CACHE_DIR..."
# -f so an already-empty cache doesn't abort the script. Glob patterns
# are case-sensitive even on macOS's case-insensitive APFS — the files
# on disk are lowercase `browse_after_*`, so the pattern must match.
rm -fv "$CACHE_DIR"/browse_* 2>/dev/null || true

echo
echo "==> [3/6] Running top_shows.py --n $N (live progress below, also logged to run.log)..."
echo "         Ctrl-C aborts the whole pipeline. This step usually takes a while."
echo "         ---"
cd "$TOP_SHOWS_DIR"
# -u: unbuffered Python stdout, so progress prints appear in real time
#     instead of being held back by pipe buffering.
# tee: stream to terminal AND to run.log so you can grep the log later.
# PIPESTATUS check: tee always exits 0; we want python's exit code to
#     fail the pipeline if it crashed.
set +e
.venv/bin/python -u top_shows.py --n "$N" 2>&1 | tee run.log
TOP_SHOWS_EXIT=${PIPESTATUS[0]}
set -e
if [[ "$TOP_SHOWS_EXIT" -ne 0 ]]; then
  echo "!! top_shows.py exited $TOP_SHOWS_EXIT — aborting before touching poster-index.json"
  exit "$TOP_SHOWS_EXIT"
fi
echo "         ---"

echo
echo "==> [4/6] Copying top_shows.json → poster-index.json..."
cp "$TOP_SHOWS_OUTPUT" "$POSTER_INDEX"
echo "         $(python3 -c "import json; print(len(json.load(open('$POSTER_INDEX'))['entries']))") entries written."

echo
echo "==> [5/6] Regenerating onboarding-lists.json (top 99)..."
cd "$LISTS_DIR"
./derive-onboarding-lists.py

echo
echo "==> [6/6] Diff:"
git --no-pager diff --stat poster-index.json onboarding-lists.json

if git diff --quiet poster-index.json onboarding-lists.json; then
  echo "         No changes vs origin. Done — nothing to commit."
  exit 0
fi

echo
DEFAULT_MSG="Refresh popular shows for $(date +%Y-%m)"
read -rp "Commit message [$DEFAULT_MSG]: " MSG
MSG="${MSG:-$DEFAULT_MSG}"

git add poster-index.json onboarding-lists.json
git commit -m "$MSG"

echo
read -rp "Push to origin/main now? [y/N]: " PUSH
if [[ "$PUSH" =~ ^[Yy]$ ]]; then
  git push origin main
  echo "==> Pushed. Live app will pick up the new payload on next onboarding open."
else
  echo "==> Committed locally; not pushed. Run 'git push origin main' when ready."
fi
