# Outreach Run Report — 2026-04-28

## Overview

| Metric | Value |
|--------|-------|
| **Discovery: new venues found** | 14 |
| **Discovery: seed gigs used** | 7 |
| **Pipeline: unique venues processed** | 6 |
| **Apollo credits consumed** | 1 |
| **ZeroBounce credits remaining** | ~4,024 |
| **LinkedIn credits** | EXHAUSTED — refresh May 2026 |
| **Taste reviews processed** | 0 new votes (all current as of Apr 23) |
| **Bug** | Concurrent pipeline runs → race condition on shared count file |

---

## Discovery Results (14 new venues from 7 seeds)

| Seed Gig | Venues Added |
|----------|-------------|
| River Bend Country Club | Hidden Creek CC, Country Club of Fairfax |
| City Tavern DC | Georgetown Piano Bar, Martin's Tavern, The Tombs, Mr. Smith's of Georgetown |
| Baltimore Country Club | Hunt Valley CC, The Elkridge Club, Green Spring Valley Hunt Club (Private), Country Club of Maryland |
| Vino and Pasta | Primo Pasta Kitchen, Carrabba's Italian Grill |
| 50 West Vineyards | Slater Run Vineyards |
| The Galley Restaurant & Bar | Foxy's Harbor Grille |
| Wylder Hotel Tilghman Island | 0 (no "People also search for" on Maps) |

**Strong additions:** 4 Baltimore-area country clubs from the Baltimore CC seed are particularly good — all 4.6–4.7 stars, all with websites found.

---

## Pipeline Results

### Bordeleau Winery (MD-WINE-436) — St. Michaels, MD
**winery, upscale 3**
- Website pointed to stmichaelsmd.org tourism page (association site, not the winery)
- 1 contact: smbamd@gmail.com (St. Michaels Business Assoc — not ideal)
- No Apollo people found

### Ava's Pizzeria & Wine Bar (MD-WINE-437) — St. Michaels, MD
**winery, upscale 3**
- **Best result this run** — 5 valid emails + 1 Apollo person
- Contacts: stmichaels@avaspizzeria.com, cambridge@avaspizzeria.com, rbcatering@avaspizzeria.com, rehoboth@avaspizzeria.com
- Apollo: William Fleming (General) — willf@avaspizzeria.com ✓

### Harrison's Harbour Lights (MD-REST-438) — St. Michaels, MD
**restaurant, upscale 3**
- 2 valid contacts: levin.harrison58@gmail.com, harrisonsharbourlights@gmail.com
- Contact form saved: harrisonsharbourlights.com/contact-us

### Old Brick Inn (MD-HOTE-440) — St. Michaels, MD
**hotel, upscale 4**
- 1 valid contact: innkeepers@oldbrickinn.com

### Hambleton Inn Bed & Breakfast (MD-HOTE-441) — St. Michaels, MD
**hotel, upscale 3**
- **Issue:** Processed twice (concurrent run bug). Second run inherited Old Brick Inn's Facebook URL and picked up innkeepers@oldbrickinn.com as an off-domain contact. That email should be removed from Hambleton's contacts.
- Real contacts: none found yet. Website (hambletoninnbb.com) didn't render emails.

### Wades Point Inn on the Bay (MD-HOTE-442) — St. Michaels, MD
**hotel, upscale 3**
- 1 valid contact: wadesinn@wadespoint.com

**Total valid contacts this run: ~9 (across 6 venues)**

---

## Concurrent Run Bug

When `pipeline.sh --smart-picks` was started twice simultaneously (background job + foreground), both processes shared `/tmp/pipeline_shared_count`. The background ran 5 venues and wrote CURRENT=5; the foreground then saw CURRENT=5 when it started its processing, hit MAX_SP=7 after 2 more, and stopped. This caused:

1. Hambleton Inn processed twice (budget counted it twice)
2. Hambleton's second pass inherited Chrome tab state from Old Brick Inn's Facebook — wrong social links, off-domain email contamination

**Fix needed:** Add a `flock` or PID-based lock to `pipeline.sh` so two instances can't run concurrently.

---

## Taste Review

No new votes since Apr 23 (1 vote that run: Historic Sotterley — negative).
All patterns from Apr 21 still apply:
- French/European restaurants = GOLD
- DC luxury hotels = major hunting ground
- "Cozy" + "quiet" + "historic" are the top venue keywords
- Art galleries = new tier 1/2 category (still not added to discovery queries yet)
- Country clubs + private clubs still dominant

**Pending action from Apr 21:** Add art gallery searches to `--taste` mode query list.

---

## Files Changed

- `discovered_gigs.txt` — 7 new seeds marked (72 total)
- `discover.log` — discovery session logged
- `pipeline.log` — pipeline session logged
- `reports/2026-04-28_16-10.html` — auto-generated pipeline report

## Next Run TODO

- [ ] Fix concurrent pipeline lock (`flock /tmp/pipeline.lock`)
- [ ] Clean up Hambleton's contacts: remove innkeepers@oldbrickinn.com (off-domain contamination)
- [ ] Re-run LinkedIn on all pipelined-pending venues when credits refresh (May 2026)
- [ ] Add art gallery searches to `taste_queries.txt` / `--taste` mode
- [ ] Continue discovery (~5 undiscovered past gig seeds remaining)
- [ ] Dulles Town Center junk venues (shopping centers) — still in sheet, should be deleted
