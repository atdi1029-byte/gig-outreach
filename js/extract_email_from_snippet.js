(function() {
    var junk = ['wix.com','wordpress','sentry.io','cloudflare','example.com',
        'squarespace','shopify','mailchimp','googleapis','google.com','gstatic',
        'facebook','instagram','twitter','hubspot','sendgrid','zendesk'];
    var generic = ['noreply@','no-reply@','support@','admin@','webmaster@',
        'billing@','dataremoval@','privacy@','careers@','jobs@','hr@'];

    // Grab all visible text from Google search result snippets
    var text = document.body.innerText || '';
    var matches = text.match(/[a-zA-Z0-9._%+\-]+@[a-zA-Z0-9.\-]+\.[a-zA-Z]{2,}/g) || [];

    var emails = [];
    for (var i = 0; i < matches.length; i++) {
        var e = matches[i].toLowerCase();
        var isJunk = false;
        for (var j = 0; j < junk.length; j++) {
            if (e.indexOf(junk[j]) > -1) { isJunk = true; break; }
        }
        if (!isJunk) {
            for (var g = 0; g < generic.length; g++) {
                if (e.indexOf(generic[g]) === 0) { isJunk = true; break; }
            }
        }
        if (!isJunk && e.length < 60 && emails.indexOf(e) === -1) {
            emails.push(e);
        }
    }
    return emails.join('|');
})()
