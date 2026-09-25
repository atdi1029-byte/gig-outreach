(function() {
    // Emails from Google result snippets, pipe-joined. Only reads the result blocks
    // (not page chrome), and never invents an address: "info@x.com.Read more" is
    // info@x.com, not info@x.com.read. If the caller sets
    // window.__outreachVenueDomain = "venue.com" first, only addresses on that domain
    // (or a free-mail domain) are returned, so neighbouring results can't leak in.
    var junk = ['wix.com','wordpress','sentry.io','cloudflare','example.com',
        'squarespace','shopify','mailchimp','googleapis','google.com','gstatic',
        'facebook','instagram','twitter','hubspot','sendgrid','zendesk',
        'domain.com','email.com','yoursite','yourdomain','sentry'];
    var hardReject = /^(noreply|no-reply|no_reply|donotreply|do-not-reply|support|admin|webmaster|billing|dataremoval|privacy|careers|jobs|hr|marketing|press|media|abuse|postmaster|mailer-daemon|unsubscribe|optout)@/;
    // Sentence words that run into a domain ("x.com.Read more", "x.com.Call us").
    var trailing = {read:1, more:1, see:1, view:1, call:1, visit:1, book:1, open:1,
        menu:1, hours:1, learn:1, click:1, follow:1, contact:1, email:1, phone:1,
        tel:1, fax:1, website:1, directions:1, reserve:1, order:1};
    var badTld = {png:1, jpg:1, jpeg:1, gif:1, webp:1, svg:1, css:1, js:1, read:1,
        html:1, htm:1, php:1, pdf:1, json:1, xml:1, txt:1, more:1};
    var freeMail = {'gmail.com':1, 'yahoo.com':1, 'outlook.com':1, 'hotmail.com':1,
        'aol.com':1, 'icloud.com':1, 'comcast.net':1, 'verizon.net':1, 'me.com':1};
    var venueDomain = (window.__outreachVenueDomain || '').toLowerCase().replace(/^www\./, '');

    var blocks = document.querySelectorAll('#search .MjjYud, #search .g, #rso > div');
    var texts = [];
    for (var b = 0; b < blocks.length; b++) texts.push(blocks[b].innerText || blocks[b].textContent || '');
    if (texts.length === 0) texts.push(document.body ? (document.body.innerText || '') : '');

    var re = /[A-Za-z0-9][A-Za-z0-9._%+\-]*@[A-Za-z0-9\-]+(?:\.[A-Za-z0-9\-]+)*\.[A-Za-z]{2,24}(?![A-Za-z0-9])/g;
    var emails = [];
    for (var t = 0; t < texts.length; t++) {
        var matches = texts[t].match(re) || [];
        for (var i = 0; i < matches.length; i++) {
            var raw = matches[i];
            var at = raw.indexOf('@');
            var local = raw.slice(0, at);
            var labels = raw.slice(at + 1).split('.');
            while (labels.length > 2) {
                var last = labels[labels.length - 1];
                var rest = labels.slice(0, -1).join('.');
                if (trailing[last.toLowerCase()] || (/^[A-Z]/.test(last) && rest === rest.toLowerCase())) {
                    labels.pop();
                } else {
                    break;
                }
            }
            var tld = labels[labels.length - 1].toLowerCase();
            if (labels.length < 2 || badTld[tld] || tld.length > 12) continue;
            // Remnants of escapes ("u003einfo@", "u00a0events@")
            local = local.replace(/^(?:u00[0-9a-fA-F]{2})+(?=[A-Za-z0-9])/, '');
            var e = (local + '@' + labels.join('.')).toLowerCase();
            var dom = labels.join('.').toLowerCase();
            var isJunk = hardReject.test(e) || e.length >= 60;
            for (var j = 0; j < junk.length && !isJunk; j++) {
                if (dom.indexOf(junk[j]) > -1) isJunk = true;
            }
            if (!isJunk && venueDomain && !freeMail[dom] &&
                dom !== venueDomain && dom.slice(-(venueDomain.length + 1)) !== '.' + venueDomain) {
                isJunk = true;
            }
            if (!isJunk && emails.indexOf(e) === -1) emails.push(e);
        }
    }
    return emails.join('|');
})()
