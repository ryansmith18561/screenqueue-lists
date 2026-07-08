#!/usr/bin/env bash
#
# refresh-popular-imdb.sh
#
# End-to-end "monthly refresh" for the popular-shows surface, sourced from
# IMDb's "Most Popular TV" (tvmeter) chart instead of Rotten Tomatoes.
# This is a drop-in alternative to refresh-popular.sh — same downstream
# outputs (poster-index.json, onboarding-lists.json), different top-list source.
# Run whichever one you trust this month; do NOT run both at once (they write
# the same files).
#
#   1. Pull screenqueue-lists from origin so we don't push onto a stale tree.
#   2. Wipe the TopShowsProgram imdb_* cache so top_shows_imdb.py re-fetches a
#      fresh chart from IMDb instead of replaying an old capture.
#   3. Run top_shows_imdb.py --n N IN THE FOREGROUND with line-buffered stdout
#      so progress streams live to your terminal (and to run-imdb.log via tee —
#      its own log file, so it never clobbers the RT pipeline's run.log).
#      This launches headless Google Chrome once to clear IMDb's bot challenge.
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

# N = how many shows to ask top_shows_imdb.py for. The tvmeter chart holds 100,
# so 100 is the practical ceiling. Override per-run by passing a positional arg,
# so this file stays git-clean across one-off runs:
#   ./refresh-popular-imdb.sh           # default 100
#   ./refresh-popular-imdb.sh 25        # quick sample
N="${1:-100}"
if ! [[ "$N" =~ ^[0-9]+$ ]] || [[ "$N" -lt 1 ]]; then
  echo "!! N must be a positive integer; got: '$N'" >&2
  echo "   Usage: $0 [N]    (default 100)" >&2
  exit 1
fi
echo "==> Refreshing popular shows from IMDb with N=$N"
echo

# Mutual exclusion with refresh-popular.sh (and other copies of this script):
# both pipelines write the same output/top_shows.json and poster-index.json, so
# running them concurrently would silently interleave/corrupt those files. The
# lock lives in TopShowsProgram because that's where the shared outputs are.
LOCK_DIR="$TOP_SHOWS_DIR/.refresh-lock"
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  echo "!! Another refresh (RT or IMDb) appears to be running (lock: $LOCK_DIR)." >&2
  echo "   If you're sure none is, remove the stale lock and re-run:" >&2
  echo "       rmdir \"$LOCK_DIR\"" >&2
  exit 1
fi
trap 'rmdir "$LOCK_DIR" 2>/dev/null || true' EXIT

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
echo "==> [2/6] Clearing imdb_* cache in $CACHE_DIR..."
# -f so an already-empty cache doesn't abort the script. Only the IMDb capture
# is cleared; the RT browse_*/show_* cache is left untouched so the two
# pipelines don't disturb each other.
rm -fv "$CACHE_DIR"/imdb_* 2>/dev/null || true

echo
echo "==> [3/6] Running top_shows_imdb.py --n $N (live progress below, also logged to run-imdb.log)..."
echo "         A headless Chrome window drives IMDb once to clear its bot check."
echo "         Ctrl-C aborts the whole pipeline. This step usually takes a few minutes."
echo "         ---"
cd "$TOP_SHOWS_DIR"
# -u: unbuffered Python stdout, so progress prints appear in real time
#     instead of being held back by pipe buffering.
# tee: stream to terminal AND to run-imdb.log so you can grep the log later.
#     Deliberately NOT run.log — that belongs to the RT pipeline, and switching
#     to this script after an RT failure shouldn't destroy the RT failure log.
# PIPESTATUS check: tee always exits 0; we want python's exit code to
#     fail the pipeline if it crashed.
set +e
.venv/bin/python -u top_shows_imdb.py --n "$N" 2>&1 | tee run-imdb.log
TOP_SHOWS_EXIT=${PIPESTATUS[0]}
set -e
if [[ "$TOP_SHOWS_EXIT" -ne 0 ]]; then
  echo "!! top_shows_imdb.py exited $TOP_SHOWS_EXIT — aborting before touching poster-index.json"
  exit "$TOP_SHOWS_EXIT"
fi
echo "         ---"

echo
echo "==> [4/6] Merging top_shows.json → poster-index.json (keep prior tail for coverage)..."
# NOT a plain copy: IMDb's chart is only 100 deep, but poster-index.json is a
# ~500-show poster-match index. merge-poster-index.py unions the fresh 100 on top
# (so the onboarding top-99 stays IMDb-ranked) while preserving previously-indexed
# shows below it, so poster coverage isn't lost. See that script's header.
"$LISTS_DIR/merge-poster-index.py" "$TOP_SHOWS_OUTPUT" "$POSTER_INDEX"

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
DEFAULT_MSG="Refresh popular shows (IMDb) for $(date +%Y-%m)"
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
