(function() {
    var links = document.querySelectorAll("a[href]");
    for (var i = 0; i < links.length; i++) {
        var href = links[i].href || "";
        var m = href.match(/https?:\/\/(?:www\.)?facebook\.com\/([a-zA-Z0-9._-]+)\/?/);
        if (m && m[1]) {
            var page = m[1].toLowerCase();
            // Skip non-page links
            if (["login","help","policies","privacy","settings","groups",
                 "marketplace","watch","gaming","events","pages",
                 "ads","business","sharer","sharer.php","share",
                 "policy.php","policy","terms","terms.php","about",
                 "legal","cookies","r.php","recover","profile.php"].indexOf(page) > -1) continue;
            if (page.length < 2) continue;
            return "https://www.facebook.com/" + m[1] + "/";
        }
    }
    // Fallback: check cite elements (Google results)
    var cites = document.querySelectorAll("cite");
    for (var j = 0; j < cites.length; j++) {
        var t = cites[j].textContent.trim();
        var cm = t.match(/facebook\.com\/([a-zA-Z0-9._-]+)/);
        if (cm && cm[1]) {
            var ch = cm[1].toLowerCase();
            if (["login","help","policies","privacy","settings","groups",
                 "marketplace","watch","gaming","events","pages",
                 "ads","business","sharer","sharer.php","share"].indexOf(ch) > -1) continue;
            if (ch.length < 2) continue;
            return "https://www.facebook.com/" + cm[1] + "/";
        }
    }
    return "";
})()
