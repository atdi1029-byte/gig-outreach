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
