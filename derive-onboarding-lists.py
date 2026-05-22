#!/usr/bin/env python3
"""
Regenerate onboarding-lists.json from poster-index.json.

poster-index.json is the canonical "popular shows this month" source — edit
it once a month, then run this script to mirror the same set into
onboarding-lists.json so the iOS app's Search → Discover and Onboarding →
Popular shows surfaces stay in sync.
"""

import json
from pathlib import Path

ROOT = Path(__file__).resolve().parent
POSTER_INDEX = ROOT / "poster-index.json"
ONBOARDING_LISTS = ROOT / "onboarding-lists.json"

LIST_ID = "popular-this-month"
LIST_TITLE = "Popular this month"
LIST_SUBTITLE = "The 50 shows trending in ScreenQ right now."
TOP_N = 50


def main() -> None:
    with POSTER_INDEX.open() as f:
        src = json.load(f)

    payload = {
        "version": 1,
        "lists": [
            {
                "id": LIST_ID,
                "title": LIST_TITLE,
                "subtitle": LIST_SUBTITLE,
                "shows": [
                    {"tvmazeId": entry["id"], "name": entry["name"]}
                    for entry in src["entries"][:TOP_N]
                ],
            }
        ],
    }

    with ONBOARDING_LISTS.open("w") as f:
        json.dump(payload, f, indent=2, ensure_ascii=False)
        f.write("\n")

    print(f"Wrote {len(payload['lists'][0]['shows'])} shows to {ONBOARDING_LISTS.name}")


if __name__ == "__main__":
    main()
