(function() {
    var result = {category: '', price: '', attributes: []};
    var seen = {};

    // Skip these — navigation items, not venue attributes
    var skipWords = [
        'review', 'direction', 'photo', 'send to', 'share',
        'save', 'add a', 'write', 'claim', 'overview', 'about',
        'nearby restaurants', 'nearby hotels', 'hotels', 'things to do',
        'bars', 'coffee', 'takeout', 'groceries', 'attractions',
        'more places', 'explore', 'plan', 'suggest an edit',
        'own this business', 'questions', 'updates', 'see more',
        'show less', 'menu', 'order online', 'order now',
        'see photos', 'all reviews', 'sort', 'newest',
        'open now', 'closed', 'hours might differ'
    ];

    function isSkip(txt) {
        for (var i = 0; i < skipWords.length; i++) {
            if (txt === skipWords[i] || txt.indexOf(skipWords[i]) === 0) return true;
        }
        if (/^\d/.test(txt)) return true;
        if (/^[a-z]\)/.test(txt)) return true;
        return false;
    }

    function addAttr(txt) {
        txt = txt.trim().toLowerCase();
        if (!txt || txt.length < 3 || txt.length > 40) return;
        if (seen[txt] || isSkip(txt)) return;
        seen[txt] = true;
        result.attributes.push(txt);
    }

    // Category: look for the type label under venue name
    var catEl = document.querySelector('.DkEaL');
    if (!catEl) {
        var btns = document.querySelectorAll('button[jsaction*="category"]');
        if (btns.length > 0) catEl = btns[0];
    }
    if (catEl) result.category = catEl.textContent.trim();

    // Price level
    var allSpans = document.querySelectorAll('span, [aria-label*="Price"]');
    for (var i = 0; i < allSpans.length; i++) {
        var t = allSpans[i].textContent.trim();
        if (/^\${1,4}$/.test(t)) {
            result.price = t;
            break;
        }
        var al = allSpans[i].getAttribute('aria-label') || '';
        if (al.indexOf('Price') > -1) {
            var pm = al.match(/(\${1,4})/);
            if (pm) { result.price = pm[1]; break; }
        }
    }

    // Strategy 1: Find sections by header text, extract LEAF spans only
    var headers = document.querySelectorAll('h2, h3, [role="heading"]');
    var sectionNames = [
        'highlight', 'popular', 'amenit', 'atmospher',
        'service option', 'planning', 'accessibility',
        'dining option', 'offering', 'payment'
    ];
    for (var h = 0; h < headers.length; h++) {
        var hText = headers[h].textContent.trim().toLowerCase();
        var isSection = false;
        for (var sn = 0; sn < sectionNames.length; sn++) {
            if (hText.indexOf(sectionNames[sn]) > -1) { isSection = true; break; }
        }
        if (!isSection) continue;

        // Walk the parent container and find leaf text nodes
        var container = headers[h].closest('[class]');
        if (!container) container = headers[h].parentElement;
        if (!container) continue;

        // Get all spans that have NO child spans (leaf nodes)
        var allInner = container.querySelectorAll('span');
        for (var si = 0; si < allInner.length; si++) {
            var childSpans = allInner[si].querySelectorAll('span');
            if (childSpans.length > 0) continue; // not a leaf
            var leafTxt = allInner[si].textContent.trim();
            if (leafTxt && leafTxt !== hText) addAttr(leafTxt);
        }

        // Also check for aria-label attributes (icon-based attributes)
        var labeled = container.querySelectorAll('[aria-label]');
        for (var li = 0; li < labeled.length; li++) {
            var label = labeled[li].getAttribute('aria-label');
            if (label) addAttr(label);
        }
    }

    // Strategy 2: Look for icon-row attributes (dine-in, takeout, etc.)
    var goodAttrs = [
        'dine-in', 'takeout', 'delivery', 'outdoor seating',
        'rooftop', 'fireplace', 'romantic', 'live music',
        'live entertainment', 'fine dining', 'casual dining',
        'cozy', 'upscale', 'elegant', 'trendy', 'wine',
        'cocktail', 'full bar', 'beer', 'patio', 'terrace',
        'garden', 'historic', 'waterfront', 'scenic', 'intimate',
        'private dining', 'private event', 'banquet', 'catering',
        'brunch', 'lunch', 'dinner', 'breakfast', 'late night',
        'valet', 'reservation', 'accepted', 'required',
        'free parking', 'street parking', 'parking lot',
        'good for groups', 'good for kids', 'dog-friendly',
        'wi-fi', 'comfort food', 'farm-to-table', 'organic',
        'vegetarian', 'gluten-free', 'prix fixe',
        'tasting menu', 'wine list', 'sommelier',
        'craft cocktails', 'happy hour', 'sunday brunch',
        'views', 'courtyard', 'lounge'
    ];
    var infoEls = document.querySelectorAll(
        '[data-item-id] .fontBodyMedium, .LTs0Rc, .iP2t7d, .wmQCje'
    );
    for (var r = 0; r < infoEls.length; r++) {
        var rowText = infoEls[r].textContent.trim().toLowerCase();
        if (!rowText || rowText.length < 3 || rowText.length > 40) continue;
        for (var ga = 0; ga < goodAttrs.length; ga++) {
            if (rowText.indexOf(goodAttrs[ga]) > -1) {
                addAttr(rowText);
                break;
            }
        }
    }

    // Strategy 3: aria-label scanning (Google Maps often uses these)
    var ariaEls = document.querySelectorAll('[aria-label]');
    for (var ai = 0; ai < ariaEls.length; ai++) {
        var ariaText = ariaEls[ai].getAttribute('aria-label').toLowerCase();
        for (var ga2 = 0; ga2 < goodAttrs.length; ga2++) {
            if (ariaText.indexOf(goodAttrs[ga2]) > -1 && ariaText.length < 60) {
                addAttr(ariaText);
                break;
            }
        }
    }

    return JSON.stringify(result);
})()