(function() {
    var stateRe = /\b(AL|AK|AZ|AR|CA|CO|CT|DE|FL|GA|HI|ID|IL|IN|IA|KS|KY|LA|ME|MD|MA|MI|MN|MS|MO|MT|NE|NV|NH|NJ|NM|NY|NC|ND|OH|OK|OR|PA|RI|SC|SD|TN|TX|UT|VT|VA|WA|WV|WI|WY|DC)\b/;

    // Find the scrollable results panel
    var panels = document.querySelectorAll('.m6QErb');
    var scrollable = null;
    for (var p = 0; p < panels.length; p++) {
        if (panels[p].scrollHeight > panels[p].clientHeight + 50) {
            scrollable = panels[p];
            break;
        }
    }
    // Fallback: try role=feed container
    if (!scrollable) {
        scrollable = document.querySelector('[role="feed"]');
    }
    if (!scrollable) return '[]';

    // Find all venue cards in the results
    var cards = scrollable.querySelectorAll('[jsaction*="mouseover"]');
    if (cards.length === 0) {
        // Fallback: try common card containers
        cards = scrollable.querySelectorAll('.Nv2PK, .lI9IFe');
    }

    var results = [];
    var seen = {};
    for (var c = 0; c < cards.length; c++) {
        // Get venue name
        var headline = cards[c].querySelector(
            '.fontHeadlineSmall, .NrDZNb, .qBF1Pd, .OSrXXb'
        );
        if (!headline) continue;
        var name = headline.textContent.trim();
        if (!name || name.length < 3 || name.length > 80 || seen[name]) continue;
        seen[name] = true;

        var text = cards[c].textContent;

        // Rating
        var rating = '';
        var rm = text.match(/([0-9]\.[0-9])/);
        if (rm) rating = rm[1];

        // Review count
        var reviews = '';
        var revm = text.match(/\(([0-9,]+)\)/);
        if (revm) reviews = revm[1].replace(/,/g, '');

        // Category: look for known type patterns in card text
        var category = '';
        var lines = text.split(/[\n·]/);
        for (var l = 0; l < lines.length; l++) {
            var ln = lines[l].trim();
            if (ln.length > 2 && ln.length < 45 && ln !== name &&
                !/^[0-9]/.test(ln) && !/^\(/.test(ln) &&
                ln.indexOf('star') === -1 && ln.indexOf('Closed') === -1 &&
                ln.indexOf('Open') === -1 && ln.indexOf('hours') === -1 &&
                ln.indexOf('ago') === -1 && ln !== rating) {
                category = ln;
                break;
            }
        }

        // Location: find line with state abbreviation
        var location = '';
        for (var l2 = 0; l2 < lines.length; l2++) {
            var ln2 = lines[l2].trim();
            if (stateRe.test(ln2) && ln2 !== name) {
                location = ln2;
                break;
            }
        }
        // Fallback: check full text for state
        if (!location) {
            var sm = text.match(
                /[\d]+[^,\n]*,\s*[A-Za-z\s]+,?\s*(AL|AK|AZ|AR|CA|CO|CT|DE|FL|GA|HI|ID|IL|IN|IA|KS|KY|LA|ME|MD|MA|MI|MN|MS|MO|MT|NE|NV|NH|NJ|NM|NY|NC|ND|OH|OK|OR|PA|RI|SC|SD|TN|TX|UT|VT|VA|WA|WV|WI|WY|DC)\b/
            );
            if (sm) location = sm[0].trim();
        }

        results.push({
            name: name,
            rating: rating,
            reviews: reviews,
            category: category,
            location: location
        });
    }
    return JSON.stringify(results);
})()