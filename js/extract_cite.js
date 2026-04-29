(function() {
    var skipDomains = [
        "google.com","youtube.com","facebook.com","instagram.com","yelp.com",
        "tripadvisor.com","wikipedia.org","twitter.com","linkedin.com","pinterest.com",
        "opentable.com","doordash.com","grubhub.com","ubereats.com","mapquest.com",
        "yellowpages.com","bbb.org","indeed.com","glassdoor.com","apple.com","x.com",
        "tiktok.com","reddit.com","amazon.com","weddingwire.com","theknot.com",
        "foursquare.com","zomato.com","nextdoor.com","eventbrite.com",
        // Directories & listing aggregators
        "chamberofcommerce.com","manta.com","hotfrog.com","superpages.com",
        "merchantcircle.com","loc8nearme.com","cylex.us","n49.com","ezlocal.com",
        "mapquest.com","citysearch.com","localstack.com","brownbook.net",
        "find-us-here.com","showmelocal.com","spoke.com","corporationwiki.com",
        "bizapedia.com","opencorporates.com","dnb.com",
        // Travel & tourism directories
        "expedia.com","booking.com","hotels.com","kayak.com","priceline.com",
        "travelocity.com","orbitz.com","airbnb.com","vrbo.com","homeaway.com",
        "getaroom.com","hotelscombined.com","agoda.com",
        // Wine/venue specific directories
        "winemaps.com","findwinery.com","wineriesonline.com","winecountry.com",
        "graperadio.com","winefolly.com","vivino.com",
        "golfadvisor.com","golflink.com","golfnow.com",
        "weddingspot.com","venuesforthewedding.com","perfectvenue.us"
    ];

    // Path patterns that indicate a directory listing (not the venue's own site)
    var skipPaths = [
        "/list/member/", "/listing/", "/directory/", "/member/",
        "/places/", "/business/", "/venue/", "/location/",
        "/profile/", "/company/", "/biz/", "/find/"
    ];

    // Domain keyword patterns that indicate a directory or tourism board
    var skipDomainPatterns = [
        /^visit/, /tourism/, /chamber/, /discover/, /explore/,
        /traveler/, /travelguide/, /vacationspot/, /getaway/,
        /localguide/, /cityguide/, /areaguide/
    ];

    var cites = document.querySelectorAll("cite");
    for (var i = 0; i < cites.length; i++) {
        var t = cites[i].textContent.trim();

        // Check skip domains
        var skip = false;
        for (var s = 0; s < skipDomains.length; s++) {
            if (t.indexOf(skipDomains[s]) > -1) { skip = true; break; }
        }
        if (skip) continue;
        if (t.indexOf(".") === -1) continue;

        var url = t.split("›")[0].trim();
        if (!url.startsWith("http")) url = "https://" + url;
        var m = url.match(/^(https?:\/\/[^\/\s]+)(\/[^\s]*)?/);
        if (!m) continue;

        var domain = m[1].replace(/^https?:\/\//, "").toLowerCase();
        var path = m[2] || "";

        // Check domain keyword patterns
        var domainBad = false;
        for (var p = 0; p < skipDomainPatterns.length; p++) {
            if (skipDomainPatterns[p].test(domain)) { domainBad = true; break; }
        }
        if (domainBad) continue;

        // Check path patterns (directory listing URLs)
        var pathBad = false;
        for (var k = 0; k < skipPaths.length; k++) {
            if (path.toLowerCase().indexOf(skipPaths[k]) > -1) { pathBad = true; break; }
        }
        if (pathBad) continue;

        return m[1];
    }
    return "";
})()
