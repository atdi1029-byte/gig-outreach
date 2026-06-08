# Outreach Run Report -- 2026-06-08

## Overview

| Metric | Value |
|--------|-------|
| **Discovery: past gig seeds** | 0 new (all 70 exhausted) |
| **Discovery: taste queries run** | 10 |
| **Discovery: total new venues** | 124 |
| **Pipeline: venues processed** | 10 (smart picks) |
| **New valid contacts this run** | 14 (Burning Tree 1, Sovereign 3, YELLOW 3, Cafe Milano 3, DIVINO 1, Le Diplomate 1, Residents 1, Aventino 1) |
| **Apollo credits consumed** | ~16 (12 pipeline + 4 manual enrichment) |
| **ZeroBounce credits remaining** | ~3,621 |
| **Taste reviews processed** | 0 new votes (still current as of Apr 23) |

---

## Discovery Results

### Past Gig Seeds
All 70 gig seeds exhausted. Nothing new.

### Taste Discovery (10 queries run)

Continued the `European bistro` series through Chevy Chase, Great Falls,
McLean, Alexandria, Annapolis, and Roland Park Baltimore. Then started
`private club` series through Georgetown, Dupont Circle, Potomac, Bethesda.

| Query | New Venues Added |
|-------|-----------------|
| European bistro Chevy Chase MD | 6 |
| European bistro Great Falls VA | 0 (no results) |
| European bistro McLean VA | 5 |
| European bistro Alexandria VA | 6 |
| European bistro Annapolis MD | 18 |
| European bistro Roland Park Baltimore MD | 13 |
| private club Georgetown DC | 0 (no results) |
| private club Dupont Circle DC | 10 |
| private club Potomac MD | 43 |
| private club Bethesda MD | 23 |

**124 total venues added.** High yield, but the `private club` queries
for Potomac and Bethesda pulled in lots of junk (swim clubs, tennis
academies, rec centers, YMCAs, community pools). These are miscategorized
as "restaurant" by Google Maps and pass the score threshold because
Potomac/Bethesda are sweet spot cities. The pipeline smart-picks scoring
should filter most out, but a cleanup pass would help.

**Good finds this run:**
- Cafe Normandie, Annapolis (French!)
- Petit Louis Bistro, Roland Park (French bistro)
- Marie Louise Bistro, Baltimore (French)
- Le Comptoir du Vin, Baltimore (French wine bar)
- Congressional Club, DC (private club)
- Woodmont Country Club, Bethesda
- Kenwood Golf and Country Club, Bethesda
- Bethesda Country Club
- Congressional Country Club, Potomac

**462 taste queries remain.**

---

## Pipeline Results

### 1. Burning Tree Club (MD-COUN-915) -- Bethesda, MD
**country_club, score 99 -- top pick**
- Website: none found by pipeline (no domain)
- Pipeline: 0 contacts (no domain = no scraping)
- **Manual check:** Apollo found Charlie Briggs (Golf Professional)
  with verified email `cbriggs@burningtreecc.org`. Domain: burningtreecc.org.
  Saved to sheet.
- **Contacts: 1 valid (cbriggs@burningtreecc.org)**
- Note: Extremely exclusive club (men-only, Presidents play here).
  Golf pro is likely the right contact for entertainment inquiries.

### 2. Jaleo Bethesda (MD-REST-885) -- Bethesda, MD
**restaurant, score 85 -- PERMANENTLY CLOSED**
- Not on official jaleo.com website (only DC, Vegas, Disney Springs remain)
- VRConcierge lists it as permanently closed
- **Contacts: 0 -- marked as CLOSED in notes**
- Note: ThinkFoodGroup still operates Jaleo DC at 480 7th St NW.
  Could pipeline the DC location separately.

### 3. Aventino Cucina (MD-REST-886) -- Bethesda, MD
**restaurant, score 85**
- Website: aventinocucina.com
- events@ and info@ both do_not_mail
- Found off-domain: molly@mhco.studio (valid)
- **Contacts: 1 valid**

### 4. The Sovereign (DC-REST-1024) -- Washington, DC
**restaurant, score 85 -- best result this run**
- Part of Neighborhood Restaurant Group
- keghunt@churchkeydc.com, michael@neighborhoodrestaurantgroup.com,
  guestservices@neighborhoodrestaurantgroup.com -- all valid
- **Contacts: 3 valid**
- Best bet: michael@ (likely management at parent company)

### 5. YELLOW Georgetown (DC-REST-1026) -- Washington, DC
**restaurant, score 85**
- Website: yellowthecafe.com
- georgetown@, unionmarket@, yellow@ -- all valid
- **Contacts: 3 valid**
- Best bet: georgetown@ (location-specific)

### 6. Cafe Milano (DC-REST-1029) -- Georgetown, DC
**restaurant, score 85 -- high-profile venue**
- Website: cafemilano.com
- francisco@, pancrazio@, amila@ -- all valid from Apollo
- **Contacts: 3 valid**
- Note: Famous Georgetown power-dining spot. Perfect for
  classical guitar -- educated wealthy clientele.

### 7. DIVINO Ristorante Enoteca (DC-REST-1030) -- Georgetown, DC
**restaurant (Italian), score 85**
- Website: divinodc.com
- events@divinodc.com do_not_mail
- belmont@divinoristorante.com valid (Apollo)
- **Contacts: 1 valid**

### 8. Le Diplomate (DC-REST-1031) -- Washington, DC
**restaurant (French brasserie), score 85**
- Part of Starr Restaurant Group
- Charlie Smedile (GM): charlie.smedile@starr-restaurant.com valid
- **Contacts: 1 valid**
- Best pick: GM is exactly the right person to contact

### 9. Bistrot Du Coin (DC-REST-1032) -- Dupont Circle, DC
**restaurant (French bistro), score 85**
- Website: bistrotducoin.com
- inquiries@bistrotducoin.com do_not_mail (only email on site)
- **Manual check:** Apollo found 4 people, all with no email:
  - Yannis Felix (Executive Chef/Partner, co-founder since 1999)
  - Michel Verdon (Co-Owner since 1999)
  - Ayca Kargin (Manager)
  - Antoine Delattre (Office Manager)
- **Contacts: 0 valid emails**
- Note: Classic French bistro in Dupont Circle, 25+ years.
  EXACTLY the type that scores 9/10 in taste profile.
  Worth a phone call: (202) 234-6969.

### 10. Residents Cafe & Bar (DC-REST-1042) -- Washington, DC
**restaurant, score 85**
- Website: residentsdc.com
- contact@ do_not_mail
- Lucy Valenti (Server): lucy@residentsdc.com valid
- **Contacts: 1 valid**

---

## Manual Venue Check Summary

| Venue | Pipeline Contacts | Manual Result |
|-------|------------------|---------------|
| Burning Tree Club | 0 | +1 (Apollo: cbriggs@burningtreecc.org) |
| Jaleo Bethesda | 0 | CLOSED -- removed from pipeline |
| Bistrot Du Coin | 0 | 0 (4 people found, all no email) |

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
| Taste discovery junk from "private club" | Potomac (43 added) and Bethesda (23 added) queries returned many swim clubs, tennis academies, community centers, YMCAs. All miscategorized as "restaurant" by Google Maps. Need to add skip_names filter for: pool, swim, tennis, YMCA, community center, aquatic, fitness, pilates |
| Jaleo Bethesda closed | Pipeline still had it as score 85 active venue. Marked as closed in notes. |
| pipeline_contacts_count file missing | `pipeline.sh: line 2579` error when no contacts found. Minor. |

---

## Files Changed

- `taste_queries.txt` -- 10 new queries logged (66 -> 76 total)
- `discover.log` -- this session logged
- `pipeline.log` -- this session logged
- `reports/2026-06-08_01-04.html` -- auto-generated pipeline HTML report

---

## Next Run TODO

- [ ] Add skip_names filters in discover.sh for: pool, swim, tennis, YMCA,
  community center, aquatic, fitness, pilates, recreation center
- [ ] Bistrot Du Coin -- try calling (202) 234-6969 directly
- [ ] Consider adding Jaleo DC (480 7th St NW) as a replacement venue
- [ ] Continue taste queries -- 462 remaining. Next batch: `private club`
  series through Chevy Chase, Great Falls, McLean, Alexandria, etc.
- [ ] DC restaurants dominating smart picks -- great corridor for outreach
