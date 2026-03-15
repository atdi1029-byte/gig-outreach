# Email Project — Notes

## Session 1 (Mar 1, 2026)

### Context
- **User is a classical guitarist** looking to book gigs
- Outreach targets: venues, events, businesses that hire live musicians

### Overview
- **Goal**: Automate the grunt work of client outreach for gigs
- **Two parts**: (1) Claude replicates email workflow for finding/stacking leads, (2) Website + app to store and review everything
- **Key constraint**: NO auto-sending — Google/Instagram TOS. Claude stacks up people/resources to message, user manually reviews and sends
- **Claude runs in background**: researches leads, drafts messages, queues everything up
- **Website + PWA app**: user can review queued outreach on the go (e.g. copy/paste while on a walk)
- **Summary**: Does all the grunt work while user is away → user reviews + sends manually

### Workflow

**Step 1: Find a comprehensive list for the category**
- Example: "wineries in maryland" → finds marylandwine.com/wineries/ (association directory)
- Prefers detailed compiled lists (association sites, trail directories) over individual Google results
- Maryland wineries example: 70+ wineries listed with wine trail groupings
- Goal: find the best source that has the most complete list, then work through it

**Automation idea**: For each category, search for association/directory sites first (e.g. "[category] association [state]"), then fall back to Google Places if no good list exists

**Step 2: Visit individual venue page**
- Click into each venue from the directory (e.g. marylandwine.com/wineries/big-cork-vineyards/)
- Info available: name, address, phone, website link, hours, about description, activities
- Example: Big Cork Vineyards — 4236 Main Street Rohrersville MD 21779, (301) 302-8032
- Also note: user has a "To Email - Google Docs" tab open (that's where compiled info goes)

**Step 3: From the venue's actual website, grab:**
- Email address(es)
- Facebook page link
- Instagram page link
- (Usually found in header/footer icons — e.g. Big Cork has phone/email/FB/IG icons in top bar)
- Don't need: address, phone number

**Step 3b: Use Apollo.io Chrome extension (free tier)**
- Opens sidebar panel on the venue's website
- Shows: company name, category tags (Winery, Concert venue, Tourism, Event venue, etc.), location, employee count, revenue
- "24+ employees" with "View" button to see individual contacts
- Has social links at bottom (Apollo, Crunchbase, X, Facebook, Crunchbase)
- Tags are useful for ranking (e.g. "Concert venue" + "Event venue" = higher priority for gigs)
- Free tier = limited; paid API = future option

**Step 3c: Apollo employee list → Access email**
- Click "View" on employees → shows list of contacts with names + titles
- Key contacts to target (for gigs): Event-related roles
  - Emma Norton — Event Services Specialist
  - Meagan Grove — Events Manager ← this is the one you want
  - David Collins / Dave Collins — VP Operations, Winemaker (probably not the right person)
- Click "Access email" to reveal their email address
- Apollo free tier has limited email reveals per month
- Result: personal email like mgrove@bigcorkvineyards.com (verified with green check)
- Only care about the email — not phone number

**Step 4: Verify email is real**
- Must verify before sending — Gmail penalizes you for bounced emails (spam score)
- Uses an email verification service to check if address is valid
- Avoids sending duds that hurt deliverability
- Service: **ZeroBounce** (zerobounce.net)
- Currently does 1 by 1, but can bulk verify
- Future: scrape all emails → batch verify through ZeroBounce → only queue verified ones
- ZeroBounce dashboard: zerobounce.net/members/dashboard
- Currently 368 credits, free subscription renews Apr 1, 2026
- 1,637 total validations done so far
- Has: Validate, Score, Email Finder, Domain Search, Bulk options, API access
- Quick Stats: removed 140 invalids, 167 complainers/spamtraps, fixed 4 typos
- **ZeroBounce has an API** — can automate bulk verification programmatically
- Validation result shows: STATUS (valid/invalid), SUB-STATUS, FREE EMAIL (yes/no), DOMAIN, SMTP PROVIDER, MX FOUND, DOMAIN AGE
- Only care about: STATUS = "valid" → good to email
- Example: mgrove@bigcorkvineyards.com → valid, Microsoft SMTP, MX found = Yes

**Step 5: Send email using predefined template**
- Each category (wineries, restaurants, weddings, etc.) has its own email template
- If verified → send using the matching template for that venue type
- **This is the handoff point** — everything before this is automatable, sending is manual
- User copies email → opens Gmail → pulls up the right template → sends manually
- Gmail account: alexbarnettclassical@gmail.com
- Phone: 410-794-6204

**Winery Template:**
- Subject: "Classical Guitarist (Spanish/Brazilian Music) to Perform at your Winery!"
- Body:
  - Opening: "Hi I'm a Baltimore based Classical Guitarist and I want to perform at your Winery!"
  - International credits: Copacabana Palace (Brazil), Cadogan Hotel (London), Lake of Meneith Hotel (Scotland), National Museum (Colombia)
  - Local credits: L'Auberge Chez Francois, The Inn at Perry Cabin, The Maryland Club, The Army Navy Country Club, The River Bend Country Club
  - YouTube playlist link
  - Contact info (email + phone)
  - Sign-off: "Best, Alexander Barnett"
- Template varies by venue type (swap "Winery" for "Restaurant", "Hotel", etc.)
- Mostly same body, just the subject + opening line changes per category

**Step 6: LinkedIn — LAST STEP, cleanup only (Apollo does the heavy lifting)**
- Search the venue name on LinkedIn to find people Apollo missed
- LinkedIn profile: Alex Barnett, Classical Guitarist, Ellicott City, Maryland
- Goal: find event managers, owners, coordinators that Apollo might have missed
- Filter by "People" tab, check first 3 pages max
- Example Big Cork results:
  - Keith Morris — VP & General Manager (Message)
  - Pam Piper — Executive Assistant (Message)
  - Vincent Perrotta — Wine Server/Tour Guide (skip — too low level)
  - **Grant Taylor — Events & Business Coordinator** ← target
  - **Meagan Grove — Events Manager** ← target (same as Apollo)
  - Randy Thompson — President & CEO (Connect)
- Target: anyone with "Events", "Manager", "Coordinator" in title
- Can Message (3rd+ connections) or Connect (2nd connections)
- Important: filter for "Current:" employees only — skip "Past:" (no longer work there)
  - e.g. Kaitlynn Campbell "Past: Event Coordinator at Big Cork" = skip
- Click person's name → Apollo sidebar loads their info → grab email
- Same flow: Apollo email → ZeroBounce verify → queue for sending
- Check first 3 pages of LinkedIn results max
- ONLY keep people who have the venue name in their title (filters out random connections)
- Anyone without the venue name in their LinkedIn title = skip (not confirmed current employee)
- Keep all emails for now — user uses discretion on personal vs business
- Some small businesses use gmail as their business email

**Step 7: Instagram outreach**
- Open venue's Instagram (link already scraped from website)
- Two things:
  1. DM them — same template as email
  2. Grab email from Instagram bio/contact button (business profiles often have one)
- App flow: tap button → opens their IG profile + copies DM text to clipboard → paste and send
- Mainly mobile workflow
- IG contact button email may be different/better than website email — always grab it
- Desktop IG may not show contact button — mobile app only (limitation to note)

**Step 8: Facebook outreach (LAST STEP)**
- Open venue's Facebook page (link already scraped from website)
- Facebook page has: Message button, IG link, phone, address, website
- Also shows useful context: "2026 Concerts In The Vines" = they DO live events → high priority
- DM via Messenger — same template
- Check About → Contact info section for email (e.g. info@bigcork.com)
- Facebook About page URL pattern: facebook.com/[page]/directory_contact_info
- Also shows: IG link, phone, Messenger, website link
- This is scrapable — structured contact info page

**How it works:**
- User defines ~10 search categories (e.g. types of venues/businesses)
- Claude systematically goes city by city through an entire state
- For each city × category combo: compile contact info, details, draft outreach
- **Tracking**: system keeps record of what's been done (which cities, which categories, who's been contacted)
- No duplicate work — never waste time re-researching something already covered
- All results queue up on website/app for manual review + send

**Borrowed from Trade Dashboard:**
- **Ranking system**: prioritize best leads first (criteria TBD later)
- **Pokemon leveling**: level up every X emails sent (gamification to make grind fun)
- **Potential other game elements**: badges, streaks, etc. (TBD)

### Complete Workflow Summary (per venue)
1. **Find venue** from directory/association list (e.g. marylandwine.com)
2. **Scrape website** for emails + Facebook + Instagram links (curl script)
3. **Apollo on website** → find employees → grab emails (event managers, coordinators, GMs)
4. **ZeroBounce verify** all collected emails
5. **Send email** using category-specific template (manual — from app queue)
6. **LinkedIn** → search venue → People filter → "Current:" employees only → Apollo for emails → verify → send
7. **Instagram** → DM (same template) + grab email from contact button
8. **Facebook** → DM (same template) + grab email from About/Contact info page

**Then repeat for next venue. Then next city. Then next state.**

### What Claude Automates vs Manual
| Step | Claude | User |
|------|--------|------|
| Find directory lists | YES | |
| Scrape emails/social links | YES | |
| Apollo employee emails | TBD (browser automation?) | Currently manual |
| ZeroBounce verification | YES (API) | |
| Compile & rank leads | YES | |
| Track what's done | YES | |
| Send emails | | MANUAL |
| Send Instagram DMs | | MANUAL |
| Send Facebook messages | | MANUAL |

### Search Categories
**Current 6:**
1. Wineries / Vineyards
2. Museums / Galleries
3. Country clubs / Golf clubs / Private clubs
4. Hotels / Resorts / Inns
5. Events (event planners, wedding planners)
6. Restaurants

**TODO — Expand to full list (user wants comprehensive categories):**
- Breweries / Taprooms / Distilleries
- Wedding venues / Estates / Barns
- Spas / Wellness centers
- Yacht clubs / Marinas
- Corporate event spaces
- Libraries (concert series)
- Churches / Cathedrals (concert series)
- Botanical gardens / Arboretums
- Historic estates / Mansions
- Funeral homes
- Senior living / Retirement communities
- Embassies / Consulates (DC area)
- University music departments
- Theater / Performing arts centers
- Rooftop bars / Lounges
- Tea rooms / Cigar lounges
- High-end retail (jewelry stores, in-store events)
- Real estate open houses (luxury homes)
- Private dining / Supper clubs
- **User to finalize which to include**

### Ranking System
- Primary signal: **how upscale the venue is** (higher end = better fit for classical guitar)
- **Proximity to wealthy zones**: DC, Annapolis, Easton MD, etc. — priority areas
- **Zone system**: tag cities/areas as high-value zones (more money = higher rank)
- TBD: how to score this (Google price range $$$$, reviews, photos, zone, etc.)

### App/Website Design

**Screen 1 — Top Picks**
- First thing you see when opening the app
- Shows the best fit venues regardless of location/category
- Ranked by upscale score + relevance (e.g. they host live events, have events manager, etc.)

**Navigation hierarchy:**
- Top Picks (best fit regardless of location)
- States → Counties → Cities → Categories → Individual venues
  - e.g. Maryland → Howard County → Ellicott City → Wineries → Big Cork Vineyards
- States: Maryland, Virginia, West Virginia, Pennsylvania, Delaware
- Categories inside each city: restaurants, hotels, wineries, wine bars, museums, country clubs, events

**Venue card — what to show:**
- Venue name + category
- **Action needed** — what's left to do:
  - Emails to send (verified, ready to go)
  - Instagram DM pending
  - Facebook message pending
  - Apollo emails to review
- Status: untouched / in progress / fully contacted
- Tap-to-copy: email, IG link, FB link, DM template
- Pre-filled Gmail link (subject + body ready)
- Don't need: address, phone, hours — just actionable stuff
- **Completed venues disappear** — only show venues with actions remaining (no clutter)
- Priority zones color-coded: green (high value) / yellow (medium) / default

### TODO
- Get list of venues where Alex has played successfully — use as ranking baseline/template for "good fit"

### Still To Build
- **Apollo.io integration** — browser automation (Selenium/Playwright) to pull employee emails from LinkedIn + websites
- **LinkedIn search** — automate finding employees with "Current:" at target venues, first 3 pages
- **Instagram contact email** — grab email from IG bio/contact button (mobile-only limitation)
- **Facebook About page scraping** — pull emails from /about contact info section
- **ZeroBounce bulk verify** — batch all collected emails at once instead of one by one
- **More templates** — museum, hotel, restaurant, country club, event (only winery done so far)
- **Ranking system** — upscale scoring, zone priority, venue fit scoring
- **Pokemon leveling** — tune thresholds for outreach counts
- **GitHub Pages PWA** — deploy for mobile phone access
- **Design polish** — make dashboard look nicer

### Email Rules
- **Skip info@ emails** — they never work (generic inbox, nobody reads them)
- **Skip inquiries@ emails** — same problem, generic inbox
- Only queue personal/named emails (e.g. mgrove@, jane@, etc.)
- Generic prefixes to auto-skip: info@, hello@, admin@, support@

### Session 3 (Mar 13, 2026) — Automation Proof of Concept

**Apollo MCP Test (Free Tier):**
- Connected Apollo on Claude.ai (Settings → Integrations)
- Free tier can't search employees at a company (paywalled $49-99/mo)
- Can only enrich individuals if you already have their name
- Organization enrichment works (company details) but no contacts
- **Verdict: MCP not useful on free tier for contact discovery**

**Apollo Website Automation (PROVEN):**
- Use app.apollo.io website instead of Chrome extension — same data, easier to automate
- AppleScript + JavaScript controls Chrome, reads page content, clicks buttons
- Full flow working:
  1. Navigate to `app.apollo.io/#/organizations/{id}/people`
  2. Read employee list via `document.body.innerText` (names, titles)
  3. Find "Access email" buttons via `document.querySelectorAll('button')`
  4. Click via JavaScript: `btn.click()` — WORKS
  5. Read revealed email from page text via regex
  6. Paginate with `>` next button (25 per page)
- **Green check = click** (verified email available)
- **Red X = skip** (invalid/bad email)
- **Question mark = skip** (unverified, wastes credits)
- Apollo rate limits: ~5 min between "Access email" clicks
- Free tier: ~100 email reveals per month — one overnight run covers it
- **Tested on Inn at Perry Cabin: got daniel.silva@pyramidglobal.com and mratliff@perrycabinresorts.com**

**Setup Requirements:**
- Chrome: View → Developer → Allow JavaScript from Apple Events (one-time)
- `cliclick` installed via brew (for physical mouse clicks if needed)
- AppleScript can read DOM but Apollo renders via React — some elements need alternate query methods

**Inn at Perry Cabin — Added to Sheet:**
- Venue ID: MD-HOTE-003, category: hotel, upscale score: 5, zone: high
- Source: past_gig — luxury resort, ideal client base
- 53 employees on Apollo, subsidiary of Pyramid Global Hospitality
- High management turnover — re-scrape contacts periodically
- Instagram for weddings: instagram.com/perrycabinweddings/

**Email Filter Rules (updated):**
- Auto-skip: info@, hello@, admin@, support@
- Keep: inquiries@, contact@, reservations@ (you never know)

**Key Design Decisions:**
- Recommendation engine is CORE — build intelligence before mass outreach
- No "hosts live music" filter — targeting venues that SHOULD have it
- Contact targeting is broad — anyone with decision-making power (not just event managers)
- User teaches system what "good contact" looks like over time
- Categories need expansion beyond original 6 (user has a list)

**Manual Email Inbox Feature:**
- Each venue page gets an "Add Email" button
- User pastes emails found manually (Facebook, IG bio, cold browsing, etc.)
- Email goes into master "Unverified" queue, tagged to the venue
- Once daily: batch-verify all pending emails via ZeroBounce API
- Valid ones move to venue's contact list as "ready to send"
- Invalid ones get flagged
- Keeps everything organized — every email tied to a venue, auto-verified

**Facebook Scraping (tested Mar 13):**
- Navigate to facebook.com/[page]/about → click "Contact info" tab
- Reads email, phone, Messenger from structured contact section
- Inn at Perry Cabin: found marketing@perrycabinresorts.com
- Works via AppleScript + JavaScript regex scrape

**Instagram Scraping (tested Mar 13):**
- Navigate to instagram.com/[handle]/ on desktop
- Business profiles show contact info (from linked Facebook page)
- Inn at Perry Cabin: found marketing@perrycabinresorts.com
- Same email regex approach works
- IG "Contact" button for DMs is mobile-only — DMs stay manual
- Email scraping from profile page works on desktop

**Apollo Automation Steps (PROVEN Mar 15 2026):**

**ANTI-DETECTION: All delays use randomizer** — never flat seconds. Use `sleep $((RANDOM % range + min))` or similar. Looks human, avoids bot detection.

Step 1: Open Apollo
  - `osascript -e 'tell application "Google Chrome" to activate'`
  - `osascript -e 'tell application "Google Chrome" to set URL of active tab of front window to "https://app.apollo.io/#/home"'`
  - Wait 4-7s for load (randomized)

Step 2: Search for venue
  - `osascript -e 'tell application "System Events" to keystroke "k" using command down'` (opens search modal)
  - Wait 1-2s (randomized)
  - `echo -n "VENUE NAME" | pbcopy` then `osascript -e 'tell application "System Events" to keystroke "v" using command down'` (paste from clipboard — NOT keystrokes)
  - Wait 4-7s for results (randomized)

Step 3: Click company in search results
  - Search dropdown has sections: People, Companies, Email Templates
  - Find smallest `<div>` inside `[data-testid=omni-search-modal]` that contains venue name + industry (e.g. "Hospitality")
  - `.click()` on that div
  - Wait 2-5s for company page to load (randomized)

Step 4: Click People tab
  - Account detail tabs are `<label>` elements (NOT buttons, NOT sidebar nav)
  - `document.querySelectorAll("label")` → find text "People" → `.click()`
  - Don't confuse with sidebar nav "People" (goes to general search) or Company Insights tabs (Overview, News, Technologies — those ARE buttons)
  - People tab shows employee table with: Name, Title, Company, Access email, Access Mobile, Location, etc.
  - Pagination: "1 - 25 of N" at bottom

Step 5: Click Access email (loop)
  - Read all `[role=row]` elements on the page
  - Check SVG fill color: Green (`#3DCC85`) → click, Red (`#D93636`) → skip, Grey (`#474747`) → skip
  - Click "Access email", read revealed email, save to temp CSV (name, title, email, venue)
  - **Wait 5-6 minutes (randomized) between each click** — Apollo tracks bots
  - At ~5.5 min per email, 50 employees = ~4.5 hours. Overnight run.

Step 6: Next page, repeat until no more pages
  - Click next button (`aria-label` contains "next")
  - Check pagination text (e.g. "26 - 50 of 52")
  - Repeat step 5 on each page
  - Stop when no next button or last page reached

Step 7: Batch verify via ZeroBounce
  - Upload full temp CSV to ZeroBounce bulk verify
  - ZeroBounce API key in scraper.py: 7a47396026644791a236621ebe3d2584

Step 8: Push valid emails to Google Sheet
  - Only valid emails get pushed via Apps Script `?action=add_contact`
  - They appear in the app ready to send

**Apollo DOM Details:**
- Employee list uses `[role=row]` divs, NOT `<tr>` table rows
- Use heredoc `osascript << 'EOF'` for multi-line JS (avoids quote escaping hell)
- Employee names are in `<a>` tags inside each row

**Apollo Green Check Filter (SOLVED):**
- Green check: SVG fill `#3DCC85`, no clip-path → CLICK
- Red X: SVG fill `#D93636`, has clip-path → SKIP
- Grey question: SVG fill `#474747`, has clip-path → SKIP

**MASTER TODO (in order):**

**DONE:**
- [x] Prove Apollo automation (steps 1-5, pagination, SVG colors)
- [x] Prove LinkedIn employee discovery (20 people found for Inn at Perry Cabin)
- [x] Apollo script saved (`apollo_scrape.sh`) — full 8-step workflow
- [x] LinkedIn script saved (`linkedin_scrape.sh`) — with cross-ref + dedup
- [x] ZeroBounce verify + sheet push tested (mratliff, ewilhelm → valid → C-006, C-007)
- [x] Skip/star word filter in app (tap title words to filter contacts)
- [x] Auto distance calculation on add_venue/add_contact
- [x] Top Picks collapsed by default

**NEXT:**
1. Finish LinkedIn → Apollo enrichment (find emails for LinkedIn-only people)
2. Build "Add Past Gig" feature — feed in venues you've played
3. Google Places enrichment for past gigs (profile builder, "people also visit")
4. Live run-through — full pipeline on a real venue, user watching

**PIPELINE (per venue, in order):**
1. Website scrape — hit venue website + /contact page, grab emails + Instagram + Facebook links
2. Social media scrape — check Instagram/Facebook bios for additional emails
3. Apollo scrape — search employees, click Access email, verify, push to sheet
4. LinkedIn cleanup — find anyone missed, enrich via Apollo for emails
- Each step checks the sheet first, skips duplicates, only spends credits on new people

**RESEARCH NEEDED:**
- [ ] Rate limits deep research: Google Places API daily/monthly caps, Instagram scraping limits, Facebook scraping limits, LinkedIn scraping limits (connection requests, page views, searches), Apollo free tier limits (100 email reveals/month, 120 lead credits), ZeroBounce free tier (100 validations?), Gmail sending limits (500/day personal, 2000/day workspace)
- [ ] Google Places "find similar" — test with a past gig, see if "people also visit" returns useful similar venues

**LATER:**
5. Build full overnight automation script (loop through venue list, all 4 steps)
6. Build Rating Hub (past gig rating, winner profile, lead scoring)
7. Expand scraper beyond MD wineries (all 6 states, all categories)
8. Build manual email inbox ("Add Email" button, unverified queue, batch verify)
9. Expand + improve email templates (A/B test, personalize per venue type)
10. Pay for Apollo month → run hard → collect contacts → cancel
11. Start sending outreach

### TODO (saved from session 1)
1. ~~Angel background darkening fix~~ DONE
2. ~~State title text bigger + centered~~ DONE
3. ~~Category cards as picture cards~~ DONE
4. ~~Font: Cinzel + Great Vibes drop-caps~~ DONE

## Session 2 (Mar 12, 2026) — Make It Functional

### Current Status
- **Frontend (index.html)**: Built, dark angel-bg PWA, venue browser, top picks, Gmail/IG/FB outreach, Pokemon leveling
- **Backend (apps_script.gs)**: Full CRUD API written but **NOT DEPLOYED** — returns Access Denied
- **Scraper (scraper.py)**: MD wineries only, capped at MAX_VENUES=2 (test mode), ZeroBounce verification
- **Service worker**: v34
- **Git repo**: `github.com:atdi1029-byte/gig-outreach.git`
- **GitHub Pages**: NOT enabled yet
- **Google Sheet**: https://docs.google.com/spreadsheets/d/1ma7s1C8JZ99xcM3DHBp0ldFhB0J_iNRgDUOrLCagwjU/edit
- **ADB for mobile testing**: Galaxy S23 Ultra `-s R3CW506ZK7N` (same as AutoPilot)

### Phase 1: Make Functional
- [x] Deploy Apps Script as web app (Execute as: Me, Access: Anyone)
- [x] Verify Google Sheet has correct tabs (Venues, Contacts, Outreach Log, Config, Templates, Progress)
- [x] Add setupSheets() function to auto-create tabs + headers
- [x] Test API end-to-end (add venue, add contact, dashboard)
- [x] Enable GitHub Pages on gig-outreach repo
- [x] Test PWA on mobile

### Phase 2: Smart Scraper
- [ ] Make scraper run automatically — not just MD wineries
- [ ] Add Google Places API / Google Maps search for all categories
- [ ] Cover all 6 states: MD, VA, DC, WV, PA, DE
- [ ] Cover all 6 categories: wineries, museums, hotels, country clubs, events, restaurants
- [ ] Smart deduplication — never re-scrape venues already in the Sheet
- [ ] Auto-discover directory/association sites per category+state (e.g. virginiawine.org, visitmaryland.org)
- [ ] Fall back to Google search when no good directory exists
- [ ] ZeroBounce bulk verification via API
- [ ] Run scraper as background task, push results to Sheet automatically

### Phase 2b: Apollo Email Discovery — Two Approaches

**Approach A: Apollo MCP on Claude.ai**
- Claude.ai has Apollo.io connector (MCP integration) — 13 tools
- Key tools: `apollo_search_organizations`, `apollo_search_people`, `apollo_enrich_person`, `apollo_bulk_enrich_people`
- Connect Apollo account on Claude.ai → search for venues by category+location → find employees with event titles → reveal emails
- Pro: Fast, bulk, fully automated in a conversation
- Con: Uses Apollo enrichment credits (limited on free plan)
- Could output JSON/CSV → push to Google Sheet via Apps Script

**Approach B: Browser Automation (Control Chrome)**
- Use Playwright/Puppeteer to physically control Chrome like a human
- Script: open venue website → Apollo Chrome extension sidebar loads → click "View employees" → find event-related titles → click "Access email" → scrape the revealed email
- Also works for LinkedIn: search venue name → People tab → filter "Current:" employees → click person → Apollo sidebar → grab email
- Pro: Uses free Apollo Chrome extension — no credit cost
- Con: Slower, needs Chrome running, rate limit risk
- Could also use AppleScript to control Chrome on Mac
- Playwright can run headed (visible) so user can watch/intervene

**Decision (Mar 13 2026)**: Apollo MCP tested — free tier can't search employees at a company (paywalled $49-99/mo). Can only enrich individuals if you already have their name.
- **Browser automation is the path** — Chrome extension shows employees for free, just need to automate clicking
- Apollo paid plan ($49/mo) is worth it IF pipeline proves out — one gig pays for a year
- **TODO: Build Playwright/AppleScript automation to control Chrome + Apollo sidebar**
  - Open venue website → Apollo sidebar loads → click employee list → click "Access email" → save results
  - Same automation approach works for LinkedIn too
- MCP connection page: Claude.ai → Settings → Integrations → Apollo.io → Connected (free tier)

### Phase 3: Outreach Limits Research
- [ ] Gmail daily send limits (free vs workspace)
- [ ] Instagram DM limits (before getting flagged)
- [ ] Facebook Messenger limits
- [ ] ZeroBounce credit management
- [ ] Apollo enrichment credit limits (free tier)
- [ ] Best practices for cold outreach volume (avoid spam flags)

### Phase 4: Polish & Extras
- [ ] Enable Pokemon leveling section
- [ ] Ranking/scoring system (upscale score, zone priority)
- [ ] Search/filter in the app
- [ ] Manual venue add from the app
- [ ] Stats dashboard (emails sent, outreach by channel, by date)

### Future Features — Gig Success Tracking & Venue Recommendation Engine
- **"How'd it go?" prompt**: After each gig, rate it — tips earned, rebooked (yes/no), audience size, vibe rating
- **Tag winners as "great gig"**: Builds a profile of what works (category, area, price level, audience type)
- **Find similar venues**: Use Google Places API "people also visit" / "similar to" data
- **Geographic clustering**: If a winery in Annapolis went great, find other venues within 10mi (same wealthy clientele)
- **Attribute matching**: Winners share traits (upscale, hosts events, has event space). Score new venues by trait overlap
- **Upscale scoring formula**: Distance + venue type fit + verified email + zone priority + hosts live music
- **Google Places profile**: Capture price_level (1-4), star rating, place type for each venue, then search for matches

### Google Sheet Tabs & Columns
**Venues**: venue_id | name | category | website | city | county | state | address | facebook | instagram | upscale_score | zone_priority | status | source | scraped_date | notes
**Contacts**: contact_id | venue_id | name | title | email | source | verified | verified_date | email_sent | email_sent_date | ig_dm_sent | fb_msg_sent
**Outreach Log**: timestamp | venue_id | contact_id | channel | template_used
**Config**: key | value
**Templates**: category | subject | body
**Progress**: state | category | last_scraped | venues_found | status
