(function() {
    var skip = ["google.com","youtube.com","facebook.com","instagram.com","yelp.com",
                "tripadvisor.com","wikipedia.org","twitter.com","linkedin.com","pinterest.com",
                "opentable.com","doordash.com","grubhub.com","ubereats.com","mapquest.com",
                "yellowpages.com","bbb.org","indeed.com","glassdoor.com","apple.com","x.com",
                "tiktok.com","reddit.com","amazon.com","weddingwire.com","theknot.com",
                "foursquare.com","zomato.com","nextdoor.com","eventbrite.com"];
    var cites = document.querySelectorAll("cite");
    for (var i = 0; i < cites.length; i++) {
        var t = cites[i].textContent.trim();
        var dominated = false;
        for (var s = 0; s < skip.length; s++) {
            if (t.indexOf(skip[s]) > -1) { dominated = true; break; }
        }
        if (!dominated && t.indexOf(".") > -1) {
            var url = t.split("›")[0].trim();
            if (!url.startsWith("http")) url = "https://" + url;
            var m = url.match(/^(https?:\/\/[^\/\s]+)/);
            return m ? m[1] : "";
        }
    }
    return "";
})()
