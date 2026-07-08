#!/usr/bin/env python3
"""
Merge a fresh top-shows pull into poster-index.json, preserving coverage.

poster-index.json is a broad poster-match index (historically ~500 shows from
Rotten Tomatoes). IMDb's "Most Popular TV" chart is only 100 deep, so a plain
overwrite would shrink the index to 100 and drop poster coverage for every show
below the top 100. Instead we UNION:

  * the fresh pull goes on TOP, in its original order — so derive-onboarding-lists.py,
    which takes entries[:99], still gets a correctly-ranked popular list;
  * any previously-indexed show NOT in the fresh pull is appended below it,
    keeping its poster data.

Dedup is by TVMaze id; the fresh entry wins for shows present in both (so posters
and names get refreshed). The index therefore never loses a show once seen and
grows slowly over time as shows cycle through the top 100 — which is exactly what
you want from a poster-match index.

Usage:
    merge-poster-index.py <fresh_top_shows.json> <poster_index.json>

Both files are {"version": 1, "entries": [{"id", "name", "posterURLs"}, ...]}.
The merged result is written back to <poster_index.json>. If <poster_index.json>
does not exist yet, the result is just the fresh pull.
"""

import json
import sys
from pathlib import Path


def load_entries(path):
    if not path.exists():
        return []
    doc = json.loads(path.read_text(encoding="utf-8"))
    return doc.get("entries") or []


def merge(fresh, existing):
    """Fresh entries first (in order), then existing entries whose id isn't
    already present. Entries without an id are kept but never used to dedup."""
    merged = []
    seen = set()
    preserved = 0
    for source in (fresh, existing):
        for entry in source:
            eid = entry.get("id")
            if eid is not None and eid in seen:
                continue
            if eid is not None:
                seen.add(eid)
            merged.append(entry)
            if source is existing:
                preserved += 1
    return merged, preserved


def main():
    if len(sys.argv) != 3:
        print(__doc__)
        return 2
    fresh_path = Path(sys.argv[1])
    index_path = Path(sys.argv[2])

    fresh = load_entries(fresh_path)
    existing = load_entries(index_path)
    merged, preserved = merge(fresh, existing)

    doc = {"version": 1, "entries": merged}
    index_path.write_text(
        json.dumps(doc, indent=2, ensure_ascii=False) + "\n", encoding="utf-8"
    )
    print(
        f"         merged: {len(fresh)} fresh + {preserved} preserved from prior "
        f"index = {len(merged)} total entries."
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
