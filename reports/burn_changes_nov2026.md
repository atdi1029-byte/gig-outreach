# Outreach burn, Nov 6-11 2026: every big change

Kept so the end-of-burn report misses nothing (Alex, Nov 11: "i want to make sure i dont miss any other big
changes you made"). Code changes are in git (`git log --since=2026-11-06`); the rest is listed here.

## How the bot runs
- **The burn** (Nov 6, e0736b9, 7947f2e, a27b4af): `night_run.sh --burn`, started by `burn_run.command`. Rounds
  of 25 around the clock, a full audit of every venue after each round, a scraper-fix session every 4 rounds,
  pause/resume with `.burn_pause`, waits when Claude is out of credits.
- **The 1:00 night bot is cancelled for good** (Nov 11): launchd job `com.alexbarnett.outreach-night` unloaded,
  plist moved to `~/Library/LaunchAgents.disabled/`.
- **Credits** (`.env`): ZeroBounce day cap raised to 5000 for the burn (set back to 400 after);
  `APOLLO_MIN_CREDITS=1` so the burn runs Apollo down to 0 (Nov 11); low-credit phone alerts turned off (Nov 11).

## Which places run
- **Best places first** (Nov 7, `DREAM_FIRST=1`): region-wide best-of searches (Michelin, Washingtonian,
  magazines, Forbes, awards, weddings, clubs) added ~140 elite venues; the planner runs them first.
- **2-hour radius really holds** (Nov 7, d87d57f): measured drive time from Pasadena beats the city shortcut;
  Washington VA is not DC.
- **No big-university sites** (Nov 10, 136af6d) after the crawl roamed umd.edu.
- **Real stages first** (Nov 11, a7c0846): restaurants, hotels, clubs, wineries, event venues before galleries,
  museums, churches, senior living, apartments. (Round of Nov 11 afternoon ran a college gallery, a nature
  foundation and senior homes because a loose 1-5 rating ranked them above restaurants.)
- **Upscale but not European** (Nov 11, 5e7185f): the taste rules only knew European food, so Old Ebbitt,
  The Dabney, Kingbird, Bazaar Meat never ran. Claude rated 392 such restaurants; 45 rated 4-5 now run.
- **Pool repair** (Nov 11): ~700 good rows stuck behind bad data from the old Google Maps discovery (query
  words as city, chain homepages, geocodes in other states, never verified) were researched and fixed:
  websites, cities, addresses, drive times; ~110 non-venues dismissed (gyms, shops, parks, apartments, a strip
  club, street numbers). Now automatic in every burn prep (e8f8b1f: `repair_pool.py`, `NIGHT_REPAIR.md`),
  each row rechecked at most every 30 days.

## Who gets saved
- **LinkedIn stays on** (Nov 8): searches the exact venue name in quotes (59f9005); Google and LinkedIn queries
  carry venue type and state, results outside DC/MD/VA dropped (b5eef68: no more Altitude Trampoline Park TX).
- **Wrong-organisation guards** (Nov 11, a8acc92): a venue that is one page of a bigger site (college, chain,
  government) is read on its own page only; listing/wedding-marketplace sites never count as the venue;
  chain head-office and other-location staff dropped; legislators on a links page dropped; Apollo searches
  the venue's own people in its city; hotel-domain booking inboxes paired with the GM the site names.
- **Save everyone at the venue** (Nov 11, f9a9334, `CONTACT_SAVE_ALL=1`): Alex: "just add everyone and ill
  parse it". No title filter, no per-venue cap; the audit lists suspect contacts instead of deleting them.
  Apollo still enriches booking titles first (each person costs a credit).
- **Scraper fixes**: fix sessions committed 30+ fixes (names in sentences, couples, officer mailboxes, forms,
  mail domains on www, director@ = Executive Director...).

## Data cleanups (backups in `reports/repair/`)
- Nov 10: 135 university staff contacts deleted (UMD golf course, Folger, Corcoran).
- Nov 11: 233 junk contacts deleted (St. John's College staff, Here Comes the Guide staff, Cogir head office,
  Chesapeake Bay Foundation org staff, legislators, nameless inboxes). Some were real Workhouse / CBF staff:
  restorable from `cleanup-20261111-junk-contacts.json`.
- Nov 11: venue rows fixed (see Pool repair), 997 marked "Repair checked 2026-11-11".
- Nov 11: the interrupted afternoon run (old picks) closed so the night plans fresh.

## App
- Untouched and waiting venues hidden until the bot runs them (bcab939, 9e65a8b); one Event Venues tile;
  Cream of the Crop skips senior living and other non-prime kinds.

## Other
- Discovery log (`discovery_log.md`) records every search so none is repeated.
- Runbook (`Email/CLAUDE.md`) and home `CLAUDE.md` updated for all of the above.
