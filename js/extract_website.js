(function() {
    var skip = ['google.com','youtube.com','facebook.com','instagram.com',
                'yelp.com','tripadvisor.com','wikipedia.org','twitter.com',
                'linkedin.com','pinterest.com','opentable.com','doordash.com',
                'grubhub.com','ubereats.com','mapquest.com','yellowpages.com',
                'bbb.org','indeed.com','glassdoor.com','apple.com','x.com',
                'tiktok.com','reddit.com','amazon.com'];
    var all = document.querySelectorAll('a[href]');
    for (var i = 0; i < all.length; i++) {
        var h = all[i].getAttribute('href');
        if (!h || !h.startsWith('http')) continue;
        var dominated = false;
        for (var s = 0; s < skip.length; s++) {
            if (h.indexOf(skip[s]) > -1) { dominated = true; break; }
        }
        if (!dominated) return h;
    }
    return '';
})()