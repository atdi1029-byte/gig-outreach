(function() {
    var headers = document.querySelectorAll('h2');
    var targetH2 = null;
    for (var h = 0; h < headers.length; h++) {
        if (headers[h].textContent.trim().toLowerCase().indexOf('people also search') > -1) {
            targetH2 = headers[h];
            break;
        }
    }
    if (!targetH2) return '[]';
    var section = targetH2.parentElement.parentElement;
    var nameEls = section.querySelectorAll('span.GgK1If');
    if (nameEls.length === 0) {
        var links = section.querySelectorAll('a[href*="/maps/place"]');
        var results = [];
        var seen = {};
        for (var i = 0; i < links.length; i++) {
            var spans = links[i].querySelectorAll('span');
            for (var s = 0; s < spans.length; s++) {
                var nm = spans[s].textContent.trim();
                if (nm && nm.length > 2 && nm.length < 60 && !seen[nm]) {
                    var card = links[i].closest('[class]');
                    var chunk = card ? card.textContent : '';
                    var rating = '';
                    var reviews = '';
                    var category = '';
                    var rm = chunk.match(/([0-9]\.[0-9])/);
                    if (rm) rating = rm[1];
                    var revm = chunk.match(/\(([0-9,]+)\)/);
                    if (revm) reviews = revm[1].replace(/,/g,'');
                    var catParts = chunk.split('\n');
                    for (var cp = 0; cp < catParts.length; cp++) {
                        var pt = catParts[cp].trim();
                        if (pt.length > 2 && pt.length < 30 && pt !== nm && !pt.match(/^[0-9]/) && !pt.match(/^\(/) && pt.indexOf('star') === -1) {
                            category = pt;
                            break;
                        }
                    }
                    seen[nm] = true;
                    results.push(JSON.stringify({name:nm, rating:rating, reviews:reviews, category:category}));
                    break;
                }
            }
        }
        if (results.length > 0) return '[' + results.join(',') + ']';
    }
    var names = [];
    for (var n = 0; n < nameEls.length; n++) {
        var nm2 = nameEls[n].textContent.trim();
        if (nm2 && nm2.length > 2) names.push(nm2);
    }
    if (names.length === 0) return '[]';
    var fullText = section.textContent;
    var results2 = [];
    for (var i2 = 0; i2 < names.length; i2++) {
        var start = fullText.indexOf(names[i2]);
        if (start === -1) continue;
        var after = start + names[i2].length;
        var end = (i2 < names.length - 1) ? fullText.indexOf(names[i2+1], after) : fullText.length;
        var chunk2 = fullText.substring(after, end);
        var rating2 = '';
        var reviews2 = '';
        var category2 = '';
        var rm2 = chunk2.match(/([0-9]\.[0-9])/);
        if (rm2) rating2 = rm2[1];
        var revm2 = chunk2.match(/\(([0-9,]+)\)/);
        if (revm2) reviews2 = revm2[1].replace(/,/g,'');
        var catMatch = chunk2.match(/\)[\s]*([A-Za-z][A-Za-z ]+)/);
        if (catMatch) category2 = catMatch[1].trim();
        results2.push(JSON.stringify({name:names[i2], rating:rating2, reviews:reviews2, category:category2}));
    }
    return '[' + results2.join(',') + ']';
})()