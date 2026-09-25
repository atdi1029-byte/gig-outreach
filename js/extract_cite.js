(function() {
    // Returns up to 5 candidate official-site URLs, pipe-joined (format used by
    // discover.sh, pipeline.sh and backfill_websites.sh). Pure ASCII on purpose:
    // AppleScript may read this file as MacRoman.
    var RSAQUO = String.fromCharCode(8250);  // Google's cite breadcrumb separator
    var skipDomains = [
        "google.com","youtube.com","facebook.com","instagram.com","yelp.com",
        "tripadvisor.com","wikipedia.org","twitter.com","linkedin.com","pinterest.com",
        "opentable.com","doordash.com","grubhub.com","ubereats.com","mapquest.com",
        "yellowpages.com","bbb.org","indeed.com","glassdoor.com","apple.com","x.com",
        "tiktok.com","reddit.com","amazon.com","weddingwire.com","theknot.com",
        "foursquare.com","zomato.com","nextdoor.com","eventbrite.com","resy.com",
        "toasttab.com","seamless.com","zola.com","peerspace.com","tagvenue.com",
        "eventective.com","partyslate.com","meetup.com",
        // Directories & listing aggregators
        "chamberofcommerce.com","manta.com","hotfrog.com","superpages.com",
        "merchantcircle.com","loc8nearme.com","cylex.us","n49.com","ezlocal.com",
        "citysearch.com","localstack.com","brownbook.net",
        "find-us-here.com","showmelocal.com","spoke.com","corporationwiki.com",
        "bizapedia.com","opencorporates.com","dnb.com",
        // Travel & tourism directories
        "expedia.com","booking.com","hotels.com","kayak.com","priceline.com",
        "travelocity.com","orbitz.com","airbnb.com","vrbo.com","homeaway.com",
        "getaroom.com","hotelscombined.com","agoda.com","trivago.com",
        // News / magazines / guides (articles about a venue are not its website)
        "baltimoresun.com","washingtonpost.com","washingtonian.com","eater.com",
        "timeout.com","patch.com","wtop.com","nbcwashington.com","wusa9.com",
        "fox5dc.com","dcist.com","bizjournals.com","washingtoncitypaper.com",
        "northernvirginiamag.com","bethesdamagazine.com","capitalgazette.com",
        "thrillist.com","theinfatuation.com","michelin.com","zagat.com",
        "baltimoremagazine.com","nytimes.com","forbes.com","cntraveler.com",
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

    // A real hostname with a TLD. Rejects follower counts like "1.8K+" that used to
    // become "https://1.8K+".
    var HOST_RE = /^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)*\.[a-z]{2,}$/;

    // Exact host or subdomain match: "hotels.com" must not swallow kimptonhotels.com,
    // and "x.com" must not swallow innatfairfax.com.
    function skippedHost(host) {
        for (var s = 0; s < skipDomains.length; s++) {
            var d = skipDomains[s];
            if (host === d || host.slice(-(d.length + 1)) === "." + d) return true;
        }
        return false;
    }

    function cleanHost(h) {
        return (h || "").toLowerCase().replace(/^www\./, "");
    }

    var results = [];
    var seen = {};

    // First: grab the Knowledge Panel website link (most reliable)
    var kpLink = null;
    var allLinks = document.querySelectorAll('a');
    for (var j = 0; j < allLinks.length; j++) {
        var txt = allLinks[j].textContent.trim();
        var aria = allLinks[j].getAttribute('aria-label') || '';
        if (txt === 'Website' || aria === 'Website') {
            kpLink = allLinks[j]; break;
        }
    }
    if (kpLink && kpLink.href) {
        var kpHref = kpLink.href;
        // Google sometimes wraps the panel link as google.com/url?q=<site>
        var kq = kpHref.match(/[?&](?:q|url)=([^&]+)/);
        if (kq && /^https?:\/\/(?:www\.)?google\./.test(kpHref)) {
            try { kpHref = decodeURIComponent(kq[1]); } catch (e) {}
        }
        var kpUrl = kpHref.replace(/[?#].*$/, '').replace(/\/+$/, '');
        var kpHost = cleanHost(kpUrl.replace(/^https?:\/\//, '').split('/')[0]);
        if (HOST_RE.test(kpHost) && !skippedHost(kpHost)) {
            results.push(kpUrl);
            seen[kpHost] = true;
        }
    }
    var cites = document.querySelectorAll("cite");
    for (var i = 0; i < cites.length; i++) {
        var t = cites[i].textContent.trim();
        if (t.indexOf(".") === -1) continue;

        // "https://www.venue.com > events > private" breadcrumb (either separator)
        var crumbs = t.split(new RegExp("\\s*(?:" + RSAQUO + "|>)\\s*"));
        var url = crumbs[0].trim();
        if (!/^https?:\/\//.test(url)) url = "https://" + url;
        var m = url.match(/^(https?:\/\/[^\/\s]+)(\/[^\s]*)?/);
        if (!m) continue;

        var domain = m[1].replace(/^https?:\/\//, "").toLowerCase();
        var host = cleanHost(domain);
        if (!HOST_RE.test(host)) continue;
        if (skippedHost(host)) continue;
        var path = (m[2] || "") + (crumbs.length > 1 ? "/" + crumbs.slice(1).join("/") : "");

        // Check domain keyword patterns
        var domainBad = false;
        for (var p = 0; p < skipDomainPatterns.length; p++) {
            if (skipDomainPatterns[p].test(host)) { domainBad = true; break; }
        }
        if (domainBad) continue;

        // Check path patterns (directory listing URLs)
        var pathBad = false;
        var pathL = (path.toLowerCase().replace(/\s+/g, "-") + "/");
        for (var k = 0; k < skipPaths.length; k++) {
            if (pathL.indexOf(skipPaths[k]) > -1) { pathBad = true; break; }
        }
        if (pathBad) continue;

        // Dedupe by domain
        if (!seen[host]) {
            seen[host] = true;
            results.push(m[1]);
        }
        // Return up to 5 candidates
        if (results.length >= 5) break;
    }
    return results.join("|");
})()
