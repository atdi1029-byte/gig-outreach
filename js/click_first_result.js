(function() {
    var results = document.querySelectorAll('a[href*="/maps/place"]');
    if (results.length === 0) return 'already_on_venue';
    var h2s = document.querySelectorAll('h2');
    for (var h = 0; h < h2s.length; h++) {
        if (h2s[h].textContent.trim().toLowerCase().indexOf('people also search') > -1) {
            return 'already_on_venue';
        }
    }
    var first = document.querySelector('.Nv2PK a, a.hfpxzc');
    if (first) {
        first.click();
        return 'clicked';
    }
    if (results.length > 0) {
        results[0].click();
        return 'clicked';
    }
    return 'no_results';
})()