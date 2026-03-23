# Re-Verification Report — 2026-03-23

## Summary

| Metric | Value |
|--------|-------|
| **Total unknown emails** | 290 |
| **Venues with unknowns** | 31 |
| **Total valid emails** | 187 |
| **Total other (catch-all, invalid, do_not_mail)** | 69 |

These 290 emails got "unknown" status because ZeroBounce credits ran out mid-pipeline on Mar 23 2026.
They need re-verification once ZeroBounce credits are refilled.

## Venues Needing Re-Verification (by size)

### Large (20+ unknowns)
| Venue | Unknown Emails | Notes |
|-------|---------------|-------|
| Ritz-Carlton Georgetown | 50 | Global Ritz employees, mostly NOT Georgetown |
| Strathmore Mansion | 48 | Good contacts — events, programming, marketing |
| Army Navy Club | 45 | Actually Army Navy Country Club (ancc.org) |
| Camp Wharf | 24 | Mixed — some DC Wharf, some other Wharf properties |
| Mount Vernon Country Club | 22 | Good contacts — GM, catering, events |

### Medium (5-19 unknowns)
| Venue | Unknown Emails |
|-------|---------------|
| Rehoboth Art League | 17 |
| Maryland Hall | 16 |
| Sulgrave Club | 9 |
| The Athenaeum NVFAA | 8 |
| Black Ankle Vineyards | 7 |
| Academy Art Museum | 6 |
| Maryland Art Place | 5 |
| St Michaels Art Gallery District | 5 |

### Small (1-4 unknowns)
| Venue | Unknown Emails |
|-------|---------------|
| 2941 Restaurant | 4 |
| Creative Alliance | 4 |
| Antrim 1844 | 2 |
| La Chaumiere | 2 |
| Old Angler's Inn | 2 |
| The Sheridan at Severna Park | 2 |
| 600 T | 1 |
| Alta Strada | 1 |
| Alta Strada (Mosaic) | 1 |
| Amalfi Coast Italian + Wine Bar | 1 |
| City Tavern DC | 1 |
| Hamilton Hotel | 1 |
| Lone Oak Farm Brewing Co. | 1 |
| NOMA Gallery | 1 |
| Orchid Cellar Meadery and Winery | 1 |
| Principle Gallery | 1 |
| River Bend Bistro & Wine Bar | 1 |
| Waverly Street Gallery | 1 |

## Priority Re-Verification

**High priority** (good venues with named contacts stuck as "unknown"):
1. Strathmore Mansion — 48 emails (events team, programming, marketing)
2. Mount Vernon Country Club — 22 emails (GM, catering director, events)
3. Sulgrave Club — 9 emails (operations, dining, sous chef)
4. 2941 Restaurant — 4 emails (GM, events director, private dining)
5. Rehoboth Art League — 17 emails (executive director, events, education)
6. Maryland Hall — 16 emails (programming, development, marketing)

**Lower priority** (global matches or generic emails only):
- Ritz-Carlton Georgetown — 50 emails but mostly global employees, not Georgetown-specific
- Army Navy Club — 45 emails but matched country club, not DC private club
- Camp Wharf — 24 emails but mixed parent company employees

## Safeguards Needed in Pipeline

Two safeguards to add to `pipeline.sh`:

1. **ZeroBounce credit check before each verify** — call the ZB credits API before processing a venue. If credits < 10, stop the pipeline with a clear message instead of letting verify_and_push hang.

2. **Timeout on ZeroBounce API calls** — add a curl timeout (e.g. 15 seconds) so if ZB hangs, the pipeline moves on with "unknown" status instead of stalling for 90+ minutes.
