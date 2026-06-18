# Outreach Run Report -- 2026-06-18

## Overview

| Metric | Value |
|--------|-------|
| **Discovery: taste queries** | 6 web searches |
| **Discovery: new venues added** | 11 |
| **Venues marked closed** | 1 (Harryman House, March 2025) |
| **Pipeline: venues processed** | 11 |
| **Pipeline contacts found** | 19 |
| **Manual check contacts added** | 3 emails + 3 contact forms |
| **Total contacts this run** | 22 emails |
| **Apollo MCP credits consumed** | 0 |
| **Taste reviews processed** | 0 new votes |

---

## Pipeline Results

| # | Venue | Pipeline | Manual | Total |
|---|-------|----------|--------|-------|
| 1 | Bavarian Inn (Shepherdstown WV) | 1 (khenry@) | +1 (booking@) | 2 |
| 2 | Bistro 112 (Shepherdstown WV) | 0 | form saved | form only |
| 3 | Lancaster Arts Hotel (Lancaster PA) | 2 (Deirdre Stevens, Darcy Show) | +1 (ladan@ events) | 3 |
| 4 | Inn at Leola Village (Leola PA) | 8 (goldmine) | fixed website URL | 8 |
| 5 | Al Tiramisu (DC Dupont) | 1 (luigi@ chef/owner) | Wix site unreadable | 1 |
| 6 | Rosemarino D'Italia (DC Dupont) | 0 | form saved | form only |
| 7 | King Street Oyster Bar (Middleburg VA) | 3 (Condren, Esguerra, Riley) | verified | 3 |
| 8 | Maple Ave Restaurant (McLean VA) | 1 (juste@) | verified, GM Ricardo Teves | 1 |
| 9 | Agora Tysons (McLean VA) | 0 | info@ generic only | 0 (phone) |
| 10 | Six Wicket Vineyards (Myersville MD) | 1 (kathy@) | contact form | 1 |
| 11 | Simple Theory Wines (Frederick MD) | 2 (Melissa, Wendy) | +1 (sales@) | 3 |

---

## Manual Check Notes

- **Inn at Leola Village** website was wrong (innatleola.com = "Coming Soon"). Fixed to theinnatleolavillage.com
- **Bavarian Inn** /contact 404 -- booking@ found via curl on homepage
- **Lancaster Arts Hotel** no emails in raw HTML -- found ladan@johnjjeffries.com (on-site restaurant events) via Google
- **Al Tiramisu** is a Wix site, curl/WebFetch can't extract content
- **Rosemarino D'Italia** has info@ (generic, skipped) + private dining inquiry form

---

## Taste Review

No new votes. All patterns hold.

---

## Files Changed

- `taste_queries.txt` -- 6 new queries
- `pipeline.log` -- this session
- Harryman House (MD-REST-1807) status -> closed
