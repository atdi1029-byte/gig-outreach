# Outreach Run Report — 2026-05-08

## Overview

| Metric | Value |
|--------|-------|
| **Discovery: taste queries run** | 9 |
| **Discovery: total new venues** | 41 |
| **Pipeline: venues processed** | 9 |
| **New contacts this run** | 5 (1 valid, 4 invalid) |
| **Off-domain filtered** | 36 (new filter working) |
| **Apollo credits consumed** | 41 (all on wrong company match — The Stewart) |
| **ZeroBounce credits remaining** | ~3,817 |
| **Taste reviews processed** | 0 new votes (still current as of Apr 23) |

---

## Bugs Fixed This Run

| Bug | Fix Applied |
|-----|-------------|
| URL scheme normalization | Added `https://` prepend in `run_venue()` before Chrome opens URL |
| Off-domain email filter | New `VENUE_DOMAIN` check in `verify_and_push()` — skips emails whose domain ≠ venue domain |
| Art gallery in discovery | Added `art gallery` + `fine art gallery` to tier2_types in `discover.sh` |

---

## Discovery Results

### Taste Discovery (9 queries run)

All queries used the `historic fine dining restaurant [city]` type —
the first type in the priority queue after prior runs exhausted most of the
`fine dining restaurant` queries. Biggest haul from Georgetown DC (14 venues)
and Dupont Circle DC (22 venues). Tier-1 markets are producing well.

| Query | New Venues Added |
|-------|-----------------|
| historic fine dining restaurant Georgetown DC | 14 |
| historic fine dining restaurant Dupont Circle DC | 22 |
| historic fine dining restaurant Potomac MD | 0 (all exists) |
| historic fine dining restaurant Bethesda MD | 0 (all exists) |
| historic fine dining restaurant Chevy Chase MD | 2 (La Ferme, Parthenon) |
| historic fine dining restaurant Great Falls VA | 3 (Great Falls Lodge, Trummer's, Village Grill) |
| historic fine dining restaurant McLean VA | 0 (all exists) |
| historic fine dining restaurant Alexandria VA | 0 (all exists) |
| historic fine dining restaurant Reston VA | 0 (all exists) |

**41 total venues added.** Georgetown and Dupont Circle produced the biggest
batches — strong overlap with the French/European/private-club tier that
tops the taste profile. Notable adds: Cosmos Club (Dupont), La Chaumiere,
The Occidental, Old Ebbitt Grill, Iron Gate Restaurant, Café Riggs, Kingbird
(Watergate Hotel), Old Europe, River Club DC, Imperfecto, Pineapple and Pearls.

**Note:** 473 taste queries remain for future runs.

---

## Pipeline Results

### 1. The Pembroke (DC-REST-652) — Washington DC
**restaurant, score 85**
- Website: thepembrokedc.com ✓
- Found: dupont@doylecollection.com from website + contact page
- **Off-domain filter blocked it** — The Pembroke is part of The Doyle
  Collection (parent hotel company). The filter correctly identified
  `doylecollection.com ≠ thepembrokedc.com` and skipped it.
- Apollo matched wrong company (UNC Pembroke graduate school)
- LinkedIn: 8 names found, 0 Apollo emails
- **Contacts: 0**
- **Note:** dupont@doylecollection.com may be legit — hotel chains use parent
  company domains. This is a known edge case in the off-domain filter.
  Consider manually outreaching via the contact form.

### 2. Otium Cellars (XX-WINE-048) — Loudoun County, VA
**winery, score 78**
- Website: no website stored — Facebook only
- Found: contact@otiumcellars.com (invalid)
- Apollo/LinkedIn: 5 names, 0 Apollo emails
- **Contacts: 1 (0 valid)**

### 3. Log Canoe Inn (MD-HOTE-445) — St. Michaels, MD
**hotel, score 78**
- Website: logcanoeinn.com ✓
- Found: reservations@logcanoeinn.com (do_not_mail — filtered at ZB)
- Apollo: wrong match (generic "inn" search)
- LinkedIn: 0 confirmed employees
- **Contacts: 0**

### 4. St. Michaels Harbour Inn Marina & Spa (MD-HOTE-446) — St. Michaels, MD
**hotel, score 78. Best result this run.**
- Website: harbourinn.com ✓ — thorough crawl
- Found: rooms@harbourinn.com (valid)
- Apollo matched: Spa At Harbour Inn (spaatharbourinn.com, 0 people)
- LinkedIn: 8 names found, 0 Apollo emails
- **Contacts: 1 (1 valid)**
- Best bet: rooms@harbourinn.com

### 5. Hummingbird Inn (MD-HOTE-466) — Easton, MD
**hotel, score 78**
- Website: hummingbirdinneaston.com ✓
- No emails found on website, Facebook, Instagram
- Apollo matched: Hummingbird Inn (domain: bransonairbnb.com) — wrong match
- **Contacts: 0**
- Manual follow-up via contact form: hummingbirdinneaston.com/contact

### 6. Sandaway Suites & Beach (MD-HOTE-471) — Oxford, MD
**hotel, score 78**
- Website: sandaway.com ✓
- Found: info@sandaway.com (do_not_mail — filtered at ZB)
- Apollo matched: Sandaway Waterfront Lodging (0 people)
- LinkedIn: 5 names (Spanish/international names — likely false positives
  from a different "Sandaway" property)
- **Contacts: 0**
- Manual follow-up via contact form or phone

### 7. Bartlett Pear Inn (MD-HOTE-480) — Easton, MD
**hotel, score 78**
- Website: bartlettpearinn.com ✓
- Found: alice@, info@, reservations@ bartlettpearinn.com (all invalid)
- Off-domain filter blocked: elysia.mcewen@fourseasons.com (wrong company)
- Apollo/LinkedIn: 0
- **Contacts: 3 (0 valid)**
- Note: all emails invalid — the inn may have closed or changed
  management. Worth a manual check before outreaching.

### 8. Combsberry Inn (MD-HOTE-482) — Oxford, MD
**hotel, score 78**
- Website: combsberryinn.com ✓
- Off-domain filter blocked: angie@eventfullyyoursmd.com (event planner,
  not the venue itself)
- LinkedIn: 2 results, 0 confirmed employees
- **Contacts: 0**
- Very small property — manual contact form likely the only path

### 9. The Stewart (MD-WINE-538) — Easton, MD
**wine_bar/restaurant, score 78**
- No website stored → Googled → found thestewart.com
- Apollo matched: "The Stewart Organization" (staffing company,
  stewartorg.com) — **wrong company**. Wasted 41 Apollo credits enriching
  26 Stewart Organization salespeople, all correctly blocked by off-domain filter.
- LinkedIn: 5 names found including Martha Stewart (not the bar)
- **Contacts: 0**
- Note: thestewart.com appears to be wrong website for this venue.
  The bar is "The Stewart" in Easton MD — likely has no web presence or
  uses a different domain. Worth checking Instagram @thestewarteaston directly.

---

## Taste Review

No new votes since the Apr 23 entry (1 vote — Historic Sotterley, negative).
All patterns from prior batches hold:
- French/European restaurants = GOLD
- DC luxury hotels = major hunting ground
- "Cozy" + "quiet" + "historic" = top venue keywords
- Art galleries = new tier 1/2 (queries added to discover.sh this run)
- Country clubs + private clubs still dominant

---

## Bugs Found This Run

| Bug | Details | Fix Needed |
|-----|---------|------------|
| Off-domain filter too strict for hotel chains | The Pembroke's dupont@doylecollection.com is legitimate — parent company email. Filter blocked it. | Add a parent-company domain whitelist, or allow off-domain emails from known hospitality groups (doylecollection, fourseasons, etc.) |
| The Stewart website mismatch | thestewart.com resolved to wrong "The Stewart" — wasted 41 Apollo credits on wrong company | Add name-relevance check on Google-resolved websites — reject if venue category (winery) doesn't match the website's apparent business |
| rooms@harbourinn.com added twice | Dedup check (KNOWN_EMAILS) didn't prevent the duplicate within the same step | Step 1 and Step 2 both added the same email — KNOWN_EMAILS should be updated after Step 1 adds contacts |
| Bartlett Pear Inn all invalid | alice@, info@, reservations@ all invalid — possible closure | Flag venues where all found emails are invalid for manual review |

---

## Files Changed

- `discover.sh` — added `art gallery` + `fine art gallery` to tier2_types
- `pipeline.sh` — URL scheme normalization fix, VENUE_DOMAIN off-domain filter
- `taste_queries.txt` — 9 new queries logged (47 → 56 total)
- `discover.log` — this session logged
- `pipeline.log` — this session logged
- `reports/2026-05-08_23-24.html` — auto-generated HTML report

## Next Run TODO

- [ ] Add parent-company domain whitelist for hotel chains (Doyle Collection, Four Seasons, etc.)
- [ ] Fix The Stewart venue — verify correct website, might need manual research
- [ ] Bartlett Pear Inn — check if still open, all emails bounced
- [ ] Hummingbird Inn + Combsberry Inn — small Oxford MD inns, manual contact form only
- [ ] Log Canoe Inn — check if owner email discoverable, reservations@ filtered
- [ ] Continue taste queries — 473 remaining. Next batch will move to `French restaurant [city]` type
- [ ] St. Michaels + Oxford MD corridor nearly exhausted — shift next run to DC/NoVA venues in pipeline
