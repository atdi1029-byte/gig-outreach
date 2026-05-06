# LinkedIn Run Report — 2026-05-06

## Overview

| Metric | Value |
|--------|-------|
| Venues targeted | 5 |
| LinkedIn pages scraped | 3 pages per venue |
| New contacts added to sheet | 1 |
| Apollo enrichments | 1 (no email returned) |
| linkedin_pending cleared | 5 |

---

## Results by Venue

### Solomons Victorian Inn (MD-HOTE-331)
- **LinkedIn**: 5 results, 0 confirmed employees (venue name not in any titles)
- **Apollo API**: 0 results
- **Outcome**: No contacts found. linkedin_pending cleared.

### Hambleton Inn Bed & Breakfast (MD-HOTE-441)
- **LinkedIn**: 4 results, 0 confirmed employees
- **Apollo API**: 0 results
- **Outcome**: No contacts found. linkedin_pending cleared.

### Ruse Restaurant (MD-REST-431)
- **LinkedIn**: 30 results, 3 matches on keyword filter
  - **Michael Correll** — Chef/Partner, Ruse at Wildset Hotel ✓ (added to sheet)
  - Vildan Remvidas — food tech vendor, not an employee
  - Gaëtan Dubret — Restaurant Manager Sommelier, Sydney-based
- **Apollo enrichment**: Michael Correll found in database, no email available
- **Outcome**: 1 contact added (C-1173), no email yet. linkedin_pending cleared.
- **Note**: Michael Correll is a 2025 James Beard Best Chef Mid-Atlantic semi-finalist — strong contact worth pursuing manually.

### Limoncello Italian Restaurant & Wine Bar (MD-REST-432)
- **LinkedIn**: 30 results scraped, JSON parse error on merge (apostrophe in name broke string)
- **Apollo API**: 0 results
- **Outcome**: 0 confirmed employees. linkedin_pending cleared.
- **Bug**: Script crashes on names with apostrophes/special chars — needs fix.

### Parsonage Inn (MD-HOTE-443)
- **LinkedIn**: 30 results, 5 keyword matches — all false positives (different venues named "Parsonage Inn" in NC, CA, NH)
- **Apollo API**: 0 results
- **Outcome**: 0 real contacts for St. Michaels location. linkedin_pending cleared.
- **Note**: Contaminated email (wadesinn@wadespoint.com) still needs to be removed.

---

## Issues Found

| Issue | Venue | Action Needed |
|-------|-------|---------------|
| JSON parse error on apostrophes in names | Limoncello | Fix linkedin_scrape.sh string escaping |
| False positives on generic venue names | Parsonage Inn | Filter by location in Python step |
| SSL cert error on sheet push (Python) | All | Fix with `ssl.create_default_context()` or use curl instead |
| Contaminated email still in sheet | Parsonage Inn (MD-HOTE-443) | Delete wadesinn@wadespoint.com from this venue |

---

## Next Steps

- [ ] Remove wadesinn@wadespoint.com from Parsonage Inn contacts
- [ ] Try to find Ruse/Michael Correll email via contact form or manual search
- [ ] Fix apostrophe bug in linkedin_scrape.sh
- [ ] Fix SSL cert error in Python sheet push
- [ ] Add location filtering to LinkedIn confirm step (skip results outside MD/DC/VA)
