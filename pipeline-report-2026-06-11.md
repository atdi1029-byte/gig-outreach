# Outreach Run Report -- 2026-06-11

## Overview

| Metric | Value |
|--------|-------|
| **Discovery: past gig seeds** | 0 new (all 70+ exhausted) |
| **Discovery: taste queries run** | 12 (web search, Google Maps returned 0) |
| **Discovery: total new venues** | 17 (7 dupes skipped) |
| **Pipeline: venues processed** | 11 (smart picks) |
| **New valid contacts this run** | 12 (AMBAR 3, Julii 2, Ege Market 1, Kielbasa Factory 1, La Bonne Vache 1, European Delight 1*, MezeHub 1*, Gregorio's 1) |
| **Apollo MCP credits consumed** | 3 (Gregorio's 2, Ruta 1) |
| **Apollo pipeline credits consumed** | 6 |
| **ZeroBounce credits remaining** | ~3,534 |
| **Taste reviews processed** | 0 new votes since Apr 23 |

*European Delight contact (thrive@joe.coffee) is for wrong venue -- pipeline scraped joe.coffee instead of the actual deli. MezeHub contact (stmichaels@avaspizzeria.com) is off-domain junk.

---

## Discovery Results

### Past Gig Seeds
All 70+ gig seeds exhausted. Nothing new.

### Google Maps Taste Discovery (via discover.sh --taste)
Ran 10 "wine bar" queries across sweet spot cities -- ALL returned 0 results. Chrome/Google Maps DOM scraping appears broken (every query returns "No results found"). **Bug to investigate next run.**

### Web Search Taste Discovery (manual)
Switched to web search. 12 queries across wine bars, Italian fine dining, art galleries, country clubs, and historic inns. Added 17 new venues:

| Category | New Venues |
|----------|-----------|
| Wine bars (DC/MD) | 7: Lutece, Veritas, Maison Bar a Vins, Amelie DC, Vin Sur Vingt, Nero DC, Co2 Lounge |
| Italian fine dining | 4: Fratelli, Ristorante Tosca, La Panetteria, Positano, Fiola Mare Bethesda |
| Art galleries/museums | 3: Fathom Gallery Georgetown, Circle Gallery Annapolis, Annapolis Maritime Museum |
| Historic inns | 2: Red Fox Inn Middleburg, Welbourne Inn Middleburg |
| Country clubs | 0 (all already in sheet) |

**Good finds:** Maison Bar a Vins (1000+ bottle French wine bar in brownstone), Red Fox Inn (since 1728, oldest inn in VA), Fathom Gallery (150-person event space Georgetown).

---

## Pipeline Results

### 1. AMBAR Restaurant, Shaw (DC-REST-1071) -- score 85
- Website: ambarrestaurant.com
- clarendon@ambarrestaurant.com -- valid
- shaw@ambarrestaurant.com -- valid
- Laura Scarpa (Founder & Partner): laura@ambarhrservices.com -- valid (off-domain)
- **Contacts: 3 valid**

### 2. Gregorio's Trattoria (MD-REST-1073) -- score 85
- Website: gregoriostrattoria.com
- Pipeline: 0 contacts (wrong FB/IG scraped: augiesbeergarden)
- **Manual check:** Apollo MCP found Greg Kahn (Managing Partner) with verified email gregory@gregoriostrattoria.com. ZeroBounce confirmed valid. Anne Donovan email invalid.
- **Contacts: 1 valid (gregory@gregoriostrattoria.com)**

### 3. Nova Europa Restaurant (MD-REST-1075) -- score 85
- Website: novaeuroparestaurant.com
- Pipeline: 0 valid (only .read junk)
- Manual check: Apollo found Jake (Busser, no email). LinkedIn 0 results. Family-owned Portuguese since 1982. Only info@ email exists.
- **Contacts: 0 valid -- dead end**

### 4. O PORTUGUES - European Market Inc. (MD-REST-1076) -- score 85
- Website: wheree.com landing page (not real website)
- Pipeline: 0 valid (off-domain junk)
- Manual check: Apollo 0, LinkedIn 0. Small European grocery in Derwood MD.
- **Contacts: 0 valid -- dead end (not a gig venue)**

### 5. MezeHub (MD-REST-1079) -- score 85
- Website: mezehub.com
- sales@mezehub.com -- do_not_mail
- stmichaels@avaspizzeria.com -- valid but WRONG VENUE
- Doug Wheeler (Co-Founder): doug@mezehub.com -- invalid
- **Contacts: 0 valid (junk only)**

### 6. Ruta Ukrainian Restaurant (MD-REST-1082) -- score 85
- Website: rutadc.us (Wix)
- info@rutadc.us -- do_not_mail
- Manual check: Apollo MCP found Ruslan Falkov (Director of Operations/co-owner), email unavailable. LinkedIn profile exists but no email.
- **Contacts: 0 valid emails (1 pending: Ruslan Falkov)**

### 7. Julii (MD-REST-1084) -- score 85
- Website: julii.com
- mara@eatcava.com -- valid (off-domain, restaurant group contact)
- molly@mhco.studio -- valid (off-domain, hospitality consultant)
- **Contacts: 2 valid**

### 8. European Delight (MD-REST-1089) -- score 85
- **WRONG WEBSITE**: Pipeline scraped joe.coffee (coffee app). Real venue is a small Eastern European deli at 1488 Rockville Pike, Rockville MD.
- thrive@joe.coffee -- valid but WRONG VENUE
- **Contacts: 0 valid for actual venue**

### 9. Ege Market (MD-REST-1092) -- score 85
- Website: egemarketbethesda.com
- egemarketgs@gmail.com -- valid (from Facebook)
- **Contacts: 1 valid**

### 10. Kielbasa Factory (MD-REST-1098) -- score 85
- Website: kielbasafactory.com
- kielbasafactory@hotmail.com -- valid
- **Contacts: 1 valid**

### 11. La Bonne Vache (MD-REST-1099) -- score 85
- Website: labonnevachedc.com
- Claire Wilder (Owner): claire@labonnevachedc.com -- valid
- **Contacts: 1 valid -- best result (owner email!)**

---

## Manual Venue Check Summary

| Venue | Pipeline | Manual Result |
|-------|----------|---------------|
| Gregorio's Trattoria | 0 | +1 (Apollo MCP: Greg Kahn, gregory@gregoriostrattoria.com) |
| Nova Europa | 0 | 0 (family-owned, no personal emails anywhere) |
| O Portugues | 0 | 0 (small grocery, dead end) |
| Ruta Ukrainian | 0 | 0 emails (found Ruslan Falkov, Dir of Ops, no email) |
| MezeHub | 0 valid | 0 (junk off-domain only) |
| European Delight | wrong site | 0 (pipeline had wrong website entirely) |

---

## Taste Review

No new votes since Apr 23 (Historic Sotterley, negative).
All patterns from prior batches hold:

- French/European restaurants = GOLD
- DC luxury hotels = major hunting ground
- "Cozy" + "quiet" + "historic" = top venue keywords
- Art galleries = tier 1/2
- Country clubs + private clubs still dominant

---

## Bugs / Issues This Run

| Issue | Details |
|-------|---------|
| Google Maps taste discovery broken | discover.sh --taste returned 0 results for ALL 10 wine bar queries. Chrome DOM scraping failing -- "No results found" on every query. Need to debug scroll_search_results.js / extract_search_results.js. |
| European Delight wrong website | Pipeline matched joe.coffee as the venue domain. The real venue has no website (small deli). Pipeline domain lookup needs improvement for venues without real websites. |
| Pipeline smart picks = all MD-REST | All 11 smart picks were Bethesda/Potomac restaurants scored 85. No diversity in category or location. Smart pick scoring may be over-indexing on Bethesda/Potomac sweet spots. |
| Gregorio's wrong social links | Pipeline scraped augiesbeergarden for both FB and IG -- completely wrong venue. |
| MezeHub off-domain junk | FB scraper returned avaspizzeria.com emails, IG snippet returned them too. Cross-contamination from adjacent FB pages. |

---

## Files Changed

- `taste_queries.txt` -- 12 new queries logged (108 -> 120 total)
- `discover.log` -- this session logged
- `pipeline.log` -- this session logged
- `reports/2026-06-11_23-43.html` -- auto-generated pipeline HTML report

---

## Next Run TODO

- [ ] Debug Google Maps taste discovery (scroll/extract JS broken)
- [ ] Add skip filters for small grocery/deli/market venues
- [ ] Fix pipeline domain lookup for venues with no real website
- [ ] Continue taste queries -- 438+ remaining. Next batch: Italian fine dining, art gallery, boutique hotel across more cities
- [ ] Ruta Ukrainian -- try calling Ruslan Falkov or DM via LinkedIn
- [ ] Consider adding Jaleo DC (480 7th St NW) as a venue
