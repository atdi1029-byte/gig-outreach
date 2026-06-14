# Outreach Run Report -- 2026-06-14 (Run 2)

## Overview

| Metric | Value |
|--------|-------|
| **Discovery: past gig seeds** | 0 new (all 74 exhausted) |
| **Discovery: taste queries run** | 6 web searches |
| **Discovery: new venues added** | 6 (L'Hirondelle Club, Visitation Hotel, Tersiguel's [CLOSED], 18th & 21st, Thompson Italian, Parallel Wine) |
| **Venues marked closed** | 2 (Trapezaria, Tersiguel's) |
| **Pipeline: venues processed** | 11 |
| **Pipeline contacts found** | 11 |
| **Manual check contacts added** | 5 emails + 3 contact forms |
| **Total contacts this run** | 16 emails |
| **Apollo MCP credits consumed** | 2 (Saeed Abtahi, Ivuca Svalina -- both unavailable) |
| **Taste reviews processed** | 0 new votes |

---

## Discovery Results

### Web Search Taste Discovery
6 searches: French restaurants Bethesda/Potomac, boutique hotels Frederick, wine bars Tysons/Reston, private clubs Towson/Ruxton, fine dining Ellicott City/Columbia, Italian/French Alexandria.

**6 new venues added:**
- Visitation Hotel Frederick (MD) -- boutique hotel in 1846 convent, Voltaggio restaurant
- L'Hirondelle Club (Ruxton MD) -- private club est 1872
- Tersiguel's French Country (Ellicott City) -- CLOSED, marked in sheet
- 18th & 21st (Columbia MD) -- elevated supper club
- Thompson Italian (Alexandria VA) -- Old Town King Street
- Parallel Wine and Whiskey Bar (Ashburn VA)

**Venues marked closed:**
- Trapezaria (Rockville MD) -- closed March 2023
- Tersiguel's (Ellicott City MD) -- closed December 2025

---

## Pipeline Results

### 1. L'Hirondelle Club (MD-PRIV-1754) -- Ruxton, MD
- Michael Cochrane (Dir of Racquets): mcochrane@lhirondelle.com -- valid
- Parker Greene (Executive Chef): pgreene@lhirondelle.com -- valid
- Michael Barron: mbarron@lhirondelle.com -- valid
- Tony James: tjames@lhirondelle.com -- valid
- **Manual:** info@lhirondelle.com + full leadership team (GM Jason Donati, Event Dir Leanne Franco, Membership Dir Abby Izydore, F&B Dir Thomasine Dolan)
- **Contacts: 5 valid emails + named staff**

### 2. Visitation Hotel Frederick (MD-HOTE-1753) -- Frederick, MD
- Pipeline: 0 (probes found 17 paths but all false positives from Wix-style site)
- **Manual:** info@visitationhotel.com + contact form
- **Contacts: 1 valid email + form**

### 3. Cafe Renaissance (VA-REST-1163) -- Vienna, VA
- Pipeline: 0
- Manual: Owner Saeed Abtahi found (no email on Apollo or web). Phone only: 703-938-3311
- **Contacts: 0 emails (phone only)**

### 4. De Ma Vie (VA-REST-1168) -- Falls Church/Tysons, VA
- Pipeline: 0
- **Manual:** info@demavie.co, owner Adel Kebaish (Google search)
- **Contacts: 1 valid email**

### 5. Knead Wine (VA-REST-1191) -- Middleburg, VA
- Chip Fey (owner/Master Sommelier): chip@kneadwine.com -- valid
- Also known: kneadwine@gmail.com
- **Contacts: 1 valid email**

### 6. Echelon Wine Bar (VA-REST-1201) -- Leesburg, VA
- Julie Seibert: julie@echelonwinebar.com -- valid
- Catherine Lindahl: clindahl@leesburgva.gov -- valid (city contact, may not be venue)
- **Contacts: 2 valid emails**

### 7. Caffe Bottega Italiana (VA-REST-1197) -- Leesburg, VA
- Pipeline: 0
- **Manual:** info@bottegaitalianacaffe.com, owner David
- **Contacts: 1 valid email**

### 8. Old House Cosmopolitan (VA-REST-1150) -- Alexandria, VA
- Pipeline: 0
- Manual: Owners Ivuca & Amela Svalina (Apollo: no email). Contact form at /contact-1
- **Contacts: 0 emails (form only)**

### 9. Thompson Italian (VA-REST-1757) -- Alexandria, VA
- Gabriel Thompson (Chef/Owner): gabe@thompsonitalian.com -- valid
- Sarah Ewald: sarah@thompsonitalian.com -- valid
- Carson Burns: carson@thompsonitalian.com -- valid
- **Manual:** alexandria@thompsonitalian.com (location email), GM Mel Haynes-Dunphy, Chef Lucy Dakwar
- **Contacts: 4 valid emails + named staff**

### 10. Parallel Wine and Whiskey Bar (VA-WINE-1758) -- Ashburn, VA
- jason@parallelwinebistro.com -- valid
- Also known: info@parallelwinebistro.com
- **Contacts: 1 valid email**

### 11. 18th & 21st (MD-REST-1756) -- Columbia, MD
- Pipeline: 0
- Manual: Contact form at cured1821.com/contact, phone 667-786-7111
- **Contacts: 0 emails (form only)**

---

## Manual Venue Check Summary

| Venue | Pipeline | Manual Result |
|-------|----------|---------------|
| Visitation Hotel | 0 | +1 email (info@visitationhotel.com) + form |
| Cafe Renaissance | 0 | Owner found, no email (phone only) |
| De Ma Vie | 0 | +1 email (info@demavie.co) + owner name |
| Caffe Bottega | 0 | +1 email (info@bottegaitalianacaffe.com) + owner |
| Old House Cosmopolitan | 0 | Owners found, no email (form only) |
| 18th & 21st | 0 | form only |
| L'Hirondelle Club | 4 | +1 email (info@) + leadership names |
| Thompson Italian | 3 | +1 email (alexandria@) + GM/chef names |

---

## Taste Review

No new votes since Apr 23. All patterns hold.

---

## Bugs / Issues

| Issue | Details |
|-------|---------|
| Probe false positives | Visitation Hotel (Wix site) returned 200 for ALL 17 probe paths. Need content-length or content-hash validation to skip identical pages. |
| De Ma Vie slow (11 min) | All probes hit + Google fallback. Mostly wasted time on false probe paths. |
| Echelon clindahl@leesburgva.gov | City government email, not venue contact. Pipeline shouldn't save .gov emails as venue contacts. |

---

## Files Changed

- `taste_queries.txt` -- 6 new queries
- `pipeline.log` -- this session
- Trapezaria (MD-REST-1743) status -> closed
- Tersiguel's (MD-REST-1755) status -> closed

---

## Next Run TODO

- [ ] Add content-hash check to subpath probes (skip if same content as homepage)
- [ ] Filter .gov emails from venue contacts
- [ ] Fix probe list -- too many paths slows down every venue unnecessarily
