# Discovery log

Every search for new venues, so none is run twice (Alex, Nov 7 2026: "Make sure we are keeping track so we
don't do searches over again too"). Check this file before any sweep and add a row after it. Each search's
write-up is the `sweep_*.md` file named in the row. `import_sweep_files.py` puts its READY TO ADD rows on
the sheet, and it skips venues already there.

## Best-of searches (region-wide, by kind) — do these first

| Date | File | Lists and kinds covered | Added | Gaps to retry |
|---|---|---|---|---|
| 2026-11-07 | sweep_dream_dining_2026-11-07.md | French/European, fine dining, tasting menus, upscale Italian/Spanish, private dining (Michelin, Washingtonian, Baltimore mag) | 25 found | Yelp, TripAdvisor, OpenTable pages refused fetching |
| 2026-11-07 | sweep_dream_hotels_2026-11-07.md | 5-star, luxury, boutique, historic inns | 6 found | Sagamore Pendry, Airlie, Hotel Washington (their sites blocked the check) |
| 2026-11-07 | sweep_dream_clubs_wine_2026-11-07.md | elite city clubs, country clubs, wine bars, estate wineries | 33 found | |
| 2026-11-07 | sweep_dream2_lists_2026-11-07.md | full Michelin Guide DC list, Washingtonian 100, Baltimore mag best, NoVa mag best (about 130 already on the sheet) | 14 found | Baltimore and NoVa magazine pages refused fetching; AAA 2026 PDFs unreadable |
| 2026-11-07 | sweep_dream2_estates_2026-11-07.md | event estates, mansions, hotel piano bars, embassy and cultural venues, Annapolis, Middleburg, Hunt Country, Eastern Shore | 13 found | George Peabody Library, Decatur House (sites didn't load) |
| 2026-11-07 | sweep_dream3_awards_2026-11-07.md | Wine Spectator awards, James Beard, OpenTable romantic/top 100, Relais & Châteaux, AAA Diamonds | 7 found (almost every award venue was already on the sheet) | closed: Métier, Kinship, Tail Up Goat, Gravitas, Cranes |
| 2026-11-07 | sweep_dream3_stays_2026-11-07.md | Forbes, Condé Nast, T+L, Historic Hotels of America, Select Registry, wedding guides' estates | 10 found | Sagamore Pendry, Airlie (403) |
| 2026-11-07 | sweep_dream3_clubs_2026-11-07.md | Platinum Clubs, Golf Digest/Golfweek private, historic city clubs, VA Governor's Cup, MD Comptroller's Cup, best wine bars | 3 found (sheet already had nearly all) | |
| 2026-11-08 | sweep_dream4_weddings_2026-11-08.md | wedding/event award venues (Washingtonian Weddings, Baltimore and NoVa magazine picks, Knot/WeddingWire winners), Baltimore and Annapolis private clubs, embassy residences and cultural institutes, faculty clubs | running | |
| 2026-11-08 | sweep_dream4_retry_2026-11-08.md | retry of blocked sites (Sagamore Pendry, Airlie, Hotel Washington, Peabody Library, Decatur House, Chateau O'Brien), then hotel bars, lounges, rooftop and private dining rooms in DC, Baltimore, Annapolis, Alexandria | running | |

From dream4 on, every prompt also sets a hard 2-hour drive limit from Pasadena MD. The planner enforces it with the measured drive time.

The dream-dining, hotels and clubs searches overlap, and all three put 52 new venues on the sheet. dream2 added 27, and dream3 18. By dream3 the best-of lists were close to used up: most names were already on the sheet.

## Town sweeps

| Date | File | Area | Added |
|---|---|---|---|
| 2026-08-25 | sweep_vienna_tysons_2026-08-25.md | Vienna / Tysons VA | |
| 2026-08-31 | sweep_cleveland_park_2026-08-31.md | Cleveland Park DC | |
| 2026-09-10 | sweep_georgetown_2026-09-10.md | Georgetown DC | |
| 2026-09-15 | sweep_reston_2026-09-15.md | Reston VA | |
| 2026-09-21 | sweep_spring_valley_2026-09-21.md | Spring Valley DC | |
| 2026-09-28 | sweep_falls_church_2026-09-28.md | Falls Church VA | 68 |
| 2026-11-06 | sweep_frederick_2026-11-06.md | Frederick MD | |
| 2026-11-06 | sweep_chestertown_2026-11-06.md | Chestertown MD | |
| 2026-11-06 | sweep_arlington_2026-11-06.md | Arlington VA | |
| 2026-11-07 | sweep_towson_2026-11-07.md | Towson MD | |
| 2026-11-07 | sweep_silver_spring_kensington_2026-11-07.md | Silver Spring + Kensington MD | |
| 2026-11-07 | sweep_havre_de_grace_2026-11-07.md | Havre de Grace MD | |
| 2026-11-07 | sweep_fredericksburg_2026-11-07.md | Fredericksburg VA | |

The three Nov 6 sweeps put 92 venues on the sheet between them, and the four Nov 7 town sweeps 118. Older town and region sweeps are also
recorded in the app's discovery tracker (discovery-tracker.html, `action=load_discovery`).

## Ideas not run yet

- Shenandoah and Northern Neck inns: too far (over 2 hours), skip.
- Done in dream4: wedding awards, Baltimore and Annapolis clubs, embassy venues, and the retry of blocked sites.
