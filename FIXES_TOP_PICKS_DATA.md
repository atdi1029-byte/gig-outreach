# Top Picks + Venue Data Fixes

## What changed

### 1. Top Picks is now luxury-first
- Only considers verified, high-end venue types: fine/upscale restaurants, luxury hotels/resorts, country/private/yacht clubs, wine bars, and select wineries.
- Generic restaurants must have both a strong upscale score and fine-dining signals (French/Italian/Spanish/Argentinian, tasting menu, Michelin, steakhouse/chophouse, sommelier/wine pairing, etc.).
- Hotels must look genuinely luxury/boutique/five-star or have the highest quality score.
- Cafes, casual food, budget hotels, recreation/athletic clubs, retail, and other random businesses are hard-rejected.
- `needs_review` discoveries cannot appear in Top Picks.
- Restaurants are capped at 2. The list may intentionally show fewer than 10 rather than fill space with mediocre venues.
- Legacy rows such as a Country Club incorrectly stored as `restaurant` are inferred correctly in Top Picks from strong name signals.

### 2. Unknown businesses no longer default to `restaurant`
- Discovery classification is now conservative: unknown Google categories become `other` and remain out of the pipeline.
- Strong identity in a venue name (Country Club, Yacht Club, Wine Bar, luxury hotel brand, etc.) overrides a generic Google `Restaurant` label.

### 3. Website matching is much stricter
- Added `venue_quality.py` with shared URL matching rules.
- Discovery and pipeline Google fallbacks no longer take the first non-directory result.
- Directory/social/tourism/booking sites are rejected.
- Candidate domains/paths must plausibly match the venue's distinctive name/brand, with support for common luxury hotel parent domains and club acronyms.

### 4. Smart Picks / pipeline budget is now luxury-gated
- `needs_review` venues are excluded.
- Smart Picks and untouched-budget processing use the same high-end gate instead of processing generic restaurants and unrelated venue categories.

## Existing-data cleanup

`audit_venue_data.py` is included to audit rows already stored in the Google Sheet/API.

Read-only audit:

```bash
python3 audit_venue_data.py
```

High-confidence safe repairs only:

```bash
python3 audit_venue_data.py --apply-safe
```

`--apply-safe` fixes obvious restaurant→hotel/club/wine-bar misclassifications and clears known directory/social website URLs, moving those rows back to `needs_review`. Other suspicious domain mismatches are reported for review rather than deleted automatically.

## Validation performed
- `bash -n discover.sh`
- `bash -n pipeline.sh`
- Python compile checks for new helpers
- JavaScript syntax checks for `index.html` and `apps_script.gs`
- Functional tests covering fine dining, luxury hotels, country clubs, wine bars, random cafes, wrong domains, and quarantined rows
