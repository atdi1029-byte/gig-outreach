(function() {
    // Only the lodging / nearby-places expander ("View more hotels", "More places
    // nearby"). A bare "view more" also matches review, photo and Q&A buttons.
    var btns = document.querySelectorAll('button');
    for (var i = 0; i < btns.length; i++) {
        var t = btns[i].textContent.trim().toLowerCase().replace(/\s+/g, ' ');
        if (t.length < 40 && /\bmore\b/.test(t) && /\b(hotels?|nearby|places)\b/.test(t) &&
            !/review|photo|question|update|menu/.test(t)) {
            btns[i].click();
            return 'clicked';
        }
    }
    return 'none';
})()
