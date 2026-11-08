# Dream sweep 4: wedding/event award venues, clubs, embassies, faculty clubs (2026-11-08)

Search by kind across DC / MD / VA, within ~2 h of Pasadena, MD. WebSearch + WebFetch only (no browser).
Every candidate was checked against the sheet (`dash.json`, 5,351 venues, by name and by website domain,
whatever the status) and against earlier `sweep_*.md` files.

**Sources searched:** Best of Baltimore Weddings 2025 readers' poll (venue categories), Northern Virginia
Magazine Best of NoVA 2025 weddings, The Knot / WeddingWire DC-area venue roundups, Washingtonian wedding
tags, the DC / Maryland / Annapolis–Eastern Shore wedding venue price comparisons for 2026 (30 + 25 + 22
ranked venues), private-estate venue guides, the Embassy Series and other embassy concert listings, cultural
institutes, university faculty and alumni clubs, Baltimore / Annapolis / DC private clubs, Forbes 2026 and
AAA Four Diamond 2026 lists, and new 2025–2026 hotel and venue openings.

**Result:** the sheet already covers almost every top-tier venue in the region. I checked about 330
names, and more than 90% were already on it: every Forbes and AAA hotel, all the DC city clubs, the
country clubs and yacht clubs, all the big DC museum and mansion venues, the Eastern Shore inns and the
Middleburg estates. Most of the rest were already in earlier sweep files. What's left is below. Each one
has its own official site, fetched, with the name and address on it.

## READY TO ADD

| # | Name | Website | Address | City | State | Category | Score | Why |
|---|------|---------|---------|------|-------|----------|-------|-----|
| 1 | Decatur House | https://www.whitehousehistory.org/decatur-house | 1610 H Street NW | Washington | DC | event_venue | 5 | 1818 Latrobe mansion on Lafayette Square run by the White House Historical Association. Its Carriage House, Courtyard and historic parlors host weddings and receptions, and it is #6 on the 2026 DC luxury wedding venue ranking. The WHHA site blocks automated fetches (403), so I verified the venue from WHHA's own rental guidelines PDF (dated 3/12/2026, with 2027 rates), which names Decatur House and the 1610 H Street NW entrance. |
| 2 | International Student House (I-House DC) | https://ihousedc.org/ | 1825 R Street NW | Washington | DC | event_venue | 3 | 1912 Tudor-revival mansion (the Meserve-Lloyd House) near Dupont Circle that hosts Embassy Series chamber concerts, ambassador talks and a gala. It rents its rooms for dinners and receptions. The official site gives the address. |
| 3 | Mt. Washington Mill Dye House | https://www.dyehouseevents.com/ | 1340 Smith Ave | Baltimore | MD | event_venue | 3 | Co-winner of the Industrial & Rustic category in the 2025 Best of Baltimore Weddings readers' poll. Restored 19th-century mill building that hosts weddings, galas and fundraisers. The official site gives the address. |
| 4 | Westminster Hall | https://westminsterhall.org/events | 519 W. Fayette St | Baltimore | MD | event_venue | 3 | Gothic-revival church hall (Poe's burial ground) downtown, run by the University of Maryland School of Law, that hosts weddings, receptions and galas. The official events page places it "at the corner of Fayette and Greene Streets" but gives no street number; 519 W. Fayette St comes from its public listings. |
| 5 | Samuel Riggs IV Alumni Center (University of Maryland) | https://riggs.umd.edu/ | 7801 Alumni Drive | College Park | MD | event_venue | 3 | UMD's Georgian alumni and university club building, with a marble reception hall. It offers wedding and special-event packages. This is the faculty/alumni-club fit in the region (none of the area universities runs a separate faculty club). The official site gives the address. |
| 6 | The Hotel at the University of Maryland | https://www.thehotelumd.com/ | 7777 Baltimore Ave | College Park | MD | hotel | 3 | AAA Four Diamond independent hotel with ballrooms, terraces and about 43,000 sq ft of event space, used for galas and weddings. The official site gives the address. |
| 7 | The Historic Clifton Mansion | https://cliftonmansion.com/ | 2701 Saint Lo Drive | Baltimore | MD | event_venue | 3 | Johns Hopkins' Italianate summer estate in Clifton Park, with a ballroom, a drawing room and a wraparound porch. It rents for weddings and receptions (fees go to Civic Works). The official site gives the address. |
| 8 | The George Washington University Museum and The Textile Museum | https://museum.gwu.edu/ | 701 21st St. NW | Washington | DC | museum | 3 | University museum and cultural institute in Foggy Bottom that hosts opening receptions and university events. The official site gives the address; it lists an event-reservation link but publishes no rental details. |

## Excluded

**Not verifiable: the official site blocked the fetch, didn't resolve, or showed no address**
- SPAIN arts & culture (Former Residence of the Ambassadors of Spain, 2801 16th St NW): it hosts concerts and receptions, but spainculture.us returns 403.
- Goethe-Institut Washington: goethe.de returns 403.
- Alliance Française de Washington (2142 Wyoming Ave NW, concerts): francedc.org returned an empty page and a "page not found" error.
- Embassy of Finland (concerts, rents its premises to partners): finlandabroad.fi returns 403.
- Japan Information & Culture Center (Embassy of Japan): returns 403.
- Korean Cultural Center Washington: koreaculturedc.org is now a hijacked casino domain, and washingtondc.korean-culture.org redirects in a loop. Most of its concerts are also held at partner venues.
- Perry Belmont House (1618 New Hampshire Ave NW, Beaux-Arts mansion): no official website found, only Cvent and directory listings.
- Valley Country Club / The Mansion at Valley CC (Towson; finalist in the 2025 Best of Baltimore Weddings Clubs category): valleycountryclub.com fails the SSL handshake. Worth retrying with another tool.
- Tremont Grand (Baltimore): tremontgrand.com fails with a TLS error.
- Maryland Center for History and Culture (event rentals): mdhistory.org returns 403.
- The Clarice Smith Performing Arts Center (UMD venue rental): the site's certificate was rejected.
- Bowling Brook Mansion (Keymar, MD): no official website found, only directories.
- Bonnie View Country Club (Pikesville): no official website found.
- Elkridge-Harford Hunt Club (Monkton): its official site gives no address and mentions no events or rentals.
- Officina at the Wharf (DC): officinadc.com returns 404, and a fall 2026 report says it is closing.
- Riverside on the Potomac (Leesburg): returns 403.

**Closed or not bookable**
- Merchants Club (Baltimore): closed in 1989.
- Stone Manor Country Club (Middletown, MD): reported closed, with weddings moved to Springfield Manor.
- Annapolis Roads Club: no current club under that name (it split into separate clubs and went public in 1951).
- Riggs Library (Georgetown University): run by the President's office for university-sponsored functions only, not open for outside events.
- Davidge Hall (UMB): a campus lecture hall booked through university event services, not a reception venue.
- United States Institute of Peace: federal building; its use as an event venue is uncertain since 2025.
- Mandarin Oriental Washington: became Salamander DC, now The Potomac Hotel (on the sheet).
- Clifton Inn (Charlottesville): too far.

**Already on the sheet (by domain or name) or in an earlier sweep file.** Checked but not repeated here: George Town Club (georgetownclub.org), City Tavern Club, DACOR Bacon House, Anderson House, Meridian House, Dumbarton House, Tudor Place, Evermay, Heurich House, Woodrow Wilson House, Hillwood, Dumbarton Oaks, Kreeger, Phillips, Folger, NMWA, Art Museum of the Americas, La Maison Française, Italian Cultural Institute, Austrian Cultural Forum, House of Sweden, Mexican Cultural Institute, Embassy Series, Carnegie Science, DAR, National Building Museum, Mellon Auditorium, Washington National Cathedral, every DC luxury hotel (Four Seasons, Jefferson, Hay-Adams, Willard, Rosewood, Park Hyatt, Waldorf Astoria, St. Regis, Salamander / The Potomac, Conrad, Pendry, Fairmont, Watergate, The Darcy, The LINE, Eaton, Hoya Hotel), Cosmos, Metropolitan, University Club, Sulgrave, Arts Club, Army and Navy Club, Woman's National Democratic Club, Chevy Chase, Congressional, Columbia, Kenwood, Woodmont, Lakewood, Manor CC, Bethesda CC, Baltimore's Maryland Club, Center Club, Engineers Club, Hamilton Street Club, Mount Vernon Club, Johns Hopkins Club, Elkridge Club, Green Spring Valley Hunt Club, Baltimore CC, Suburban, Woodholme, Hayfields, Hunt Valley CC, Chestnut Ridge, Hillendale, Rolling Road, Annapolis Yacht Club, Eastport YC, Severn Sailing, Sherwood Forest, Gibson Island Club, Chesapeake YC, Naval Academy Club, Chartwell, Talbot CC, Tred Avon YC, Miles River YC, Chester River Y&CC, Paca House, Hammond-Harwood House, Historic Inns of Annapolis, Whitehall, London Town, Inn at Perry Cabin, The Oaks, Tidewater Inn, Bartlett Pear, Inn at 202 Dover, Robert Morris Inn, Sagamore Pendry, Four Seasons Baltimore, The Ivy, Lord Baltimore, Hotel Revival, George Peabody Library, Walters, BMA, Evergreen, Homewood, Ladew, Cylburn, The Belvedere, Gramercy, Glenview, Strathmore, Woodend, Historic Oakland, Belmont Manor, Elkridge Furnace Inn, Antrim 1844, Liriodendron, Mount Harmon, Sotterley, Brittland, Ceresville, Pavilion at Weatherly, Newton White, Oxon Hill Manor, Riversdale, Salamander Middleburg, Goodstone, Red Fox Inn, Greenhill Vineyards, Boxwood, RdV, National Sporting Library, Oatlands, Morven Park, Raspberry Plain, Rust Manor, Poplar Springs, Airlie, Inn at Vint Hill, Lansdowne, Mount Vernon Estate, River Farm, Woodlawn, Gunston Hall, Carlyle House, Lee-Fendall, L'Auberge Chez François, Harrimans, Gari Melchers Belmont, Kenmore, Chatham Manor, Academy Art Museum, Loyola, St. John's College and the Smith College Club.

**Below the bar (casual or mid-market winners of the readers' polls):** Pine Ridge Farm, Vignon Manor Farm, Bortner Valley, Chase Court, Vandiver Inn, Island View Waterfront, Marriott Owings Mills, Live! Casino, Turf Valley, Hopkins Farm Brewery, Bohemia Overlook, Big Truck Farm, The Winslow, Kylan Barn, Wildflower Estate, Celebrations at the Bay, Anchor Inn, Kurtz's Beach, Silver Swan Bayside, Herrington on the Bay, Blackwall Barn, Maria's Love Point, Stone Tower and Morais (both already on the sheet), Tranquility Farm, Paradise Springs, Westfields, and Cabell's Mill.
