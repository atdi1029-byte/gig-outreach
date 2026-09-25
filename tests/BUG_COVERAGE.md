# Test Suites and Bug Coverage

Which past bugs each test catches, and what is still NOT covered. Updated
2026-09-25 (fix sprint): earlier versions of this file listed bugs as covered
that had no real test (double signoff, row shift, generic-email filtering,
cascade delete). Those claims are corrected below.

## How to run

Offline (free, no network, safe any time):

| Command | What it checks |
|---|---|
| `/usr/bin/python3 tests/gate_tests.py` | mark_step.sh + verify_run.sh against fixture runs (31 tests) |
| `/usr/bin/python3 tests/reverify_tests.py` | reverify.sh with a stub backend and stub guard (7 tests) |
| `/usr/bin/python3 tests/zerobounce_guard_tests.py` | the ZeroBounce cost guard (14 tests) |
| `/usr/bin/python3 tests/check_heredocs_tests.py` | the embedded-python syntax checker itself (3 tests) |
| `/usr/bin/python3 tests/check_heredocs.py` | every python heredoc / `python3 -c` block in the repo's *.sh |
| `bash tests/template_smoke_tests.sh` | every email/IG/FB template variant (node; ~1450 checks, deterministic) |
| `bash tests/site_discovery_tests.sh` | the website crawler (owned by the discovery work) |
| `./preflight.sh --no-chrome` | all of the static checks above that matter before a run, plus live health checks |

Against a live Apps Script deployment (writes REGTEST_* rows, then deletes them):

| Command | Notes |
|---|---|
| `GIG_OUTREACH_URL=<test /exec URL> bash tests/regression_tests.sh` | refuses the production URL unless `--allow-production` |
| `bash tests/deploy_and_test.sh` | interactive: backup, deploy, version check, regression + template tests |

## Run gate (gate_tests.py)

| Bug | Where | Test |
|---|---|---|
| A printed step header counted as "done" (Apollo crashed on 28/28 venues, gate said DONE) | SUP-1 / PROC-1 | `test_header_only_log_is_not_evidence`, `test_failed_step_without_manual_mark_is_missing` |
| Tracebacks inside a step were ignored | SUP-1 | `test_traceback_in_step_is_flagged` |
| Any digit / "none" accepted as evidence; Apollo counts accepted for LinkedIn; "0 contacts" accepted as contacts done | SUP-3 | `MarkStepTests.*`, `test_bad_ledger_note_is_missing` |
| Closed-venue skip could never pass the gate | SUP-10 / PROC-13 | `test_closed_venue_skip_passes_gate_but_needs_review` |
| Report mark accepted without the gate output in the report | SUP-11 | `test_clean_run_is_clean_after_embedding`, `test_stale_block_is_missing` |
| One batch per run, no size limit | SUP-12 | `test_batch_limit_and_append`, `test_plan_batches_all_appended_under_one_run` |
| Sheet contact check never ran | SUP-2 | `test_sheet_checks`, `test_p4_status_checks` |
| Curl-only scrapes / blocked crawls / missing Apollo counts not flagged | goal: coverage | `test_curl_only_is_a_coverage_gap`, `test_crawl_blocked_throttled_and_missing_kinds`, `test_missing_apollo_name_count_is_a_gap`, `test_social_search_blocked_is_a_gap` |
| Miss audit counted / "not run" never treated as zero | goal: misses | `test_misses_counted_and_rated`, `test_no_miss_audit_is_not_zero` |
| A batch that died looked finished; resume logs ignored | PROC-6 | `test_dead_batch_is_missing` |

## reverify.sh (reverify_tests.py)

| Bug | Where | Test |
|---|---|---|
| Wrong Apps Script action (update_contact_email) — paid results never saved, "✓" printed anyway | GS-3 / SUP-5 | `test_updates_via_update_contact_and_reads_back`, `test_backend_handler_takes_these_params` |
| Counters lost in a pipe subshell (always "Re-verified: 0") | SUP-5 | `test_updates_via_update_contact_and_reads_back` |
| .env's 500 cap overrode the 5-per-run cap; `--retry-unknown` re-paid cached unknowns | SUP-18 | `test_cap_is_not_raised_by_dotenv_and_no_retry_unknown` |
| A budget deferral only stopped one venue's loop | SUP-18 | `test_deferral_stops_the_whole_run` |
| Unverified (ZeroBounce out of credits) contacts re-checked cached-first, dry run shows spend | Sep 25 decision | `test_unverified_mode_cached_first_dry_run_and_removal` |

## ZeroBounce guard (zerobounce_guard_tests.py)

Covered: same email paid once; per-run and per-day caps; kill switch; timeout counts
against the budget; fail closed when the balance can't be read; reserve floor;
unknown-verdict TTL; vendor error bodies are not cached as "unknown" (SUP-9); the
curl fallback never repeats a request that may have been sent (SUP-8); a second
process waits for the first one's verdict instead of paying (SUP-19); `lookup`
is free; `budget` reports effective settings.

## Embedded python (check_heredocs_tests.py)

The Aug/Sep Apollo `IndentationError` lived inside a heredoc, where `bash -n`
can't see it. `test_indentation_error_in_heredoc_fails` reproduces that shape;
`test_docstring_inside_dash_c_fails` the `"""docstring"""` inside `python3 -c "..."`
case (pipeline.sh's old --smart-picks block had one).

## Regression suite (regression_tests.sh) — Apps Script backend

### 2. Add Venue
| Bug | Commit | Covered by |
|---|---|---|
| Venues disappearing | `912b37d` | read-back of every field after add_venue |
| Duplicate venues | — | same name + city + website must return the existing venue (a second venue is a FAIL and is cleaned up) |
| New venues must start as needs_review (P4) | — | status read-back (C5 backend) |

### 3. Add Contact
| Bug | Commit | Covered by |
|---|---|---|
| Duplicate contact_id | `d3ed927` | update_contact calls pass venue_id |
| Generic-email filtering (`fe06536`) | `fe06536` | NOT covered: no role-mailbox case in the suite |
| Junk / off-domain / masked-name contacts refused, email-less dedupe, verified default | C5 | group 3b (C5 backend only) |

### 4–9. Update venue / mark sent / skip / log outreach / upsert / LinkedIn pending
Covered as before (read-back after every write): contacted status, email_sent true/skipped,
IG/FB/contact-form flags, update_contact_email upsert (update vs create), linkedin_pending
blocking auto-contact.

### 10–11. Delete Contact / Delete Venue
| Bug | Covered by |
|---|---|
| Deleted contact still visible | venue_detail read-back |
| Cascade: deleting a venue must delete its contacts | the contact is gone afterwards (update on it must fail) |
| Row shift on delete (iterating forward) | NOT covered: needs several adjacent rows deleted in one call |

### 12–18. Dashboard, templates, stats, config, gigs, recommendations, monthly
Response shape only. The monthly-tasks save is skipped on production (it would overwrite
Alex's real tasks) and restored afterwards elsewhere. cleanup_generic is only checked as a
dry run on the C5 backend (the old backend really deletes).

## Template smoke tests (template_smoke_tests.sh)

| Bug | Commit | Covered by |
|---|---|---|
| Venue name in greeting | `d05814d` | greeting checks for every variant + venue-sounding / short names |
| Invisible category labels | `c698351` | every category has a label and subjects; every body refers to the venue generically |
| Double signoff in IG/FB | `9351920` | "Alexander Barnett" exactly once in every email, IG and FB variant |
| Links in the FB first message | — | every FB variant, every category |
| Missing YouTube link / phone in some variants | `0d1bc39` | checked in EVERY email variant (was any-of-5 random samples, which could never catch one bad variant and failed randomly ~40% of runs) |

## Not covered yet

- pipeline.sh end to end (needs Chrome, Apollo, ZeroBounce); the C3 `[STEP]` lines are
  covered only through verify_run fixtures
- postcheck.sh, discover.sh, build_batch.sh beyond their own test files
- cleanup_generic apply mode, calc_distances, update_taste
- concurrent writes (LockService) and service-worker cache invalidation
- JSONP callback wrapping
