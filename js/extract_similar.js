(function() {
    var headers = document.querySelectorAll('h2');
    var targetH2 = null;
    for (var h = 0; h < headers.length; h++) {
        var t = headers[h].textContent.trim().toLowerCase();
        if (t.indexOf('similar') > -1 && (t.indexOf('hotel') > -1 || t.indexOf('nearby') > -1)) {
            targetH2 = headers[h];
            break;
        }
    }
    if (!targetH2) return '[]';
    var section = targetH2.parentElement.parentElement;
    var nameEls = section.querySelectorAll('span.GgK1If');
    var names = [];
    for (var n = 0; n < nameEls.length; n++) {
        var nm = nameEls[n].textContent.trim();
        if (nm && nm.length > 2) names.push(nm);
    }
    if (nameEls.length === 0) {
        var links = section.querySelectorAll('a[href*="/maps/place"]');
        var seen = {};
        for (var i = 0; i < links.length; i++) {
            var spans = links[i].querySelectorAll('span');
            for (var s = 0; s < spans.length; s++) {
                var nm2 = spans[s].textContent.trim();
                if (nm2 && nm2.length > 2 && nm2.length < 60 && !seen[nm2]) {
                    seen[nm2] = true;
                    names.push(nm2);
                    break;
                }
            }
        }
    }
    if (names.length === 0) return '[]';
    var fullText = section.textContent;
    var results = [];
    for (var i2 = 0; i2 < names.length; i2++) {
        var start = fullText.indexOf(names[i2]);
        if (start === -1) continue;
        var after = start + names[i2].length;
        var end = (i2 < names.length - 1) ? fullText.indexOf(names[i2+1], after) : fullText.length;
        var chunk = fullText.substring(after, end);
        var rating = '';
        var reviews = '';
        var category = 'Hotel';
        var rm = chunk.match(/([0-9]\.[0-9])/);
        if (rm) rating = rm[1];
        var revm = chunk.match(/\(([0-9,]+)\)/);
        if (revm) reviews = revm[1].replace(/,/g,'');
        results.push(JSON.stringify({name:names[i2], rating:rating, reviews:reviews, category:category}));
    }
    return '[' + results.join(',') + ']';
})()