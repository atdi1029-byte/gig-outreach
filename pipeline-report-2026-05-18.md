# Outreach Run Report — 2026-05-18

## Overview

| Metric | Value |
|--------|-------|
| **Discovery: past gig seeds** | 0 new (all 74 exhausted) |
| **Discovery: taste queries run** | 9 |
| **Discovery: total new venues** | 1 |
| **Pipeline: venues processed** | 9 |
| **New contacts this run** | 12 valid (Chartwell 9, Osteria 1, Harry Browne's 1, Treaty 1) |
| **Apollo credits consumed** | ~63 (9 venues × 7 avg) |
| **ZeroBounce credits remaining** | ~3,799 |
| **Total contacts in system** | 1,334 |
| **Pending emails (ready to send)** | 221 |
| **Taste reviews processed** | 0 new votes (still current as of Apr 23) |

---

## Discovery Results

### Past Gig Seeds
All 74 gig seeds exhausted — every past gig has been discovered.
Nothing new from this mode.

### Taste Discovery (9 queries run)

Continued the `historic fine dining restaurant` series through Middleburg, Leesburg,
St. Michaels, Easton, Roland Park Baltimore, then started `French restaurant` series
through Georgetown, Dupont Circle, Potomac, Bethesda.

| Query | New Venues Added |
|-------|-----------------|
| historic fine dining restaurant Middleburg VA | 0 (all skipped — location bug) |
| historic fine dining restaurant Leesburg VA | 0 (all skipped — location bug) |
| historic fine dining restaurant St. Michaels MD | 0 (exists) |
| historic fine dining restaurant Easton MD | 1 (Breakfast in Easton) |
| historic fine dining restaurant Roland Park Baltimore MD | 0 (all exists) |
| French restaurant Georgetown DC | 0 (all exists) |
| French restaurant Dupont Circle DC | 0 (all exists) |
| French restaurant Potomac MD | 0 (all exists) |
| French restaurant Bethesda MD | 0 (all exists) |

**1 total venue added.** Very low yield this run.

**Critical Bug: Discovery scoring broken.**
Google Maps search results are returning venues with empty location/category
data. The pre-score function penalizes empty state (-50 points), so nearly
every venue scores 0 and gets skipped. Middleburg returned 44 results
including Red Fox Inn & Tavern, Salamander Middleburg, Goodstone Inn —
all skipped. Leesburg returned 51 results including Tuscarora Mill, Lightfoot
Restaurant — all skipped. This is a significant loss of high-quality venues.
**Fix needed: location extraction in extract_search_results.js.**

**492 taste queries remain.**

---

## Pipeline Results

### 1. Naval Academy Club (MD-PRIV-693) — Annapolis, MD
**private_club, score 99 — top pick**
- Website: not stored, Google lookup failed
- Apollo/LinkedIn: no match found
- **Contacts: 0**
- Note: Naval Academy Club is a prestigious officers' club — exactly the
  audience type (educated, disciplined, high culture). Worth manual research
  to find the right contact. Try navyclub.com or direct web search.

### 2. Chartwell Golf and Country Club (MD-COUN-732) — Potomac, MD
**country_club, score 89. Best result this run.**
- Website: chartwellgcc.com ✓ — thorough crawl
- Found from website + Apollo: 9 valid contacts
  - bendres@chartwellgcc.com
  - cgregorski@chartwellgcc.com
  - clubhouse@chartwellgcc.com
  - dmayhew@chartwellgcc.com (Deidra Mayhew, WSET III — wine specialist!)
  - edorn@chartwellgcc.com (Erick Dorn, Facilities Manager)
  - etipton@chartwellgcc.com
  - ragresti@chartwellgcc.com (Robert Agresti, PGA Head Golf Professional)
  - rmarr@chartwellgcc.com (Richard Marr)
  - rshowalter@chartwellgcc.com (Rebecca Showalter, Controller)
- **Contacts: 9 valid**
- Best bets: dmayhew (wine specialist = wine dinners), cgregorski, bendres

### 3. Lewnes' Steakhouse (MD-REST-679) — Annapolis, MD
**restaurant, score 85**
- Website: lewnessteakhouse.com ✓
- No emails on website
- FB found: mcl79@cornell.edu — off-domain, blocked
- Apollo: 2 people, 0 with emails
- LinkedIn: 2 names, 0 enrichable
- **Contacts: 0**
- Note: Annapolis upscale steakhouse, been around since 1921. Worth a
  manual call or contact form reach.

### 4. Osteria 177 (MD-REST-681) — Annapolis, MD
**restaurant (Italian fine dining), score 85**
- Website: osteria177.com ✓
- Found: osteria177@yahoo.com — valid
- Apollo/LinkedIn: 13 names found, 0 enrichable
- **Contacts: 1 valid**

### 5. Harry Browne's Restaurant (MD-REST-688) — Annapolis, MD
**restaurant, score 85**
- Website: harrybrownes.net ✓
- Found: harrybrownesevents@gmail.com — valid ← events-specific address
- FB: info@harrybrownes.com → invalid
- Apollo: 0 people
- LinkedIn: 19 names found, 0 enrichable (harrybrownes.com domain bounces)
- **Contacts: 1 valid (harrybrownesevents@gmail.com)**
- Best pick: harrybrownesevents — goes directly to events coordinator

### 6. Les Folies Brasserie (MD-REST-689) — Annapolis, MD
**restaurant (French brasserie), score 85**
- Website stored as brasserie9.com — **wrong website** (Bangkok restaurant)
- Apollo matched Brasserie 9 Bangkok — all off-domain blocked
- LinkedIn: 10 names found, enriched to Bangkok company
- **Contacts: 0**
- Note: Les Folies Brasserie in Annapolis has no web presence under that
  name. May have closed — worth manual verification.

### 7. Flamant (MD-REST-690) — Annapolis, MD
**restaurant, score 85**
- Website: none found (Google returned Baltimore Magazine)
- Apollo matched Flamant the Belgian interior design brand (info@flamant.com
  → do_not_mail)
- LinkedIn: 13 names, all Flamant family (Belgian company)
- **Contacts: 0**
- Note: Flamant the restaurant may be closed or have minimal web presence.
  Worth checking manually — if still open, this is exactly the French/European
  fine dining category that scores highest in taste profile.

### 8. Treaty of Paris Restaurant (MD-REST-691) — Annapolis, MD
**restaurant, score 85**
- Website: none — historical restaurant in Maryland Inn
- FB found: djefferson@jecoannapolis.com — valid but off-domain
  (jecoannapolis.com = JECO, a hospitality management company)
- Apollo: no match
- LinkedIn: 18 names found (French restaurant results — wrong company)
- **Contacts: 1 valid (djefferson@jecoannapolis.com)**
- Note: JECO manages Maryland Inn where Treaty of Paris is located.
  djefferson is likely the right person to contact. Parent company email
  is legitimate for hotel-managed restaurants (same pattern as Pembroke/Doyle).

### 9. Reynolds Tavern (MD-REST-692) — Annapolis, MD
**restaurant (historic tavern/inn), score 85**
- Website: reynoldstavern.org ✓ — good crawl
- Found: events@reynoldstavern.com, reservations@reynoldstavern.com
  — both do_not_mail (ZeroBounce filtered)
- Apollo: 1 person, no email
- LinkedIn: 7 names found, 0 enrichable
- **Contacts: 0 valid**
- Note: events@ is likely the right address but ZeroBounce flagged it.
  Reynolds Tavern is a historic 1747 building — exactly the cozy historic
  vibe that scores well in taste profile. Worth a manual call or contact form.

---

## Taste Review

No new votes since Apr 23 entry (Historic Sotterley, negative).
All patterns from prior batches hold:

- French/European restaurants = GOLD
- DC luxury hotels = major hunting ground
- "Cozy" + "quiet" + "historic" = top venue keywords
- Art galleries = tier 1/2 (queries added last run)
- Country clubs + private clubs still dominant

---

## Bugs Found This Run

| Bug | Details | Fix Needed |
|-----|---------|------------|
| Discovery scoring broken | extract_search_results.js returns empty location/category — all venues score 0, get skipped. Middleburg + Leesburg produced 95 combined results but 0 added. | Fix location parsing in extract_search_results.js; add fallback from query city/state if location field empty |
| pipeline_contacts_count missing | `pipeline.sh: line 2434: /tmp/pipeline_contacts_count: No such file or directory` | Minor — appears when no contacts added; initialize file before reading |
| Les Folies Brasserie website wrong | brasserie9.com resolves to Bangkok restaurant — wrong company | Check if venue is still open; if so, find correct website manually |
| Flamant wrong Apollo match | Apollo matched Belgian furniture brand, not Annapolis restaurant | Same as above — verify venue still exists |
| do_not_mail on events@ | Reynolds Tavern events@reynoldstavern.com flagged as do_not_mail | Consider adding a bypass option for events@ addresses at legit venues |

---

## Files Changed

- `taste_queries.txt` — 9 new queries logged (57 → 66 total)
- `discover.log` — this session logged
- `pipeline.log` — this session logged
- `reports/2026-05-18_14-39.html` — auto-generated HTML report

---

## Next Run TODO

- [ ] **Fix extract_search_results.js location parsing** — biggest win possible.
  Middleburg + Leesburg alone have 95 venues with 0 added due to score bug.
  Fall back to extracting city/state from the query string if location field empty.
- [ ] Naval Academy Club — find correct website / contact manually
- [ ] Les Folies Brasserie — verify if still open; find correct contact
- [ ] Flamant — verify if still open
- [ ] Reynolds Tavern — manual contact form or phone (events@ do_not_mail)
- [ ] Lewnes' Steakhouse — manual contact form (no email found)
- [ ] Continue taste queries — 492 remaining. Next batch: `French restaurant` series
  through Chevy Chase, Great Falls, McLean, Alexandria, Reston, Middleburg, Leesburg
- [ ] Annapolis corridor largely covered — shift next pipeline to DC venues
