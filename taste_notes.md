# Taste Notes — Processed Venue Feedback

<!-- Master record of all processed venue notes. Each pipeline run appends new entries only. -->

## Backfill — Mar 26, 2026

### The Tidewater Inn (hotel, Easton MD) — POSITIVE
> "I think this would be a great fit for me, easton is a nice historic town with wealthy people. it looks like it has a nice cozy environment."
- **Extracted:** historic, cozy, wealthy clientele, small-town charm
- **Action:** Added to taste_venues.txt. Easton added as sweet spot city.

### Mount Vernon Club (country_club, Baltimore MD) — POSITIVE
> "Good fit! I play at a country club near by and its a similar vibe, historic country club"
- **Extracted:** historic country club, familiar vibe, proven category
- **Action:** Added to taste_venues.txt.

### King & Rye (restaurant, Alexandria VA) — POSITIVE
> "this looks like it has a more upscale vibe and is in alexandria"
- **Extracted:** upscale vibe, Alexandria (already a prime area)
- **Action:** Added to taste_venues.txt. Alexandria confirmed as sweet spot city.

### Washington Golf & Country Club (country_club) — POSITIVE
> "This looks like a perfect fit, it looks like a very high class country club"
- **Extracted:** high class, perfect fit — reinforces country_club as tier 1
- **Action:** Added to taste_venues.txt.

### Army Navy Club (private_club, Washington DC) — POSITIVE
> "great gig, very fancy place, id love to play here, i love historic country clubs, plus its in dc, i play at a similar one thats always a great gig that has super intelligent people."
- **Extracted:** fancy, historic, DC, intelligent crowd, similar to existing great gig
- **Action:** Already in taste_venues.txt (as Army Navy Country Club). Reinforces private_club tier 1, DC as sweet spot.

### Le Cavalier at Hotel du Pont (restaurant, Wilmington DE) — POSITIVE
> "Amazing historic looking building I would love to play there in terms of the vibe."
- **Extracted:** historic architecture, strong vibe appeal
- **Action:** Added to taste_venues.txt. Wilmington added as sweet spot city.

### Hidden Hills Farm and Vineyard (winery, Frederick MD) — NEGATIVE
> "i dont like this place the owners and the people that go there were nt good and we didnt mesh."
- **Extracted:** bad crowd fit, bad owner dynamic — not all wineries are equal
- **Action:** Not in taste_venues.txt (no removal needed). Note: winery stays tier 1 overall but this is a reminder that crowd matters more than category.

### Sunset Hills Vineyard (winery, Purcellville VA) — NEUTRAL
> "i used to play there in the past, it was pretyy ok overall not amazing not bad either"
- **Extracted:** past gig, mediocre experience, no strong signal
- **Action:** No changes. Not worth adding to taste_venues.txt.

---

## Patterns Observed
- **"Historic" is the #1 keyword** — appears in 5 of 6 positive notes. User strongly drawn to historic buildings, clubs, and towns.
- **Wealthy/intelligent crowd** matters — not just the venue, but who goes there.
- **Country clubs + private clubs = strongest category** — 3 of 6 positives.
- **Bad crowd > good venue** — Hidden Hills is a winery (tier 1 category) but the people killed it.
- **Architecture/vibe matters** — Le Cavalier is a restaurant but the historic building made it a strong positive.

---

## Apr 6, 2026 — Post-Pipeline Review

### 2941 Restaurant (restaurant, Falls Church VA) — POSITIVE
> "Amazing looking vibe, good area, I think I'd be a good fit here"
- **Extracted:** great vibe, good area (Falls Church/NoVA), strong fit instinct
- **Action:** Added to taste_venues.txt. Falls Church confirmed as viable NoVA target.

### Clarity (restaurant, Vienna VA) — POSITIVE
> "Fine dining in north Virginia is a great combination for me"
- **Extracted:** fine dining + NoVA = winning combo. Vienna is prime territory.
- **Action:** Added to taste_venues.txt. Reinforces NoVA fine dining as tier 1.

### The Oaks Waterfront Hotel (hotel, Easton MD) — POSITIVE
> "Looks like a nice boutique hotel on the water"
- **Extracted:** boutique hotel, waterfront, Easton (already a sweet spot)
- **Action:** Added to taste_venues.txt. Reinforces Eastern Shore boutique hotels.

### Inn at Perry Cabin (hotel, St Michaels MD) — POSITIVE (thumbs up, no notes)
- **Extracted:** Already a dream venue (9.5 rating). Thumbs up confirms continued love.
- **Action:** Already in taste_venues.txt. No changes needed.

### Sulgrave Club (country_club, Washington DC) — POSITIVE
> "Fancy, historic country club in dc!"
- **Extracted:** fancy, historic, DC — hits all three green flags at once
- **Action:** Added to taste_venues.txt. Another DC private club like University Club/Cosmos Club.

### Black Ankle Vineyards (winery, Mt Airy MD) — POSITIVE
> "I already play here but it has a nice cozy vibe with very Inteligent people! I enjoy playing here"
- **Extracted:** cozy vibe, intelligent crowd — the audience factor again
- **Action:** Already in taste_venues.txt. Reinforces: smart crowd > everything.

### Antrim 1844 (hotel, Taneytown MD) — POSITIVE
> "It looks like an ideal place to play at, nice and historic"
- **Extracted:** historic inn, ideal fit, rural Maryland charm
- **Action:** Added to taste_venues.txt. Historic inns outside the usual corridors are still a match.

### Burnt Hill Farm (winery, Hebron MD) — POSITIVE
> "This is the type of winery I'd love to play at and do well. I can't explain it but the vibe is perfect"
- **Extracted:** perfect vibe (gut feeling), winery — can't articulate why but instinct says yes
- **Action:** Added to taste_venues.txt. Trust the gut on vibe-based picks.

### Linganore Winecellars (winery, Mt Airy MD) — POSITIVE (thumbs up, no notes)
- **Extracted:** Thumbs up, no specific feedback. Winery in Mt Airy area.
- **Action:** Not added to taste_venues.txt (no strong signal beyond thumbs up).

### Elk Run Winery (winery, Mt Airy MD) — NEUTRAL (no notes)
- **Action:** No changes. Neutral = no signal.

### Loew Vineyards (winery, Mt Airy MD) — NEUTRAL (no notes)
- **Action:** No changes.

### Sugarloaf Mountain Vineyard (winery, Dickerson MD) — NEUTRAL (no notes)
- **Action:** No changes.

### The Majestic (restaurant, Alexandria VA) — NEUTRAL (no notes)
- **Action:** No changes. Alexandria stays a sweet spot regardless.

### Bogati Winery (winery, Delaplane VA) — NEUTRAL (no notes)
- **Action:** No changes.

---

## Updated Patterns (Apr 6)
- **"Historic" still #1** — appears in Sulgrave, Antrim, plus all previous positives
- **"Vibe" is emerging as keyword #2** — 2941, Burnt Hill, Black Ankle all mention vibe/feel
- **NoVA fine dining confirmed** — Clarity + 2941 both positive for Falls Church/Vienna area
- **Intelligent/smart crowd keeps surfacing** — Black Ankle explicitly, others implied
- **Gut feeling matters** — Burnt Hill "can't explain it but the vibe is perfect" = trust instinct on venue aesthetics
- **Country clubs + private clubs still dominant** — Sulgrave is the 4th positive private club

---

## Apr 21, 2026 — Post-Pipeline Review (20 new votes)

### Brx American Bistro (restaurant, Flint Hill VA) — POSITIVE
> "Fanny restauruant. I can tell this one would be Good."
- **Extracted:** fancy restaurant, gut instinct positive, Flint Hill VA (rural but upscale)
- **Action:** Added to taste_venues.txt. Rural VA fine dining = viable target.

### The Wildset Hotel (hotel, Saint Michaels MD) — POSITIVE (cautious)
> "I think a good fit. But might be too small"
- **Extracted:** good fit, Eastern Shore, size concern
- **Action:** Added to taste_venues.txt. Small boutique hotels on Eastern Shore still worth pursuing.

### Bourbon & Fig (restaurant, Woodbridge VA) — POSITIVE
> "Amazing, looks like a classy, fine dining, with quiet vibe where I'd do well."
- **Extracted:** classy, fine dining, quiet vibe — the "quiet" keyword is new and important
- **Action:** Added to taste_venues.txt. Quiet fine dining = strong signal.

### Mount Vernon Country Club (country_club, Alexandria VA) — POSITIVE (thumbs up, no notes)
- **Extracted:** Another Alexandria country club thumbs up
- **Action:** Added to taste_venues.txt. Country clubs in Alexandria = reliable.

### Addison Ripley Fine Art (art_gallery, Washington DC) — POSITIVE
> "Fine art galleries and art museums seem like a great fit for what I do!"
- **Extracted:** NEW CATEGORY SIGNAL — art galleries and museums explicitly called out as good fit
- **Action:** Added to taste_venues.txt. Art galleries should move to Tier 1/2 target list.

### Vandiver Inn (hotel, Havre de Grace MD) — POSITIVE
> "It has a nice vibe, seems cozy."
- **Extracted:** cozy vibe, Havre de Grace (northern MD waterfront)
- **Action:** Added to taste_venues.txt. Havre de Grace added as potential sweet spot.

### Alta Strada (Mosaic) (restaurant, Fairfax VA) — POSITIVE
> "Upscale italian restaurant is always a good fit"
- **Extracted:** upscale Italian = confirmed category. Fairfax/Mosaic District.
- **Action:** Added to taste_venues.txt. Italian fine dining confirmed Tier 2+.

### 600 T (restaurant, Washington DC) — POSITIVE
> "Looks like a nice classy place where I'd do well"
- **Extracted:** classy DC restaurant
- **Action:** Added to taste_venues.txt.

### L'Avant-Garde (restaurant, Washington DC) — POSITIVE
> "I think I'd do well, looks like a fancy upscale restaurant"
- **Extracted:** fancy upscale DC restaurant
- **Action:** Added to taste_venues.txt.

### La Chaumiere (restaurant, Washington DC) — POSITIVE
> "Literally perfect! I would do amazing here, fancy French restaurant!"
- **Extracted:** STRONGEST SIGNAL — "literally perfect" + French restaurant. Reinforces French dining as #1 category.
- **Action:** Added to taste_venues.txt. French restaurants remain the gold standard.

### Lulu's Winegarden (wine_bar, Washington DC) — POSITIVE
> "Wine bars are great for me"
- **Extracted:** wine bars confirmed as category. DC wine bars = sweet spot.
- **Action:** Added to taste_venues.txt.

### The Tabard Inn (hotel, Washington DC) — POSITIVE
> "Historic inns are always a great match!"
- **Extracted:** historic inn in DC — "always a great match" = strong category confirmation
- **Action:** Added to taste_venues.txt. Historic inns = tier 1.

### Iron Gate (restaurant, Washington DC) — POSITIVE
> "Fancy restaurant! Looks like a good fit. Upscale"
- **Extracted:** fancy, upscale DC restaurant
- **Action:** Added to taste_venues.txt.

### wineLAIR (wine_bar, Washington DC) — POSITIVE
> "I've played here before, it's a nice cozy wine bar, attracts fancy Upscale people. Nice warm vibe"
- **Extracted:** cozy wine bar, upscale clientele, warm vibe — past gig confirmation
- **Action:** Added to taste_venues.txt. Wine bars with upscale crowd = verified.

### Conrad Washington, DC (hotel, Washington DC) — POSITIVE
> "I've played here before, it's amazing, very upscale very good vibes, very cozy and sophisticated"
- **Extracted:** past gig reconfirmation — already a dream venue (9/10). Upscale, cozy, sophisticated.
- **Action:** Already in taste_venues.txt.

### Salamander Washington DC (hotel, Washington DC) — POSITIVE
> "Fancy hotel, always a good fit"
- **Extracted:** luxury hotel in DC
- **Action:** Added to taste_venues.txt.

### The Jefferson, Washington, DC (hotel, Washington DC) — POSITIVE
> "Very Fancy historic hotel in dc, id do Great"
- **Extracted:** fancy + historic + DC = triple hit. The Jefferson is legendary.
- **Action:** Added to taste_venues.txt.

### Lyle Washington DC (hotel, Washington DC) — POSITIVE
> "Looks like an upscale hotel, I think I'd do nice"
- **Extracted:** upscale DC hotel, positive instinct
- **Action:** Added to taste_venues.txt.

### Pendry Washington DC - The Wharf (hotel, Washington DC) — POSITIVE
> "Luxury hotel! Good fit"
- **Extracted:** luxury hotel at The Wharf
- **Action:** Added to taste_venues.txt.

### Bastille Brasserie & Bar (restaurant, Alexandria VA) — POSITIVE
> "French restaurant is always a good fit. European in general"
- **Extracted:** French/European restaurant in Alexandria — "European in general" expands the French preference
- **Action:** Added to taste_venues.txt. European restaurants broadly = good fit.

---

## Updated Patterns (Apr 21)
- **French/European restaurants = GOLD** — La Chaumiere "literally perfect", Bastille "always a good fit", L'Avant-Garde positive. This is the strongest single category signal.
- **DC luxury hotels emerging as major category** — Jefferson, Salamander, Pendry, Lyle, Conrad all positive. 5 DC hotels in one batch = hunt more aggressively.
- **"Cozy" + "quiet" joining "historic" as top keywords** — Bourbon & Fig (quiet), wineLAIR (cozy warm), Vandiver Inn (cozy), Conrad (cozy sophisticated). The ideal venue is cozy/intimate, not grand/cavernous.
- **Art galleries = NEW tier 1/2 category** — Addison Ripley explicitly called out. Should add museum/gallery searches to discovery.
- **Wine bars confirmed** — Lulu's + wineLAIR both positive in DC. Small, intimate, educated crowd.
- **Italian fine dining confirmed** — Alta Strada positive. Italian joins French/European as target.
- **Geographic expansion: DC dominates this batch** — 12 of 20 positives are DC venues. The city is the #1 market by far.
- **Country clubs still solid** — Mount Vernon CC positive, no new negatives.
- **Rural fine dining viable** — Brx American Bistro in Flint Hill VA shows that upscale restaurants in rural areas still work if the vibe is right.

---

## Apr 23, 2026 — Post-Pipeline Review (1 new vote)

### Historic Sotterley (event, Hollywood MD) — NEGATIVE
> "It's like a plantation museum"
- **Extracted:** plantation museum — uncomfortable historical association, not the right vibe
- **Action:** Not added to taste_venues.txt. Event venues at plantation/museum sites are a poor fit — the setting clashes with the cozy/upscale/sophisticated atmosphere the user thrives in.

---

## Updated Patterns (Apr 23)
- **No major pattern shifts** — only 1 new vote this cycle (negative).
- **Plantation/museum event venues = hard no** — Historic Sotterley rejected for uncomfortable plantation associations. Category "event" at historical sites needs vetting for vibe fit.
- **All prior patterns hold** — French/European restaurants, DC luxury hotels, historic inns, country clubs, wine bars, art galleries remain the top categories.

---

## Jun 25, 2026 — Post-Pipeline Review (23 new votes)

### Springfield Golf & Country Club (country_club) — POSITIVE (thumbs up, no notes)
- **Extracted:** Country club thumbs up, no specific feedback
- **Action:** Added to taste_venues.txt. Country clubs remain reliable.

### Bas Rouge (restaurant, Easton MD) — POSITIVE
> "Upscale French restaurant!"
- **Extracted:** upscale French restaurant in Easton — Eastern Shore fine dining
- **Action:** Added to taste_venues.txt. French restaurants on Eastern Shore = double win.

### The Stewart (wine_bar, Easton MD) — POSITIVE
> "Fancy wine bar! Good fit"
- **Extracted:** fancy wine bar in Easton — wine bar + Eastern Shore combo
- **Action:** Added to taste_venues.txt. Wine bars in upscale areas confirmed again.

### Country Club of Maryland (country_club) — POSITIVE (thumbs up, no notes)
- **Extracted:** Country club thumbs up
- **Action:** Added to taste_venues.txt.

### La Grande Boucherie DC (restaurant, DC) — POSITIVE (thumbs up, no notes)
- **Extracted:** French boucherie in DC — name signals upscale French dining
- **Action:** Added to taste_venues.txt.

### Pearl Restaurant Annapolis (restaurant, Annapolis MD) — NEGATIVE
> "Tiki bar"
- **Extracted:** tiki bar = wrong vibe entirely. Don't be fooled by "restaurant" category.
- **Action:** Not added. Tiki/tropical bars = skip.

### Gibson Island Club (country_club, Gibson Island MD) — POSITIVE (thumbs up, no notes)
- **Extracted:** Exclusive private club on Gibson Island (very wealthy, gated community)
- **Action:** Added to taste_venues.txt. Gibson Island = elite clientele.

### Le Refuge (restaurant, Alexandria VA) — POSITIVE
> "Historic French restaurant"
- **Extracted:** historic + French + Alexandria = triple hit
- **Action:** Added to taste_venues.txt. Another Alexandria French gem.

### Lightfoot Restaurant (restaurant, Leesburg VA) — POSITIVE (thumbs up, no notes)
- **Extracted:** Leesburg restaurant, Loudoun County area
- **Action:** Added to taste_venues.txt.

### Kenwood Golf Country Club (country_club, Bethesda MD) — POSITIVE (thumbs up, no notes)
- **Extracted:** Bethesda country club — wealthy area
- **Action:** Added to taste_venues.txt.

### Dacha Beer Garden (Shaw) (restaurant, DC) — NEGATIVE
- **Extracted:** Beer garden = wrong vibe. Outdoor, loud, beer-focused.
- **Action:** Not added. Beer gardens = skip (like sports bars).

### Nova Europa Restaurant (restaurant, Potomac MD) — POSITIVE
> "Portuguese/ European restaurants are a good fit"
- **Extracted:** Portuguese/European restaurant in Potomac (wealthy area). Confirms European dining broadly as a fit.
- **Action:** Added to taste_venues.txt. European restaurants (not just French) = confirmed.

### Ege Market (restaurant, Bethesda MD) — NEGATIVE
- **Extracted:** No feedback — thumbs down without comment. Likely wrong vibe or cuisine type.
- **Action:** Not added.

### La Bonne Vache (restaurant, Bethesda MD) — POSITIVE
> "French restaurant"
- **Extracted:** French restaurant in Bethesda
- **Action:** Added to taste_venues.txt. French + Bethesda = reliable.

### KaFean Koffee (restaurant, Bethesda MD) — NEGATIVE
- **Extracted:** Thumbs down, no notes. Coffee shop/cafe = wrong fit.
- **Action:** Not added.

### Le Bustiere Boutique (restaurant, Bethesda MD) — NEGATIVE
> "Terrible, a lingerie store"
- **Extracted:** Not actually a restaurant — misclassified. Lingerie store.
- **Action:** Not added. Discovery bug — non-venue slipping through.

### De Ma Vie (restaurant, McLean VA) — NEGATIVE
- **Extracted:** Thumbs down, no notes.
- **Action:** Not added.

### Petit Louis Bistro (restaurant, Roland Park Baltimore MD) — POSITIVE (thumbs up, no notes)
- **Extracted:** French bistro in Roland Park — upscale Baltimore neighborhood
- **Action:** Added to taste_venues.txt. Roland Park = good Baltimore area.

### Le Comptoir du Vin (wine_bar, Roland Park Baltimore MD) — POSITIVE (thumbs up, no notes)
- **Extracted:** French wine bar in Roland Park
- **Action:** Added to taste_venues.txt. Wine bar + French + Roland Park.

### The Vineyard Wine Bar (wine_bar, Havre de Grace MD) — POSITIVE
> "Wine bars are a good fit"
- **Extracted:** Wine bar confirmation again, Havre de Grace area
- **Action:** Added to taste_venues.txt.

### L'Hirondelle Club (private_club, Ruxton MD) — POSITIVE (thumbs up, no notes)
- **Extracted:** Private club in Ruxton (wealthy Baltimore suburb)
- **Action:** Added to taste_venues.txt. Private clubs remain tier 1.

### Bavarian Inn (hotel, Shepherdstown WV) — POSITIVE (thumbs up, no notes)
- **Extracted:** Inn in Shepherdstown — historic college town, edge of radius
- **Action:** Added to taste_venues.txt.

### Lancaster Arts Hotel (hotel, Lancaster PA) — POSITIVE (thumbs up, no notes)
- **Extracted:** Arts hotel in Lancaster PA — cultural/artistic venue
- **Action:** Added to taste_venues.txt. Arts-oriented hotels = good fit.

---

## Updated Patterns (Jun 25)
- **French dominance continues** — Bas Rouge, Le Refuge, La Bonne Vache, La Grande Boucherie, Petit Louis, Le Comptoir du Vin all positive. French restaurants/wine bars are the single strongest category.
- **European broadly confirmed** — Nova Europa: "Portuguese/European restaurants are a good fit." Not just French — Portuguese, Italian, European in general.
- **Wine bars = tier 1 confirmed** — The Stewart, Le Comptoir du Vin, The Vineyard Wine Bar all positive. User explicitly says "wine bars are a good fit."
- **Country clubs still rock solid** — Springfield, Country Club of MD, Gibson Island, Kenwood all thumbs up with zero hesitation.
- **Private clubs strong** — L'Hirondelle Club positive, reinforces tier 1.
- **Eastern Shore expanding** — Bas Rouge + The Stewart in Easton = more than just hotels there. Fine dining + wine bars viable.
- **Roland Park (Baltimore) = new sweet spot** — Petit Louis + Le Comptoir du Vin both positive. Add to Baltimore area targets.
- **Beer gardens/tiki bars = hard no** — Dacha + Pearl both negative. Outdoor, loud, casual = wrong audience.
- **Discovery quality issue** — Le Bustiere Boutique is a lingerie store, not a venue. Filter needs work.
- **6 negatives this batch** — highest negative count yet. But all are clear category mismatches (tiki, beer garden, coffee, lingerie). The taste system is working — user is filtering junk quickly.

---

## Jun 26, 2026 — Post-Pipeline Review (2 new votes)

### Fleurie Restaurant (restaurant, Charlottesville VA) — REJECTED (distance)
> "Too far"
- **Extracted:** Charlottesville = outside 2hr radius. Confirms existing venue_radius rule.
- **Action:** No changes. Charlottesville remains out of range.

### 1799 at The Clifton (restaurant, Charlottesville VA) — REJECTED (distance)
> "Too far"
- **Extracted:** Same — Charlottesville too far.
- **Action:** No changes.

---

## Updated Patterns (Jun 26)
- **No major pattern shifts** — only 2 new votes, both distance rejections.
- **Charlottesville confirmed too far** — two separate venues rejected for distance alone. Remove from taste discovery tier 2 locations if still present.
- **All prior patterns hold** — French/European restaurants, wine bars, country clubs/private clubs, DC luxury hotels, historic venues remain top categories.

---

## Jul 4, 2026 — Post-Pipeline Review (5 new votes)

### Le Chat Noir (restaurant, Washington DC) — POSITIVE (thumbs up, no notes)
- **Extracted:** French restaurant in Tenleytown DC, wine lounge upstairs. Already identified as legit in Jun 26 run.
- **Action:** Added to taste_venues.txt. French restaurants in DC remain gold.

### Annapolis Waterfront Hotel Autograph Collection (hotel, Annapolis MD) — POSITIVE (thumbs up, no notes)
- **Extracted:** Waterfront hotel in Annapolis — upscale area, tourist/boating crowd.
- **Action:** Added to taste_venues.txt. Annapolis hotels = viable targets.

### Al Tiramisu (restaurant, Washington DC) — POSITIVE (thumbs up, no notes)
- **Extracted:** Italian fine dining in DC (Dupont Circle area). White tablecloth Italian.
- **Action:** Added to taste_venues.txt. Italian fine dining confirmed again as tier 2+.

### Rosemarino D'Italia (restaurant, location TBD) — POSITIVE (thumbs up, no notes)
- **Extracted:** Italian restaurant — name signals upscale Italian dining.
- **Action:** Added to taste_venues.txt.

### Monarque (restaurant, Washington DC) — POSITIVE (thumbs up, no notes)
- **Extracted:** French brasserie in DC (Penn Quarter). Upscale French dining.
- **Action:** Added to taste_venues.txt. Another DC French restaurant thumbs up.

---

## Updated Patterns (Jul 4)
- **French/Italian dominance continues** — Le Chat Noir, Monarque (both French), Al Tiramisu, Rosemarino D'Italia (both Italian) all positive. These two cuisines are the strongest single signal.
- **Annapolis hotels confirmed** — waterfront hotel thumbs up, adds to Eastern Shore/Annapolis as viable territory.
- **All 5 votes positive** — zero negatives this batch. User's taste profile is well-calibrated at this point.
- **All prior patterns hold** — French/European, Italian fine dining, wine bars, country clubs/private clubs, DC luxury hotels, historic venues remain top categories.

---

## Jul 8, 2026 — Post-Pipeline Review (5 new votes)

### Chester River Yacht & Country Club (country_club, Chestertown MD) — POSITIVE
> "Private club are good"
- **Extracted:** Private/yacht club on Eastern Shore, Chestertown area. Reinforces clubs as tier 1.
- **Action:** Added to taste_venues.txt. Yacht clubs confirmed alongside country clubs.

### Norbeck Country Club (country_club, Potomac MD) — POSITIVE (thumbs up, no notes)
- **Extracted:** Country club in Potomac — one of the wealthiest areas in MD.
- **Action:** Added to taste_venues.txt. Potomac country clubs = prime targets.

### La Ferme (restaurant, Chevy Chase MD) — POSITIVE
> "Fancy French restaurant"
- **Extracted:** French restaurant in Chevy Chase — wealthy DC suburb, French dining confirmed again.
- **Action:** Added to taste_venues.txt. French restaurants in wealthy suburbs = reliable.

### LiLLiES Italian (restaurant, Washington DC) — POSITIVE (thumbs up, no notes)
- **Extracted:** Italian restaurant in DC. Another Italian fine dining thumbs up.
- **Action:** Added to taste_venues.txt. Italian continues to rank alongside French.

### Filomena Ristorante (restaurant, Georgetown DC) — POSITIVE (thumbs up, no notes)
- **Extracted:** Iconic Georgetown Italian restaurant. White tablecloth, upscale crowd.
- **Action:** Added to taste_venues.txt. Georgetown Italian = strong fit.

---

## Updated Patterns (Jul 8)
- **French + Italian = bulletproof** — La Ferme (French), LiLLiES + Filomena (Italian) all positive. These two cuisines have zero negatives across all batches.
- **Clubs still rock solid** — Chester River Y&CC + Norbeck CC both positive. User explicitly says "private clubs are good."
- **Georgetown Italian emerging** — Filomena is a Georgetown institution. Combined with Brasserie Liberte and Degrees Bistro, Georgetown has the highest density of positive votes.
- **All 5 votes positive** — zero negatives again. Taste profile is extremely well-calibrated.
- **All prior patterns hold** — French/European, Italian, wine bars, clubs, DC hotels, historic venues.

---

## Jul 15, 2026 — Post-Pipeline Review (10 new votes)

### The Tidewater Inn (hotel, Easton MD) — POSITIVE (thumbs up, no notes)
- **Extracted:** Already processed in backfill (Mar 26). Re-confirmed positive. Historic inn in Easton.
- **Action:** Already in taste_venues.txt. No changes.

### La Chaumiere (restaurant, Washington DC) — POSITIVE (duplicate vote)
- **Extracted:** Already processed Apr 21 ("Literally perfect!"). Re-confirmed.
- **Action:** Already in taste_venues.txt. No changes.

### Brasserie Royale (restaurant, Reston VA) — POSITIVE (thumbs up, no notes)
- **Extracted:** French brasserie in Reston — NoVA fine dining territory.
- **Action:** Added to taste_venues.txt. French + Reston = reliable.

### Brasserie Liberte (restaurant, Georgetown DC) — POSITIVE (thumbs up, no notes)
- **Extracted:** French brasserie in Georgetown — premium DC location.
- **Action:** Added to taste_venues.txt. Georgetown French = strong fit.

### Degrees Bistro (restaurant, Georgetown DC) — POSITIVE (thumbs up, no notes)
- **Extracted:** Bistro in Georgetown at the Ritz-Carlton. Hotel dining + Georgetown.
- **Action:** Added to taste_venues.txt. Georgetown hotel restaurants = viable.

### Le Sel French Bistro (restaurant, Dupont Circle DC) — POSITIVE (thumbs up, no notes)
- **Extracted:** French bistro in Dupont Circle — wealthy, cultured neighborhood.
- **Action:** Added to taste_venues.txt. Dupont Circle French = strong fit.

### Tuscarora Mill Restaurant (restaurant, Leesburg VA) — POSITIVE (thumbs up, no notes)
- **Extracted:** Fine dining in Leesburg — historic mill building, Loudoun County.
- **Action:** Added to taste_venues.txt. Leesburg fine dining = viable.

### La Fete (restaurant, Wilmington DE) — POSITIVE (thumbs up, no notes)
- **Extracted:** French restaurant in Wilmington DE — Brandywine Valley territory.
- **Action:** Added to taste_venues.txt. Wilmington French dining confirmed.

### The Elkridge Furnace Inn (hotel, Ellicott City MD) — POSITIVE (thumbs up, no notes)
- **Extracted:** Historic inn — user already plays here (past gig). Re-confirmed love.
- **Action:** Already in taste_venues.txt. No changes.

### Alta Strada (Mosaic) (restaurant, Fairfax VA) — POSITIVE (duplicate vote)
- **Extracted:** Already processed Apr 21. Re-confirmed.
- **Action:** Already in taste_venues.txt. No changes.

---

## Updated Patterns (Jul 15)
- **French brasseries are the GOLD STANDARD** — Brasserie Royale, Brasserie Liberte, Le Sel, La Fete all positive. Every French restaurant vote across all batches has been positive. Zero negatives ever.
- **Georgetown density increasing** — Brasserie Liberte + Degrees Bistro join Filomena. Georgetown now has the most concentrated cluster of positive votes.
- **Leesburg/Loudoun emerging** — Tuscarora Mill joins Lightfoot Restaurant as Leesburg fine dining targets. The 8 batch 1 venues from this run are all Leesburg — a heavy investment in the area.
- **All 10 votes positive** — third consecutive batch with zero negatives. Taste profile is highly calibrated.
- **All prior patterns hold** — French/European, Italian, wine bars, clubs, DC hotels, historic venues.

---

## Jul 18, 2026 — Post-Pipeline Review (12 new votes)

### Woodholme Country Club (country_club, Baltimore MD) — POSITIVE (thumbs up, no notes)
- **Extracted:** Country club in Baltimore area. Another club thumbs up.
- **Action:** Added to taste_venues.txt.

### The Elkridge Club (country_club, Baltimore MD) — POSITIVE (thumbs up, no notes)
- **Extracted:** Historic private club in Baltimore — prestigious, old-money institution.
- **Action:** Added to taste_venues.txt. Baltimore elite clubs = strong fit.

### Green Spring Valley Hunt Club (private_club, Baltimore MD) — POSITIVE (thumbs up, no notes)
- **Extracted:** Exclusive private hunt club in Green Spring Valley — very wealthy area.
- **Action:** Added to taste_venues.txt. Hunt clubs joining country clubs as tier 1.

### Le Yaca French Restaurant (restaurant, Williamsburg VA) — POSITIVE
> "French restaurant"
- **Extracted:** French restaurant — simple confirmation. Note: Williamsburg may be outside radius but user still voted positive on quality.
- **Action:** Added to taste_venues.txt. French = always positive.

### Chez Billy Sud (restaurant, Georgetown DC) — POSITIVE (thumbs up, no notes)
- **Extracted:** French restaurant in Georgetown. Already a strong neighborhood.
- **Action:** Added to taste_venues.txt. Georgetown French = bulletproof.

### La Piquette (restaurant, DC) — POSITIVE (thumbs up, no notes)
- **Extracted:** French restaurant in DC.
- **Action:** Added to taste_venues.txt.

### Cafe du Parc (restaurant, DC) — POSITIVE (thumbs up, no notes)
- **Extracted:** French cafe/restaurant in DC.
- **Action:** Added to taste_venues.txt.

### Barcelona Wine Bar (restaurant, DC) — POSITIVE
> "Fancy Spanish wine bar is an amazing fit!"
- **Extracted:** Spanish wine bar — "amazing fit" is strong signal. NEW: Spanish wine bars join French/Italian as positive cuisine categories.
- **Action:** Added to taste_venues.txt. Spanish wine bars = new tier 2+ category.

### The Tower Club Tysons (restaurant/private_club, Tysons VA) — POSITIVE (thumbs up, no notes)
- **Extracted:** Private business club in Tysons — upscale corporate crowd.
- **Action:** Added to taste_venues.txt. Business/tower clubs joining private clubs as targets.

### Bistro 112 (restaurant, Shepherdstown WV) — POSITIVE (thumbs up, no notes)
- **Extracted:** Bistro in Shepherdstown — WV college town at edge of radius.
- **Action:** Added to taste_venues.txt. Shepherdstown viable for bistro-quality venues.

### Takumi Japanese Bistro (restaurant, Bethesda MD) — NEGATIVE (thumbs down, no notes)
- **Extracted:** Japanese restaurant = wrong fit. Sushi/ramen atmosphere doesn't match classical guitar.
- **Action:** Not added. Japanese restaurants = skip.

### Takumi Japanese Bistro & Bar (restaurant, Bethesda MD) — NEGATIVE (thumbs down, no notes)
- **Extracted:** Same chain/concept, same negative signal. Japanese dining confirmed as poor fit.
- **Action:** Not added. Two separate Takumi entries both negative = strong signal against Japanese restaurants.

---

## Updated Patterns (Jul 18)
- **Spanish wine bars = NEW positive category** — Barcelona Wine Bar "amazing fit." Adds to French/Italian/European as confirmed cuisines.
- **Baltimore elite clubs cluster** — Woodholme, Elkridge Club, Green Spring Valley Hunt Club all positive in one batch. Baltimore private clubs = hunt aggressively.
- **Business/tower clubs viable** — Tower Club Tysons positive. Corporate private clubs (not just country clubs) are targets.
- **Japanese restaurants = skip** — two separate Takumi venues both negative. Japanese cuisine doesn't match classical guitar vibe.
- **French still undefeated** — Chez Billy Sud, La Piquette, Cafe du Parc, Le Yaca all positive. ZERO negative French votes across all time.
- **10 of 12 positive** — two negatives are both Japanese restaurants (same concept). Taste profile remains highly calibrated.
- **All prior patterns hold** — French/European, Italian, Spanish wine bars, wine bars, clubs, DC hotels, historic venues.

---

## Jul 23, 2026 — Post-Pipeline Review (3 new votes)

### Rosewood Washington DC (hotel, Georgetown DC) — POSITIVE (thumbs up, no notes)
- **Extracted:** Luxury hotel in Georgetown — premium location + high-end brand.
- **Action:** Added to taste_venues.txt. Georgetown luxury hotels = strong fit.

### The Georgetown Inn (hotel, Georgetown DC) — POSITIVE (thumbs up, no notes)
- **Extracted:** Georgetown hotel — another Georgetown hospitality venue thumbs up.
- **Action:** Added to taste_venues.txt. Georgetown hotels clustering as targets.

### Bethesda Theater (event, Bethesda MD) — NEGATIVE
> "Counterintuitively I'm not looking for theaters"
- **Extracted:** Theaters explicitly rejected as a category. Despite seeming like a cultural fit, user doesn't want them.
- **Action:** Not added. Theaters/performance venues = skip. This is a new anti-pattern — not obvious from the taste profile.

---

## Updated Patterns (Jul 23)
- **Georgetown hotel cluster** — Rosewood + Georgetown Inn join Degrees Bistro (at Ritz), Chez Billy Sud. Georgetown is the #1 neighborhood for positive votes across all categories.
- **Theaters = NEW anti-pattern** — user explicitly says "not looking for theaters." Counterintuitive but clear. Remove theater/performance venues from discovery targets.
- **All prior patterns hold** — French/European, Italian, Spanish wine bars, wine bars, clubs, DC hotels, historic venues. No French restaurant has ever received a negative vote.

---

## Aug 2, 2026 — Post-Pipeline Review (2 new votes)

### Il Porto Ristorante (restaurant, Alexandria VA) — POSITIVE (thumbs up, no notes)
- **Extracted:** Italian restaurant in Alexandria — Old Town area, upscale Italian dining.
- **Action:** Added to taste_venues.txt. Italian + Alexandria = reliable combo, reinforces both categories.

### Round House Theatre (event, Bethesda MD) — NEGATIVE
> "Theatre are bad"
- **Extracted:** Another theater explicitly rejected. Confirms Jul 23 pattern.
- **Action:** Not added. Theaters = confirmed anti-pattern (now 2 separate negative votes).

---

## Updated Patterns (Aug 2)
- **Theaters double-confirmed as skip** — Round House Theatre joins Bethesda Theater as explicit negative. Two separate theater venues rejected = hard rule.
- **Italian in Alexandria still bulletproof** — Il Porto joins the long list of positive Italian/Alexandria votes.
- **All prior patterns hold** — French/European, Italian, Spanish wine bars, wine bars, clubs, DC hotels, historic venues. No French or Italian restaurant has ever received a negative vote.
