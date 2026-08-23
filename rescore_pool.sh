#!/bin/bash
# =============================================================
# Re-score Pool — reclassify + taste score ALL untouched venues
#
# Usage:
#   ./rescore_pool.sh              — dry run (preview only)
#   ./rescore_pool.sh --apply      — update the sheet
#   ./rescore_pool.sh --limit 50   — preview first N
#
# Steps:
#   1. Reclassify all untouched venues (venue_classifier.py)
#   2. Calculate taste scores (taste_score.py)
#   3. Write taste_score as a NEW field (not overwriting upscale_score)
#
# Safe to run multiple times — idempotent.
# =============================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/.env" 2>/dev/null || true
APPS_SCRIPT_URL="https://script.google.com/macros/s/AKfycbxlZsGnG_pZG27FJjI8A_CWI5PZ1qs5tlyt2FbqlzfTm5sEvdQjStRDoobOkMOWzyBT/exec"

APPLY=0
LIMIT=0
LIMIT_NEXT=0
for arg in "$@"; do
    case "$arg" in
        --apply) APPLY=1 ;;
        --limit) LIMIT_NEXT=1 ;;
        *)
            if [ "$LIMIT_NEXT" = "1" ]; then
                LIMIT=$arg
                LIMIT_NEXT=0
            fi
            ;;
    esac
done

if [ "$APPLY" = "0" ]; then
    echo "[DRY RUN] Preview only. Use --apply to update the sheet."
fi

echo "Fetching all venues..."
curl -sL "${APPS_SCRIPT_URL}?action=venues" -o /tmp/rescore_venues.json

cd "$SCRIPT_DIR"

python3 << 'PYEOF'
import json, sys, os

sys.path.insert(0, os.environ.get('SCRIPT_DIR', '.'))
sys.path.insert(0, '.')

APPLY = int(os.environ.get('APPLY', '0'))
LIMIT = int(os.environ.get('LIMIT', '0'))

from venue_classifier import classify
from taste_score import score as taste_score

with open('/tmp/rescore_venues.json') as f:
    venues = json.load(f).get('venues', [])

untouched = [v for v in venues if v.get('status') == 'untouched']
print(f"Total venues: {len(venues)}")
print(f"Untouched: {len(untouched)}")

# Classify + score all
results = []
for v in untouched:
    c = classify(v.get('name',''), v.get('category',''),
                 v.get('notes',''))
    ts, reasons = taste_score(v, c)
    results.append({
        'venue_id': v['venue_id'],
        'name': v.get('name', ''),
        'raw_category': v.get('category', ''),
        'classified_category': c['primary_category'],
        'category_changed': v.get('category','') != c['primary_category'],
        'tags': c['venue_tags'],
        'confidence': c['classification_confidence'],
        'taste_score': ts,
        'reasons': reasons,
        'city': v.get('city', ''),
        'state': v.get('state', ''),
    })

# Sort by taste score descending
results.sort(key=lambda x: -x['taste_score'])

# Stats
print(f"\nScore distribution:")
for lo, hi in [(60,100),(50,60),(40,50),(30,40),(25,30),(15,25),(0,15)]:
    n = sum(1 for r in results if lo <= r['taste_score'] < hi)
    print(f"  {lo:3d}-{hi:3d}: {n:4d} venues")

# Category reclassification stats
changed = [r for r in results if r['category_changed']]
print(f"\nCategory reclassifications: {len(changed)} / {len(results)}")
from collections import Counter
reclass = Counter()
for r in changed:
    reclass[f"{r['raw_category']} -> {r['classified_category']}"] += 1
for change, count in reclass.most_common(20):
    print(f"  {change}: {count}")

# Show top N
show_n = LIMIT if LIMIT > 0 else 30
print(f"\n=== TOP {show_n} by taste score ===")
for r in results[:show_n]:
    reclass_mark = " *RECLASS*" if r['category_changed'] else ""
    tag_str = ', '.join(r['tags'][:4])
    print(f"  {r['taste_score']:5.0f}  {r['venue_id']:20s}  "
          f"{r['name']:40s}  [{r['classified_category']}]  "
          f"{r['city']} {r['state']}{reclass_mark}")
    for reason in r['reasons']:
        print(f"         {reason}")

# Show bottom 10
print(f"\n=== BOTTOM 10 ===")
for r in results[-10:]:
    reclass_mark = " *RECLASS*" if r['category_changed'] else ""
    print(f"  {r['taste_score']:5.0f}  {r['venue_id']:20s}  "
          f"{r['name']:40s}  [{r['classified_category']}]  "
          f"{r['city']} {r['state']}{reclass_mark}")

# Show reclassified examples
print(f"\n=== RECLASSIFICATION EXAMPLES (first 15) ===")
for r in changed[:15]:
    print(f"  {r['name']:40s}  "
          f"{r['raw_category']:15s} -> {r['classified_category']:15s}  "
          f"(conf={r['confidence']:.2f})")

# Write update file
if APPLY or True:  # always write for bash loop
    with open('/tmp/rescore_updates.tsv', 'w') as f:
        for r in results:
            reasons_str = ' | '.join(r['reasons'])
            f.write(f"{r['venue_id']}\t{r['taste_score']}\t"
                    f"{r['classified_category']}\t{reasons_str}\n")
    print(f"\nWrote {len(results)} updates to /tmp/rescore_updates.tsv")

if not APPLY:
    print(f"\n[DRY RUN] Would update {len(results)} venues. "
          f"Run with --apply to execute.")
PYEOF

if [ "$APPLY" = "1" ]; then
    total=$(wc -l < /tmp/rescore_updates.tsv)
    echo ""
    echo "Applying $total score updates to sheet..."
    echo "(Writing taste_score + classified category)"
    count=0
    errors=0
    while IFS=$'\t' read -r vid new_score new_cat reasons; do
        # Write taste_score as new field
        result=$(curl -sL "${APPS_SCRIPT_URL}?action=update_venue&venue_id=${vid}&field=taste_score&value=${new_score}" 2>/dev/null)
        status=$(echo "$result" | python3 -c "import json,sys; print(json.load(sys.stdin).get('status',''))" 2>/dev/null)

        # Update category if reclassified
        cur_cat=$(curl -sL "${APPS_SCRIPT_URL}?action=venue_detail&venue_id=${vid}" 2>/dev/null | python3 -c "import json,sys; print(json.load(sys.stdin).get('venue',{}).get('category',''))" 2>/dev/null)
        if [ "$cur_cat" != "$new_cat" ] && [ -n "$new_cat" ]; then
            curl -sL "${APPS_SCRIPT_URL}?action=update_venue&venue_id=${vid}&field=category&value=${new_cat}" > /dev/null 2>&1
        fi

        count=$((count + 1))
        if [ "$status" != "ok" ]; then
            echo "  FAIL: $vid ($new_score) — $status"
            errors=$((errors + 1))
        fi
        # Progress every 100
        if [ $((count % 100)) -eq 0 ]; then
            echo "  ... $count / $total updated"
        fi
    done < /tmp/rescore_updates.tsv
    echo ""
    echo "=== RESCORE COMPLETE ==="
    echo "Updated: $((count - errors)) / $total"
    [ "$errors" -gt 0 ] && echo "Errors: $errors"
fi
