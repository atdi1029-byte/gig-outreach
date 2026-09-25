(function() {
    var MIDDOT = String.fromCharCode(183);
    var SPLIT_RE = new RegExp('[\\n' + MIDDOT + ']');
    // Lodging type lines in the expanded "View more hotels" list ("4-star hotel",
    // "Bed & breakfast", "Vacation rental"). Anything else stays '' so the classifier
    // decides from the name rather than every card being called a Hotel.
    var TYPE_RE = /\b(hotel|inn|resort|lodge|bed (?:&|and) breakfast|motel|guest ?house|hostel|vacation rental|cottage|apartment|condo)\b/i;
    var panels = document.querySelectorAll('.m6QErb');
    var scrollable = null;
    for (var p = 0; p < panels.length; p++) {
        if (panels[p].scrollHeight > panels[p].clientHeight + 50) {
            scrollable = panels[p];
            break;
        }
    }
    if (!scrollable) return '[]';
    scrollable.scrollTop = scrollable.scrollHeight;
    var cards = scrollable.querySelectorAll('[jsaction*="mouseover"]');
    var results = [];
    var seen = {};
    for (var c = 0; c < cards.length; c++) {
        var text = cards[c].innerText || cards[c].textContent || '';
        var headline = cards[c].querySelector('.fontHeadlineSmall, .NrDZNb, .qBF1Pd');
        if (!headline) continue;
        var name = headline.textContent.trim();
        if (!name || name.length < 3 || name.length > 60) continue;
        if (seen[name]) continue;
        seen[name] = true;
        var rating = '';
        var rm = text.match(/([0-9]\.[0-9])/);
        if (rm) rating = rm[1];
        var reviews = '';
        var revm = text.match(/\(([0-9,]+)\)/);
        if (revm) reviews = revm[1].replace(/,/g,'');
        var category = '';
        var lines = text.split(SPLIT_RE);
        for (var l = 0; l < lines.length; l++) {
            var ln = lines[l].trim();
            if (ln && ln !== name && ln.length < 40 && TYPE_RE.test(ln)) { category = ln; break; }
        }
        results.push(JSON.stringify({name: name, rating: rating, reviews: reviews, category: category}));
    }
    return '[' + results.join(',') + ']';
})()
