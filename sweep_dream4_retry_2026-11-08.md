# Dream sweep 4: retries + hotel bars, rooftops, private dining (2026-11-08)

Method: WebSearch and WebFetch only, no browser. Every name below was checked against the sheet
(dash.json, 5,351 venues) by name and website domain. The sheet already covers almost every
best-of name in the region: of the Washingtonian 100 Very Best 2026, the DC/Alexandria hotel bars
(Off the Record, Round Robin, Quill, Bourbon Steak lounge, Summit at Conrad, Kingbird, Opaline),
the Baltimore clubs and Atlas restaurants, and the Annapolis/Alexandria fine dining, nearly all were
already there. So this list is short.

**Part 1: the six retries.** Their official sites still return 403 (pendry.com, airlie.com,
thehotelwashington.com, whitehousehistory.org) or fail the certificate check
(peabodyevents.library.jhu.edu). As asked, they were confirmed from search results and pages that do
load: Michelin, press, Wikipedia, Historic Hotels and AAA listings, plus Google's index of the official
pages. The official website is given for each.

**Part 2: new venues.** Each one's own official page was fetched and shows the name and address.

## READY TO ADD

| # | Name | Website | Address | City | State | Category | Score | Why |
|---|------|---------|---------|------|-------|----------|-------|-----|
| 1 | Sagamore Pendry Baltimore | https://www.pendry.com/baltimore/ | 1715 Thames Street, Baltimore, MD 21231 | Baltimore | MD | hotel | 5 | Michelin Key luxury hotel (128 keys) on the 1914 Recreation Pier in Fell's Point, with a 4,565 sq ft ballroom, terraces and event rooms. Confirmed by the Michelin Guide listing, AAA, Wallpaper and CommercialSearch (opening, address); pendry.com returns 403 to fetches. Note: pendry.com is also the website of the sheet's "Pendry Washington DC - The Wharf", a different property; its Rec Pier Chop House is on the sheet. |
| 2 | Hotel Washington | https://www.thehotelwashington.com/ | 515 15th Street NW, Washington, DC 20004 | Washington | DC | hotel | 4 | Historic 1918 hotel facing the White House (the W, renamed in 2021), Forbes Travel Guide listed, 326 rooms, with the VUE rooftop lounge over the Mall. Open in 2026: VUE July 4 2026 gala, Thanksgiving brunch listed for Nov 26 2026, and an Oct 7 2026 Madison Realty Capital loan release. Confirmed by Wikipedia, Forbes Travel Guide, Washingtonian and GlobeNewswire; the site returns 403. |
| 3 | George Peabody Library | https://peabodyevents.library.jhu.edu/ | 17 East Mount Vernon Place, Baltimore, MD 21202 | Baltimore | MD | event_venue | 5 | Johns Hopkins' 1878 "cathedral of books" (five tiers of cast-iron balconies), one of the region's most beautiful event rooms. 2026 weddings at $11,500 (2027 at $12,500), 200 seated, events office privateeventsoffice@jhu.edu, (443) 840-9585. Confirmed by Wikipedia (which links this events site), Google's index of the events pages, Here Comes the Guide and WeddingWire; the site fails the TLS check from here. |
| 4 | Decatur House | https://www.whitehousehistory.org/decatur-house | 1610 H Street NW, Washington, DC 20006 | Washington | DC | event_venue | 5 | 1818 Latrobe house on Lafayette Square, run by the White House Historical Association. Rents its Carriage House, Courtyard and Entertaining Parlors (up to 220 seated); 2027 rental guidelines are published; special events office (202) 218-4333. Confirmed by Wikipedia (official link), the WHHA FAQ in search, washington.org and BizBash; whitehousehistory.org returns 403. |
| 5 | Airlie | https://www.airlie.com/ | 6809 Airlie Road, Warrenton, VA 20187 | Warrenton | VA | hotel | 3 | 300-acre Historic Hotels of America estate (1899) in Fauquier hunt country, about 1h45 from Pasadena: hotel, restaurant, farm, weddings. WeddingWire Couples' Choice 2026 and a May 2026 celebrity wedding (Northern Virginia Magazine), so it's open. Confirmed by Historic Hotels, AAA and Northern Virginia Magazine; airlie.com returns 403. 3.5-star conference estate, not top luxury. |
| 6 | Rye Street Tavern | https://www.ryestreettavern.com/ | 225 E Cromwell Street, Baltimore, MD 21230 | Baltimore | MD | restaurant | 4 | Kevin Plank's waterfront tavern at Baltimore Peninsula, next to Sagamore Spirit. The page lists eight private rooms (Heron Dining Room 100 seated, Great Blue Heron 62, Distiller's Row, Loft Bar...) and the Overlook event venue (250 seated / 400 standing, indoor + rooftop). |
| 7 | Loch Bar Baltimore | https://www.lochbar.com/baltimore | 240 International Drive, Baltimore, MD 21202 | Baltimore | MD | restaurant | 4 | Atlas Restaurant Group's seafood and whisky bar in the Four Seasons Baltimore, Harbor East. Its page says it "features live and local musicians" and asks musicians to apply (music@atlasrestaurantgroup.com); baltimore@lochbar.com, 443.961.8949. Note: lochbar.com is also the domain of the sheet's "Loch Bar Philadelphia", a different location. |
| 8 | Ada's on the River | https://www.adasontheriver.com/ | 3 Pioneer Mill Way, Alexandria, VA 22314 | Alexandria | VA | restaurant | 4 | Upscale wood-fired grill on the Old Town Alexandria waterfront (Potomac views). Private dining room for 40 and buyouts up to 150, with patio cocktail parties (Tripleseat inquiries). |
| 9 | Oyster Oyster | https://www.oysteroysterdc.com/ | 1440 8th Street NW, Washington, DC 20001 | Washington | DC | restaurant | 4 | Michelin-starred vegetable tasting-menu restaurant in Shaw (Washingtonian 100 Very Best 2026; chef Rob Rubba, James Beard Outstanding Chef 2023). Small, quiet, a wine crowd. |
| 10 | Carrol's Creek Cafe | https://www.carrolscreek.com/ | 410 Severn Avenue, Annapolis, MD 21403 | Annapolis | MD | restaurant | 3 | Eastport waterfront restaurant facing the Annapolis harbor and the Naval Academy. Its private dining rooms with "a panoramic view of the waterfront" do banquets (Boakley@carrolscreek.com, 410-263-8102 opt. 2). |
| 11 | La Jambe | https://www.lajambedc.com/ | 1309 5th Street NE, Washington, DC 20002 | Washington | DC | wine_bar | 3 | French wine bar at Union Market: winemaker dinners, events and catering pages, info@lajambedc.com. A wine-sipping crowd, more relaxed than the rest of this list. |
| 12 | Hammond-Harwood House | https://www.hammondharwoodhouse.org/ | 19 Maryland Avenue, Annapolis, MD 21401 | Annapolis | MD | museum | 3 | 1774 William Buckland Georgian masterpiece, a National Historic Landmark in the Annapolis historic district. Hosts concerts and lectures (its page lists them), open Apr 1 to Dec 30. Its page doesn't mention private rentals. |

## Excluded

| Name | Reason |
|------|--------|
| Chateau O'Brien at Northpoint (Markham VA) | Already on the sheet (untouched, chateauobrien.com, 3238 Rail Stop Road, Markham, VA 22643). Markham is also at the edge of the radius, about 10 miles east of Front Royal on I-66. |
| The Bygone (29th floor, Four Seasons Baltimore, 400 International Drive) | Top-tier (1920s supper-club rooftop, 800+ wines, jazz on some nights), but its site (thebygonerestaurant.com) gives only a cookie banner to fetches, so no name or address could be read on the page. thebygone.com is a parked domain. Worth adding by hand. |
| The Prime Rib, Washington DC (2020 K Street NW) and Baltimore (1101 N Calvert Street) | Classic jacket-required steakhouses with nightly piano and bass, which suits him, but no official site found: theprimerib.com now redirects to an unrelated barbecue site. One OpenTable page calls the DC one closed. Baltimore signed a 15-year lease in 2023. Worth confirming by phone (DC 202-466-8811, Baltimore 410-539-1804). The Live! Casino location is already on the sheet. |
| Arrels (Arlo Washington DC, 333 G St NW) | Washingtonian 100 Very Best 2026 Catalan restaurant (Pepe Moncayo), but arrels-dc.com returned 404, so it couldn't be verified on its own site. Also inside an Arlo (not a luxury brand). |
| Jack Rose Dining Saloon (2007 18th St NW) | Whiskey saloon with a rooftop terrace and events up to 300, open in 2026, but no street address appears in the page text (only inside an ordering link). It's also more of a whiskey-bar crowd than a wine one. |
| Allegory (Eaton DC) | Its page shows no street address, and Eaton DC is already on the sheet. |
| Silver Lyan (Riggs, 900 F St NW) | No separate site; it's part of Riggs Washington DC (riggsdc.com), which is already on the sheet. |
| Dōgon (Salamander DC) | Its page is salamanderdc.com, which is already on the sheet. |
| Moonraker (Pendry Wharf), Off the Record (Hay-Adams), Round Robin (Willard), Quill/Plume (Jefferson), Summit (Conrad), Top of the Gate/Kingbird (Watergate) | Each hotel is already on the sheet (same domain). |
| The Owl Bar (Belvedere, 1 E Chase St) | Part of Belvedere & Co. Events, which is already on the sheet. |
| Columbia Room (DC) | Site has a self-signed certificate and couldn't be fetched. |
| Cranes (DC) | Site refused the connection; status unconfirmed. |
| Charlie Palmer Steak DC | No longer on charliepalmersteak.com (only NY, Napa, Reno), so it's presumably closed. |
| Ouzo Bay (Baltimore) | ouzobay.com redirects to ouzobeach.com; Baltimore status unclear. |
| Bar Vasquez (Baltimore) | Site returned an empty page; couldn't verify. |
| Carnegie Institution for Science (1530 P St NW) | Historic ballroom used for weddings, but the rentals page returned 500 and MapQuest marks it closed. Status unconfirmed. |
| DAR National Headquarters | dar.org returns 403. |
| Bar del Monte, Providencia, Maydan, Perry's, Omakase at Barracks Row and other Washingtonian 100 names not on the sheet | More casual, or too small for a guitarist. |
| Good Fortune, Café 44 (Alexandria rooftops) | Casual; Café 44 is already on the sheet. |
| Hotel Revival / Topside, Kimpton Lorien, Moxy, AKA | Not true luxury brands. |
