(function() {
    // Keep this file pure ASCII. AppleScript's `read POSIX file` decodes as MacRoman,
    // which turned a literal middle dot into two junk characters, so the separators
    // are built from char codes instead.
    var MIDDOT = String.fromCharCode(183);   // Maps card separator
    var DOTOP = String.fromCharCode(8901);   // "Open <dot> Closes 10 PM"
    var ENDASH = String.fromCharCode(8211);  // "$20-30" price ranges
    var SPLIT_RE = new RegExp('[\\n' + MIDDOT + DOTOP + ']');
    var STATES = 'AL|AK|AZ|AR|CA|CO|CT|DE|FL|GA|HI|ID|IL|IN|IA|KS|KY|LA|ME|MD|MA|MI|MN|MS|MO|MT|NE|NV|NH|NJ|NM|NY|NC|ND|OH|OK|OR|PA|RI|SC|SD|TN|TX|UT|VT|VA|WA|WV|WI|WY|DC';
    // A state only where an address puts one: ", ST" or "ST 12345". "5th St NE" is a
    // DC quadrant, not Nebraska.
    var LOC_RE = new RegExp(',\\s*(' + STATES + ')\\b|\\b(' + STATES + ')\\s+\\d{5}\\b');
    var STREET_RE = /^\d+[A-Za-z]?(?:-\d+)?\s+\S+/;
    var PRICE_RE = new RegExp('(?:^|\\s|' + MIDDOT + ')(\\${1,4})(?=\\s|' + MIDDOT + '|$)');
    var RANGE_RE = new RegExp('\\$(\\d+)\\s*[-' + ENDASH + ']\\s*\\$?(\\d+)|\\$(\\d+)\\+');

    function priceTier(text) {
        var pm = text.match(PRICE_RE);
        if (pm) return pm[1];
        var rm = text.match(RANGE_RE);
        if (!rm) return '';
        var low = parseInt(rm[1] || rm[3], 10);
        if (rm[3]) return '$$$$';          // "$100+"
        if (low >= 50) return '$$$$';
        if (low >= 30) return '$$$';
        if (low >= 20) return '$$';
        return '$';
    }

    function placeInfo(card) {
        var a = card.querySelector('a[href*="/maps/place"]');
        if (!a && card.closest) a = card.closest('a[href*="/maps/place"]');
        if (!a) return {url: '', lat: '', lng: ''};
        var href = a.href || '';
        var m = href.match(/!3d(-?\d+\.\d+)!4d(-?\d+\.\d+)/);
        return {url: href.split('?')[0], lat: m ? m[1] : '', lng: m ? m[2] : ''};
    }

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
    if (!scrollable) {
        // A loaded page with genuinely nothing to list (a single-place page or
        // "Google Maps can't find ...") is an empty result. Anything else means the
        // page or its DOM did not load; the caller must not mark the query done.
        var body = document.body ? (document.body.innerText || '') : '';
        if (document.querySelector('h1') || /can.t find|no results/i.test(body)) return '[]';
        return 'NO_PANEL';
    }

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

        // innerText keeps the line breaks between the card's rows; textContent ran
        // name, rating, category and address together.
        var text = cards[c].innerText || cards[c].textContent || '';

        // Rating
        var rating = '';
        var rm = text.match(/([0-9]\.[0-9])/);
        if (rm) rating = rm[1];

        // Review count
        var reviews = '';
        var revm = text.match(/\(([0-9,]+)\)/);
        if (revm) reviews = revm[1].replace(/,/g, '');

        // Price level is a luxury signal and must NOT be mistaken for category.
        var price = priceTier(text);

        var lines = text.split(SPLIT_RE);

        // Category: first short line that isn't the name, rating, price, hours or address
        var category = '';
        for (var l = 0; l < lines.length; l++) {
            var ln = lines[l].trim();
            if (ln.length > 2 && ln.length < 45 && ln !== name &&
                !/^[0-9]/.test(ln) && !/^\(/.test(ln) && !/^\$/.test(ln) &&
                ln.indexOf('star') === -1 && ln.indexOf('Closed') === -1 &&
                ln.indexOf('Open') === -1 && ln.indexOf('Closes') === -1 &&
                ln.indexOf('hours') === -1 && ln.indexOf('ago') === -1 &&
                ln !== rating && !LOC_RE.test(ln)) {
                category = ln;
                break;
            }
        }

        // Location: a line with "City, ST" / "ST 12345"; address: the street line
        var location = '';
        var address = '';
        for (var l2 = 0; l2 < lines.length; l2++) {
            var ln2 = lines[l2].trim();
            if (!ln2 || ln2 === name || ln2.length > 120) continue;
            if (!location && LOC_RE.test(ln2)) location = ln2;
            if (!address && STREET_RE.test(ln2) && ln2.length > 6 && ln2.indexOf('(') === -1) address = ln2;
        }
        // Fallback: a full "123 Street, City, ST" address anywhere in the card text
        if (!location) {
            var sm = text.match(new RegExp('\\d+[^,\\n]*,\\s*[A-Za-z .]+,?\\s*(' + STATES + ')\\b(?:\\s+\\d{5})?'));
            if (sm && LOC_RE.test(sm[0])) location = sm[0].trim();
        }

        var place = placeInfo(cards[c]);
        results.push({
            name: name,
            rating: rating,
            reviews: reviews,
            price: price,
            category: category,
            location: location,
            address: address,
            place_url: place.url,
            lat: place.lat,
            lng: place.lng
        });
    }
    return JSON.stringify(results);
})()
