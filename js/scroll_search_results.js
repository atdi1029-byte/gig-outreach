(function() {
    var panels = document.querySelectorAll('.m6QErb');
    var scrollable = null;
    for (var p = 0; p < panels.length; p++) {
        if (panels[p].scrollHeight > panels[p].clientHeight + 50) {
            scrollable = panels[p];
            break;
        }
    }
    if (!scrollable) return 'no panel';
    var i = 0;
    var timer = setInterval(function() {
        scrollable.scrollTop += 800;
        i++;
        if (i > 25) clearInterval(timer);
    }, 200);
    return 'scrolling';
})()