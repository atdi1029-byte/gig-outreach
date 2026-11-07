# Dream sweep 3: award lists (DC / MD / VA), 2026-11-07

Terminal session, WebSearch + WebFetch only (no Chrome, no sheet writes).

Lists worked, region-wide:
- Wine Spectator Restaurant Awards: 2026 Maryland list (Patch, all 28), 2026 DC list (39 names), 2025/2026 Virginia (partial: Fahrenheit 132, Pazzo Pomodoro, Harrimans Grill, Ashby Inn, Inn at Little Washington)
- James Beard semifinalists/finalists 2024, 2025, 2026 (DC, MD, VA)
- Michelin Guide Washington DC 2025: all 25 starred restaurants, plus Bib/recommended additions
- Washingtonian 100 Very Best Restaurants 2026 (99 names) and its Feb 2026 romantic picks
- OpenTable Top 100 Romantic 2025 (VA, MD) and Top 100 2025 (DC)
- Relais & Châteaux (Inn at Little Washington, The Ivy Hotel), Forbes 2026 (Four Seasons DC; no other DMV 4-star entries), AAA Five Diamond (Inn at Little Washington)

Every name was checked against the sheet (dash.json, 5,333 venues, by name and website domain) and the earlier sweep_*.md files.
**Almost every award-list venue in the region is already on the sheet.** About 120 names were checked, and only the ones below are new, open, and on their own verified websites.

## READY TO ADD

| # | Name | Website | Address | City | State | Category | Score | Why |
|---|---|---|---|---|---|---|---|---|
| 1 | Estuary | https://www.estuarydc.com/ | 950 New York Ave NW, Washington, DC 20001 | Washington | DC | restaurant | 4 | Wine Spectator 2026 Best of Award of Excellence. The Conrad DC's signature restaurant: Private Dining Room, Blue Willow Room and main room, 15–100 guests, weddings. Name and address are on its own site. |
| 2 | The Henri | https://www.thehenridc.com/ | 1301 Pennsylvania Ave NW, Washington, DC 20004 | Washington | DC | restaurant | 4 | Wine Spectator 2026 Award of Excellence. An upscale downtown dining room on Pennsylvania Ave (entrance on 13th St). Open Mon–Sat dinner per its own site. |
| 3 | Three Blacksmiths | https://www.threeblacksmiths.com/ | 20 Main Street, Sperryville, VA 22740 | Sperryville | VA | restaurant | 5 | Destination tasting menu in Rappahannock hunt country, near the Inn at Little Washington: weekly fixed multi-course menu from $168, wine pairings. Small, with 20 seats and one seating. About 2 hours' drive, at the edge of the radius. |
| 4 | The Red Hen | https://www.theredhendc.com/ | 1822 1st St NW, Washington, DC 20001 | Washington | DC | restaurant | 3 | Washingtonian 100 Very Best 2026, and on Washingtonian's 2026 romantic list. Wood-fired Italian with a strong wine list, dinner 7 nights. |
| 5 | Dauphine's | https://www.dauphinesdc.com/ | 1100 15th St NW, Washington, DC 20005 | Washington | DC | restaurant | 3 | Michelin Guide DC 2025 (Bib list). Polished New Orleans seafood house and boucherie downtown near the K Street power-lunch crowd. |
| 6 | Ama | https://www.amarestaurant.bar/ | 885 New Jersey Ave SE, Washington, DC 20003 | Washington | DC | restaurant | 3 | James Beard 2026 Best Chef: Mid-Atlantic semifinalist (Johanna Hellrigl). Northern Italian with a wine and spritz program, near Navy Yard and Capitol Hill. |
| 7 | Lapis | https://www.lapisdc.com/ | 1847 Columbia Rd NW, Washington, DC 20009 | Washington | DC | restaurant | 2 | Washingtonian 100 Very Best 2026, and on Washingtonian's 2026 romantic list. Modern Afghan bistro in Adams Morgan. More mid-priced than the rest, so it ranks last. |

## Excluded

Closed (award listings are stale):
- Métier and Kinship (DC, Eric Ziebold): both closed late 2025 (WTOP, May 2026).
- Tail Up Goat (DC, Michelin star): closed Dec 20, 2025, lease ended.
- Gravitas (DC, Michelin star): seized and closed by DC tax office Jan 22, 2026.
- Cranes (DC): closed Feb 18, 2026.
- Marcel's (DC): closed May 12, 2024.
- Charlie Palmer Steak (DC): closed late 2024. Atlas's The Ruxton opens there spring 2027, so add it then.
- La Cuchara (Baltimore): closed indefinitely after a fire, Jan 2026.
- Wit & Wisdom (Four Seasons Baltimore): closed Dec 2018.
- Hiraya / Kayu (DC): closed on H St NE June 2025. The relocation isn't confirmed.
- Corduroy (DC): listed as permanently closed on OpenTable and En Primeur Club.

Couldn't verify on their own website (no address on the page, blocked, or no official site):
- Sagamore Pendry Baltimore, 1715 Thames St: pendry.com returns 403 on every page. Its restaurant Rec Pier Chop House is already on the sheet. Retry later; it's a true luxury venue.
- The Bygone (29th floor, Four Seasons Baltimore): thebygonerestaurant.com renders no address, and atlasrestaurantgroup.com returns 403. Four Seasons Hotel Baltimore is already on the sheet (no website saved).
- Nobu Washington DC, 2525 M St NW: its own pages (home, private events, contact) show no street address, only a maps link. Large event capacity (300 seated buyout, 80-seat Skylight Room), so it's worth a manual add.
- SHIA (DC, Edward Lee, Korean tasting menu; OpenTable Top 100 2025): no official website found, only OpenTable.
- Providencia (DC, Michelin recommended): no official website found.
- Little Pearl (DC, Michelin star): littlepearldc.com shows the name but no street address (921 Pennsylvania Ave SE per listings).
- RdV Vineyards (Delaplane VA): the site's TLS certificate failed, so it couldn't be fetched.
- Airlie (Warrenton VA): the site returns 403. It's also a 3.5-star conference hotel.
- Costiera (Baltimore): the site returns 403.
- Ouzo Bay (Baltimore): ouzobay.com now redirects to the seasonal Ouzo Beach.
- Manalù (Frederick MD, Wine Spectator 2026 Award of Excellence): no official website found.
- Inn at 202 Dover (Easton MD): the domain is now a spam blog. Kent Manor Inn: the domain doesn't resolve.

Shares a domain with a venue already on the sheet (the importer would match it):
- Dōgon (salamanderdc.com = Salamander Washington DC).
- Arrels (arlohotels.com = Arlo Washington DC; arrels-dc.com returns 404).
- Voltaggio Brothers Steak House (mgmnationalharbor.mgmresorts.com = MGM National Harbor).
- CUT by Wolfgang Puck DC (wolfgangpuck.com = already on the sheet as "CUT D.C. by Wolfgang Puck").

Chains, casual, or out of the radius:
- Zaytinya (7-city José Andrés chain), RPM Italian (chain, DC page has no address), Joe's Seafood Prime Steak (chain), Seasons 52, Capital Grille, Morton's, Fogo de Chão, Gordon Ramsay Steak, Facci (3-location chain).
- Tide Room and 1945 Steak & Seafood (Ocean City, over 2.5 h). L'Opossum and Bookbinder's (Richmond, over 2.5 h). Maude & the Bear (Staunton). Le Yaca (Williamsburg).
- Casual Washingtonian 100 entries: Martha Dear, Daru, Duck & the Peach, Namak, Ellē, Koryouri Urara, Bar del Monte, Perry's, Queen's English.

Already on the sheet (sample of the award-list names that matched): Inn at Little Washington, minibar, Jônt, Pineapple and Pearls, Albi, Bresca, Causa, Elcielo, Fiola, Fiola Mare, Masseria, Mita, Rania, Rooster & Owl, Rose's Luxury, Xiquet, The Dabney, Oyster Oyster, Imperfecto, Sushi Taro, Centrolina, Cucina Morini, Pascual, Casa Teresa, Moon Rabbit, Elmina, 1789, Apéro, Annabelle, Bourbon Steak, CUT, Del Mar, Osteria Mozza, Lutèce, Gemini, Nasime, Ellie Bird, Joon, Tremolo, Field & Main, L'Auberge Chez François, 2941, Bistro L'Hermitage, Harrimans Grill, Goodstone, Ashby Inn, Fahrenheit 132, Pazzo Pomodoro, Ivy Inn, Bas Rouge, The Wardroom, The Stewart, Ruse, Magdalena / The Ivy Hotel, CuVino, The Oregon Grille, Lewnes', Antrim 1844, Citron, Charleston, Peerce's, Azumi, Clavel, The Duchess, Wren, Osteria 177, Riggs, Rosewood, Waldorf Astoria, St. Regis, Salamander DC and Middleburg, Pendry DC, Inn at Perry Cabin.
