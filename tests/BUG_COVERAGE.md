# Regression Test — Bug Coverage Map

Which past bugs each test group catches, mapped to git commits.

## Test Group → Bug Map

### 2. Add Venue
| Bug | Commit | What happened |
|-----|--------|--------------|
| Venues disappearing | `912b37d` | Venues vanished when LinkedIn outreach was still pending — the auto-contact logic was deleting/hiding them |
| Duplicate venue IDs | — | Duplicate detection by name+state prevents scraper from adding the same venue twice |

### 3. Add Contact
| Bug | Commit | What happened |
|-----|--------|--------------|
| Duplicate contact_id | `d3ed927` | Two contacts at different venues got the same C-XXX ID. Fixed by passing venue_id to disambiguate update_contact calls |
| Generic emails not filtered | `fe06536` | Scraper was filtering out `events@`, `info@`, `contact@` as junk — these are actually valid venue contacts |

### 4. Update Venue
| Bug | Commit | What happened |
|-----|--------|--------------|
| contacted_date not stamped | `912b37d` | Marking a venue as "contacted" didn't record when it happened |
| Status not updating | `d90ee0c` | Contact form persistence + Mark Done confirmation were broken |

### 5. Mark Email Sent
| Bug | Commit | What happened |
|-----|--------|--------------|
| Skip buttons silently failing | `bd32f24` | Skip/sent buttons appeared to work but didn't actually hit the API — no response check |
| Auto-contact premature | `912b37d` | Venue auto-upgraded to "contacted" before all contacts were emailed |

### 6. Skip Contact
| Bug | Commit | What happened |
|-----|--------|--------------|
| Skip buttons silently failing | `bd32f24` | The `value=skipped` wasn't being saved — API returned ok but field stayed false |

### 7. Log Outreach (IG/FB/Email)
| Bug | Commit | What happened |
|-----|--------|--------------|
| IG/FB sent status not persisting | `511f1e2` | For venues without any contacts, the IG/FB sent flags weren't being tracked — outreach log wasn't checked |
| Contact form persistence | `d90ee0c` | Contact form sent status wasn't being tracked in the outreach log |

### 8. Update Contact Email (Upsert)
| Bug | Commit | What happened |
|-----|--------|--------------|
| Contact duplication on enrich | — | Apollo enrichment was creating new contacts instead of updating existing LinkedIn-discovered ones |

### 9. LinkedIn Pending Blocks Auto-Contact
| Bug | Commit | What happened |
|-----|--------|--------------|
| Venues disappearing when LinkedIn pending | `912b37d` | If `linkedin_pending=true`, all emails sent → venue auto-contacted → disappeared from action queue, even though LinkedIn outreach wasn't done |

### 10–11. Delete Contact / Delete Venue
| Bug | Commit | What happened |
|-----|--------|--------------|
| Row shift on delete | — | Deleting contacts in forward order caused row indices to shift, skipping rows. Fixed by iterating backwards |
| Cascade delete | — | Deleting a venue must also delete all its contacts to avoid orphans |

### Template Smoke Tests

#### Greeting Safety
| Bug | Commit | What happened |
|-----|--------|--------------|
| Venue name in greeting | `d05814d` | `generateEmail` was using the contact's full name as greeting — but sometimes the "contact name" was actually the venue name (e.g. "Le Bistro"). Fixed with skipWords filter |

#### Category Labels
| Bug | Commit | What happened |
|-----|--------|--------------|
| Invisible category labels | `c698351` | 15 venue categories had no visible label in templates — the label was empty or undefined |

#### Double Signoff
| Bug | Commit | What happened |
|-----|--------|--------------|
| Double signoff in IG/FB | `9351920` | IG and FB templates had "Alexander Barnett" twice — once in body, once appended |

#### FB No-Link Rule
| Bug | Commit | What happened |
|-----|--------|--------------|
| Links in FB first message | — | Facebook flags accounts that send links in first messages to strangers. FB templates must not contain URLs |

#### Email Content
| Bug | Commit | What happened |
|-----|--------|--------------|
| Missing YouTube link | `0d1bc39` | "Hear my playing" section was missing the actual link in some template variants |
| Missing contact info | — | Some variants dropped the phone number line |

## Tests NOT Yet Covered (Future Work)

- `cleanup_generic` — Bulk deletion of generic emails (noreply@, info@, etc.)
- `calc_distances` — Google Maps distance calculation
- `update_taste` — Taste preference updates
- Rate limiting / concurrent write safety
- Service worker cache invalidation
- JSONP callback wrapping
