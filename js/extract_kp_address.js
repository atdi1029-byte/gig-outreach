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
    return JSON.stringify(out);
})()
