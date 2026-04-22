# Outreach Run Report — 2026-04-21

## Overview

| Metric | Value |
|--------|-------|
| **Discovery: new venues found** | 30 |
| **Discovery: seed gigs used** | 6 |
| **Pipeline: venues processed** | 6 |
| **Apollo credits consumed** | 11 |
| **ZeroBounce credits remaining** | 4,076 |
| **LinkedIn credits** | EXHAUSTED for the month |
| **Taste reviews processed** | 20 new votes |
| **Bug fixed** | discover.sh map_category NameError |

## Bug Fix

`discover.sh` default mode was crashing on every venue — `map_category` function was only defined in `--taste` mode Python block but called in default mode. Fixed by adding the function definition to both blocks.

## Discovery Results (30 new venues from 6 seeds)

| Seed Gig | Venues Added |
|----------|-------------|
| 1757 Golf Club | (map_category was broken, 0 added on first pass) |
| Holly Hills Country Club | (same bug) |
| Conrad Washington DC | 5 hotels (Yours Truly DC, Kimpton Banneker, etc.) |
| Pirouette Restaurant & Wine Shop | 3 (Brass Rabbit, Screwtop Wine Bar, Green Pig Bistro) |
| Le Meridien Arlington | 5 hotels (Hyatt Centric Arlington, Hilton Garden Inn, etc.) — 1 Airbnb auto-rejected |
| Dulles Town Center | 5 (mostly shopping centers — junk from mall seed) |

**Note:** After bug fix, re-ran 1757 Golf Club through Dulles Town Center. Total 30 venues added.

## Pipeline Results

### Maryland Club (MD-PRIV-328) — Baltimore, MD
**Historic private club, upscale score 9**

**Website fix:** Was pointing to marylandclub.org (wrong), corrected to marylandclub1857.org
**Social fix:** Facebook and Instagram were pointing to UMD M Club (college athletics). Cleared and replaced with correct FB (TheMarylandClub1857). No Instagram exists.

**9 valid contacts found:**

| Name | Title | Email | Source |
|------|-------|-------|--------|
| Olivia (unknown last name) | Events | olivia@marylandclub1857.org | website |
| Andrew Cordova | Racquets Director | andrew@marylandclub1857.org | Apollo |
| Milton Franklin | Food & Beverage Manager | milton@marylandclub1857.org | Apollo |
| Michael Stetka | Executive Chef | mike@marylandclub1857.org | Apollo |
| Isauro Lopez | Fitness Director | iglopez@marylandclub1857.org | Apollo |
| Corinne Hart | Dir, Membership & Marketing | chart@marylandclub1857.org | Apollo |
| Katherine Mandaro | General Manager | krmandaro@marylandclub1857.org | Apollo |
| John Podles | Communications Manager | john@marylandclub1857.org | Apollo |
| Matthew Smeal | Dir of Accounts & Facilities | msmeal@marylandclub1857.org | Apollo |

**Best contacts to email:** Katherine Mandaro (GM), Corinne Hart (Membership & Marketing), Milton Franklin (F&B), Olivia (Events)

**LinkedIn:** Marked as `linkedin_pending` — credits exhausted for the month. Found 8 people but couldn't enrich.

## Taste Review (20 new venue votes)

### New Positives (19 added to taste_venues.txt)
- **La Chaumiere** (DC) — "Literally perfect! Fancy French restaurant!" — STRONGEST signal
- **The Jefferson, Washington DC** (hotel) — "Very Fancy historic hotel in dc"
- **Salamander Washington DC** (hotel) — "Fancy hotel, always a good fit"
- **Pendry Washington DC** (hotel) — "Luxury hotel! Good fit"
- **Lyle Washington DC** (hotel) — "Upscale hotel"
- **Conrad Washington DC** (hotel) — reconfirmed dream venue
- **The Tabard Inn** (DC hotel) — "Historic inns are always a great match!"
- **Iron Gate** (DC restaurant) — "Fancy restaurant! Upscale"
- **L'Avant-Garde** (DC restaurant) — "Fancy upscale restaurant"
- **600 T** (DC restaurant) — "Nice classy place"
- **Bastille Brasserie & Bar** (Alexandria) — "French restaurant always a good fit. European in general"
- **Addison Ripley Fine Art** (DC gallery) — "Fine art galleries seem like a great fit!" — NEW CATEGORY
- **wineLAIR** (DC wine bar) — "Cozy wine bar, fancy upscale people"
- **Lulu's Winegarden** (DC wine bar) — "Wine bars are great for me"
- **Bourbon & Fig** (Woodbridge VA) — "Classy, fine dining, quiet vibe"
- **Alta Strada Mosaic** (Fairfax VA) — "Upscale Italian always a good fit"
- **Brx American Bistro** (Flint Hill VA) — "Fancy restaurant, I can tell it would be good"
- **Vandiver Inn** (Havre de Grace MD) — "Nice vibe, seems cozy"
- **The Wildset Hotel** (St Michaels MD) — "Good fit, but might be too small"

### Updated Patterns
- **French/European restaurants = GOLD** — strongest single category signal
- **DC luxury hotels = major new hunting ground** — 5 positive in one batch
- **"Cozy" + "quiet" joining "historic"** as top venue keywords
- **Art galleries = NEW category** to add to discovery searches
- **Wine bars confirmed** in DC
- **Italian fine dining confirmed** alongside French/European

## Additional Pipeline Results (5 more venues)

### Sweetbay Restaurant & Bar (MD-REST-330) — Solomons, MD
- 1 contact: sweetbaymaryland@gmail.com (website)
- LinkedIn: pending (credits exhausted)

### Solomons Victorian Inn (MD-HOTE-331) — Solomons, MD
- No named contacts found (small B&B)
- LinkedIn: pending

### Historic Sotterley (MD-EVEN-332) — Hollywood, MD
- 1 contact: execdirector@sotterley.org (valid)
- LinkedIn: pending

### Annmarie Sculpture Garden & Arts Center (MD-MUSE-333) — Solomons, MD
- 1 contact: K Glascock (Gift Shop Manager) — giftshop@annmariegarden.org
- info@ and donor@ both do_not_mail
- LinkedIn: pending

### The Inn at Leonardtown (MD-HOTE-334) — Leonardtown, MD
- 1 contact: md248@stayatchoice.com (from Facebook)
- Corporate hotel (Choice Hotels) — Apollo had no results
- LinkedIn: pending

**Total this run: 6 venues pipelined, 13 valid contacts found**

## Files Changed
- `discover.sh` — map_category bug fix
- `discovered_gigs.txt` — 6 new seeds marked
- `taste_notes.md` — 20 new reviews processed
- `taste_venues.txt` — 19 new positives added
- `discover.log`, `pipeline.log` — session logs

## Next Run TODO
- [ ] Re-run LinkedIn on all 6 venues when credits refresh (May 2026)
- [ ] Continue discovery (still ~16 undiscovered past gig seeds)
- [ ] Add art gallery searches to taste discovery queries
- [ ] Clean up Dulles Town Center junk venues (shopping centers)
