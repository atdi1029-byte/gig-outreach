(function() {
    // Returns ALL candidate Instagram profile URLs as a JSON array string, deduped,
    // in page order: '["https://www.instagram.com/venue/", ...]' ('[]' when none).
    // Callers pick the one that matches the venue. Pure ASCII on purpose.
    var RSAQUO = String.fromCharCode(8250);
    // Posts, reels, stories and site pages are not profiles.
    var reserved = ["explore","p","reel","reels","stories","accounts","about","directory",
        "developer","legal","tv","share","embed","direct","privacy","terms","web",
        "challenge","sharer","popular","emails","session","oauth","ar"];
    var results = [];
    var seen = {};

    function add(handle) {
        if (!handle) return;
        var low = handle.toLowerCase();
        if (reserved.indexOf(low) > -1) return;
        if (low.length < 2 || /^\d+$/.test(low)) return;
        if (!/^[a-z0-9._]+$/i.test(handle)) return;
        if (seen[low]) return;
        seen[low] = true;
        results.push("https://www.instagram.com/" + handle + "/");
    }

    function fromUrl(href) {
        var q = href.match(/[?&](?:q|url)=([^&]+)/);
        if (q && href.indexOf("google.") > -1) {
            try { href = decodeURIComponent(q[1]); } catch (e) {}
        }
        var m = href.match(/^https?:\/\/(?:www\.|m\.)?instagram\.com\/([A-Za-z0-9._]+)(?:[\/?#]|$)/i);
        if (m) add(m[1]);
    }

    var links = document.querySelectorAll("a[href]");
    for (var i = 0; i < links.length && results.length < 10; i++) {
        fromUrl(links[i].href || "");
    }
    // Fallback: cite elements (Google results), incl. "instagram.com > venue" breadcrumbs
    var citeRe = new RegExp("instagram\\.com(?:/|\\s*(?:" + RSAQUO + "|>)\\s*)([A-Za-z0-9._]+)", "i");
    var cites = document.querySelectorAll("cite");
    for (var j = 0; j < cites.length && results.length < 10; j++) {
        var cm = cites[j].textContent.trim().match(citeRe);
        if (cm && cm[1]) add(cm[1]);
    }
    return JSON.stringify(results);
})()
