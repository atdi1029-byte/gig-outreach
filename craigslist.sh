#!/bin/bash
# Quick Craigslist job search — MD, VA, DC
# Opens all searches in Chrome tabs at once

REGIONS=("washingtondc" "baltimore")
KEYWORDS=("guitar" "church" "portuguese")

for region in "${REGIONS[@]}"; do
  for keyword in "${KEYWORDS[@]}"; do
    open "https://${region}.craigslist.org/search/jjj?query=${keyword}"
  done
done

echo "Opened ${#REGIONS[@]}x${#KEYWORDS[@]} = $(( ${#REGIONS[@]} * ${#KEYWORDS[@]} )) Craigslist searches"
