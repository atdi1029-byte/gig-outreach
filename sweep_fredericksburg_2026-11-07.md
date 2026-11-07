# Fredericksburg VA Sweep — 2026-11-07
# WebSearch/WebFetch only, nothing written to the sheet. Every row in READY TO ADD had its own site fetched, with the name and address on it.
# Scope: City of Fredericksburg + Falmouth, Stafford, Spotsylvania, King George within about 15 min (a few at ~20, noted). Distances are estimates from downtown, not measured.

## Coverage gaps (read this first)
- **Yelp, TripAdvisor, OpenTable listing pages were NOT read.** Yelp 403 (yelp.com, yelp.ca), TripAdvisor 403 (.com, .co.uk), OpenTable timed out (5 pages across .com, .co.uk, .ie, .ae). Only OpenTable names seen in search results were used. The workflow requires these pages, so a later pass from a browser could still find venues.
- Also blocked: PartySlate King George (403), TableAgent (403), Lonely Planet (404), Zola page 2 (404), visitfred.com/eat-drink (404).
- Read in full instead: fxbg.com restaurants (all 111 listings, 5 pages), lodging (15), arts & culture (23), galleries (13), history (38), wineries (6), rehearsal dinner sites (all 6 pages); Tour Stafford dine (176), weddings (12), arts (8); Spotsylvania County American (45), Italian (25), brews/wines (10), B&Bs (2); Visit King George venues (14); Zola page 1.
- Not read: the other Spotsylvania cuisine pages (Asian, Mexican, seafood, Mediterranean, African/Caribbean), which are mostly casual going by the category names.
- All 17 search passes were run, plus about 12 extra searches (Stafford, Spotsylvania, King George, piano/jazz, classical series, historic rentals, senior living).

## Already in sheet (skip)
- Potomac Point Winery (twice, Stafford), Fairview Beach Yacht Club (King George)
- La Petite Auberge: on the sheet by domain (lapetiteaubergefred.com) but filed under **Middleburg**. It is at 311 William St, Fredericksburg. City needs fixing.
- Aquia Harbour Yacht Club: on the sheet, filed under Great Falls (ahyc.org). Likely a Stafford club, city worth checking.
- Rebellion Bourbon Bar: the Leesburg location is on the sheet with eatatrebellion.com. The Fredericksburg location (row 13) is not, but shares that domain, so the backend may reject it as a duplicate.

## READY TO ADD
| # | Name | Website | Address | City | State | Category | Score | Why |
|---|---|---|---|---|---|---|---|---|
| 1 | Ristorante Renato | https://rrenato.com/ | 422 William St | Fredericksburg | VA | restaurant | 5 | Fine dining Italian since 1978, private wine room, Caymus and Prisoner wine dinners |
| 2 | Fahrenheit 132 | https://www.fahrenheit132.com/ | 318 William St | Fredericksburg | VA | restaurant | 5 | Wine Spectator Best of Award of Excellence 2016-2026, OpenTable 4.9 (4,700+ reviews), private parties |
| 3 | Cork & Table | https://www.corkandtable.com/ | 909 Caroline St | Fredericksburg | VA | restaurant | 5 | Chef-owned, tasting menus, weekly wine dinners, Gathering Table series, private room for 25 |
| 4 | Locavore | https://www.locavoreva.com/ | 314 William St | Fredericksburg | VA | restaurant | 4 | Opened 2025, chef Dan Perron, rooftop bar Folklore, flexible event spaces, public events |
| 5 | Five Chophouse & Bar | https://www.fivechop.com/ | 713 William St | Fredericksburg | VA | restaurant | 4 | Upscale chophouse in The Publisher hotel, downtown |
| 6 | Foode | https://www.foodefredericksburg.com/ | 900 Princess Anne St | Fredericksburg | VA | restaurant | 4 | Farm-to-table in the historic National Bank Building, Vault room for chef's tastings and wine dinners, private room for 22 |
| 7 | Orofino Restaurant | https://www.orofinorestaurant.com/ | 1006 Caroline St | Fredericksburg | VA | restaurant | 3 | Downtown Italian with monthly regional menus, catering and events |
| 8 | Tapa Rio | https://www.tapario.com/ | 1101 Sophia St | Fredericksburg | VA | restaurant | 3 | Latin and Italian on the Rappahannock with river-view patio. Site footer says 2023, confirm it is current |
| 9 | The Alpine Chef Restaurant | https://www.alpinechefrestaurant.com/ | 200 Lafayette Blvd | Fredericksburg | VA | restaurant | 3 | Bavarian dining in the historic train station, private events, Sunday brunch |
| 10 | River's End Speakeasy | https://www.galvinsdeli.com/riversend | 216 William St | Fredericksburg | VA | restaurant | 4 | Already books live music (first Wednesdays, ticketed shows), rents for 20-100, cocktail bar above Galvin's Deli |
| 11 | Zibibbo 73 | https://www.zibibbo73.com/ | 2757 Richmond Hwy, Suite 101 | Stafford | VA | restaurant | 3 | ~20 min. Italian ristorante and raw bar, OpenTable 4.7, semi-private room for 40, rehearsal dinners |
| 12 | Castiglia's Italian Restaurant | https://www.castigliasitalianrestaurant.com/ | 324 William St | Fredericksburg | VA | restaurant | 3 | Family-owned, private rooms for 50-200, hosts wine dinners and weddings, rooftop Sky Bar |
| 13 | Rebellion Bourbon Bar & Kitchen | https://eatatrebellion.com/ | 309 William St | Fredericksburg | VA | restaurant | 2 | Maybe: bourbon bar, but private dining room for 100 and Downstairs Armory. Domain shared with the Leesburg row on the sheet |
| 14 | Orleans Bistro | https://www.orleansbistrova.com/ | 5442 Southpoint Plaza Way | Fredericksburg | VA | restaurant | 2 | ~15 min. Maybe: lively room, but jazz brunches, live music and a wine club. Also karaoke and DJ nights |
| 15 | Curio Wine Bar & Tasting Room | https://curiowines.com/ | 209 William St | Fredericksburg | VA | wine_bar | 4 | 60 wines on tap, Curio Wine Bistro at 205 William, wine school, cellar rental for private events |
| 16 | Eden Try Winery | https://www.edentrywinery.com/ | 6818 River Rd | Fredericksburg | VA | winery | 4 | ~10 min. 12-acre estate with Manor House and restored barn, weekend live music, weddings |
| 17 | The Estate at White Hall Vineyard | https://www.theestateatwhitehall.com/ | 3668 White Hall Rd | King George | VA | winery | 4 | 15 min per its own listing. Historic barn tasting rooms, local live music, weddings |
| 18 | Wilderness Run Vineyards | http://www.wildernessrunvineyards.com/ | 11109 Plank Rd | Spotsylvania | VA | winery | 3 | ~15 min. Open daily, weddings and events |
| 19 | Mattaponi Winery | http://www.mattaponiwinery.com | 7530 Morris Rd | Spotsylvania | VA | winery | 3 | ~20 min. Food and wine pairing events, Spotsylvania Wine Trail |
| 20 | The Publisher, Downtown Fredericksburg | https://www.marriott.com/en-us/hotels/rictx-the-publisher-downtown-fredericksburg-a-tribute-portfolio-hotel/events | 711 William St | Fredericksburg | VA | hotel | 4 | Tribute Portfolio boutique hotel, The Press (125), The Wine Room (50), The Library, weddings |
| 21 | Ironclad Inn | https://www.ironcladinn.com/ | 1200 Princess Anne St | Fredericksburg | VA | hotel | 4 | Former Kenmore Inn (c.1793), Stable Block Bourbon & Bar Room, event spaces, supper clubs, ticketed Bourbon Notes music series |
| 22 | The Richard Johnston Inn & 1890 Caroline House | http://www.therichardjohnstoninn.com | 711 Caroline St | Fredericksburg | VA | hotel | 3 | Historic Old Town inn, courtyard and parlors for small weddings and events |
| 23 | Stevenson Ridge | https://www.stevensonridge.com/ | 6901 Meeting St | Spotsylvania | VA | event_venue | 4 | ~20 min. Events facility with cabins and cottages, weddings up to 200, corporate and social events |
| 24 | Fredericksburg Country Club | https://fredclub.org | 11031 Tidewater Trail | Fredericksburg | VA | country_club | 5 | ~10 min. Private club on the Rappahannock at the Smithfield estate (1819 mansion), weddings, member dining and events |
| 25 | Augustine Golf Club | http://www.GolfAugustine.com | 76 Monument Dr | Stafford | VA | country_club | 3 | ~15 min. Chalet-style clubhouse, weddings up to 130, The Grille open to the public |
| 26 | The Gauntlet Golf Club | http://www.golfgauntlet.com | 18 Fairway Dr | Fredericksburg | VA | country_club | 2 | ~10 min. Social events calendar, bar and grille with veranda |
| 27 | Mill District Events (The Silk Mill & The Woolen Mill) | http://www.innattheoldesilkmill.com/ | 1707 Princess Anne St | Fredericksburg | VA | event_venue | 4 | Historic mills with on-site 25-room inn, up to 300 guests, weddings, galas, military balls |
| 28 | REIGN the Venue | https://www.reignthevenue.com/ | 1409 Princess Anne St | Fredericksburg | VA | event_venue | 3 | Downtown, 120 guests across 3,000+ sq ft, weddings and nonprofit events, bar The Court due Q1 2027 |
| 29 | 718 Venue | https://www.718venue.com/ | 718 Caroline St | Fredericksburg | VA | event_venue | 3 | Exposed brick and tin ceiling downtown, up to 100 guests. Site footer says 2021, confirm it is current |
| 30 | Glen Garden Weddings | http://www.glengardenweddings.com | 306 Hartwood Rd | Fredericksburg | VA | event_venue | 3 | ~15 min. Garden wedding venue, Christmas in the Cottage season Nov 27-Jan 1 |
| 31 | Washington Heritage Museums | https://www.washingtonheritagemuseums.org/event-space-rental | 1200 Charles St | Fredericksburg | VA | museum | 4 | Mary Washington House, Rising Sun Tavern, Apothecary Shop and St. James' House, rentals up to 50 |
| 32 | Gari Melchers Home and Studio at Belmont | https://www.garimelchers.org/about/ | 224 Washington St | Falmouth | VA | museum | 5 | ~5 min. Painter's estate and art center, weddings, events calendar |
| 33 | Fredericksburg Area Museum | https://famva.org/ | 907 Princess Anne St | Fredericksburg | VA | museum | 4 | FAM-TINI tasting event, holiday markets, hosted the ArtsLIVE! jazz fundraiser |
| 34 | Historic Kenmore | https://kenmore.org/visit-historic-kenmore/ | 1201 Washington Ave | Fredericksburg | VA | museum | 4 | George Washington's sister's 18th-century mansion, events calendar, group tours |
| 35 | James Monroe Museum and Memorial Library | https://jamesmonroemuseum.umw.edu/ | 908 Charles St | Fredericksburg | VA | museum | 4 | Memorial Garden rented for intimate weddings and receptions, public programs |
| 36 | Meyer Fine Art Gallery | https://meyerfineart.gallery/ | 1015 Caroline St | Fredericksburg | VA | art_gallery | 4 | 15th-19th century American and European art, hosts artist celebrations |
| 37 | Fredericksburg Center for the Creative Arts | http://fccagallery.org/ | 813 Sophia St | Fredericksburg | VA | art_gallery | 3 | Oldest arts center in the area, two galleries, First Friday events |
| 38 | LibertyTown Arts Workshop | https://libertytownarts.com/ | 916 Liberty St | Fredericksburg | VA | art_gallery | 3 | Gallery, studios and national exhibitions |
| 39 | Art First Gallery | https://artfirstgallery.com/contact-us | 824 Caroline St | Fredericksburg | VA | art_gallery | 3 | Artists' cooperative since 1992, rotating exhibits |
| 40 | Brush Strokes Gallery | http://brushstrokesfredericksburg.com | 824 Caroline St | Fredericksburg | VA | art_gallery | 3 | First Friday 5-9 pm events, Open House Weekend |
| 41 | UMW Galleries | https://cas.umw.edu/art/umw-galleries-2/ | 1301 College Ave | Fredericksburg | VA | art_gallery | 3 | Ridderhof Martin and duPont galleries, 3-4 exhibitions per semester |
| 42 | ArtsLIVE! | https://artsliveva.org/ | 904 Princess Anne St, Suite C8 | Fredericksburg | VA | music_venue | 5 | Presents chamber music, Fredericksburg Chamber Festival since 1988, the region's oldest performing arts nonprofit |
| 43 | St. George's Episcopal Church | https://www.stgeorgesepiscopal.net/music/concerts/ | 905 Princess Anne St | Fredericksburg | VA | music_venue | 5 | Free concert and Chamber Series in Old Town, recent seasons included the Portland Guitar Duo. music@stgeorgesepiscopal.net |
| 44 | Riverside Center for the Performing Arts | https://www.riversidedt.com/ | 95 Riverside Pkwy | Fredericksburg | VA | theater | 3 | ~10 min. Regional dinner theater with 3-course served meal, group sales |
| 45 | Harmony at Falls Run | https://www.harmonyseniorservices.com/senior-living/va/fredericksburg/brimley-dr/our-community | 60 Brimley Dr | Fredericksburg | VA | senior_living | 2 | ~10 min. Independent living, assisted and memory care, full events calendar |
| 46 | Charter Senior Living of Fredericksburg | https://www.charterfredericksburg.com/ | 20 HeartFields Ln | Fredericksburg | VA | senior_living | 2 | ~5 min. Assisted living and memory care, life-enrichment programs |
| 47 | Bickford of Spotsylvania | https://www.bickfordseniorliving.com/spotsylvania | 5000 Spotsylvania County Pkwy | Fredericksburg | VA | senior_living | 2 | ~15 min. Assisted living and memory care, family and community events |

## Excluded
### Good venues that failed the website rule (add by hand if you can confirm them)
- **Brock's Riverside Grill** (brocksgrill.com): strong fit, with river-view rooms for 30-150 and a banquet hall. The site never states a street address; 503 Sophia St appears only in a gift card link and on fxbg.com.
- **City Vino** (city-vino.com, 100 Hanover St): wine shop with jazz piano and vocal afternoons, the only Fredericksburg venue found with piano. Its site returned 403, so name and address could not be read.
- Fredericksburg Symphony Orchestra (fredericksburgsymphony.org): the site shows only a P.O. box.
- Vibin' With Val (vibinval.com, 10691 Spotsylvania Ave): winery with rental space. No address on the home page, other pages 404.
- Highland Barn (highlandbarnvirginia.com): no address on the site, which no longer mentions weddings.
- Glasgow Farm (theglasgowfarm.com): site returned 403.
- Olde Towne Steak & Seafood (1612 Caroline St, since 1981): site's certificate is broken, and open status could not be confirmed.
- Courtyard by Marriott Historic District: Marriott property page not fetched, and chain hotel.

### No official site found or site dead
- Bello Manzo, Stockyards (Facebook only); The Clubhouse at Aquia Harbour and Robiolina (domains don't resolve); Angela's Italian (domain doesn't resolve)
- Stafford Stables, Belle's Pleasure, Forest Farms, Oasis Weddings, Riverside Weddings by Clore, Elegance Estates, Lodge at Moss Neck, Bella Vista at Bleak Hill (Facebook only): seen only on wedding directories
- Paramount Senior Living, Viva/Commonwealth Senior Living, Spring Arbor, Chancellor's Village, Jubilation, Marian Manor, Morningside House: directory listings only
- Kybecca (402 William St): listings say permanently closed

### Beyond 15 minutes (each worth its own King George or Lake Anna sweep)
- Belle Grove Plantation (King George, about 25-30 min): James Madison's birthplace, B&B, teas, weddings
- Oaken Brow (King George, about 25 min): 1830 house hosting "intimate musical performances", oakenbrow1830@gmail.com
- Backporch Vineyard, Little Ferry Inn (King George, about 25-30 min)
- Fawn Lake Country Club and The Cove (Spotsylvania, about 25 min): Arnold Palmer course, ballroom with lake views
- Lake Anna Winery (about 30 min), Rock Hill Pavilion (Stafford, about 25 min), Brodie Farm B&B (about 25 min)
- The Lion's Den 1837 (Mineral, about 35-40 min): fine dining, black-tie jazz anniversary evening
- Ingleside Vineyards (about 40 min), Bel Air 1740 (Prince William County), Littlepage Inn / Prospect Hill (near Mineral)

### Failed the filter
- Breweries, brewpubs, beer gardens: 6 Bears & A Goat, Adventure Brewing, Highmark, Barley Naked, Deutschland Downtown, Maltese, Log Home, Sedona Taphouse, Capital Ale House
- Bars and pubs: J. Brian's Tap Room, Colonial Tavern, Sunken Well Tavern, Spirit's, Happy Endings, Harry's Ale House, The Pub, Paddy's
- Chains: The Melting Pot (brand already on the sheet), Bonefish, Carrabba's, Firebirds, Park Lane Tavern, Outback, LongHorn, Olive Garden, Silver Diner, Bravo! (Spotsylvania location closed early 2026), all chain hotels on Hospitality Lane
- Casual: Sammy T's, Harry's Downtown, Scafa's (family restaurant), Mason Dixon Cafe, Benny Vitali's, Allman's, Billiken's, Mama's, Battlefield Country Store, Goolrick's, Agave, Smugglers Cafe, coffee, ice cream, delis, diners and quick-service spots
- Small Asian and Indian spots with no event evidence: Osan, Umi, Miso, Guru, Taj, Bangkok Cafe
- Not gig venues: A. Smith Bowman Distillery, Belvedere Plantation (farm with pig races, owners working on a technology campus), Bacchus Winery (no own site found), Groove Music Hall (country touring), Wine & Design (paint studio), PONSHOP, Sophia Street Studios, Canal Quarter Arts (Facebook only), NPS sites (Chatham Manor, Ellwood), Patawomeck Museum, Rappahannock Railroad Museum, Shannon Air Museum
- Community and school theater: Stage Door Productions, Fredericksburg Theatre Ensemble, Klein Theatre at UMW

## Top priorities
1. St. George's Episcopal: chamber series that has already programmed a guitar duo
2. ArtsLIVE!: the region's chamber music presenter
3. River's End Speakeasy: already books live music
4. Ironclad Inn: runs its own ticketed music series
5. Gari Melchers Home and Studio: art estate with weddings and events
6. Cork & Table, Ristorante Renato, Fahrenheit 132: wine-dinner crowd
7. Fredericksburg Country Club: private club in an 1819 mansion
8. Brock's Riverside Grill and City Vino: worth adding by hand (see Excluded)

**TOTAL: 47 ready to add.**
