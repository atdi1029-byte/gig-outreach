# Pool repair research (unattended)

`night_run.sh` starts you during a burn with `LIST` (venues the planner skips because their sheet row is
bad) and `OUT` (the file you write). Alex is asleep. Never ask a question: decide, do it, write it down.

Why (Nov 11 2026): about 700 good DC/MD/VA restaurants, hotels, clubs and wineries sat unused for months.
The old Google Maps discovery saved query words as the city ("historic place to eat in"), chain homepages
as websites (marriott.com, invitedclubs.com), geocodes in other states (Reston at 43 hours), and the taste
rules skip upscale places that aren't European (Old Ebbitt Grill, The Dabney, Kingbird). You find the
truth; `repair_pool.py apply OUT` writes it.

## Hard rules
- WebSearch and WebFetch only. Never Chrome: no `osascript`, no Claude-in-Chrome tools, no `open`, no
  browser of any kind (a pipeline run is using Chrome). No subagents.
- Never write to the sheet, never edit code or any file but `OUT`, never commit or push.
- Never fill anything from memory: what you could not confirm from a fetched page or a search result is
  confidence "low". `python3` on PATH is broken: use `/usr/bin/python3` if you need it.
- Budget about 40 minutes; the session is killed at 60. Rewrite `OUT` after every 10 venues.

## For every venue in LIST
`LIST` is `{"venues": [{venue_id, name, category, city, state, address, website, reason, rate, promote}]}`.
1. Still open, or permanently closed (with evidence)?
2. Real street address, city, state (it may be outside DC/MD/VA: say so).
3. Its OWN website: for a restaurant or bar inside a hotel, or a club run by a group, its own page on that
   site, never the brand homepage; never a directory, review, tourism, news, social or booking site. If
   the current website is right, return it unchanged.
4. A real place a classical guitarist could play (restaurant, bar, hotel, club, winery, event venue), or
   not (gym, shop, park, apartments, school, marina service, office, strip club...)? -> `not_a_venue`.
5. Only when `rate` is true: an `upscale` rating 1-5 for a solo classical / Spanish / Brazilian / jazz
   guitarist who wants upscale rooms: 5 = dream gig (Michelin or Washingtonian-100 level, luxury hotel
   lounge, elegant club or estate); 4 = clearly upscale; 3 = nice mid-range sit-down; 2 = casual (sports
   bar, chain, fast casual, carryout, food hall); 1 = can't play there. Plus a one-line `why`.

## OUT
A JSON list, one object per LIST venue:
`{"venue_id", "name", "closed": bool, "website", "city", "state", "address": "street, city, ST zip",
"facebook", "instagram", "not_a_venue": bool, "upscale": 1-5 or null, "why", "confidence": "high|medium|low",
"evidence": "one line"}`. Confidence high only when the venue's own site or an official page confirms the
site and address. Every LIST venue must appear.
