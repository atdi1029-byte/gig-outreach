(function() {
    var buttons = document.querySelectorAll('button[role="tab"]');
    for (var i = 0; i < buttons.length; i++) {
        if (buttons[i].textContent.trim().toLowerCase() === 'about') {
            buttons[i].click();
            return 'clicked';
        }
    }
    return 'no_about_tab';
})()