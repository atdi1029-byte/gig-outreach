# ZeroBounce Cost Guard

This patch makes ZeroBounce spending fail-safe instead of open-ended.

## Live settings (Sep 25 2026)

Alex's `.env` sets `ZB_ENABLED=1`, `ZB_MAX_PER_RUN=500`, `ZB_MAX_PER_DAY=9999`,
`ZB_MIN_BALANCE=100`, `ZB_FAIL_CLOSED=1`, with `ZB_RUN_ID` = the run's RUN_ID so the
per-run cap covers all batches of a run. `./preflight.sh` prints the effective values
and headroom. Role inboxes (info@, events@...) are never sent to ZeroBounce.

When the guard can't verify (budget, reserve, no credits, outage), the address is
**saved as `verified=unverified`** (Alex's decision, Sep 25 2026) and listed as
"needs ZB check" in the report. After topping up credits:
`./reverify.sh --unverified --dry-run` (shows the cost), then
`./reverify.sh --unverified --limit N`. Cached verdicts are never paid for twice.

## Code defaults (used only when .env doesn't set them)

- **5 paid validation attempts per run** (`ZB_MAX_PER_RUN=5`)
- **10 paid validation attempts total per UTC day** across all project copies (`ZB_MAX_PER_DAY=10`)
- **500-credit reserve floor** (`ZB_MIN_BALANCE=500`)
- **Persistent cache** at `~/.outreach/zerobounce_guard.sqlite3`
- **Fail closed** if the credit balance cannot be checked
- **Paid verification is OFF by default.** Set `ZB_ENABLED=1` only when you intentionally want to spend credits; `ZB_ENABLED=0` is the emergency kill switch.

The shared database is intentionally outside the project directory. If two copies of the outreach app run at the same time, they share the same daily limit and email cache.

Every call to the paid `/validate` endpoint is counted as a budget attempt *before* the request is made. This means a timeout or malformed response cannot cause unlimited retries beyond the configured cap.

## Suggested `.env` settings

```bash
ZB_ENABLED=0
ZB_MAX_PER_RUN=5
ZB_MAX_PER_DAY=10
ZB_MIN_BALANCE=500
ZB_FAIL_CLOSED=1
```

For a complete ZeroBounce freeze while still allowing website/social discovery:

```bash
ZB_ENABLED=0
```

or equivalently set `ZB_MAX_PER_RUN=0`.

## What happens after the cap is reached?

The crawler continues discovering emails and records them as deferred candidates. It does **not** spend another ZeroBounce credit. A future run can verify a small number of those candidates within the next budget.

## Cache behavior

A previously verified address is served from the local cache and costs zero credits. Valid/invalid/do-not-mail/etc. results are cached for 180 days by default; `unknown` is cached for 30 days. Those values can be changed with `ZB_CACHE_DAYS` and `ZB_UNKNOWN_CACHE_DAYS`.
