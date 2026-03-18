(function() {
    var links = document.querySelectorAll("a[href]");
    for (var i = 0; i < links.length; i++) {
        var href = links[i].href || "";
        var m = href.match(/https?:\/\/(?:www\.)?instagram\.com\/([a-zA-Z0-9._]+)\/?/);
        if (m && m[1]) {
            var handle = m[1].toLowerCase();
            // Skip non-profile pages
            if (["explore","p","reel","reels","stories","accounts",
                 "about","directory","developer","legal"].indexOf(handle) > -1) continue;
            if (handle.length < 2) continue;
            return "https://www.instagram.com/" + m[1] + "/";
        }
    }
    // Fallback: check cite elements (Google results)
    var cites = document.querySelectorAll("cite");
    for (var j = 0; j < cites.length; j++) {
        var t = cites[j].textContent.trim();
        var cm = t.match(/instagram\.com\/([a-zA-Z0-9._]+)/);
        if (cm && cm[1]) {
            var ch = cm[1].toLowerCase();
            if (["explore","p","reel","reels","stories","accounts",
                 "about","directory","developer","legal"].indexOf(ch) > -1) continue;
            if (ch.length < 2) continue;
            return "https://www.instagram.com/" + cm[1] + "/";
        }
    }
    return "";
})()
