(function() {
    // Returns ALL candidate Facebook page URLs as a JSON array string, deduped, in
    // page order: '["https://www.facebook.com/venue/", ...]' ('[]' when none).
    // Callers pick the one that matches the venue; returning only the first hit made
    // that choice impossible. Pure ASCII on purpose (AppleScript may read MacRoman).
    var RSAQUO = String.fromCharCode(8250);
    // Not venue pages: share/login/help endpoints, groups, bare /people/ and
    // profile.php links, photos and posts.
    var reserved = ["login","login.php","help","policies","privacy","settings","groups",
        "marketplace","watch","gaming","events","pages","ads","business","sharer",
        "sharer.php","share","share.php","dialog","plugins","tr","policy.php","policy",
        "terms","terms.php","about","legal","cookies","r.php","recover","profile.php",
        "people","photo","photo.php","photos","story.php","permalink.php","hashtag",
        "search","reel","reels","videos","home.php","l.php","messages","notifications",
        "p","pg","media","stories","friends","bookmarks","fundraisers","public"];
    var results = [];
    var seen = {};

    function push(url, key) {
        key = key.toLowerCase();
        if (seen[key]) return;
        seen[key] = true;
        results.push(url);
    }

    function add(handle) {
        if (!handle) return;
        var h = handle.replace(/[?#].*$/, "");
        var low = h.toLowerCase();
        if (reserved.indexOf(low) > -1) return;
        if (low.length < 2 || /^\d+$/.test(low)) return;
        if (!/^[a-z0-9._-]+$/i.test(h)) return;
        push("https://www.facebook.com/" + h + "/", h);
    }

    function fromUrl(href) {
        // Google sometimes wraps result links as /url?q=<target>
        var q = href.match(/[?&](?:q|url)=([^&]+)/);
        if (q && href.indexOf("google.") > -1) {
            try { href = decodeURIComponent(q[1]); } catch (e) {}
        }
        var m = href.match(/^https?:\/\/(?:[a-z]{2,3}(?:-[a-z]{2})?\.|www\.|m\.|web\.|business\.)?facebook\.com\/([^?#]*)/i);
        if (!m) return;
        var parts = m[1].split("/").filter(function(p) { return p; });
        if (parts.length === 0) return;
        var first = parts[0].toLowerCase();
        // facebook.com/pg/Venue/about is an alias of facebook.com/Venue
        if (first === "pg" && parts.length > 1) { add(parts[1]); return; }
        // New-style pages: /people/Venue-Name/1000123/ and /p/Venue-Name-1000123/.
        // The name part lets the caller match it; the bare prefixes are not pages.
        if (first === "people" && parts.length >= 3 && /^\d{6,}$/.test(parts[2]) &&
                /^[A-Za-z0-9._%-]+$/.test(parts[1])) {
            push("https://www.facebook.com/people/" + parts[1] + "/" + parts[2] + "/", "people/" + parts[2]);
            return;
        }
        if (first === "p" && parts.length >= 2 && /-\d{6,}$/.test(parts[1]) &&
                /^[A-Za-z0-9._%-]+$/.test(parts[1])) {
            push("https://www.facebook.com/p/" + parts[1] + "/", "p/" + parts[1]);
            return;
        }
        add(parts[0]);
    }

    var links = document.querySelectorAll("a[href]");
    for (var i = 0; i < links.length && results.length < 10; i++) {
        fromUrl(links[i].href || "");
    }
    // Fallback: cite elements (Google results), incl. "facebook.com > Venue" breadcrumbs
    var citeRe = new RegExp("facebook\\.com(?:/|\\s*(?:" + RSAQUO + "|>)\\s*)([A-Za-z0-9._-]+)", "i");
    var cites = document.querySelectorAll("cite");
    for (var j = 0; j < cites.length && results.length < 10; j++) {
        var cm = cites[j].textContent.trim().match(citeRe);
        if (cm && cm[1]) add(cm[1]);
    }
    return JSON.stringify(results);
})()
