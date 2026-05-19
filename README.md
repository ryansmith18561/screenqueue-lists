# screenqueue-lists

Public source of curated show lists rendered on the ScreenQueue onboarding "Popular shows" step.

The ScreenQueue iOS app fetches `onboarding-lists.json` from this repo's raw URL on each onboarding open. Editing this file and pushing to `main` updates the lists for every user **without shipping a new build**. The app caches the most recent successful fetch so an offline relaunch still renders something.

## File the app reads

```
https://raw.githubusercontent.com/ryansmith18561/screenqueue-lists/main/onboarding-lists.json
```

That URL is hardcoded in [`CuratedListsSource.swift`](../ScreenQueue/ScreenQueue/ScreenQueue/Services/CuratedListsSource.swift) — if you rename the repo or move branches, update both places.

## Schema

```jsonc
{
  "version": 1,
  "lists": [
    {
      "id": "prestige-week",                        // unique slug, kebab-case
      "title": "Prestige shows of the week",        // section header in the app
      "subtitle": "Hand-picked weekly rotation.",   // optional, shown under the title
      "shows": [
        { "tvmazeId": 41428, "name": "Severance" }  // tvmazeId is canonical; name is informational
      ]
    }
  ]
}
```

Rules:

- `version` must stay `1` for the current shipping app. Bump only when ship-time JSON-shape changes are needed and you've coordinated an app update.
- `id` must be unique across lists. The app uses it as a SwiftUI `Identifiable` key — duplicates collapse silently.
- `tvmazeId` is the canonical TVmaze numeric show id. Everything else (artwork, network, premiere date, status) is fetched live, so the JSON never goes stale.
- `name` is purely a hint for offline rendering before the TVmaze metadata resolves. The app does **not** trust it — when the TVmaze fetch succeeds, the canonical name from TVmaze wins.
- Order within each `shows` array is preserved in the app — shuffle to feature different shows at the top.
- 6–12 shows per list is the sweet spot. The grid uses 3 columns, so 6/9/12 fill cleanly.
- Two lists is the slice-1 target. More are fine — they just stack with the same section header treatment.

## Finding a show's `tvmazeId`

The fastest path is the public TVmaze search endpoint. From a terminal:

```bash
curl -s "https://api.tvmaze.com/singlesearch/shows?q=severance" | jq '{id, name, premiered, network: .network.name}'
```

Example response:

```json
{
  "id": 41428,
  "name": "Severance",
  "premiered": "2022-02-18",
  "network": "Apple TV+"
}
```

For ambiguous titles use `/search/shows` (returns multiple matches with relevance scores):

```bash
curl -s "https://api.tvmaze.com/search/shows?q=the+office" | jq '.[] | {id: .show.id, name: .show.name, premiered: .show.premiered, network: .show.network.name}'
```

Or just open `https://www.tvmaze.com/shows/{id}/...` in a browser — the id is in the URL.

## Editing flow

1. Edit `onboarding-lists.json` directly on github.com (Edit button on the file page) — easiest path.
2. Commit straight to `main` with a one-line message like "Refresh Prestige picks for 2026-W12".
3. Force-quit and relaunch the app to confirm the new lists render. Fetched JSON is **not** validated server-side; if you malform it, the app silently falls back to the cached copy (or empty + retry state) — a malformed push won't crash anyone.

For bigger changes, branch and PR like any other repo.

## Validation before pushing

```bash
jq empty onboarding-lists.json && jq '.lists | length, [.[].shows | length]' onboarding-lists.json
```

The first command parses; the second prints `<list-count>` then an array of per-list show counts. Sanity check that every list has 6+ entries.

## Versioning

This repo is unversioned. The app reads `main` directly. Tagging releases would imply support for older app builds reading older list shapes, which we don't currently want — every change applies to every user immediately.
