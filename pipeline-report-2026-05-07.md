# Outreach Run Report — 2026-05-07

## Overview

| Metric | Value |
|--------|-------|
| **Discovery: gig seeds processed** | 3 (all seeds now exhausted) |
| **Discovery: taste queries run** | 15 |
| **Discovery: total new venues** | 15 |
| **Pipeline: venues processed** | 8 |
| **New contacts this run** | 17 (13 valid, 2 invalid, 1 catch-all, 1 name-only) |
| **Apollo credits consumed** | 10 |
| **ZeroBounce credits remaining** | ~3,832 |
| **LinkedIn credits** | Active (refreshed May 2026) |
| **Taste reviews processed** | 0 new votes (all current as of Apr 23) |

---

## Discovery Results

### Past Gig Seeds (3 remaining seeds processed)

All 70 past gigs are now fully discovered — seeds are exhausted.

| Seed Gig | New Venues Found |
|----------|-----------------|
| Bistrot Lepic | Chez Billy Sud, Lutèce, Brasserie Liberté, 1789 Restaurant |
| Sunset Hills Winery | Notaviva Farm Brewery & Winery |
| The Oaks Waterfront Hotel | George Brooks House B&B, Tidewater Inn |

**7 total from gig seeds.** Strong haul from Bistrot Lepic — 4 French/upscale DC-area
restaurants, exactly the category at the top of the taste profile.

### Taste Discovery (15 queries run)

All 15 queries searched "fine dining restaurant [city/state]." Most prime locations
(Bethesda, Chevy Chase, Great Falls, McLean, Alexandria, Reston, Middleburg, Leesburg,
St. Michaels, Easton, Annapolis, Roland Park) returned venues already in the database.
New adds came from Georgetown DC and Baltimore.

| Query | New Venues Added |
|-------|-----------------|
| fine dining Georgetown DC | Sequoia DC, Kappo DC, The Fountain Inn DC, Founding Farmers DC, Kitchen + Kocktails |
| fine dining Dupont Circle DC | PLANTA Washington DC |
| fine dining Potomac MD | La Grande Boucherie DC |
| fine dining Roland Park Baltimore MD | Rec Pier Chop House |
| All others | 0 (all already in DB) |

**8 total from taste queries.** Most tier-1 locations are well-saturated — the database
is now covering the top markets comprehensively.

**Note:** 452 taste queries remain for future runs.

---

## Pipeline Results

### Scossa Restaurant & Lounge (MD-REST-464) — Easton, MD
**restaurant, upscale 4, score 79**
- Website: scossarestaurant.com ✓
- Apollo: 0 people found (company found but no contacts)
- LinkedIn: 9 names found, no emails returned from Apollo enrichment
- **Contacts: 0**

### Hunters' Tavern at Tidewater Inn (MD-REST-465) — Easton, MD
**restaurant (inn), upscale 4, score 79**
**Best result this run.**
- Website: thorough crawl of tidewaterinn.com (26 subpages)
- Found 4 emails from website: cmorgan@, lcatterton@, mbennett@, spainfo@
- Apollo: 7 enrichments — Lauren Catterton (Director of Sales), Don Reedy (Director of
  Operations), Stacey Hamilton (Controller), Brandy Milligan (Sales Admin), Michelle
  Peed (Corporate Sales Manager) all valid
- LinkedIn: 7 additional names found, enriched via Apollo
- **Contacts: 10 (8 valid, 2 invalid)**
- Key contacts: lcatterton (Director of Sales), mpeed (Corp Sales Mgr), dreedy (Dir Ops)

### Out of the Fire (MD-REST-539) — Easton, MD
**restaurant, upscale 3, score 79**
- Website: outofthefire.com ✓
- Found: amy@outofthefire.com (valid), market@ (catch-all)
- Apollo: 0 people
- LinkedIn: 12 results, 0 confirmed employees (search "Out of the Fire" matches
  global fire safety professionals, not the restaurant)
- **Contacts: 2 (1 valid, 1 catch-all)**
- Best bet: amy@outofthefire.com

### P. Bordier (MD-REST-548) — Easton, MD
**restaurant, upscale 4, score 79**
- Website: pbordier.com — didn't render (likely React/JS-heavy)
- Apollo: no company match for "P. Bordier"
- LinkedIn: 2 names found (both false matches — French cheese company "Bordier")
- **Contacts: 0**
- Manual follow-up needed via their Instagram: @pbordiereaston

### Purser's Pub (MD-REST-574) — St. Michaels, MD
**restaurant, upscale 3, score 79**
- No website found (it's the pub inside Inn at Perry Cabin — no standalone web presence)
- Google lookup correctly rejected innatperrycabin.com as a mismatch
- Social: picked up Inn at Perry Cabin's IG/FB — marketing@perrycabinresorts.com
  flagged do_not_mail (correct)
- LinkedIn: "Purser's Pub" search returns global bar/pub employees — all false positives.
  19 names added to sheet without emails. **Sara Romera (Vega Mare) contact is noise.**
- **Contacts: 0 valid**
- This venue should be manually outreached through Inn at Perry Cabin contacts
  (already in DB from previous run)

### Bistro St Michaels (MD-REST-595) — St. Michaels, MD
**BUG — duplicate, deleted**
- Website stored as "stmichaelsmd.org" (missing https://) → Chrome error
- Script fell back to crawling LinkedIn pages → scraped user's own email
  (alexbarnettclassical@gmail.com) and 4 unrelated contacts (languagebridgesolutions,
  linomusicsociety)
- These contaminated contacts (C-1336 to C-1341) were **deleted during cleanup**
- Venue itself was a duplicate of MD-REST-429 (Bistro St. Michaels, already fully
  contacted on May 6) → **deleted**
- **Fix needed in pipeline.sh:** Before opening a URL, prepend "https://" if it
  starts with "www." or doesn't have a scheme. This prevents the Chrome URL error
  that caused the fallback to LinkedIn pages.

### Financier Chesapeake at Robert Morris Inn (MD-REST-610) — Oxford, MD
**restaurant (inn), upscale 4, score 79**
- Website: robertmorrisinn.com — didn't render (no emails or social scraped)
- Apollo: found "Homestead Real Estate LLC MD" at same domain (0 people)
- LinkedIn: 0 results
- **Contacts: 0**
- Robert Morris Inn is a historic Colonial inn in Oxford. No email found. Manual
  outreach via contact form.

### Two Twisted Posts Winery & Tavern (XX-WINE-047) — Loudoun County, VA
**winery, upscale 4, score 78**
- Website: twotwistedposts.com — excellent crawl
- Found 4 emails: casey@, lynda@ (Social Media Manager), brad@ (Owner), plus
  one non-venue contact (Samantha Milchenski at veraxx.com — add noise)
- Apollo: 3 enrichments — Lynda Dattilio, Brad Robertson (Owner), Samantha Milchenski
- **Contacts: 4 (3 core venue contacts valid)**
- Best bets: brad@twotwistedposts.com (Owner), lynda@twotwistedposts.com (SM Mgr)

---

## Taste Review

No new votes since the Apr 23 entry (1 vote — Historic Sotterley, negative).
All patterns from the Apr 21 batch still apply:
- French/European restaurants = GOLD (confirmed again by Bistrot Lepic seed producing
  4 French DC restaurants)
- DC luxury hotels = major hunting ground (15 taste queries still returned 0 new DC
  hotels — most are already in DB)
- "Cozy" + "quiet" + "historic" = top venue keywords
- Art galleries = tier 1/2 (still not in taste query list)

**Pending action:** Add art gallery searches to `taste_queries.txt` — first flagged
Apr 21, still not done.

---

## Bugs Found This Run

| Bug | Details | Fix |
|-----|---------|-----|
| Broken URL → LinkedIn fallback | `stmichaelsmd.org` without `https://` caused Chrome error; script scraped LinkedIn instead of the venue website, adding contaminated emails | Add URL scheme normalization in pipeline.sh before passing to Chrome |
| Contaminated contacts added | alexbarnettclassical@gmail.com + 4 other unrelated emails added to Bistro St Michaels (C-1336 to C-1341) | **Cleaned up — contacts deleted, duplicate venue deleted** |
| "Purser's Pub" LinkedIn mismatch | Generic venue name matches global pub employees; 19 names added without emails | Add location filter to LinkedIn confirm step (only accept results with "St Michaels" / "MD" in title) |
| sam.milchenski@veraxx.com (off-domain) | Added to Two Twisted Posts but email is @veraxx.com — unrelated company | Pipeline should filter contacts whose email domain doesn't match or relate to the venue's domain |

---

## Files Changed

- `discovered_gigs.txt` — 3 new seeds marked (all 70 now exhausted)
- `taste_queries.txt` — 15 new queries logged (32 → 47 total)
- `discover.log` — this session logged
- `pipeline.log` — this session logged
- `reports/2026-05-07_23-18.html` — auto-generated HTML report

## Next Run TODO

- [ ] Fix URL scheme normalization (prepend https:// when missing)
- [ ] Add art gallery searches to taste queries (overdue since Apr 21)
- [ ] Add off-domain email filter (skip contacts where email domain ≠ venue domain)
- [ ] Purser's Pub: outreach through Inn at Perry Cabin contacts already in DB
- [ ] P. Bordier + Robert Morris Inn: manual follow-up (no emails found)
- [ ] Taste discovery mode will dominate next run (all past gig seeds exhausted)
- [ ] Re-run taste queries with "French restaurant", "private club", "wine bar" types
  which still have 452 untouched queries
