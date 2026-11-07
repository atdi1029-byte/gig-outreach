# Frederick MD Sweep — 2026-11-06
# Scope: City of Frederick (21701/21702/21703/21704) + towns ~10–15 min out with the same crowd: Urbana, Ijamsville, New Market, Middletown, Myersville, Adamstown. Stretch (20–25 min, noted): Thurmont, Knoxville.
# Method: WebSearch + WebFetch only (no Chrome — a pipeline holds it). Nothing written to the sheet; this file is for import_sweep_files.py.
# Every READY TO ADD row: own official website fetched, venue name + street address seen on the fetched page, not a listing/social page, not already on the sheet (name + domain checked against dash.json, 5044 venues).

## Already in sheet (skip)
The Tasting Room (trrestaurant.com), The Wine Kitchen on the Creek, Showroom (showroomfrederick.com — sheet city says "Roland Park Baltimore", wrong: it's 882 N East St, Frederick), Visitation Hotel Frederick, Simple Theory Wines, NOMA Gallery, Hidden Hills Farm & Vineyard, Celebration Cellars, Six Wicket Vineyards, Orchid Cellar, Catoctin Breeze, Linganore Winecellars, Black Ankle, Elk Run, Loew Vineyards, Sugarloaf Mountain Vineyard

## Round 1: the 17 core + deep-dive searches
fine dining · Italian · French/European · wine bar · winery · boutique hotel/inn/B&B · country club · event/wedding venue · art gallery/museum · senior living · live music/acoustic · things to do · new restaurants 2025/2026 · romantic/private dining · Carroll Creek waterfront · hidden gems · supper club/chef's table
+ extra passes: tasting menu/steakhouse, classical concert series/churches, Middletown/Urbana/New Market dining, Atlas Restaurant Group hotel, cocktail/jazz/piano bars, historic estates (Buckeystown/Adamstown), restaurant week, Weinberg/New Spire/MET, tapas/Mediterranean, distilleries, Frederick Wine Trail, CCRCs (Buckingham's Choice), New Market Main St, museums (Civil War Medicine/Schifferstadt/Rose Hill), Urbana, Middletown, 55+ communities, barn/estate venues, Dragon Distillery — 37 searches in total.

## Round 2: listing pages fetched
- **downtownfrederick.org/cat/taste/** — read all 91 Eat & Drink entries (list below under Excluded for the no's)
- **downtownfrederick.org/cat/art/** — all 21 arts entries
- **downtownfrederick.org/stay/** — all 5 lodging entries
- **visitfrederick.org** (county tourism) — B&B page (4), live-music page (7), downtown dining page, homepage winery block (7). Its /restaurants/ and /restaurants/fine-dining/ pages are 404 now; its wedding-venue and wineries pages render without listings.
- **Yelp** (restaurants p1+p2, fine dining, wine bars) — HTTP 403 on every page (blocks automated fetches)
- **TripAdvisor** (restaurants, attractions, hotels) — HTTP 403 on every page
- **OpenTable** (city page + 6 mirror feature pages) — timed out every time; used its search-result snippets instead (Vintage, 200 Monroe, Cellar Door, Manalu, Monocacy Crossing, Isabella's, Dragon Distillery, Maxwell's)
- Festivals: Bites & Bevs Frederick Restaurant Week (11 downtown participants, Visit Frederick), In the Street, Baker Park summer concerts, Carroll Creek amphitheater, Sky Stage, Hood College Summer Chamber Music Festival, Calvary UMC Community Concert Series

## Round 3: website + address verification (every candidate's own site fetched)
Done in five parallel read-only passes (downtown restaurants 21, area restaurants 15, inns/clubs/estates 20, arts/museums/theater 18, senior living 12).

## READY TO ADD

| # | Name | Website | Address | City | State | Category | Score | Why |
|---|------|---------|---------|------|-------|----------|-------|-----|
| 1 | 7th Sister | https://www.7thsister.com | 228 N Market St | Frederick | MD | restaurant | 5 | Historic Houck Mansion (former Volt space), Chef Christian Blouin; "food, cocktails, music and candlelit conversation"; Mon–Thu private events only (events@7thsister.com on site) |
| 2 | Wye Oak Tavern | https://www.wyeoaktavern.com | 211 E Church St | Frederick | MD | restaurant | 5 | Bryan Voltaggio tavern/steakhouse inside the Visitation Hotel (hotel already on sheet, separate domain); upscale, valet, opened ~Dec 2024 |
| 3 | Holly Hills Country Club | https://www.hollyhillsgolf.com | 5502 Mussetter Rd | Ijamsville | MD | country_club | 5 | Only exclusive private CC in Frederick County (est. 1977, KemperSports); formal dining room, active social calendar. ~15 min |
| 4 | Calvary United Methodist Church — Community Concert Series | https://calvaryumc.org/concerts/ | 131 W 2nd St | Frederick | MD | music_venue | 5 | Classical Sunday 3 pm series; booked classical guitarist Sean Brennan Oct 18 2026; 2027 season Jan 10–May 2; coordinator Joyce Summers on page |
| 5 | Caciqué | https://www.caciquefrederick.com | 26 N Market St | Frederick | MD | restaurant | 4 | Spanish/Mexican, white tablecloths, fireplaces, cocktail lounge, semi-private dining rooms, $31–50 |
| 6 | Il Porto Italian Restaurant | https://www.ilportorestaurant.com | 200 S Market St | Frederick | MD | restaurant | 4 | Traditional Italian since 1996, wine list; Google 4.4 (774). Different business from Il Porto Ristorante Alexandria on sheet |
| 7 | Isabella's Taverna & Tapas Bar | https://www.isabellas-tavern.com | 44 N Market St | Frederick | MD | restaurant | 4 | Spanish tapas/paella, "exclusive wine list", casual-elegant, private events; Google ~4.5 (1,849) |
| 8 | Up on Market (Inn on Market) | https://www.uponmarket301.com | 301 N Market St | Frederick | MD | restaurant | 4 | European bistro in a 1770s building, 2026 wine list, "simple elegance"; 4-room inn upstairs (5 W 3rd St) |
| 9 | Manalú Italian Restaurant | https://manaluitalianrestaurant.com | 5227 Presidents Ct | Frederick | MD | restaurant | 4 | Southern Italian, chef-owner Marco Pontecorvo, "world-class hand picked Italian wines"; OpenTable 4.8 (1,300+); private dinners, 2,000 sq ft covered patio |
| 10 | Monocacy Crossing | https://www.monocacycrossing.com | 4424 Urbana Pike | Frederick | MD | restaurant | 4 | "Casually elegant" contemporary American, strong wine list, $31–50; OpenTable 4.8 (~3,400); private parties. ~10 min south |
| 11 | Ceresville Mansion | https://www.ceresville.com | 8529 Liberty Rd | Frederick | MD | event_venue | 4 | 1888 mansion on 26 acres, all-inclusive weddings/events, ballroom 150–170, garden terrace up to 250. ~10 min |
| 12 | Morningside Inn | https://www.morningside-inn.com | 7477 McKaig Rd | Frederick | MD | event_venue | 4 | 300-acre estate, weddings/banquets up to 200, on-site chef. ~15 min |
| 13 | Springfield Manor Winery, Distillery & Brewery | https://www.springfieldmanor.com | 11836 Auburn Rd | Thurmont | MD | winery | 4 | Historic manor winery with 8-suite inn; ballroom + barn seat 300. Stretch: ~20–25 min north |
| 14 | Delaplaine Arts Center | https://www.delaplaine.org | 40 S Carroll St | Frederick | MD | art_gallery | 4 | Creekside arts center, open daily, rents for weddings/events, gala + talks |
| 15 | Heritage Frederick (Historical Society of Frederick County) | https://frederickhistory.org | 24 E Church St | Frederick | MD | museum | 4 | Historic museum house with Rentals section, Museums by Candlelight, holiday events |
| 16 | Homewood Living Frederick | https://homewoodlivingfrederick.com | 7407 Willow Rd | Frederick | MD | senior_living | 4 | Not-for-profit CCRC (independent → memory care), chapel, activities calendar. ~10 min north |
| 17 | Buckingham's Choice | https://www.actsretirement.org/communities/maryland/buckinghams-choice-adamstown | 3200 Baker Cir | Adamstown | MD | senior_living | 4 | Acts CCRC on 42 acres, entrance-fee life care; resident social programs. ~12 min south |
| 18 | Hootch & Banter | https://www.hootchandbanter.com | 49 S Market St | Frederick | MD | restaurant | 3 | Upscale-casual New American, French influence; cocktail bar + upstairs Hootch Lounge used for private events |
| 19 | Cucina Massi | https://www.cucinamassi.com | 111 E Patrick St | Frederick | MD | restaurant | 3 | Italian (Liberatore family), heated patio, private events + catering |
| 20 | Bentztown | https://www.bentztown.com | 6 S Bentz St | Frederick | MD | restaurant | 3 | Modern American kitchen + bar that already books live music (weekend jazz brunch) |
| 21 | Vintage | https://www.vintage-eats.com | 8 W Main St | New Market | MD | restaurant | 3 | Historic former Mealey's building on antiques-town Main St; Market Room (8–14) + 2nd-floor room (20–40). ~15 min east |
| 22 | Tenth Ward Distilling Company | https://www.tenthwarddistilling.com | 55 E Patrick St | Frederick | MD | event_venue | 3 | Woman-owned distillery cocktail bar/tasting room; Visit Frederick lists it for live music; rents for weddings/events |
| 23 | McClintock Distilling | https://www.mcclintockdistilling.com | 35 S Carroll St | Frederick | MD | event_venue | 3 | Distillery in a 1910s garage with Back Bar cocktail lounge; weddings & private events section |
| 24 | Richland Golf Club (The Vistas) | https://www.richlandgolfclub.com | 50 Glenbrook Dr | Middletown | MD | country_club | 3 | French-country ballroom for weddings/banquets (20–162) + pergola ceremony site. ~10–15 min west |
| 25 | Catoctin Hall at Musket Ridge | https://www.musketridge.com | 3555 Brethren Church Rd | Myersville | MD | event_venue | 3 | Wedding/banquet hall (~200–250) at Musket Ridge golf club, restaurant on site. ~15–20 min |
| 26 | Crown Rose Estate | https://www.crownrose.com | 1902 Jefferson Pike | Knoxville | MD | event_venue | 3 | 76-acre estate with mansion + bank barn, rye whiskey distillery, tastings and weddings. Stretch: ~20–25 min |
| 27 | Maryland Ensemble Theatre | https://www.marylandensemble.org | 31 W Patrick St | Frederick | MD | theater | 3 | Resident professional theater, 2026–27 season, special events |
| 28 | National Museum of Civil War Medicine | https://www.civilwarmed.org | 48 E Patrick St | Frederick | MD | museum | 3 | National museum downtown; after-hours "Frederick at Night" events, talks |
| 29 | Rose Hill Manor Park & Museums | https://www.recreater.com/404/Rose-Hill-Manor-Park-Museums | 1611 N Market St | Frederick | MD | museum | 3 | County-run Georgian manor (Gov. Thomas Johnson); festivals, garden rentals ("404" is the page ID, not an error) |
| 30 | Frederick Arts Council | https://www.frederickartscouncil.org | 115 E Church St | Frederick | MD | art_gallery | 3 | County arts agency with gallery + studios; 50th-anniversary gala Nov 7 2026; connector to every arts event |
| 31 | TAG / The Artists Gallery | https://theartistsgalleryfrederick.com | 501 N Market St | Frederick | MD | art_gallery | 3 | Artist co-op with monthly First Saturday receptions |
| 32 | Eastside Artists' Gallery | https://eastsideartistsgallery.com | 313 E Patrick St | Frederick | MD | art_gallery | 3 | Co-op gallery, monthly opening receptions, private viewings |
| 33 | Edenton Frederick | https://edentonfrederick.com | 5800 Genesis Ln | Frederick | MD | senior_living | 3 | Family-owned IL/AL/memory care; resident choir, music in memory care |
| 34 | Sunrise of Frederick | https://www.sunriseseniorliving.com/communities/md/sunrise-of-frederick | 990 Waterford Dr | Frederick | MD | senior_living | 3 | Assisted living + memory care; "music, fitness, art" programming |
| 35 | Mangia e Bevi | http://mangiaebevi.us | 8927-J Fingerboard Rd | Frederick | MD | restaurant | 2 | Homemade southern Italian since 2007 with wine menu, Urbana area; casual. ~15 min |
| 36 | 10 Clarke Bed & Breakfast | https://www.10clarke.com | 10 Clarke Pl | Frederick | MD | hotel | 2 | Victorian B&B near Baker Park (~5 rooms); footer © 2022 but booking live |
| 37 | Hollerstown Hill Bed & Breakfast | https://www.hollerstownhill.com | 4 Clarke Pl | Frederick | MD | hotel | 2 | Victorian B&B (est. 2002), 4 rooms, open year round |
| 38 | Maryland National Golf Club | https://www.marylandnational.com | 8836 Hollow Rd | Middletown | MD | country_club | 2 | Public club; banquet room to 175, Eagle's Nest, Schroyer's Tavern. ~15 min |
| 39 | Gallery 322 | https://www.gallery322.com | 322 N Market St | Frederick | MD | art_gallery | 2 | Artist-run gallery, rotating shows |
| 40 | Schifferstadt Architectural Museum | https://www.fredericklandmarks.org/schifferstadt | 1110 Rosemont Ave | Frederick | MD | museum | 2 | 1750s German colonial house museum (Frederick County Landmarks Foundation), events page |
| 41 | Frederick Book Arts Center | https://frederickbookarts.org | 127 S Carroll St | Frederick | MD | art_gallery | 2 | First Saturday events, gallery shows, talks |

## Excluded
**Good leads, not verifiable on their own site (add by hand if confirmed):**
- Weinberg Center for the Arts (20 W Patrick St, weinbergcenter.org) — 1,143-seat 1926 theater + New Spire Arts black box (15 W Patrick, same domain); site returns 403 to every fetch. Rentals: Kitty Clark (Weinberg), Laura Hawk (New Spire) per search snippets. Score would be 4.
- Ricci di Mare / Ricci Italian Restaurant (1021 Mill Pond Rd, Worman's Mill, ricciitalianrestaurant.com) — upscale coastal Italian + wine bar, opened 2023; site shows no street address.
- First Chime (firstchime.com) — Chef Gérard Pangaud (Michelin) private dining, one party at a time; no address on site, last post 2021.
- Citizens Ballroom (2 E Patrick St, fetewell.com/citizens-ballroom) — 1908 bank-building event venue (165); address not on page, own domain refused connection.
- Sunhouse Farm & Events (sunhousefarm.com) — address not on page.
- Gaslight Gallery (gaslightart.com, 118 E Church St) — address not in page text.
- YAAC Gallery 115 / Ausherman Arts Center (115 E Church St) — YMCA page 404s.
- The Main Cup (Middletown, themaincup.com) — live music weekends, site 403s.
- Country Meadows of Frederick, Somerford House & Place, HeartFields at Frederick, Spring Arbor of Frederick — brand sites 403 / DNS failure; Tranquillity at Fredericktowne — no official page.
- Fingerboard Farm Inn (Ijamsville) — site returned empty.
- Marriott Downtown Frederick at Carroll Creek (20 S Carroll St) — under construction, opens 2027 with 4 Atlas Restaurant Group concepts (creekside restaurant, rooftop, lobby bar). Revisit 2027.

**Closed / gone:** Bella Trattoria, Le Parc Bistro (now Eagles Club #1067), Shab Row Bistro (now Pistarro's), Frederick Cellars (site 500, same address as Pistarro's), Tauraso's (closed; family now runs The Tasting Room), The Urbana Lodge ("permanently closed"), DISTRICT Arts (closed, domain dead), Barbara Fritchie House (private, not open), Montevue Assisted Living (converted to skilled nursing), Gabriel's (Ijamsville), Grey Goose / Lemongrass / La Tasca (no evidence they exist in Frederick). Tapia's on Main (Middletown) — status unclear, site refuses connection.

**Out of area / wrong place:** Drumore Mill (Drumore PA, 1.5 hr), Prosperity Mansion (Keymar, ~25 min, budget outdoor venue), Stone Manor (Lovettsville VA), Milton Ridge (Clarksburg, Montgomery Co.), Strawberry Inn (New Market — Airbnb only, no own site, no dining), Antrim 1844 (Taneytown, 35–40 min — worth its own sweep).

**Fails the filter (downtown directory and searches):** 200 Monroe (Frederick Community College student-run Thursday dinners, can't host outside events), Cellar Door (late-night basement whiskey bar + comedy), Tempo Di Pasta, Lazy Fish, Sanctuary Modern Kitchen (gluten-free takeout), Bloom Asian Haus (no site), Spin the Bottle Wine Co (retail shop, no bar), Dragon Distillery (by the airport), Firebirds, Bonefish Grill, Wonder, Ekiben (chains); Whiskey Creek Golf Club (public, 80-seat clubhouse); Cascades of Frederick (budget 55+ apartments); Homes at Baker Park (a 2019 student proposal, not real); Silverado Frederick (memory care only, no address on page).
Downtown directory no's (casual/bars/brewpubs/shops): 7th Sister kept above; skipped Agave 137, Attaboy Barrel House + Beer, Backslash Burger, Beans & Bagels, BK Juices, Black Hog BBQ, Brewer's Alley (brewpub), Bushwaller's Pub, Café 611, Cafe Bueno, Cafe Nola, Crabapples Deli, dōp Pizza, Eastside Liquors, Flamin' Pizza, Frederick Cheese Shop, Frederick Coffee Co, Frederick Eagles Club, Frederick Fudge, Frederick Social, Frederick Soups, Gravel & Grind, Hinzi's Kitchen, Hippy Chick Hummus, Ibiza Cafe, JoJo's Tap House, Joy Convenience, Juliet's Italian Market (deli), Lebherz Oil & Vinegar, Magoo's Pub, Market Street Boba, Maxwell's Burgers, McCutcheon's, North Market Pop Shop, Olde Mother Brewing, Olde Towne Tavern, Penny Mart, Pistarro's (pizzeria), Plaza Mexico, Pretzel and Pizza Creations, Ragin' Reef, RAK Brewing, Rare Morsel, Sabor de Cuba, Sandbox Brewhouse, Sapporo II, Shab Row Tea Emporium, Shuckin' Shack, South Market Sandwich, Starbucks, Steinhardt Brewing, Stone Hearth Bakery, Sumittra Thai, Sweeties, The Candy Kitchen, The Ice House, The Orchard, Popcorn House, Perfect Blend Cafe, Spice & Tea Exchange, TONIQ, Tsunami, Twin Bears Bakery, Voila!, Wag's, White Rabbit Gastropub, Zoe's Chocolate. Arts no's: framing/pottery/photo studios, blacksmithing school, Potters' Guild, Frederick Art Club (same building as Delaplaine). Hood College chamber festival (college, not a booking venue).

## Top priorities
1. Calvary UMC Concert Series — already books classical guitar; pitch the 2027 season (Jan 10–May 2).
2. 7th Sister — candlelit mansion dining, explicitly "music"; private-events nights Mon–Thu.
3. Wye Oak Tavern — Voltaggio, in the Visitation Hotel (pitch both together).
4. Holly Hills Country Club — the county's only private club.
5. Ceresville Mansion / Morningside Inn — wedding ceremony + cocktail-hour work.
6. Weinberg Center — add by hand (site blocks fetch).
