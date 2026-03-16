(function() {
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
        var text = cards[c].textContent;
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
        results.push(JSON.stringify({name: name, rating: rating, reviews: reviews, category: 'Hotel'}));
    }
    return '[' + results.join(',') + ']';
})()