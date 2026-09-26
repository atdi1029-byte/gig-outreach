(function() {
    // Google search Knowledge Panel: business title + street address, as JSON.
    // discover.sh uses it to fill city/state/address for a new venue when the Maps
    // card only showed a street (it checks the title matches the venue first).
    // blocked=true means Google served its CAPTCHA / unusual-traffic page instead.
    var out = {title: '', address: '', blocked: false};
    var href = (typeof window !== 'undefined' && window.location && window.location.href) || '';
    var body = document.body ? (document.body.innerText || '') : '';
    out.blocked = /\/sorry\//.test(href) || /unusual traffic from your computer network/i.test(body);
    var t = document.querySelector('[data-attrid="title"]');
    if (t) out.title = (t.innerText || t.textContent || '').trim().split('\n')[0];
    var a = document.querySelector('[data-attrid="kc:/location/location:address"]');
    if (a) {
        var txt = (a.innerText || a.textContent || '').replace(/\s+/g, ' ').trim();
        out.address = txt.replace(/^address\s*:\s*/i, '');
    }
    // Sep 2026 layout: the address row lost its data-attrid; it is now a
    // data-dtype="d3ifr" row reading "Address: 416 6th St, Annapolis, MD 21403".
    if (!out.address) {
        var rows = document.querySelectorAll('[data-dtype="d3ifr"], .zloOqf');
        for (var i = 0; i < rows.length; i++) {
            var rt = (rows[i].innerText || rows[i].textContent || '').replace(/\s+/g, ' ').trim();
            if (/^address\s*:/i.test(rt)) {
                out.address = rt.replace(/^address\s*:\s*/i, '');
                break;
            }
        }
    }
    // Google category from the panel subtitle: "4.5 316 Google reviews · $100+ · Restaurant"
    // or "4.7 33 Google reviews Art gallery in Annapolis, Maryland".
    out.category = '';
    var sub = document.querySelector('[data-attrid="subtitle"]');
    if (sub) {
        var st = (sub.innerText || sub.textContent || '').replace(/\s+/g, ' ').trim();
        var parts = st.split(new RegExp('[' + String.fromCharCode(8231, 183, 8901) + '|]'));
        for (var p = 0; p < parts.length; p++) {
            var seg = parts[p].replace(/^.*Google reviews?/i, '').replace(/\s+in\s+[A-Z][^,]*,\s*[A-Za-z ]+$/, '').trim();
            seg = seg.replace(/^\d-star\s+/i, '');            // "4-star hotel" -> "hotel"
            if (!seg || /\$|\d/.test(seg) || /^(open|closed|opens|closes|temporarily closed)\b/i.test(seg)) continue;
            if (/^[^\s]+\.[a-z]{2,}(\/|$)/i.test(seg)) continue;  // a domain, not a category
            out.category = seg.slice(0, 60);
            break;
        }
    }
    out.permanently_closed = /permanently closed/i.test(body.slice(0, 20000)) &&
        !!document.querySelector('[data-attrid="title"]');
    // The panel's "Website" button
    out.website = '';
    var as = document.querySelectorAll('a');
    for (var k = 0; k < as.length; k++) {
        var tx = (as[k].innerText || '').trim();
        if (/^website$/i.test(tx) && /^https?:/.test(as[k].href || '')) { out.website = as[k].href; break; }
    }
    return JSON.stringify(out);
})()
