# Night website research (unattended)

`night_run.sh` starts you at about 1:00 with `LIST` (venues on the sheet that have no
website of their own) and `OUT` (the file you write). Alex is asleep. Nobody will answer
a question, so never ask one: decide, do it, write it down.

Your job: find each venue's own official website with WebSearch and WebFetch, and write
the URLs to `OUT`. You only research. `backfill_websites.sh --candidates OUT --apply`
then checks every URL with the usual rules (the domain must be the venue's own and the
page must name its city) and saves only those that pass.

Why you and not Chrome (Alex, Oct 1 2026: "you run discovery here in terminal and then the
rest in chrome"): the old lookup searched Google in Chrome, about 20 searches in 5 minutes,
and Google's "unusual traffic" CAPTCHA then blocked the night's pipeline too, which ended
the Sep 30 and Oct 1 nights early. Chrome is now kept for the pipeline alone.

## Hard rules
- WebSearch and WebFetch only. Never use Chrome: no `osascript`, no Claude-in-Chrome
  tools, no `open`, no `pipeline.sh`, `discover.sh`, `postcheck.sh`,
  `backfill_websites.sh` or `sweep.sh`, and never start any browser. A pipeline run is
  using Chrome while you work.
- Never write to the sheet, never edit code or any other file than `OUT`, never commit
  or push.
- `python3` on PATH is broken: use `/usr/bin/python3` if you need it.
- Budget: about 30 minutes; the session is killed at 45. Write `OUT` after every few
  venues, so a kill keeps what you found.

## How
`LIST` is `{"venues": [{venue_id, name, city, state, category, status, website}]}`. A
`website` that is set is a brand homepage or a listing page (marriott.com, a tourism
page); find the venue's own page instead.

For up to 8 venues work alone; for more, split them over general-purpose subagents
(4-5 venues each, up to 5 at a time) and give each these instructions:
- WebSearch `"<name>" <city> <state>` and `"<name>" <city> official site`.
- WebFetch the likely site and confirm it is this venue in this city: the name and the
  address or city on the page. A same-named business elsewhere is not it.
- The venue's own domain is best. A restaurant, bar or spa inside a hotel: its own domain
  if it has one, else its page on the hotel's site. A hotel of a brand: its property page
  (marriott.com/hotels/...), never the brand homepage. A church, club or school: its own
  site.
- Never a listing or social page: Yelp, TripAdvisor, OpenTable, Resy, Facebook,
  Instagram, LinkedIn, Google, Wikipedia, The Knot, WeddingWire, Zola, Eventbrite,
  Nextdoor, news or tourism sites, directories.
- Permanently closed: no URL; say so in the note.
- Return per venue: up to 3 URLs, best first, and one short line of evidence.

## OUT
```json
{"generated": "2026-10-02T01:20:00",
 "venues": [
  {"venue_id": "DC-REST-2792", "urls": ["https://www.certodc.com"],
   "note": "own site; footer shows the Washington, DC address"},
  {"venue_id": "MD-EVEN-3003", "urls": [], "note": "no site found; only Yelp and The Knot"}
 ]}
```
Every venue in `LIST` gets an entry (`urls: []` when nothing was found). Write valid JSON
(check it with `/usr/bin/python3 -m json.tool OUT`). Your last message: one line, how many
venues got a URL.
