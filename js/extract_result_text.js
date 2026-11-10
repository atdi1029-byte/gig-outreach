(function() {
    // Title + snippet text of each Google result that links to Facebook or Instagram, as
    // a JSON object string {"<result url>": "<text>"}. The caller drops results whose text
    // names a place outside DC/MD/VA (a same-name business elsewhere: Altitude Trampoline
    // Park, Arlington TX, for the wine bar Altitude, Arlington VA). Pure ASCII on purpose.
    var out = {}, n = 0;
    var links = document.querySelectorAll("a[href]");
    for (var i = 0; i < links.length && n < 20; i++) {
        var href = links[i].href || "";
        var q = href.match(/[?&](?:q|url)=([^&]+)/);
        if (q && href.indexOf("google.") > -1) {
            try { href = decodeURIComponent(q[1]); } catch (e) {}
        }
        if (!/^https?:\/\/[^\/]*(facebook|instagram)\.com\//i.test(href)) continue;
        var box = links[i].closest("div.g, div.MjjYud, div[data-hveid]");
        var text = ((box && box.innerText) || "").replace(/\s+/g, " ");
        // A box that long holds several results: keep to the link's own text (the title).
        if (!text || text.length > 600) text = (links[i].innerText || "").replace(/\s+/g, " ");
        text = text.substring(0, 600);
        var key = href.split(/[?#]/)[0];
        if (!out[key]) n++;
        if (!out[key] || out[key].length < text.length) out[key] = text;
    }
    return JSON.stringify(out);
})()
