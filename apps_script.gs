// ============================================================
// Gig Outreach Dashboard — Google Apps Script
// Backend API for classical guitar gig outreach PWA.
// Stores venues, contacts, outreach log in Google Sheets.
// All browser communication via GET (POST fails due to CORS).
// ============================================================

// === SHEET NAME CONSTANTS ===
var VENUES      = 'Venues';
var CONTACTS    = 'Contacts';
var OUTREACH    = 'Outreach Log';
var CONFIG      = 'Config';
var TEMPLATES   = 'Templates';
var PROGRESS    = 'Progress';
var PAST_GIGS   = 'Past Gigs';

// Bump on every deploy. preflight.sh compares the live value with this file.
var BACKEND_VERSION = '2026-09-25.1';

// Generate next unique contact ID. Must be called inside withLock_: the
// high-water mark in Script Properties keeps IDs from being reused after the
// top row is deleted.
function nextContactId_(data) {
  var max = 0;
  for (var i = 1; i < data.length; i++) {
    var id = String(data[i][0]);
    if (id.startsWith('C-')) {
      var num = parseInt(id.substring(2), 10);
      if (!isNaN(num) && num > max) max = num;
    }
  }
  return 'C-' + String(nextSeq_('seq_contact', max)).padStart(3, '0');
}
var TASTE       = 'Taste';

// Returns max(stored high-water, currentMax) + 1 and stores it.
function nextSeq_(key, currentMax) {
  var n = (Number(currentMax) || 0) + 1;
  try {
    var props = PropertiesService.getScriptProperties();
    var stored = parseInt(props.getProperty(key) || '0', 10) || 0;
    if (stored + 1 > n) n = stored + 1;
    props.setProperty(key, String(n));
  } catch (e) { /* properties unavailable: max+1 is still unique under the lock */ }
  return n;
}
function peekSeq_(key) {
  try { return parseInt(PropertiesService.getScriptProperties().getProperty(key) || '0', 10) || 0; }
  catch (e) { return 0; }
}
function setSeq_(key, n) {
  try { PropertiesService.getScriptProperties().setProperty(key, String(n)); } catch (e) {}
}
// Before deleting a row: remember its number so the ID is never handed out again.
function retireId_(key, id) {
  var m = String(id || '').match(/(\d+)$/);
  if (!m) return;
  var n = parseInt(m[1], 10);
  if (n > peekSeq_(key)) setSeq_(key, n);
}

// ---------------------------------------------------------------
// Shared rules. apps_script.gs can't import outreach_rules.py, so these
// lists MIRROR it by hand. Change both files together (search for
// "outreach_rules.py" there).
// ---------------------------------------------------------------
// Null-prototype sets: a name/email word like "constructor" must not look like a member.
function setOf_(arr) { var o = Object.create(null); for (var i = 0; i < arr.length; i++) o[arr[i]] = true; return o; }

var TARGET_STATES = ['DC', 'MD', 'VA'];

var FREEMAIL_DOMAINS = setOf_([
  'gmail.com', 'googlemail.com', 'yahoo.com', 'ymail.com', 'outlook.com',
  'hotmail.com', 'live.com', 'msn.com', 'aol.com', 'icloud.com', 'me.com',
  'mac.com', 'comcast.net', 'verizon.net', 'att.net', 'sbcglobal.net',
  'protonmail.com', 'proton.me', 'gmx.com', 'zoho.com', 'cox.net',
  'earthlink.net', 'mindspring.com', 'zoominternet.net', 'bellsouth.net',
  'charter.net', 'optonline.net', 'rcn.com', 'erols.com', 'starpower.net',
  'frontier.com', 'frontiernet.net', 'windstream.net', 'centurylink.net',
  'juno.com', 'netzero.net', 'atlanticbb.net', 'shentel.net', 'ntelos.net',
  'md.metrocast.net', 'metrocast.net', 'aim.com', 'mail.com', 'fastmail.com',
  'pm.me', 'rocketmail.com'
]);

var SHARED_BRAND_DOMAINS = setOf_([
  'marriott.com', 'hilton.com', 'hiltonhotels.com', 'conradhotels.com',
  'ihg.com', 'kimptonhotels.com', 'hyatt.com', 'sonesta.com', 'sonder.com',
  'wyndhamhotels.com', 'choicehotels.com', 'bestwestern.com', 'accor.com',
  'radissonhotels.com', 'fourseasons.com', 'ritzcarlton.com', 'aubergeresorts.com',
  'invitedclubs.com', 'clubcorp.com', 'maggianos.com', 'aramark.com',
  'sodexo.com', 'compass-usa.com', 'hhmhospitality.com', 'aimbridge.com',
  'highgate.com', 'davidsonhospitality.com', 'sagehospitality.com',
  'loewshotels.com', 'omnihotels.com', 'fairmont.com', 'sofitel.com',
  'brookdale.com', 'sunriseseniorliving.com', 'erickson.com'
]);

var NON_VENUE_HOSTS = setOf_([
  'facebook.com', 'instagram.com', 'twitter.com', 'x.com', 'linkedin.com',
  'yelp.com', 'tripadvisor.com', 'opentable.com', 'resy.com', 'google.com',
  'youtube.com', 'wikipedia.org', 'theknot.com', 'weddingwire.com',
  'zola.com', 'eventective.com', 'peerspace.com', 'tagvenue.com',
  'fox5dc.com', 'washingtonpost.com', 'washingtonian.com', 'eater.com',
  'timeout.com', 'yellowpages.com', 'mapquest.com', 'foursquare.com',
  'doordash.com', 'ubereats.com', 'grubhub.com', 'toasttab.com'
]);

var PLACEHOLDER_EMAILS = setOf_([
  'user@domain.com', 'your@email.com', 'name@email.com', 'email@email.com',
  'info@mysite.com', 'example@mysite.com', 'you@example.com', 'test@test.com',
  'john@doe.com', 'johndoe@example.com', 'email@domain.com', 'name@domain.com',
  'your@domain.com', 'yourname@domain.com', 'youremail@domain.com',
  'info@example.com', 'someone@example.com', 'hello@example.com'
]);

var JUNK_EMAIL_DOMAINS = setOf_([
  'example.com', 'example.org', 'domain.com', 'email.com', 'mysite.com',
  'yoursite.com', 'yourdomain.com', 'website.com', 'sentry.io',
  'sentry-next.wixpress.com', 'sentry.wixpress.com', 'wixpress.com',
  'wix.com', 'squarespace.com', 'godaddy.com', 'shopify.com',
  'mailchimp.com', 'sendgrid.net', 'hubspot.com', 'zendesk.com',
  'cloudflare.com', 'googleapis.com', 'gstatic.com', 'fontawesome.io',
  'sentry.zendesk.com', 'latofonts.com', 'typekit.net'
]);

var BAD_TLDS = setOf_([
  'png', 'jpg', 'jpeg', 'gif', 'webp', 'svg', 'css', 'js', 'read', 'html',
  'htm', 'php', 'asp', 'aspx', 'pdf', 'ico', 'mp4', 'json', 'xml', 'txt'
]);

var HARD_REJECT_PREFIXES = [
  'noreply', 'no-reply', 'no_reply', 'donotreply', 'do-not-reply', 'webmaster',
  'billing', 'privacy', 'careers', 'recruiting', 'recruitment', 'humanresources',
  'marketing', 'mailer-daemon', 'postmaster', 'dataremoval', 'unsubscribe',
  'optout', 'emailoptout', 'accountspayable', 'accountsreceivable', 'payroll',
  'invoice', 'travelpass', 'giftcard', 'sponsorship', 'compliance'
];
var HARD_REJECT_TOKENS = setOf_([
  'hr', 'pr', 'ap', 'ar', 'jobs', 'job', 'career', 'press', 'media', 'abuse',
  'legal', 'security', 'accounting', 'donations', 'donate', 'volunteer',
  'volunteers', 'giftcards'
]);
var HARD_REJECT_SUBSTRINGS = [
  'optout', 'opt-out', 'unsubscribe', 'privacy', 'noreply', 'no-reply',
  'donotreply', 'mailer-daemon', 'dataremoval', 'gdpr'
];

// Role mailbox words (outreach_rules.py ROLE_TOKENS).
var GENERIC_PREFIXES = setOf_([
  'info', 'information', 'hello', 'contact', 'contactus', 'sales', 'events',
  'event', 'privateevents', 'private', 'specialevents', 'reservations',
  'reservation', 'reserve', 'booking', 'bookings', 'book', 'enquiries',
  'enquiry', 'inquiries', 'inquiry', 'office', 'general', 'frontdesk', 'front',
  'reception', 'support', 'admin', 'catering', 'groups', 'group', 'groupsales',
  'weddings', 'wedding', 'meetings', 'meeting', 'manager', 'gm',
  'generalmanager', 'eat', 'dine', 'dining', 'host', 'hostess', 'mail', 'team',
  'staff', 'concierge', 'banquets', 'banquet', 'venue', 'rentals', 'rental',
  'tastingroom', 'tasting', 'wine', 'wineclub', 'club', 'members', 'member',
  'membership', 'clubhouse', 'proshop', 'golf', 'tennis', 'spa', 'swim',
  'pool', 'fitness', 'kitchen', 'chef', 'bar', 'restaurant', 'cafe', 'shop',
  'store', 'orders', 'order', 'tickets', 'ticket', 'boxoffice', 'music',
  'entertainment', 'hr', 'guest', 'guests', 'guestservices', 'service',
  'customerservice', 'feedback', 'social', 'community', 'programs',
  'education', 'tours', 'tour', 'visit', 'visitors', 'farm', 'hotel', 'inn',
  'desk', 'operations', 'ops', 'director', 'gallery', 'museum', 'partners',
  'partnerships', 'hospitality', 'accounts', 'account', 'billing', 'owner',
  'owners', 'management', 'mgmt', 'hq', 'corporate', 'weddingsales'
]);

// outreach_rules.py NAME_BOILERPLATE: page words that are never a person name.
var NAME_BOILERPLATE = setOf_([
  'hours', 'visit', 'us', 'contact', 'rights', 'reserved', 'copyright', 'llc',
  'inc', 'menu', 'reservations', 'reservation', 'events', 'event', 'team',
  'staff', 'email', 'phone', 'fax', 'address', 'directions', 'info',
  'information', 'privacy', 'policy', 'terms', 'home', 'about', 'careers',
  'gift', 'cards', 'shop', 'order', 'online', 'book', 'now', 'click', 'here',
  'follow', 'subscribe', 'newsletter', 'sign', 'up', 'login', 'account',
  'sales', 'office', 'catering', 'private', 'dining', 'wedding', 'weddings',
  'club', 'hotel', 'restaurant', 'winery', 'vineyard', 'vineyards', 'bar',
  'grill', 'cafe', 'kitchen', 'general', 'manager', 'department', 'desk',
  'front', 'guest', 'services', 'service', 'group', 'groups', 'the', 'and',
  'of', 'at', 'for', 'our', 'your', 'with', 'tasting', 'room', 'wine',
  'open', 'closed', 'daily', 'monday', 'tuesday', 'wednesday', 'thursday',
  'friday', 'saturday', 'sunday', 'am', 'pm', 'map', 'location', 'locations',
  'send', 'message', 'opt', 'get', 'learn', 'view', 'inquire', 'inquiry',
  'inquiries', 'rsvp', 'tickets', 'request', 'quote', 'outing', 'outings',
  'rate', 'rates', 'basic', 'golf',
  'studio', 'studios', 'design', 'designs', 'designer', 'media', 'creative',
  'agency', 'photography'
]);

// outreach_rules.py _GENERIC_VENUE_WORDS (plus stop words).
var GENERIC_VENUE_WORDS = setOf_([
  'bar', 'grill', 'bistro', 'cafe', 'restaurant', 'kitchen', 'tavern', 'pub',
  'lounge', 'house', 'club', 'wine', 'winery', 'vineyard', 'vineyards',
  'brewing', 'inn', 'suites', 'resort', 'lodge', 'manor', 'estate', 'hotel',
  'country', 'golf', 'yacht', 'city', 'national', 'collection', 'spa',
  'farm', 'cellars', 'events', 'event', 'center', 'centre', 'group',
  'hospitality', 'company', 'co', 'llc', 'inc', 'dc', 'va', 'md',
  'washington', 'virginia', 'maryland',
  'the', 'a', 'an', 'and', 'of', 'at', 'in', 'by', 'on'
]);

var MULTI_SUFFIXES = setOf_([
  'co.uk', 'org.uk', 'ac.uk', 'gov.uk', 'com.au', 'net.au', 'org.au',
  'co.nz', 'com.br', 'com.mx', 'co.jp', 'co.za', 'com.sg', 'co.in'
]);

// Legacy website blocklist kept alongside NON_VENUE_HOSTS.
var WEBSITE_JUNK_DOMAINS = setOf_(['wix.com', 'squarespace.com', 'zoominfo.com', 'fandom.com', 'res-menu.net']);

var CONTACT_VERIFIED_VALUES = setOf_(['valid', 'role', 'unverified', 'pending', 'deferred',
  'catch-all', 'unknown', 'invalid', 'do_not_mail']);
var VERIFIED_ALIASES = {
  'catch_all': 'catch-all', 'catchall': 'catch-all', 'accept_all': 'catch-all',
  'do-not-mail': 'do_not_mail', 'donotmail': 'do_not_mail', 'do not mail': 'do_not_mail',
  'spamtrap': 'do_not_mail', 'abuse': 'do_not_mail', 'toxic': 'do_not_mail',
  'role_based': 'role', 'role-based': 'role', 'generic': 'role'
};
// Statuses the PWA may queue for sending (server-side builders only).
var SENDABLE_VERIFIED = setOf_(['valid', 'role']);

// 'dismissed' = Mark Done with nothing sent (PWA). researched/sent are legacy values.
var VENUE_STATUSES = setOf_(['needs_review', 'untouched', 'pipelined', 'contacted', 'dismissed', 'closed', 'researched', 'sent']);

var VENUE_COLS = ['venue_id', 'name', 'category', 'website', 'city', 'county', 'state',
  'address', 'facebook', 'instagram', 'upscale_score', 'zone_priority', 'status', 'source',
  'scraped_date', 'notes', 'distance_miles', 'drive_minutes', 'contacted_date',
  'contact_form', 'linkedin_pending', 'venue_vote', 'venue_feedback', 'check_status',
  'taste_score', 'taste_score_version', 'taste_reasons', 'classification_confidence',
  'location_confidence', 'priority_override'];

// ---------------------------------------------------------------
// Small helpers
// ---------------------------------------------------------------
function normHeader_(h) { return String(h == null ? '' : h).toLowerCase().replace(/[_ ]/g, ''); }

// Venue column indexes by header, falling back to the canonical position.
function venueCols_(headers) {
  var byName = {};
  for (var h = 0; h < (headers || []).length; h++) {
    var k = normHeader_(headers[h]);
    if (k && byName[k] === undefined) byName[k] = h;
  }
  var c = {};
  for (var i = 0; i < VENUE_COLS.length; i++) {
    var key = normHeader_(VENUE_COLS[i]);
    if (byName[key] !== undefined) c[VENUE_COLS[i]] = byName[key];
    // Legacy sheet with no header in that slot: use the historical position.
    else if (i < 24 && !normHeader_((headers || [])[i])) c[VENUE_COLS[i]] = i;
    else c[VENUE_COLS[i]] = -1;
  }
  return c;
}
function cell_(row, idx) { return idx >= 0 && idx < row.length ? row[idx] : ''; }

// Dates that aren't parseable must not throw (RangeError would kill the dashboard).
function isoDate_(v) {
  if (v === null || v === undefined || v === '') return '';
  var d = (v instanceof Date) ? v : new Date(v);
  return isNaN(d.getTime()) ? '' : d.toISOString();
}

// Text that Sheets would parse as a formula is stored as plain text.
function safeCell_(v) {
  if (typeof v !== 'string' || !v) return v;
  if (v.charAt(0) === '=') return "'" + v;
  if (/^[+\-@]/.test(v) && isNaN(Number(v))) return "'" + v;
  return v;
}

function sentFlag_(v) {
  var s = String(v).toLowerCase();
  return (s === 'true' || s === 'skipped' || s === 'sent_elsewhere') ? s : false;
}

// ---------------------------------------------------------------
// Email / domain rules (mirror outreach_rules.py)
// ---------------------------------------------------------------
var EMAIL_RE_ = /^[a-z0-9][a-z0-9._%+'-]*@[a-z0-9-]+(\.[a-z0-9-]+)*\.[a-z]{2,24}$/;

function normalizeEmail_(raw) {
  if (raw === null || raw === undefined) return '';
  var e = String(raw);
  try { e = decodeURIComponent(e); } catch (err) { e = e.replace(/%20/gi, ' '); }
  e = e.trim().toLowerCase().replace(/^mailto:/, '').split('?')[0].replace(/\s+/g, '');
  e = e.replace(/^[.,;:()\[\]<>"'`]+/, '').replace(/[.,;:()\[\]<>"'`]+$/, '');
  if (!EMAIL_RE_.test(e)) return '';
  if (BAD_TLDS[e.substring(e.lastIndexOf('.') + 1)]) return '';
  return e;
}

function hostOf_(urlOrHost) {
  var s = String(urlOrHost || '').trim().toLowerCase();
  if (!s) return '';
  s = s.replace(/^[a-z][a-z0-9+.-]*:\/\//, '').replace(/^\/\//, '');
  s = s.split(/[\/?#]/)[0].split('@').pop().split(':')[0];
  return s.indexOf('www.') === 0 ? s.substring(4) : s;
}

function registrableDomain_(urlOrHost) {
  var host = hostOf_(urlOrHost);
  if (!host || /^\d+(\.\d+){3}$/.test(host)) return host;
  var parts = host.split('.');
  if (parts.length >= 3 && MULTI_SUFFIXES[parts.slice(-2).join('.')]) return parts.slice(-3).join('.');
  return parts.slice(-2).join('.');
}

// Site builders host many unrelated venues on one registrable domain
// (foo.wixsite.com): the venue's own domain is unknown there. Same list as
// outreach_rules.py SITE_BUILDER_HOSTS.
var SITE_BUILDER_HOSTS = setOf_([
  'wixsite.com', 'weebly.com', 'godaddysites.com', 'business.site', 'square.site',
  'toast.site', 'wordpress.com', 'blogspot.com', 'webflow.io', 'carrd.co',
  'myshopify.com', 'site123.me', 'jimdosite.com', 'webnode.com', 'mystrikingly.com',
  'yolasite.com'
]);

// Registrable domain of a venue's own website ('' if none, a listing site or a site builder).
function venueOwnDomain_(website) {
  var reg = registrableDomain_(website);
  if (!reg || reg.indexOf('.') === -1 || NON_VENUE_HOSTS[reg] || SITE_BUILDER_HOSTS[reg]) return '';
  return reg;
}

function localTokens_(local) {
  return local.replace(/\d+/g, '').split(/[._\-+]+/).filter(function(t) { return t; });
}

// outreach_rules.py PERSON_ROLE_TITLES: one-person mailboxes at small venues.
var PERSON_ROLE_LOCALS_ = setOf_([
  'owner', 'owners', 'chef', 'executivechef', 'headchef', 'gm', 'generalmanager',
  'proprietor', 'founder', 'cofounder', 'president'
]);

function isRoleEmail_(email) {
  var e = normalizeEmail_(email);
  if (!e) return false;
  var local = e.split('@')[0];
  var stripped = local.replace(/[\d._\-+]/g, '');
  if (GENERIC_PREFIXES[stripped]) return true;
  var toks = localTokens_(local);
  if (!toks.length || GENERIC_PREFIXES[toks[0]]) return true;
  for (var w in GENERIC_PREFIXES) {
    if (w.length >= 5 && stripped.indexOf(w) === 0) return true;
  }
  return false;
}

// '' when fine, else why the address must never be saved.
function junkEmailReason_(e) {
  if (!e) return 'malformed';
  if (PLACEHOLDER_EMAILS[e]) return 'placeholder';
  var local = e.split('@')[0], dom = e.split('@')[1];
  var reg = registrableDomain_(dom);
  if (JUNK_EMAIL_DOMAINS[dom] || JUNK_EMAIL_DOMAINS[reg]) return 'junk_domain:' + reg;
  if (/^[0-9a-f]{16,}$/.test(local)) return 'hash_localpart';
  if (/\d{7,}/.test(local)) return 'long_digits';
  if (/@\dx\./.test(e)) return 'image_filename';
  if (local.length > 64) return 'too_long';
  return '';
}

function hardRejectReason_(e) {
  if (!e) return 'malformed';
  var local = e.split('@')[0];
  var i;
  for (i = 0; i < HARD_REJECT_SUBSTRINGS.length; i++) {
    if (local.indexOf(HARD_REJECT_SUBSTRINGS[i]) !== -1) return 'hard_reject:' + HARD_REJECT_SUBSTRINGS[i];
  }
  for (i = 0; i < HARD_REJECT_PREFIXES.length; i++) {
    if (local.indexOf(HARD_REJECT_PREFIXES[i]) === 0) return 'hard_reject:' + HARD_REJECT_PREFIXES[i];
  }
  var toks = localTokens_(local);
  var whole = local.replace(/[\d._\-+]/g, '');
  if (HARD_REJECT_TOKENS[whole]) return 'hard_reject:' + whole;
  if (toks.length && HARD_REJECT_TOKENS[toks[0]]) return 'hard_reject:' + toks[0];
  return '';
}

// Off-domain gate (policy P1). venueDomain is venueOwnDomain_() of the website.
function offDomainReason_(e, venueDomain) {
  if (!e || !venueDomain) return '';
  var dom = e.split('@')[1];
  var ereg = registrableDomain_(dom);
  if (ereg === venueDomain) return '';
  if (FREEMAIL_DOMAINS[ereg] || FREEMAIL_DOMAINS[dom]) return '';
  return 'off_domain:' + ereg + '!=' + venueDomain;
}

function normalizeVerified_(raw, hasEmail) {
  if (!hasEmail) return 'pending';
  var v = String(raw || '').trim().toLowerCase();
  if (VERIFIED_ALIASES.hasOwnProperty(v)) v = VERIFIED_ALIASES[v];
  if (!v || !CONTACT_VERIFIED_VALUES[v] || v === 'pending') return 'unverified';
  return v;
}

// ---------------------------------------------------------------
// Name / title rules
// ---------------------------------------------------------------
function tidyName_(name) {
  return String(name == null ? '' : name).replace(/\s+/g, ' ').trim().replace(/^[,;:\-|]+|[,;:\-|]+$/g, '').trim();
}

function normPersonName_(name) {
  var s = tidyName_(name).toLowerCase();
  try { s = s.normalize('NFD').replace(/[\u0300-\u036f]/g, ''); } catch (e) {}
  return s.replace(/[^a-z ]/g, '').replace(/\s+/g, ' ').trim();
}

// Mirrors outreach_rules.clean_person_name: '' if the text is a person's
// "First Last", else a reason. email (may be '') only sharpens the reason.
function nameProblem_(name, email) {
  var n = String(name == null ? '' : name).replace(/\s+/g, ' ').replace(/^[ \t\r\n,;:\-|]+|[ \t\r\n,;:\-|]+$/g, '');
  if (!n) return 'empty';
  if (n.indexOf('*') !== -1) return 'masked';
  if (n.indexOf('@') !== -1) return 'email_like';
  if (/\d/.test(n)) return 'digits';
  if (n.length > 60) return 'too_long';
  var toks = n.split(' ');
  if (email && toks.length === 1) {
    var localKey = email.split('@')[0].replace(/[^a-z]/g, '');
    if (localKey && n.toLowerCase().replace(/[^a-z]/g, '') === localKey) return 'equals_local_part';
  }
  if (toks.length < 2 || toks.length > 5) return 'not_first_last';
  for (var i = 0; i < toks.length; i++) {
    if (!/^[A-Za-zÀ-ÿ'’.\-]+$/.test(toks[i]) || !/[A-Za-zÀ-ÿ]/.test(toks[i])) return 'not_alpha';
    // possessives are place names ("Theo's - Rehoboth Beach"), not people
    if (/['’]s$/i.test(toks[i])) return 'possessive';
  }
  var words = toks.map(function(t) { return t.toLowerCase().replace(/[^a-zà-ÿ]/g, ''); });
  if (words.filter(function(w) { return w.length >= 2; }).length < 2) return 'not_first_last';
  for (var j = 0; j < words.length; j++) {
    if (words[j].length >= 2 && NAME_BOILERPLATE[words[j]]) return 'boilerplate:' + words[j];
  }
  return '';
}

// The tidy "First Last" (title-cased when all upper/lower), or '' if not a person name.
function cleanPersonName_(name) {
  if (nameProblem_(name, '')) return '';
  var n = String(name).replace(/\s+/g, ' ').replace(/^[ \t\r\n,;:\-|]+|[ \t\r\n,;:\-|]+$/g, '');
  if (n === n.toUpperCase() || n === n.toLowerCase()) {
    n = n.split(' ').map(function(t) { return t.charAt(0).toUpperCase() + t.substring(1).toLowerCase(); }).join(' ');
  }
  return n;
}

// Scraped titles arrive as '||||' or page text ('|Service And Tax Are Additional.|||Menu').
function cleanTitle_(title) {
  var parts = String(title == null ? '' : title).split('|').map(function(p) {
    return p.replace(/\s+/g, ' ').trim();
  }).filter(function(p) { return p; });
  if (!parts.length || parts.length > 3) return '';
  for (var i = 0; i < parts.length; i++) {
    var words = parts[i].split(' ');
    // A sentence, not a job title ("Sr. Events Manager" is fine).
    if (words.length >= 4 && /[a-z]{4,}[.!?]$/i.test(parts[i])) return '';
    if (words.length >= 6 && /[a-z]{3,}[.!?]\s+\S/i.test(parts[i])) return '';
  }
  var t = parts.join(' / ');
  if (t.length > 100) return '';
  return t;
}

// ---------------------------------------------------------------
// Locking. Every write runs under the script lock so concurrent
// writers (PWA + pipeline + discovery) can't mint the same ID or
// delete a row that moved underneath them.
// ---------------------------------------------------------------
var LOCK_WAIT_MS = 30000;
var _lockHeld = false;

function withLock_(fn) {
  if (_lockHeld) return fn();
  var lock = LockService.getScriptLock();
  if (!lock.tryLock(LOCK_WAIT_MS)) {
    throw new Error('LOCK_BUSY: another write is in progress; retry in a few seconds');
  }
  _lockHeld = true;
  try {
    var out = fn();
    SpreadsheetApp.flush();
    return out;
  } finally {
    _lockHeld = false;
    invalidateDashboardCache_();
    lock.releaseLock();
  }
}

// Read one column and return the 1-based row numbers whose value equals `value`.
function findRowsByColumn_(sheet, colNum, value) {
  var last = sheet.getLastRow();
  if (last < 2) return [];
  var vals = sheet.getRange(2, colNum, last - 1, 1).getValues();
  var rows = [];
  for (var i = 0; i < vals.length; i++) {
    if (String(vals[i][0]) === value) rows.push(i + 2);
  }
  return rows;
}

// Read the given rows (contiguous runs in one call each). Returns {rowNum: values[]}.
function readRows_(sheet, rowNums, numCols) {
  var out = {};
  var sorted = rowNums.slice().sort(function(a, b) { return a - b; });
  var i = 0;
  while (i < sorted.length) {
    var start = sorted[i], end = start;
    while (i + 1 < sorted.length && sorted[i + 1] === end + 1) { i++; end = sorted[i]; }
    var block = sheet.getRange(start, 1, end - start + 1, numCols).getValues();
    for (var b = 0; b < block.length; b++) out[start + b] = block[b];
    i++;
  }
  return out;
}

// Venue row lookup without reading the whole sheet.
// Returns null or {rowNum, row, headers, cols, count}.
function findVenueRow_(ss, venueId) {
  var sheet = ss.getSheetByName(VENUES);
  if (!sheet || !venueId) return null;
  var lastCol = sheet.getLastColumn();
  var headers = sheet.getRange(1, 1, 1, lastCol).getValues()[0];
  var rows = findRowsByColumn_(sheet, 1, venueId);
  if (!rows.length) return null;
  var row = sheet.getRange(rows[0], 1, 1, lastCol).getValues()[0];
  return { rowNum: rows[0], row: row, headers: headers, cols: venueCols_(headers), count: rows.length, sheet: sheet };
}

// ---------------------------------------------------------------
// doGet — Main API router
// All actions via GET query params: ?action=dashboard&...
// ---------------------------------------------------------------
// Global callback for JSONP support — set by doGet, used by jsonResponse_
var _jsonpCallback = '';

// lock:true runs the whole handler under the script lock. Handlers that make
// slow Maps calls (add_venue, add_contact, calc_distances) lock internally.
var ROUTES_ = {
  'dashboard':             { fn: function(p) { return serveDashboardJSON_(p); } },
  'venues':                { fn: function(p) { return serveVenuesJSON_(p); } },
  'venue_detail':          { fn: function(p) { return serveVenueDetail_(p); } },
  'update_venue':          { fn: function(p) { return updateVenue_(p); }, lock: true },
  'update_contact':        { fn: function(p) { return updateContact_(p); }, lock: true },
  'log_outreach':          { fn: function(p) { return logOutreach_(p); }, lock: true },
  'add_venue':             { fn: function(p) { return addVenue_(p); } },
  'add_contact':           { fn: function(p) { return addContact_(p); } },
  'update_contact_email':  { fn: function(p) { return updateContactEmail_(p); }, lock: true },
  'templates':             { fn: function(p) { return serveTemplates_(); } },
  'stats':                 { fn: function(p) { return serveStats_(); } },
  'config':                { fn: function(p) { return serveConfig_(); } },
  'calc_distances':        { fn: function(p) { return calcDistances_(); } },
  'migrate_schema':        { fn: function(p) { return migrateSchema_(p); }, lock: true },
  'add_gig':               { fn: function(p) { return addGig_(p); }, lock: true },
  'update_gig':            { fn: function(p) { return updateGig_(p); }, lock: true },
  'delete_gig':            { fn: function(p) { return deleteGig_(p); }, lock: true },
  'get_gigs':              { fn: function(p) { return getGigs_(); } },
  'get_recommendations':   { fn: function(p) { return getRecommendations_(); } },
  'save_monthly':          { fn: function(p) { return saveMonthly_(p); }, lock: true },
  'load_monthly':          { fn: function(p) { return loadMonthly_(); } },
  'delete_contact':        { fn: function(p) { return deleteContact_(p); }, lock: true },
  'delete_venue':          { fn: function(p) { return deleteVenue_(p); }, lock: true },
  'cleanup_generic':       { fn: function(p) { return cleanupGenericEmails_(p); }, lock: true },
  'update_taste':          { fn: function(p) { return updateTaste_(p); }, lock: true },
  'save_skip_words':       { fn: function(p) { return saveSkipWords_(p); }, lock: true },
  'get_skip_words':        { fn: function(p) { return getSkipWords_(); } },
  'save_reviewed_reports': { fn: function(p) { return saveReviewedReports_(p); }, lock: true },
  'get_reviewed_reports':  { fn: function(p) { return getReviewedReports_(); } },
  'remap_contact_venue':   { fn: function(p) { return remapContactVenue_(p); }, lock: true },
  'find_by_domain':        { fn: function(p) { return findByDomain_(p); } },
  'save_discovery':        { fn: function(p) { return saveDiscovery_(p); }, lock: true },
  'load_discovery':        { fn: function(p) { return loadDiscovery_(); } },
  'save_check':            { fn: function(p) { return saveCheck_(p); }, lock: true },
  'save_step':             { fn: function(p) { return saveStep_(p); }, lock: true },
  'audit_pipeline':        { fn: function(p) { return auditPipeline_(); } },
  'fix_venue_ids':         { fn: function(p) { return fixDuplicateVenueIds_(p); }, lock: true },
  'fix_contact_ids':       { fn: function(p) { return fixDuplicateContactIds_(p); }, lock: true }
};

function healthResponse_() {
  return jsonResponse_({ status: 'ok', message: 'Gig Outreach API is live', version: BACKEND_VERSION, timestamp: new Date().toISOString() });
}

function doGet(e) {
  var params = (e && e.parameter) || {};
  var action = params.action || '';
  _jsonpCallback = params.callback || '';
  _lockHeld = false;

  try {
    if (!action || action === 'health') return healthResponse_();
    var route = ROUTES_.hasOwnProperty(action) ? ROUTES_[action] : null;
    if (!route) {
      return jsonResponse_({ status: 'error', message: 'Unknown action: ' + action, action: action, version: BACKEND_VERSION });
    }
    if (route.lock) return withLock_(function() { return route.fn(params); });
    return route.fn(params);
  } catch (err) {
    var msg = String((err && err.message) || err);
    var out = { status: 'error', message: msg, action: action, version: BACKEND_VERSION };
    if (msg.indexOf('LOCK_BUSY') === 0) out.busy = true;
    return jsonResponse_(out);
  }
}

// ---------------------------------------------------------------
// JSON response helper
// ---------------------------------------------------------------
function jsonResponse_(obj) {
  return jsonTextResponse_(JSON.stringify(obj));
}
function jsonTextResponse_(json) {
  if (_jsonpCallback) {
    return ContentService.createTextOutput(_jsonpCallback + '(' + json + ')')
      .setMimeType(ContentService.MimeType.JAVASCRIPT);
  }
  return ContentService.createTextOutput(json)
    .setMimeType(ContentService.MimeType.JSON);
}

// ---------------------------------------------------------------
// serveDashboardJSON_ — Main dashboard payload
// ---------------------------------------------------------------
// Dashboard helpers — each builds one slice of the dashboard payload
// ---------------------------------------------------------------

// Build outreach-sent lookup maps from the outreach log.
// Returns { form, ig, fb, formSkip, igSkip, fbSkip } keyed by venueId.
// *_skip channels are kept apart so a skip is never reported as a send.
function buildOutreachSentMaps_(outreachData) {
  var form = {}, ig = {}, fb = {}, formSkip = {}, igSkip = {}, fbSkip = {};
  for (var i = 1; i < outreachData.length; i++) {
    var chan = String(outreachData[i][3]);
    var vid = String(outreachData[i][1]);
    if (chan === 'contact_form') form[vid] = true;
    else if (chan === 'contact_form_skip') formSkip[vid] = true;
    else if (chan === 'instagram') ig[vid] = true;
    else if (chan === 'instagram_skip') igSkip[vid] = true;
    else if (chan === 'facebook') fb[vid] = true;
    else if (chan === 'facebook_skip') fbSkip[vid] = true;
  }
  return { form: form, ig: ig, fb: fb, formSkip: formSkip, igSkip: igSkip, fbSkip: fbSkip };
}

// Parse raw venue sheet rows into venue objects.
// sentMaps comes from buildOutreachSentMaps_. extras (optional) collects
// {tasteScored: {vid: true}} so builders can tell "unscored" from "scored 0".
// slim=true leaves out address/source/scraped_date (no dashboard caller reads them).
function buildVenues_(venueData, sentMaps, extras, slim) {
  var venues = [];
  var C = venueCols_(venueData[0] || []);
  var tasteScored = extras ? (extras.tasteScored = {}) : {};
  for (var i = 1; i < venueData.length; i++) {
    var row = venueData[i];
    if (!row[0]) continue;
    var vid = String(row[0]);
    var v = {
      venue_id:       vid,
      name:           String(cell_(row, C.name)),
      category:       String(cell_(row, C.category)),
      website:        String(cell_(row, C.website)),
      city:           String(cell_(row, C.city)),
      county:         String(cell_(row, C.county)),
      state:          String(cell_(row, C.state)),
      address:        String(cell_(row, C.address)),
      facebook:       String(cell_(row, C.facebook)),
      instagram:      String(cell_(row, C.instagram)),
      upscale_score:  Number(cell_(row, C.upscale_score)) || 3,
      zone_priority:  String(cell_(row, C.zone_priority)) || 'default',
      status:         String(cell_(row, C.status)) || 'needs_review',
      source:         String(cell_(row, C.source)),
      scraped_date:   isoDate_(cell_(row, C.scraped_date)),
      notes:          String(cell_(row, C.notes) || ''),
      distance_miles: cell_(row, C.distance_miles) ? Number(cell_(row, C.distance_miles)) : null,
      drive_minutes:  cell_(row, C.drive_minutes) ? Number(cell_(row, C.drive_minutes)) : null,
      contacted_date: isoDate_(cell_(row, C.contacted_date)),
      contact_form:   String(cell_(row, C.contact_form) || ''),
      linkedin_pending: String(cell_(row, C.linkedin_pending)).toLowerCase() === 'true',
      venue_vote:     String(cell_(row, C.venue_vote) || ''),
      venue_feedback: String(cell_(row, C.venue_feedback) || ''),
      check_status:   String(cell_(row, C.check_status) || ''),
      contact_form_sent: !!sentMaps.form[vid],
      ig_dm_sent: !!sentMaps.ig[vid],
      fb_msg_sent: !!sentMaps.fb[vid],
      contact_form_skipped: !!(sentMaps.formSkip && sentMaps.formSkip[vid]),
      ig_dm_skipped: !!(sentMaps.igSkip && sentMaps.igSkip[vid]),
      fb_msg_skipped: !!(sentMaps.fbSkip && sentMaps.fbSkip[vid])
    };
    if (slim) { delete v.address; delete v.source; delete v.scraped_date; }
    if (C.taste_score >= 0) {
      var ts = cell_(row, C.taste_score);
      v.taste_score = Number(ts) || 0;
      if (ts !== '' && ts !== null && !isNaN(Number(ts))) tasteScored[vid] = true;
    }
    if (C.priority_override >= 0) v.priority_override = Number(cell_(row, C.priority_override)) || 0;
    venues.push(v);
  }
  return venues;
}

// Parse raw contact sheet rows into contact objects.
function buildContacts_(contactData) {
  var contacts = [];
  for (var j = 1; j < contactData.length; j++) {
    var cr = contactData[j];
    if (!cr[0]) continue;
    contacts.push({
      contact_id:     String(cr[0]),
      venue_id:       String(cr[1]),
      name:           String(cr[2]),
      title:          String(cr[3]),
      email:          String(cr[4]),
      source:         String(cr[5]),
      verified:       String(cr[6]),
      verified_date:  isoDate_(cr[7]),
      email_sent:     sentFlag_(cr[8]),
      email_sent_date: isoDate_(cr[9]),
      ig_dm_sent:     String(cr[10]).toLowerCase() === 'true',
      fb_msg_sent:    String(cr[11]).toLowerCase() === 'true'
    });
  }
  return contacts;
}

// Group contacts into a map keyed by venue_id.
function groupContactsByVenue_(contacts) {
  var map = {};
  for (var c = 0; c < contacts.length; c++) {
    var vid = contacts[c].venue_id;
    if (!map[vid]) map[vid] = [];
    map[vid].push(contacts[c]);
  }
  return map;
}

// Calculate aggregate stats from venues and contacts.
// Only 'true' is a send: 'skipped' and 'sent_elsewhere' are not.
function getVenueStats_(venues, contacts) {
  var emailsSent = 0, igDmsSent = 0, fbMsgsSent = 0;
  var pendingEmails = 0, pendingVerify = 0;

  for (var k = 0; k < contacts.length; k++) {
    if (contacts[k].email_sent === 'true') emailsSent++;
    if (SENDABLE_VERIFIED[contacts[k].verified] && contacts[k].email && !contacts[k].email_sent) pendingEmails++;
    if (contacts[k].verified === 'pending') pendingVerify++;
  }
  for (var vv = 0; vv < venues.length; vv++) {
    if (venues[vv].ig_dm_sent) igDmsSent++;
    if (venues[vv].fb_msg_sent) fbMsgsSent++;
  }

  return {
    totalVenues: venues.length,
    totalContacts: contacts.length,
    emailsSent: emailsSent,
    igDmsSent: igDmsSent,
    fbMsgsSent: fbMsgsSent,
    pendingEmails: pendingEmails,
    pendingVerify: pendingVerify,
    totalOutreach: emailsSent + igDmsSent + fbMsgsSent
  };
}

// Tokens used to match a venue name against a past-gig name:
// "Cosmos Club DC" -> [cosmos, club]; "The Galley Restaurant & Bar" -> [galley, restaurant, bar].
var GIG_NAME_DROP_ = setOf_(['the', 'a', 'an', 'and', 'of', 'at', 'dc', 'md', 'va', 'pa', 'de', 'wv']);
function gigNameTokens_(name) {
  var s = String(name || '').toLowerCase();
  try { s = s.normalize('NFD').replace(/[\u0300-\u036f]/g, ''); } catch (e) {}
  s = s.replace(/['\u2019]/g, '').replace(/&/g, ' ').replace(/[^a-z0-9]+/g, ' ');
  return s.split(' ').filter(function(t) { return t && !GIG_NAME_DROP_[t]; });
}

// Equal token lists, or the shorter (>= 2 tokens, not all generic words)
// appears contiguously inside the longer one.
function gigNameMatches_(venueTokens, gigTokens) {
  if (!venueTokens.length || !gigTokens.length) return false;
  if (venueTokens.join(' ') === gigTokens.join(' ')) return true;
  var shorter = venueTokens.length <= gigTokens.length ? venueTokens : gigTokens;
  var longer = shorter === venueTokens ? gigTokens : venueTokens;
  if (shorter.length < 2) return false;
  if (shorter.every(function(t) { return GENERIC_VENUE_WORDS[t]; })) return false;
  var needle = ' ' + shorter.join(' ') + ' ';
  return (' ' + longer.join(' ') + ' ').indexOf(needle) !== -1;
}

function isDeletedGigName_(name) {
  return String(name || '').trim().toUpperCase() === '(DELETED)';
}

// Build the set of venue IDs AND name tokens that have a past gig logged.
// Past Gigs columns: gig_id, venue_id, venue_name, ... (venue_name is index 2).
// Returns { ids: {vid: true}, _nameTokens: [[tokens]], _namesList: [names] }
function getPastGigVenueIds_(ss) {
  var gigSheet = ss.getSheetByName(PAST_GIGS);
  var ids = {};
  var namesList = [];
  var nameTokens = [];
  if (gigSheet) {
    var gd = gigSheet.getDataRange().getValues();
    for (var pg = 1; pg < gd.length; pg++) {
      if (isDeletedGigName_(gd[pg][2])) continue;
      if (gd[pg][1]) ids[String(gd[pg][1])] = true;
      if (gd[pg][2]) {
        namesList.push(String(gd[pg][2]).toLowerCase().trim());
        var toks = gigNameTokens_(gd[pg][2]);
        if (toks.length) nameTokens.push(toks);
      }
    }
  }
  ids._namesList = namesList;
  ids._nameTokens = nameTokens;
  return ids;
}

function isPastGigVenue_(venue, pastGigVenueIds) {
  if (pastGigVenueIds[venue.venue_id]) return true;
  var vt = gigNameTokens_(venue.name);
  var list = pastGigVenueIds._nameTokens || [];
  for (var i = 0; i < list.length; i++) {
    if (gigNameMatches_(vt, list[i])) return true;
  }
  return false;
}

// =========================================================
// TOP PICK SCORE — separate from taste_score
// taste_score = "is this venue a good fit?" (general quality)
// top_pick_score = "of all good fits, which to chase first?"
//
// Formula: taste_score + priority bonuses - risk penalties
// Gate: a SCORED venue below TOP_PICK_MIN_TASTE (build_batch's MIN_TASTE_SCORE)
// or scored 0 (taste_score.py's hard disqualifier) is never a top pick.
// Unscored venues start from a neutral 50.
// priority_override = 1 forces venue to the top
// Returns {score, reasons} or {gated: reason}.
// =========================================================
var TOP_PICK_MIN_TASTE = 25;
var TOP_PICK_JUNK_WORDS = [
  'ice cream', 'gelato', 'frozen', 'toast', 'bakery', 'pastry',
  'slice', 'cupcake', 'smoothie', 'juice', 'bagel', 'donut',
  'cafe', 'coffee', 'deli', 'sandwich', 'pizza', 'taco', 'burger',
  'pub', 'irish', 'beer garden', 'sports bar', 'hookah',
  'sweets', 'candy', 'dessert', 'acai', 'poke', 'bubble tea',
  'chicken', 'ramen', 'noodle', 'kebab', 'gyro', 'sushi',
  'clubhouse', 'pool', 'swim', 'tennis', 'golf simulator',
  'recreation', 'liquor', 'wine shop', 'wine store', 'spirits'
];
// Affluent target areas — venues here get a location bonus
var TOP_PICK_AFFLUENT = setOf_([
  'georgetown', 'dupont circle', 'potomac', 'chevy chase', 'bethesda', 'great falls',
  'mclean', 'alexandria', 'middleburg', 'st. michaels', 'st michaels', 'easton',
  'gibson island', 'roland park', 'annapolis', 'vienna', 'falls church', 'leesburg'
]);

function scoreTopPick_(v, pendingEmails, tasteScored) {
  var cat = String(v.category || '').toLowerCase();
  var name = String(v.name || '').toLowerCase();
  // discover.sh appends 'Taste query: <query>' to notes; that's our own search text, not evidence.
  var notes = String(v.notes || '').toLowerCase().replace(/taste query:.*$/, '');
  var text = name + ' ' + notes;
  var vote = String(v.venue_vote || '');
  var tasteScore = Number(v.taste_score || 0);
  var scored = !!(tasteScored && tasteScored[v.venue_id]);
  var city = String(v.city || '').toLowerCase().trim();
  var reasons = [];

  if (vote === 'down') return { gated: 'downvoted' };
  if (scored && tasteScore < TOP_PICK_MIN_TASTE) return { gated: 'below taste threshold' };
  for (var nj = 0; nj < TOP_PICK_JUNK_WORDS.length; nj++) {
    if (name.indexOf(TOP_PICK_JUNK_WORDS[nj]) > -1) return { gated: 'junk venue type' };
  }

  var score = scored ? tasteScore : 50;
  reasons.push(scored ? 'taste:' + tasteScore : 'base:50 (unscored)');

  // --- PRIORITY BONUSES ---
  if (/private.?club|country.?club|university.?club|city.?club|yacht.?club/.test(cat) ||
      /country club|private club|yacht club|city club|university club|hunt club|metropolitan club|army navy/.test(text)) {
    score += 15; reasons.push('+15 club');
  }
  if (/live music|concert series|music program|live entertainment|recurring event|weekly music|jazz night/.test(text)) {
    score += 12; reasons.push('+12 live music/events');
  }
  if (/french|bistro|brasserie|boucherie|auberge|chez |provenc/.test(text)) {
    score += 10; reasons.push('+10 French');
  } else if (/trattoria|osteria|ristorante/.test(text)) {
    score += 10; reasons.push('+10 Italian fine');
  } else if (/wine bar|enoteca|vinoteca|wine program|sommelier/.test(text)) {
    score += 10; reasons.push('+10 wine-forward');
  }
  if (/luxury|five star|5.star|ritz.carlton|four seasons|rosewood|mandarin|st\.? regis|waldorf|fairmont|pendry|salamander/.test(text)) {
    score += 10; reasons.push('+10 luxury');
  } else if (/historic|colonial|victorian|manor|estate|mansion|chateau/.test(text)) {
    score += 10; reasons.push('+10 historic/estate');
  }
  if (TOP_PICK_AFFLUENT[city]) { score += 8; reasons.push('+8 affluent area'); }
  var hasDecisionMaker = false;
  for (var ci = 0; ci < pendingEmails.length; ci++) {
    var title = String(pendingEmails[ci].title || '').toLowerCase();
    if (/event|general manager|owner|director|manager|banquet|catering|private dining/.test(title)) {
      hasDecisionMaker = true; break;
    }
  }
  if (hasDecisionMaker) { score += 8; reasons.push('+8 decision maker'); }
  if (pendingEmails.length > 0) { score += 6; reasons.push('+6 has contact'); }
  if (/private event|event space|private dining|banquet|reception|wedding venue/.test(text)) {
    score += 5; reasons.push('+5 event evidence');
  }

  // --- RISK PENALTIES ---
  if (/founding farmers|cheesecake factory|capital grille|ruth.s chris|mortons|flemings/.test(name) ||
      /marriott|hilton|hyatt|holiday inn|best western|comfort inn|hampton inn/.test(name)) {
    score -= 15; reasons.push('-15 chain');
  }
  if (cat === 'unknown' || cat === 'other' || !cat) { score -= 15; reasons.push('-15 uncertain category'); }
  if (pendingEmails.length === 0 && !v.instagram && !v.facebook && !v.contact_form) {
    score -= 20; reasons.push('-20 no contacts');
  }
  if (/theater|theatre|bowling|arcade|gym|crossfit|karaoke|nightclub/.test(text)) {
    score -= 30; reasons.push('-30 wrong format');
  }
  if (vote === 'up') { score += 20; reasons.push('+20 thumbs up'); }
  var dist = v.distance_miles ? Number(v.distance_miles) : 50;
  var distBonus = Math.round(Math.max(0, Math.min(10, (80 - dist) / 8)));
  if (distBonus > 0) { score += distBonus; reasons.push('+' + distBonus + ' proximity'); }
  var vState = String(v.state || '').toUpperCase();
  if (vState === 'DC') { score += 5; reasons.push('+5 DC'); }
  else if (vState === 'VA' || vState === 'MD') { score += 3; reasons.push('+3 ' + vState); }
  if (v.priority_override === 1) { score += 500; reasons.push('+500 PRIORITY OVERRIDE'); }

  return { score: score, reasons: reasons };
}

function pendingEmailContacts_(vc) {
  var out = [];
  for (var cc = 0; cc < vc.length; cc++) {
    if (SENDABLE_VERIFIED[vc[cc].verified] && vc[cc].email && !vc[cc].email_sent) out.push(vc[cc]);
  }
  return out;
}

// Build and sort the action-needed list (pipelined venues with
// unsent emails, IG, or FB). Returns the full sorted array.
// Only 'pipelined' qualifies: needs_review/untouched/closed/contacted never do.
function buildActionNeeded_(venues, contactsByVenue, pastGigVenueIds, tasteScored) {
  var actionNeeded = [];

  for (var v = 0; v < venues.length; v++) {
    var venue = venues[v];
    if (venue.status !== 'pipelined') continue;
    if (isPastGigVenue_(venue, pastGigVenueIds)) continue;

    var vc = contactsByVenue[venue.venue_id] || [];
    var pendingEmails = pendingEmailContacts_(vc);
    var hasIg = venue.instagram && venue.instagram.length > 5;
    var hasFb = venue.facebook && venue.facebook.length > 5;
    var igDone = !!(venue.ig_dm_sent || venue.ig_dm_skipped);
    var fbDone = !!(venue.fb_msg_sent || venue.fb_msg_skipped);

    var needsAction = pendingEmails.length > 0 || (hasIg && !igDone) || (hasFb && !fbDone);
    if (!needsAction) continue;
    var item = {
      venue: venue,
      contacts: vc,
      pendingEmails: pendingEmails,
      igPending: hasIg && !igDone,
      fbPending: hasFb && !fbDone
    };
    var s = scoreTopPick_(venue, pendingEmails, tasteScored);
    if (s.gated) {
      item.top_pick_score = -1;
      item.top_pick_reasons = [s.gated];
    } else {
      item.top_pick_score = s.score;
      item.top_pick_reasons = s.reasons;
    }
    actionNeeded.push(item);
  }

  actionNeeded.sort(function(a, b) {
    return (b.top_pick_score || 0) - (a.top_pick_score || 0);
  });

  return actionNeeded;
}

// Top Picks: pipelined, in-area (DC/MD/VA) venues.
function buildTopPicks_(venues, contactsByVenue, pastGigVenueIds, tasteScored) {
  var results = [];

  for (var i = 0; i < venues.length; i++) {
    var venue = venues[i];
    if (venue.status !== 'pipelined') continue;
    if (TARGET_STATES.indexOf(String(venue.state || '').toUpperCase()) === -1) continue;
    if (isPastGigVenue_(venue, pastGigVenueIds)) continue;

    var vc = contactsByVenue[venue.venue_id] || [];
    var pendingEmails = pendingEmailContacts_(vc);
    var hasIg = venue.instagram && venue.instagram.length > 5 && !venue.ig_dm_sent && !venue.ig_dm_skipped;
    var hasFb = venue.facebook && venue.facebook.length > 5 && !venue.fb_msg_sent && !venue.fb_msg_skipped;

    var s = scoreTopPick_(venue, pendingEmails, tasteScored);
    if (s.gated || s.score <= 0) continue;

    results.push({
      venue: venue,
      contacts: vc,
      pendingEmails: pendingEmails,
      igPending: hasIg,
      fbPending: hasFb,
      top_pick_score: s.score,
      top_pick_reasons: s.reasons
    });
  }

  results.sort(function(a, b) { return (b.top_pick_score || 0) - (a.top_pick_score || 0); });
  // Cap at top 50 to keep response size reasonable
  return results.slice(0, 50);
}

// Build state and category breakdowns from the venues array.
function buildBreakdowns_(venues) {
  var stateBreakdown = {};
  var categoryBreakdown = {};

  for (var i = 0; i < venues.length; i++) {
    var v = venues[i];
    var st = v.state || 'Unknown';
    if (!stateBreakdown[st]) stateBreakdown[st] = { total: 0, contacted: 0, pending: 0 };
    // dismissed (Mark Done with nothing sent) is finished work, like contacted
    var done = v.status === 'contacted' || v.status === 'dismissed';
    stateBreakdown[st].total++;
    if (done) stateBreakdown[st].contacted++;
    else stateBreakdown[st].pending++;

    var cat = v.category || 'other';
    if (!categoryBreakdown[cat]) categoryBreakdown[cat] = { total: 0, contacted: 0, pending: 0 };
    categoryBreakdown[cat].total++;
    if (done) categoryBreakdown[cat].contacted++;
    else categoryBreakdown[cat].pending++;
  }

  return { state: stateBreakdown, category: categoryBreakdown };
}

// Return the last 20 outreach log entries (newest first).
function getRecentOutreach_(outreachData) {
  var recent = [];
  for (var ro = Math.max(1, outreachData.length - 20); ro < outreachData.length; ro++) {
    var r = outreachData[ro];
    if (!r[0]) continue;
    recent.push({
      timestamp: isoDate_(r[0]),
      venue_id: String(r[1]),
      contact_id: String(r[2]),
      channel: String(r[3]),
      template_used: String(r[4])
    });
  }
  recent.reverse();
  return recent;
}

// Load all past gigs as an array of gig objects.
function loadGigs_(ss) {
  var gigSheet = ss.getSheetByName(PAST_GIGS);
  var gigs = [];
  if (!gigSheet) return gigs;

  var gData = gigSheet.getDataRange().getValues();
  for (var gi = 1; gi < gData.length; gi++) {
    if (!gData[gi][0]) continue;
    gigs.push({
      gig_id: String(gData[gi][0]),
      venue_id: String(gData[gi][1]),
      venue_name: String(gData[gi][2]),
      date: String(gData[gi][3]),
      category: String(gData[gi][4]),
      rating_tips: Number(gData[gi][5]),
      rating_rebooked: Number(gData[gi][6]),
      rating_audience: Number(gData[gi][7]),
      rating_venue_quality: Number(gData[gi][8]),
      overall_score: Number(gData[gi][9]),
      notes: String(gData[gi][10] || '')
    });
  }
  return gigs;
}

// Calculate weekly + daily outreach counts from the outreach log.
function getOutreachCounts_(outreachData) {
  var now = new Date();
  var dayOfWeek = now.getDay();
  var mondayOffset = dayOfWeek === 0 ? -6 : 1 - dayOfWeek;
  var weekStart = new Date(now.getFullYear(), now.getMonth(), now.getDate() + mondayOffset);
  var todayStart = new Date(now.getFullYear(), now.getMonth(), now.getDate());
  var weekly = { email: 0, ig: 0, fb: 0 };
  var daily = { email: 0, ig: 0, fb: 0 };

  for (var oi = 1; oi < outreachData.length; oi++) {
    var oRow = outreachData[oi];
    if (!oRow[0]) continue;
    var oDate = new Date(oRow[0]);
    var oChan = String(oRow[3]);
    if (oDate >= weekStart) {
      if (oChan === 'email' || oChan === 'contact_form') weekly.email++;
      else if (oChan === 'instagram') weekly.ig++;
      else if (oChan === 'facebook') weekly.fb++;
    }
    if (oDate >= todayStart) {
      if (oChan === 'email' || oChan === 'contact_form') daily.email++;
      else if (oChan === 'instagram') daily.ig++;
      else if (oChan === 'facebook') daily.fb++;
    }
  }

  return { weekly: weekly, daily: daily };
}

// ---------------------------------------------------------------
// serveDashboardJSON_ — Assembles the dashboard payload.
// Default (slim): topPicks/actionNeeded/recentOutreach come back empty and
// venues omit address/source/scraped_date. No caller reads those (index.html,
// build_batch.sh, pipeline.sh, reverify.sh), and they were ~1.3MB of ~5.5MB.
// ?full=1 returns everything; ?picks=1 computes topPicks/actionNeeded only.
// The built JSON is cached (CacheService, gzip, chunked) until the next write
// or DASH_CACHE_TTL_S; ?nocache=1 bypasses it.
// ---------------------------------------------------------------
function serveDashboardJSON_(params) {
  params = params || {};
  var full = params.full === '1' || params.full === 'true';
  var picks = full || params.picks === '1' || params.picks === 'true';
  var cacheable = !full && !picks && params.nocache !== '1' && params.nocache !== 'true';

  if (cacheable) {
    var hit = readDashboardCache_();
    if (hit) return jsonTextResponse_(hit);
  }
  var gen0 = cacheable ? dashboardGen_(true) : '';

  var ss = SpreadsheetApp.getActiveSpreadsheet();

  // Load raw sheet data
  var venueSheet = ss.getSheetByName(VENUES);
  var venueData = venueSheet ? venueSheet.getDataRange().getValues() : [[]];

  var contactSheet = ss.getSheetByName(CONTACTS);
  var contactData = contactSheet ? contactSheet.getDataRange().getValues() : [[]];

  var outreachSheet = ss.getSheetByName(OUTREACH);
  var outreachData = outreachSheet ? outreachSheet.getDataRange().getValues() : [[]];

  // Transform raw data
  var sentMaps = buildOutreachSentMaps_(outreachData);
  var extras = {};
  var venues = buildVenues_(venueData, sentMaps, extras, !full);
  var contacts = buildContacts_(contactData);

  // Build each dashboard section
  var stats = getVenueStats_(venues, contacts);
  var actionNeeded = [], topPicks = [];
  if (picks) {
    var contactsByVenue = groupContactsByVenue_(contacts);
    var pastGigVenueIds = getPastGigVenueIds_(ss);
    actionNeeded = buildActionNeeded_(venues, contactsByVenue, pastGigVenueIds, extras.tasteScored);
    topPicks = buildTopPicks_(venues, contactsByVenue, pastGigVenueIds, extras.tasteScored);
  }
  var breakdowns = buildBreakdowns_(venues);
  var recentOutreach = full ? getRecentOutreach_(outreachData) : [];
  var gigs = loadGigs_(ss);
  var counts = getOutreachCounts_(outreachData);

  var json = JSON.stringify({
    status: 'ok',
    stats: stats,
    weeklyCounts: counts.weekly,
    dailyCounts: counts.daily,
    topPicks: topPicks,
    actionNeeded: actionNeeded,
    venues: venues,
    contacts: contacts,
    gigs: gigs,
    recentOutreach: recentOutreach,
    stateBreakdown: breakdowns.state,
    categoryBreakdown: breakdowns.category,
    generated_at: new Date().toISOString(),
    version: BACKEND_VERSION
  });
  // Only cache if no write landed while we were reading (the generation is unchanged).
  if (cacheable && gen0 && dashboardGen_(false) === gen0) writeDashboardCache_(gen0, json);
  return jsonTextResponse_(json);
}

// --- Dashboard cache ---------------------------------------------------
// dash_gen changes on every write (withLock_) and on manual sheet edits
// (onEdit); a cached build is served only while its generation is current.
// Any cache failure or eviction is just a miss.
var DASH_CACHE_TTL_S = 600;
var DASH_CHUNK_CHARS = 90000;   // base64 is ASCII; CacheService values max 100KB
var DASH_MAX_CHUNKS = 80;

function dashCache_() {
  try { return CacheService.getScriptCache(); } catch (e) { return null; }
}

function dashboardGen_(create) {
  var c = dashCache_();
  if (!c) return '';
  try {
    var g = c.get('dash_gen');
    if (!g && create) {
      g = String(Date.now()) + '.' + Math.floor(Math.random() * 1e9);
      c.put('dash_gen', g, 21600);
    }
    return g || '';
  } catch (e) { return ''; }
}

function invalidateDashboardCache_() {
  var c = dashCache_();
  if (!c) return;
  try { c.put('dash_gen', String(Date.now()) + '.' + Math.floor(Math.random() * 1e9), 21600); } catch (e) {}
}

function readDashboardCache_() {
  var c = dashCache_();
  if (!c) return null;
  try {
    var gen = c.get('dash_gen');
    var metaRaw = c.get('dash_meta');
    if (!gen || !metaRaw) return null;
    var meta = JSON.parse(metaRaw);
    if (!meta || meta.gen !== gen || !(meta.n > 0)) return null;
    var keys = [];
    for (var i = 0; i < meta.n; i++) keys.push('dash_' + meta.id + '_' + i);
    var got = c.getAll(keys);
    var parts = [];
    for (var k = 0; k < keys.length; k++) {
      if (got[keys[k]] === undefined || got[keys[k]] === null) return null;
      parts.push(got[keys[k]]);
    }
    var bytes = Utilities.base64Decode(parts.join(''));
    var json = Utilities.ungzip(Utilities.newBlob(bytes, 'application/x-gzip')).getDataAsString('UTF-8');
    return json && json.charAt(0) === '{' ? json : null;
  } catch (e) { return null; }
}

function writeDashboardCache_(gen, json) {
  var c = dashCache_();
  if (!c || !gen) return;
  try {
    var b64 = Utilities.base64Encode(Utilities.gzip(Utilities.newBlob(json, 'application/json')).getBytes());
    var n = Math.ceil(b64.length / DASH_CHUNK_CHARS);
    if (!n || n > DASH_MAX_CHUNKS) return;
    var id = String(Date.now()) + Math.floor(Math.random() * 1000);
    var vals = {};
    for (var i = 0; i < n; i++) vals['dash_' + id + '_' + i] = b64.substring(i * DASH_CHUNK_CHARS, (i + 1) * DASH_CHUNK_CHARS);
    c.putAll(vals, DASH_CACHE_TTL_S);
    c.put('dash_meta', JSON.stringify({ gen: gen, id: id, n: n }), DASH_CACHE_TTL_S);
  } catch (e) { /* cache is best-effort */ }
}

// Simple trigger: manual edits in the Sheet also invalidate the dashboard cache.
function onEdit(e) {
  invalidateDashboardCache_();
}

// Every venue column keyed by its header. The original 15 keys keep their
// old types/defaults; the rest are typed where the meaning is known.
var VENUE_NUMERIC_OR_NULL_ = setOf_(['distance_miles', 'drive_minutes', 'taste_score',
  'classification_confidence', 'location_confidence']);
var VENUE_DATE_COLS_ = setOf_(['scraped_date', 'contacted_date']);
function venueRowToObject_(headers, row, C) {
  var v = {};
  for (var h = 0; h < headers.length; h++) {
    var key = String(headers[h] || '').trim();
    if (!key) continue;
    var val = row[h];
    if (VENUE_DATE_COLS_[key]) v[key] = isoDate_(val);
    else if (VENUE_NUMERIC_OR_NULL_[key]) v[key] = (val === '' || val === null || isNaN(Number(val))) ? null : Number(val);
    else if (val instanceof Date) v[key] = isoDate_(val);
    else v[key] = String(val === null || val === undefined ? '' : val);
  }
  C = C || venueCols_(headers);
  v.venue_id = String(cell_(row, C.venue_id));
  v.name = String(cell_(row, C.name));
  v.category = String(cell_(row, C.category));
  v.website = String(cell_(row, C.website));
  v.city = String(cell_(row, C.city));
  v.county = String(cell_(row, C.county));
  v.state = String(cell_(row, C.state));
  v.facebook = String(cell_(row, C.facebook));
  v.instagram = String(cell_(row, C.instagram));
  v.upscale_score = Number(cell_(row, C.upscale_score)) || 3;
  v.zone_priority = String(cell_(row, C.zone_priority)) || 'default';
  v.status = String(cell_(row, C.status)) || 'needs_review';
  v.contact_form = String(cell_(row, C.contact_form) || '');
  v.linkedin_pending = String(cell_(row, C.linkedin_pending)).toLowerCase() === 'true';
  v.check_status = String(cell_(row, C.check_status) || '');
  if (C.priority_override >= 0) v.priority_override = Number(cell_(row, C.priority_override)) || 0;
  return v;
}

// ---------------------------------------------------------------
// serveVenuesJSON_ — Return filtered venues (every column, by header)
// Params: state, category, city, status, fields (optional comma list)
// ---------------------------------------------------------------
function serveVenuesJSON_(params) {
  var ss = SpreadsheetApp.getActiveSpreadsheet();
  var sheet = ss.getSheetByName(VENUES);
  var data = sheet.getDataRange().getValues();
  var headers = data[0] || [];
  var C = venueCols_(headers);

  var filterState = (params.state || '').toUpperCase();
  var filterCategory = (params.category || '').toLowerCase();
  var filterCity = (params.city || '').toLowerCase();
  var filterStatus = (params.status || '').toLowerCase();
  var fields = params.fields ? String(params.fields).split(',').map(function(f) { return f.trim(); }).filter(function(f) { return f; }) : null;

  var venues = [];
  for (var i = 1; i < data.length; i++) {
    var row = data[i];
    if (!row[0]) continue;
    if (filterState && String(cell_(row, C.state)).toUpperCase() !== filterState) continue;
    if (filterCategory && String(cell_(row, C.category)).toLowerCase() !== filterCategory) continue;
    if (filterCity && String(cell_(row, C.city)).toLowerCase().indexOf(filterCity) === -1) continue;
    if (filterStatus && (String(cell_(row, C.status)) || 'needs_review').toLowerCase() !== filterStatus) continue;

    var v = venueRowToObject_(headers, row, C);
    if (fields) {
      var slim = { venue_id: v.venue_id };
      for (var f = 0; f < fields.length; f++) if (v.hasOwnProperty(fields[f])) slim[fields[f]] = v[fields[f]];
      v = slim;
    }
    venues.push(v);
  }

  return jsonResponse_({ status: 'ok', venues: venues, count: venues.length });
}

// ---------------------------------------------------------------
// serveVenueDetail_ — Single venue with all its contacts
// Reads only the venue's row, the contacts' venue_id column + matching rows,
// and three Outreach Log columns (not three whole sheets).
// ---------------------------------------------------------------
function serveVenueDetail_(params) {
  var venueId = params.venue_id || '';
  if (!venueId) return jsonResponse_({ status: 'error', message: 'venue_id required' });

  var ss = SpreadsheetApp.getActiveSpreadsheet();

  var found = findVenueRow_(ss, venueId);
  if (!found) return jsonResponse_({ status: 'error', message: 'Venue not found' });
  var row = found.row, C = found.cols;
  var venue = {
    venue_id: String(row[0]), name: String(cell_(row, C.name)), category: String(cell_(row, C.category)),
    website: String(cell_(row, C.website)), city: String(cell_(row, C.city)), county: String(cell_(row, C.county)),
    state: String(cell_(row, C.state)), address: String(cell_(row, C.address)), facebook: String(cell_(row, C.facebook)),
    instagram: String(cell_(row, C.instagram)), upscale_score: Number(cell_(row, C.upscale_score)) || 3,
    zone_priority: String(cell_(row, C.zone_priority)) || 'default',
    status: String(cell_(row, C.status)) || 'needs_review',
    source: String(cell_(row, C.source)), notes: String(cell_(row, C.notes) || ''),
    contact_form: String(cell_(row, C.contact_form) || ''),
    linkedin_pending: String(cell_(row, C.linkedin_pending)).toLowerCase() === 'true',
    venue_vote: String(cell_(row, C.venue_vote) || ''),
    venue_feedback: String(cell_(row, C.venue_feedback) || ''),
    check_status: String(cell_(row, C.check_status) || ''),
    distance_miles: cell_(row, C.distance_miles) ? Number(cell_(row, C.distance_miles)) : null,
    drive_minutes: cell_(row, C.drive_minutes) ? Number(cell_(row, C.drive_minutes)) : null,
    scraped_date: isoDate_(cell_(row, C.scraped_date)),
    contacted_date: isoDate_(cell_(row, C.contacted_date))
  };
  if (C.taste_score >= 0) venue.taste_score = Number(cell_(row, C.taste_score)) || 0;
  if (C.priority_override >= 0) venue.priority_override = Number(cell_(row, C.priority_override)) || 0;
  if (C.taste_reasons >= 0) venue.taste_reasons = String(cell_(row, C.taste_reasons) || '');
  if (C.taste_score_version >= 0) venue.taste_score_version = String(cell_(row, C.taste_score_version) || '');
  if (C.classification_confidence >= 0) venue.classification_confidence = Number(cell_(row, C.classification_confidence)) || 0;
  if (C.location_confidence >= 0) venue.location_confidence = Number(cell_(row, C.location_confidence)) || 0;
  if (found.count > 1) venue.duplicate_id_rows = found.count;

  // Check outreach log for IG/FB/form sent (and skipped) status
  var oSheet = ss.getSheetByName(OUTREACH);
  var oLast = oSheet ? oSheet.getLastRow() : 0;
  var oData = oLast >= 2 ? oSheet.getRange(2, 2, oLast - 1, 3).getValues() : [];
  for (var ol = 0; ol < oData.length; ol++) {
    if (String(oData[ol][0]) !== venueId) continue;
    var ch = String(oData[ol][2]);
    if (ch === 'instagram') venue.ig_dm_sent = true;
    else if (ch === 'instagram_skip') venue.ig_dm_skipped = true;
    else if (ch === 'facebook') venue.fb_msg_sent = true;
    else if (ch === 'facebook_skip') venue.fb_msg_skipped = true;
    else if (ch === 'contact_form') venue.contact_form_sent = true;
    else if (ch === 'contact_form_skip') venue.contact_form_skipped = true;
  }

  // Find contacts
  var cSheet = ss.getSheetByName(CONTACTS);
  var cRows = findRowsByColumn_(cSheet, 2, venueId);
  var cRowData = readRows_(cSheet, cRows, 12);
  var contacts = [];
  for (var j = 0; j < cRows.length; j++) {
    var cr = cRowData[cRows[j]];
    contacts.push({
      contact_id: String(cr[0]), name: String(cr[2]),
      title: String(cr[3]), email: String(cr[4]),
      source: String(cr[5]), verified: String(cr[6]),
      verified_date: isoDate_(cr[7]),
      email_sent: sentFlag_(cr[8]),
      email_sent_date: isoDate_(cr[9]),
      ig_dm_sent: (String(cr[10]).toLowerCase() === 'true' || String(cr[10]).toLowerCase() === 'skipped') ? String(cr[10]).toLowerCase() : false,
      fb_msg_sent: (String(cr[11]).toLowerCase() === 'true' || String(cr[11]).toLowerCase() === 'skipped') ? String(cr[11]).toLowerCase() : false
    });
  }

  return jsonResponse_({ status: 'ok', venue: venue, contacts: contacts });
}

// ---------------------------------------------------------------
// addVenue_ — Add a new venue (called by scraper / discovery)
// New venues default to needs_review (policy P4). Duplicates (same normalized
// name + city, or same own website domain) are a no-op: status and fields of
// the existing row are never touched. Response keeps 'Duplicate' in message
// (discover.sh greps for it) and adds duplicate:true.
// ---------------------------------------------------------------
function normVenueName_(s) {
  var n = String(s || '').toLowerCase();
  try { n = n.normalize('NFD').replace(/[\u0300-\u036f]/g, ''); } catch (e) {}
  n = n.replace(/['\u2019]/g, '').replace(/&/g, ' and ').replace(/[^a-z0-9]+/g, ' ').trim();
  return n.replace(/^the /, '');
}
function normCity_(s) {
  return String(s || '').toLowerCase().replace(/[^a-z0-9]+/g, ' ').trim();
}
function websitePath_(url) {
  var s = String(url || '').trim().toLowerCase().replace(/^[a-z][a-z0-9+.-]*:\/\//, '').replace(/^\/\//, '');
  var slash = s.indexOf('/');
  if (slash === -1) return '';
  return s.substring(slash).split(/[?#]/)[0].replace(/\/+$/, '').replace(/\/index\.(html?|php)$/, '');
}

// Returns null or {venue_id, status, matched_on} for the first duplicate.
function findDuplicateVenue_(data, C, name, city, state, website) {
  var nName = normVenueName_(name), nCity = normCity_(city), st = String(state || '').toUpperCase().trim();
  var dom = venueOwnDomain_(website);
  if (dom && SHARED_BRAND_DOMAINS[dom]) dom = '';
  var path = dom ? websitePath_(website) : '';
  for (var i = 1; i < data.length; i++) {
    var row = data[i];
    if (!row[0]) continue;
    if (nName && normVenueName_(cell_(row, C.name)) === nName) {
      var eCity = normCity_(cell_(row, C.city));
      var eState = String(cell_(row, C.state) || '').toUpperCase().trim();
      if (eCity === nCity || (!eCity && !nCity) ||
          ((!eCity || !nCity) && st && eState === st)) {
        return { venue_id: String(row[0]), status: String(cell_(row, C.status)), matched_on: 'name_city' };
      }
    }
    if (dom) {
      var eWeb = String(cell_(row, C.website) || '');
      if (eWeb && venueOwnDomain_(eWeb) === dom) {
        var ePath = websitePath_(eWeb);
        if (!path || !ePath || path.indexOf(ePath) === 0 || ePath.indexOf(path) === 0) {
          return { venue_id: String(row[0]), status: String(cell_(row, C.status)), matched_on: 'domain' };
        }
      }
    }
  }
  return null;
}

// Geocode only a real location: never the bare venue name (it resolves to a
// same-named place elsewhere). Returns {miles, mins} or null.
function driveDistance_(dest) {
  if (!dest) return null;
  try {
    var directions = Maps.newDirectionFinder()
      .setOrigin(HOME_ADDRESS)
      .setDestination(dest)
      .setMode(Maps.DirectionFinder.Mode.DRIVING)
      .getDirections();
    if (directions.routes && directions.routes.length > 0) {
      var leg = directions.routes[0].legs[0];
      return { miles: Math.round(leg.distance.value / 1609.34 * 10) / 10, mins: Math.round(leg.duration.value / 60) };
    }
  } catch (e) { /* Distance calc failed — run calc_distances later */ }
  return null;
}
function venueDestination_(address, city, state, name) {
  var addr = String(address || '').trim();
  if (addr && addr !== 'undefined') {
    var addrKey = normVenueName_(addr.replace(/,\s*[A-Za-z]{2}\s*$/, ''));
    if (addrKey && addrKey !== normVenueName_(name)) return addr;
  }
  if (String(city || '').trim()) return String(city).trim() + ', ' + String(state || '').trim();
  return '';
}

var ADD_VENUE_EXTRA_COLS_ = ['taste_score', 'taste_score_version', 'taste_reasons',
  'classification_confidence', 'location_confidence', 'contact_form'];

function addVenue_(params) {
  var ss = SpreadsheetApp.getActiveSpreadsheet();
  var sheet = ss.getSheetByName(VENUES);

  var name = String(params.name || '').trim();
  if (!name) return jsonResponse_({ status: 'error', reason: 'name_required', message: 'name required' });
  var status = String(params.status || 'needs_review').trim().toLowerCase();
  if (!VENUE_STATUSES[status]) {
    return jsonResponse_({ status: 'error', reason: 'invalid_status', message: 'Invalid status: ' + params.status });
  }
  var category = String(params.category || '').trim() || 'other';
  var state = String(params.state || '').trim().toUpperCase();
  var address = String(params.address || '').trim();
  // discover.sh sends address=<venue name> when it has no location.
  if (address && normVenueName_(address.replace(/,\s*[A-Za-z]{2}\s*$/, '')) === normVenueName_(name)) address = '';

  // Cheap pre-check so duplicates don't cost a Maps call.
  var data = sheet.getDataRange().getValues();
  var C = venueCols_(data[0] || []);
  var dup = findDuplicateVenue_(data, C, name, params.city, state, params.website);
  if (dup) {
    return jsonResponse_({ status: 'ok', message: 'Duplicate — skipped', duplicate: true, created: false,
      venue_id: dup.venue_id, existing_status: dup.status, matched_on: dup.matched_on });
  }

  var dist = driveDistance_(venueDestination_(address, params.city, state, name));

  var result = withLock_(function() {
    var data2 = sheet.getDataRange().getValues();
    var headers = data2[0] || [];
    var C2 = venueCols_(headers);
    var dup2 = findDuplicateVenue_(data2, C2, name, params.city, state, params.website);
    if (dup2) {
      return { status: 'ok', message: 'Duplicate — skipped', duplicate: true, created: false,
        venue_id: dup2.venue_id, existing_status: dup2.status, matched_on: dup2.matched_on };
    }

    // Generate venue_id — max numeric suffix for this prefix (and the stored
    // high-water mark, so a deleted top ID is never handed out again) + 1
    var prefix = (state || 'XX') + '-' + (params.category || 'OTHER').toUpperCase().substring(0, 4) + '-';
    var maxNum = 0;
    var existingIds = {};
    for (var j = 1; j < data2.length; j++) {
      var existingId = String(data2[j][0]);
      existingIds[existingId] = true;
      if (existingId.indexOf(prefix) === 0) {
        var num = parseInt(existingId.substring(prefix.length), 10);
        if (!isNaN(num) && num > maxNum) maxNum = num;
      }
    }
    var venueId;
    if (params.venue_id) {
      if (existingIds[String(params.venue_id)]) {
        return { status: 'error', reason: 'venue_id_exists', message: 'venue_id already exists: ' + params.venue_id, created: false };
      }
      venueId = String(params.venue_id);
    } else {
      venueId = prefix + String(nextSeq_('seq_venue_' + prefix, maxNum)).padStart(3, '0');
    }

    var values = {
      venue_id: venueId,
      name: name,
      category: category,
      website: params.website || '',
      city: params.city || '',
      county: params.county || '',
      state: state,
      address: address,
      facebook: params.facebook || '',
      instagram: params.instagram || '',
      upscale_score: Number(params.upscale_score) || 3,
      zone_priority: params.zone_priority || 'default',
      status: status,
      source: params.source || '',
      scraped_date: new Date(),
      notes: params.notes || '',
      distance_miles: dist ? dist.miles : '',
      drive_minutes: dist ? dist.mins : '',
      contacted_date: '',
      contact_form: '',
      linkedin_pending: false,
      venue_vote: '',
      venue_feedback: '',
      check_status: ''
    };
    for (var x = 0; x < ADD_VENUE_EXTRA_COLS_.length; x++) {
      var k = ADD_VENUE_EXTRA_COLS_[x];
      if (params[k] !== undefined && params[k] !== '') values[k] = params[k];
    }
    if (values.taste_score !== undefined && !isNaN(Number(values.taste_score))) values.taste_score = Number(values.taste_score);

    var width = Math.max(headers.length, 24);
    var newRow = [];
    for (var w = 0; w < width; w++) newRow.push('');
    for (var key in values) {
      var idx = C2[key];
      if (idx === undefined || idx < 0) continue;
      newRow[idx] = safeCell_(values[key]);
    }
    sheet.appendRow(newRow);
    return { status: 'ok', venue_id: venueId, name: name, created: true, duplicate: false, venue_status: status };
  });

  return jsonResponse_(result);
}

// ---------------------------------------------------------------
// addContact_ — Add a contact for a venue (called by scraper/pipeline)
//
// Server-side backstop for the save policy (outreach_rules.py is the primary):
//  - email normalized; junk/placeholder and hard-reject mailboxes refused
//  - off-domain (not the venue website's domain, not free-mail) refused unless
//    allow_off_domain=true
//  - dedupe: an email already on ANY venue is a duplicate (never copied to a
//    second venue); email-less contacts dedupe on (venue_id, normalized name)
//  - verified defaults to 'unverified' (email) / 'pending' (no email); never 'valid'
//  - names that are masked (***), contain digits, are role words or equal the
//    email local part are dropped (saved with an empty name) when an email is
//    present; an email-less contact needs a real first + last name
// Responses always carry created:true|false; duplicates add duplicate:true.
// ---------------------------------------------------------------
function prepareContact_(ss, params) {
  var rawEmail = String(params.email == null ? '' : params.email).trim();
  if (/^(none|null|undefined|n\/a)$/i.test(rawEmail)) rawEmail = '';
  var email = '';
  if (rawEmail) {
    email = normalizeEmail_(rawEmail);
    if (!email) return { error: 'Invalid email: ' + rawEmail, reason: 'malformed' };
    var junk = junkEmailReason_(email);
    if (junk) return { error: 'Rejected junk/placeholder email: ' + email, reason: junk };
    var hard = hardRejectReason_(email);
    if (hard) return { error: 'Rejected non-contact mailbox: ' + email, reason: hard };
  }

  var venueId = String(params.venue_id || '').trim();
  if (!venueId) return { error: 'venue_id required', reason: 'no_venue_id' };
  var venue = findVenueRow_(ss, venueId);
  // A stale or mistyped ID must not create orphan contacts.
  if (!venue) return { error: 'Venue not found: ' + venueId, reason: 'venue_not_found' };
  var venueDomain = venueOwnDomain_(cell_(venue.row, venue.cols.website));
  if (email && params.allow_off_domain !== 'true') {
    var off = offDomainReason_(email, venueDomain);
    if (off) return { error: 'Rejected off-domain email ' + email + ' (venue website domain ' + venueDomain + '). Pass allow_off_domain=true if verified by hand.', reason: off };
  }

  var isRole = params.is_generic === 'true' || (email ? isRoleEmail_(email) : false);
  var rawName = tidyName_(params.name);
  var name = '', nameRejected = '';
  if (rawName) {
    nameRejected = nameProblem_(rawName, email);
    if (!nameRejected) name = cleanPersonName_(rawName);
  }
  if (!email) {
    if (!rawName) return { error: 'Contact must have a name or an email.', reason: 'name:empty' };
    if (nameRejected) return { error: 'Contact name "' + rawName + '" is not a real first and last name (' + nameRejected + ').', reason: 'name:' + nameRejected };
  }
  // Policy P1: a role mailbox is only a contact when a real person is attached,
  // except one-person mailboxes (chef@, owner@, gm@...) off brand domains.
  if (email && isRole && !name && !(PERSON_ROLE_LOCALS_[email.split('@')[0].replace(/[^a-z]/g, '')] &&
      !SHARED_BRAND_DOMAINS[registrableDomain_(email.split('@')[1])])) {
    return { error: 'Role mailbox ' + email + ' needs a real person name attached; keep it as a candidate instead.',
             reason: 'role_without_name', nameRejected: nameRejected };
  }

  var verified = normalizeVerified_(params.verified, !!email);
  // Role mailboxes never go to ZeroBounce, so "valid"/"unverified" mean role here.
  if (email && isRole && ROLE_VERIFIED_OVERRIDE_[verified]) verified = 'role';

  return {
    venueId: venueId,
    venueFound: true,
    venueIdRows: venue.count,
    venueNeedsDistance: !cell_(venue.row, venue.cols.distance_miles),
    email: email,
    name: name,
    nameRejected: nameRejected,
    title: cleanTitle_(params.title),
    source: String(params.source || 'website'),
    verified: verified,
    verifiedInput: String(params.verified || ''),
    isRole: isRole
  };
}
var ROLE_VERIFIED_OVERRIDE_ = setOf_(['valid', 'unverified', 'pending', 'deferred', 'role']);

// Must run under withLock_. Returns a plain response object.
function insertContactLocked_(sheet, c) {
  var data = sheet.getDataRange().getValues();
  var nameKey = normPersonName_(c.name);
  for (var i = 1; i < data.length; i++) {
    var rowVenue = String(data[i][1]);
    if (c.email) {
      var rowEmail = normalizeEmail_(data[i][4]) || String(data[i][4]).trim().toLowerCase();
      if (rowEmail !== c.email) continue;
      var same = rowVenue === c.venueId;
      return {
        status: 'ok', created: false, duplicate: true,
        message: same ? 'Duplicate contact — skipped'
                      : 'Duplicate contact — skipped (email already on venue ' + rowVenue + ')',
        contact_id: String(data[i][0]), existing_venue_id: rowVenue, email: c.email
      };
    } else if (rowVenue === c.venueId && nameKey && normPersonName_(data[i][2]) === nameKey) {
      return {
        status: 'ok', created: false, duplicate: true,
        message: 'Duplicate contact — skipped (same name at this venue)',
        contact_id: String(data[i][0]), existing_venue_id: rowVenue, email: String(data[i][4])
      };
    }
  }

  var contactId = nextContactId_(data);
  sheet.appendRow([
    contactId,
    safeCell_(c.venueId),
    safeCell_(c.name),
    safeCell_(c.title),
    c.email,
    safeCell_(c.source),
    c.verified,
    new Date(),
    false,  // email_sent
    '',     // email_sent_date
    false,  // ig_dm_sent
    false   // fb_msg_sent
  ]);

  // Read-after-write: we hold the lock, so the last row is ours.
  SpreadsheetApp.flush();
  var lastRow = sheet.getLastRow();
  var persisted = sheet.getRange(lastRow, 1, 1, 7).getValues()[0];
  var out = {
    status: 'ok',
    created: true,
    duplicate: false,
    contact_id: contactId,
    email: c.email,
    persisted_name: String(persisted[2]),
    persisted_email: String(persisted[4]),
    verified: String(persisted[0]) === contactId,
    verified_status: String(persisted[6]),
    is_role: c.isRole
  };
  if (c.nameRejected) out.name_rejected = c.nameRejected;
  if (c.verifiedInput && c.verifiedInput.toLowerCase() !== c.verified) out.verified_input = c.verifiedInput;
  if (c.venueIdRows > 1) out.venue_id_rows = c.venueIdRows;
  return out;
}

// Every refusal names its reason so callers can log the address as a candidate.
function contactErrorResponse_(c) {
  var out = { status: 'error', created: false, message: c.error, reason: c.reason };
  if (c.nameRejected) out.name_rejected = c.nameRejected;
  return out;
}

function addContact_(params) {
  var ss = SpreadsheetApp.getActiveSpreadsheet();
  var sheet = ss.getSheetByName(CONTACTS);

  var c = prepareContact_(ss, params);
  if (c.error) return jsonResponse_(contactErrorResponse_(c));

  var result = withLock_(function() { return insertContactLocked_(sheet, c); });

  // Safety net: fill a missing venue distance (Maps call happens outside the lock).
  if (result.created && c.venueNeedsDistance) {
    try { calcDistanceForVenue_(c.venueId); } catch (e) {}
  }
  return jsonResponse_(result);
}

// ---------------------------------------------------------------
// updateVenue_ — Update a venue field
// Params: venue_id, field, value, force (social evidence), overwrite (socials)
// ---------------------------------------------------------------
var FB_NON_PAGE_RE_ = /^\/(sharer|sharer\.php|share\.php|share|groups|people|events|hashtag|watch|login|login\.php|dialog|plugins|photo\.php|story\.php|permalink\.php|search)(\/|\?|$)/;
var IG_NON_PAGE_RE_ = /^\/(p|reel|reels|explore|stories|accounts|tv|direct)(\/|\?|$)/;

function socialKey_(u) {
  return String(u || '').toLowerCase().replace(/^https?:\/\//, '').replace(/^\/\//, '')
    .replace(/^(www\.|m\.|web\.)/, '').replace(/[?#].*$/, '').replace(/\/+$/, '');
}

// '' if the social URL is plausibly this venue's own page; else why not.
// brandOnly=true returns only the checks that force=true can't bypass.
function socialProblem_(field, value, venueName, venueWebsite, brandOnly) {
  var v = String(value).toLowerCase();
  var host = registrableDomain_(v);
  if (field === 'facebook' && ['facebook.com', 'fb.com', 'fb.me'].indexOf(host) === -1) return 'not a facebook.com URL';
  if (field === 'instagram' && ['instagram.com', 'instagr.am'].indexOf(host) === -1) return 'not an instagram.com URL';
  var path = v.replace(/^[a-z]+:\/\//, '').replace(/^\/\//, '').replace(/^[^\/]*/, '');
  if (field === 'facebook') {
    // New-style Pages without a username live at /people/<Name>/<numeric id>/ (like profile.php?id=)
    if (FB_NON_PAGE_RE_.test(path) && !/^\/people\/[^\/?#]+\/\d{6,}(\/|\?|#|$)/.test(path)) return 'not a page URL (' + path + ')';
    if (/profile\.php/.test(path) && !/[?&]id=\d+/.test(v)) return 'bare profile.php without id';
  }
  if (field === 'instagram' && IG_NON_PAGE_RE_.test(path)) return 'not a profile URL (' + path + ')';

  var slug = socialKey_(v).split('/').pop().replace(/[^a-z0-9]/g, '');
  var ownDom = venueOwnDomain_(venueWebsite);
  var shared = !!(ownDom && SHARED_BRAND_DOMAINS[ownDom]);
  var label = ownDom ? ownDom.split('.')[0] : '';
  if (shared && slug && new RegExp('^' + label + '(hotels?|resorts?|clubs?|official|us|usa|global)?$').test(slug)) {
    return 'brand/chain handle "' + slug + '" is not the property\'s own page';
  }
  if (brandOnly) return '';

  // Distinctive name words only: "winery"/"restaurant"/"club" match half the internet.
  var words = normVenueName_(venueName).split(' ').filter(function(w) {
    return w.length >= 3 && !GENERIC_VENUE_WORDS[w];
  });
  var slugMatchesName = words.some(function(w) { return slug.indexOf(w) !== -1; });
  var slugMatchesDomain = !shared && label.length >= 4 && slug.indexOf(label) !== -1;
  var compact = normVenueName_(venueName).replace(/ /g, '');
  var nameMatchesSlug = compact.length >= 5 && slug && (slug.indexOf(compact) !== -1 || (slug.length >= 6 && compact.indexOf(slug) !== -1));
  if (!slugMatchesName && !slugMatchesDomain && !nameMatchesSlug) {
    return 'slug "' + slug + '" does not match venue name "' + venueName + '" or domain "' + (label || '') + '"';
  }
  return '';
}

// Worked venues must not silently go back into the batch pool (P4, PROC-11):
// a re-sweep's "add_venue then status=untouched" would otherwise un-contact them.
// contacted -> pipelined (PWA "un-mark done") stays allowed: it clears nothing.
var STATUS_DEMOTIONS_ = {
  'contacted': ['untouched', 'needs_review'],
  'dismissed': ['untouched', 'needs_review'],
  'pipelined': ['untouched', 'needs_review'],
  'closed': ['untouched', 'pipelined']
};

function updateVenue_(params) {
  var venueId = params.venue_id || '';
  var field = params.field || '';
  var value = params.value || '';
  if (!venueId || !field) return jsonResponse_({ status: 'error', message: 'venue_id and field required' });

  var ss = SpreadsheetApp.getActiveSpreadsheet();
  var sheet = ss.getSheetByName(VENUES);
  var headers = sheet.getRange(1, 1, 1, sheet.getLastColumn()).getValues()[0];

  // Find column index by header name (case/underscore-insensitive)
  var colIdx = -1;
  for (var h = 0; h < headers.length; h++) {
    if (normHeader_(headers[h]) === normHeader_(field)) { colIdx = h; break; }
  }
  if (colIdx === -1) return jsonResponse_({ status: 'error', message: 'Unknown field: ' + field });
  var canon = normHeader_(field);
  if (canon === 'venueid') {
    return jsonResponse_({ status: 'error', message: 'venue_id is the primary key and cannot be changed with update_venue' });
  }

  var found = findVenueRow_(ss, venueId);
  if (!found) return jsonResponse_({ status: 'error', reason: 'venue_not_found', message: 'Venue not found: ' + venueId });
  var row = found.row, C = found.cols;

  // Validate website updates — reject garbage URLs
  if (canon === 'website' && value) {
    // Reject favicon/image URLs
    if (/\.(ico|png|jpg|jpeg|gif|svg|css|js)(\?|$)/i.test(value)) {
      return jsonResponse_({ status: 'error', reason: 'website_invalid', message: 'Rejected website update — looks like an asset URL: ' + value });
    }
    // Reject pipe-separated junk (multiple URLs crammed together)
    if (value.indexOf('|') !== -1) {
      return jsonResponse_({ status: 'error', reason: 'website_invalid', message: 'Rejected website update — contains pipe characters: ' + value });
    }
    // Reject obvious non-venue URLs
    var reg = registrableDomain_(value);
    if (NON_VENUE_HOSTS[reg] || WEBSITE_JUNK_DOMAINS[reg]) {
      return jsonResponse_({ status: 'error', reason: 'website_invalid', message: 'Rejected website update — junk domain: ' + value });
    }
  }

  // Validate social URLs (policy P7)
  if ((canon === 'facebook' || canon === 'instagram') && value) {
    if (value.indexOf('http') !== 0 && value.indexOf('//') !== 0) {
      return jsonResponse_({ status: 'error', reason: 'social_invalid', message: canon + ' must be a full URL (got: ' + value + ')' });
    }
    var vName = String(cell_(row, C.name) || '');
    var vWebsite = String(cell_(row, C.website) || '');
    var hard = socialProblem_(canon, value, vName, vWebsite, true);
    if (hard) return jsonResponse_({ status: 'error', reason: 'social_invalid', message: canon + ' rejected: ' + hard });
    // P7: an existing, different social link is never replaced implicitly
    // (force only overrides the name/domain evidence check).
    var existing = String(cell_(row, colIdx) || '').trim();
    if (existing && socialKey_(existing) !== socialKey_(value) && params.overwrite !== 'true') {
      return jsonResponse_({
        status: 'error', reason: 'social_exists',
        message: canon + ' already set to ' + existing + '; not replaced. Pass overwrite=true to replace it.',
        existing: existing
      });
    }
    if (params.force !== 'true') {
      var soft = socialProblem_(canon, value, vName, vWebsite, false);
      if (soft) {
        var ownDom = venueOwnDomain_(vWebsite);
        return jsonResponse_({
          status: 'error', reason: 'social_mismatch',
          message: canon + ' URL ' + soft + '. Pass force=true to override.',
          venue_name: vName,
          venue_domain: ownDom ? ownDom.split('.')[0] : '',
          social_slug: socialKey_(value).split('/').pop().replace(/[^a-z0-9]/g, '')
        });
      }
    }
  }

  // Status: fixed vocabulary, and no silent demotion of worked venues (P4).
  var newStatus = '';
  if (canon === 'status') {
    newStatus = String(value).trim().toLowerCase();
    if (!VENUE_STATUSES[newStatus]) {
      return jsonResponse_({ status: 'error', reason: 'invalid_status', message: 'Invalid status: ' + value + '. Allowed: ' + Object.keys(VENUE_STATUSES).join(', ') });
    }
    var oldStatus = String(cell_(row, C.status) || '').trim().toLowerCase();
    var guarded = STATUS_DEMOTIONS_[oldStatus];
    if (guarded && guarded.indexOf(newStatus) !== -1 && params.force !== 'true') {
      return jsonResponse_({
        status: 'error', reason: 'status_demotion',
        message: 'Refusing to change status ' + oldStatus + ' -> ' + newStatus + ' without force=true',
        current_status: oldStatus
      });
    }
    value = newStatus;
  }

  var r = found.rowNum;
  sheet.getRange(r, colIdx + 1).setValue(safeCell_(value));
  // Stamp contacted_date when marking as contacted, clear when resetting
  if (canon === 'status' && C.contacted_date >= 0) {
    if (newStatus === 'contacted') sheet.getRange(r, C.contacted_date + 1).setValue(new Date());
    else if (newStatus === 'untouched') sheet.getRange(r, C.contacted_date + 1).setValue('');
  }
  // Read-after-write: confirm the value persisted
  SpreadsheetApp.flush();
  var persisted = String(sheet.getRange(r, colIdx + 1).getValue());
  var resp = {
    status: 'ok', venue_id: venueId, field: field,
    value: value, persisted: persisted,
    verified: persisted === value
  };
  if (found.count > 1) resp.ambiguous_rows = found.count;
  return jsonResponse_(resp);
}

// ---------------------------------------------------------------
// updateContact_ — Update a contact field
// Params: contact_id, venue_id (recommended), email (disambiguates
// duplicate contact_ids), field, value
// ---------------------------------------------------------------
// Rows (0-based data indexes) matching id [+ venue] [+ email].
function matchContactRows_(data, contactId, venueId, email) {
  var rows = [];
  for (var i = 1; i < data.length; i++) {
    if (String(data[i][0]) !== contactId) continue;
    if (venueId && String(data[i][1]) !== venueId) continue;
    rows.push(i);
  }
  if (rows.length > 1 && email) {
    var e = normalizeEmail_(email) || String(email).toLowerCase().trim();
    var narrowed = rows.filter(function(i) { return (normalizeEmail_(data[i][4]) || String(data[i][4]).toLowerCase().trim()) === e; });
    if (narrowed.length) rows = narrowed;
  }
  return rows;
}

function updateContact_(params) {
  var contactId = params.contact_id || '';
  var venueId = params.venue_id || '';
  var field = params.field || '';
  var value = params.value || '';
  if (!contactId || !field) return jsonResponse_({ status: 'error', message: 'contact_id and field required' });

  var ss = SpreadsheetApp.getActiveSpreadsheet();
  var sheet = ss.getSheetByName(CONTACTS);
  var data = sheet.getDataRange().getValues();

  // Column mapping
  var fieldMap = {
    'venue_id': 1, 'email_sent': 8, 'email_sent_date': 9, 'ig_dm_sent': 10, 'fb_msg_sent': 11,
    'verified': 6, 'verified_date': 7, 'name': 2, 'title': 3, 'email': 4
  };

  var colIdx = fieldMap.hasOwnProperty(field) ? fieldMap[field] : undefined;
  if (colIdx === undefined) return jsonResponse_({ status: 'error', message: 'Unknown field: ' + field });

  var rows = matchContactRows_(data, contactId, venueId, params.email);
  if (!rows.length) return jsonResponse_({ status: 'error', message: 'Contact not found: ' + contactId });
  // Duplicate contact IDs exist in the sheet (even at one venue): never guess which person is meant.
  if (rows.length > 1) {
    return jsonResponse_({
      status: 'error', ambiguous: true, reason: 'ambiguous_contact_id',
      message: 'Ambiguous contact_id ' + contactId + ' (' + rows.length + ' rows). Pass venue_id and email.',
      matches: rows.map(function(r) { return { venue_id: String(data[r][1]), name: String(data[r][2]), email: String(data[r][4]) }; })
    });
  }
  var i = rows[0];

  if (field === 'email_sent' || field === 'ig_dm_sent' || field === 'fb_msg_sent') {
    if (value === 'skipped' || (field === 'email_sent' && value === 'sent_elsewhere')) {
      sheet.getRange(i + 1, colIdx + 1).setValue(value);
    } else {
      sheet.getRange(i + 1, colIdx + 1).setValue(value === 'true');
    }
    // Also set date if marking as sent
    if (value === 'true' && field === 'email_sent') {
      sheet.getRange(i + 1, 10).setValue(new Date()); // email_sent_date
    }
  } else if (field === 'verified') {
    var hasEmail = !!String(data[i][4] || '').trim();
    value = normalizeVerified_(value, hasEmail);
    sheet.getRange(i + 1, colIdx + 1).setValue(value);
  } else if (field === 'email') {
    // Same gates as add_contact (P1): junk, hard-reject and off-domain addresses never land.
    if (value) {
      var e = normalizeEmail_(value);
      var why = e ? (junkEmailReason_(e) || hardRejectReason_(e)) : 'malformed';
      if (!why && params.allow_off_domain !== 'true') {
        var fv = findVenueRow_(ss, String(data[i][1]));
        why = fv ? offDomainReason_(e, venueOwnDomain_(cell_(fv.row, fv.cols.website))) : '';
      }
      if (why) return jsonResponse_({ status: 'error', reason: why, message: 'Rejected email ' + value + ' (' + why + ')' });
      value = e;
    }
    sheet.getRange(i + 1, colIdx + 1).setValue(value);
  } else if (field === 'name') {
    if (value) {
      var problem = nameProblem_(value, normalizeEmail_(data[i][4]));
      if (problem) return jsonResponse_({ status: 'error', reason: 'name:' + problem, message: 'Name "' + value + '" is not a real first and last name (' + problem + ')' });
      value = cleanPersonName_(value);
    }
    sheet.getRange(i + 1, colIdx + 1).setValue(safeCell_(value));
  } else if (field === 'venue_id') {
    if (!findVenueRow_(ss, value)) return jsonResponse_({ status: 'error', reason: 'venue_not_found', message: 'Venue not found: ' + value });
    sheet.getRange(i + 1, colIdx + 1).setValue(safeCell_(value));
  } else if (field === 'title') {
    value = cleanTitle_(value);
    sheet.getRange(i + 1, colIdx + 1).setValue(safeCell_(value));
  } else {
    sheet.getRange(i + 1, colIdx + 1).setValue(safeCell_(value));
  }

  return jsonResponse_({ status: 'ok', contact_id: contactId, field: field, value: value });
}

// ---------------------------------------------------------------
// deleteContact_ — Delete a contact row by contact_id
// Pass venue_id (and email) when the ID is duplicated; an ambiguous
// ID is refused instead of deleting whichever row comes first.
// ---------------------------------------------------------------
function deleteContact_(params) {
  var contactId = params.contact_id || '';
  if (!contactId) return jsonResponse_({ status: 'error', message: 'contact_id required' });

  var ss = SpreadsheetApp.getActiveSpreadsheet();
  var sheet = ss.getSheetByName(CONTACTS);
  var data = sheet.getDataRange().getValues();

  var rows = matchContactRows_(data, contactId, params.venue_id || '', params.email);
  if (!rows.length) return jsonResponse_({ status: 'error', message: 'Contact not found: ' + contactId });
  if (rows.length > 1) {
    return jsonResponse_({
      status: 'error', ambiguous: true,
      message: 'Ambiguous contact_id ' + contactId + ' matches ' + rows.length + ' rows; pass venue_id and email',
      matches: rows.map(function(i) { return { venue_id: String(data[i][1]), name: String(data[i][2]), email: String(data[i][4]) }; })
    });
  }
  var i = rows[0];
  var venueId = String(data[i][1]);
  retireId_('seq_contact', contactId);
  sheet.deleteRow(i + 1);
  return jsonResponse_({ status: 'ok', deleted: contactId, venue_id: venueId });
}

// ---------------------------------------------------------------
// fixDuplicateContactIds_ — Re-number contacts with duplicate IDs
// (?action=fix_contact_ids). Dry run unless confirm=yes. Keeps the first
// occurrence; later rows get fresh IDs. Outreach Log rows are moved to the
// new ID when (contact_id, venue_id) identifies the renumbered row.
// ---------------------------------------------------------------
function fixDuplicateContactIds_(params) {
  params = params || {};
  var apply = params.confirm === 'yes';
  var ss = SpreadsheetApp.getActiveSpreadsheet();
  var sheet = ss.getSheetByName(CONTACTS);
  var data = sheet.getDataRange().getValues();
  var seen = {};
  var max = 0;

  // First pass: find max ID and track which IDs exist
  for (var i = 1; i < data.length; i++) {
    var id = String(data[i][0]);
    if (id.startsWith('C-')) {
      var num = parseInt(id.substring(2), 10);
      if (!isNaN(num) && num > max) max = num;
      if (seen[id]) {
        seen[id].push(i);
      } else {
        seen[id] = [i];
      }
    }
  }

  var renames = [];
  var next = Math.max(max, peekSeq_('seq_contact'));
  for (var dupId in seen) {
    if (seen[dupId].length <= 1) continue;
    var keptVenue = String(data[seen[dupId][0]][1]);
    for (var j = 1; j < seen[dupId].length; j++) {
      next++;
      var rowIdx = seen[dupId][j];
      var rowVenue = String(data[rowIdx][1]);
      renames.push({
        old_id: dupId, new_id: 'C-' + String(next).padStart(3, '0'), row: rowIdx + 1,
        venue_id: rowVenue, name: String(data[rowIdx][2]), email: String(data[rowIdx][4]),
        // Same venue as the kept row: outreach history can't be told apart.
        outreach_remappable: rowVenue !== keptVenue && seen[dupId].filter(function(r) { return String(data[r][1]) === rowVenue; }).length === 1
      });
    }
  }

  var outreachMoved = 0;
  if (apply && renames.length) {
    for (var k = 0; k < renames.length; k++) sheet.getRange(renames[k].row, 1).setValue(renames[k].new_id);
    setSeq_('seq_contact', next);
    var oSheet = ss.getSheetByName(OUTREACH);
    var oData = oSheet ? oSheet.getDataRange().getValues() : [[]];
    var moveKey = {};
    renames.forEach(function(rn) { if (rn.outreach_remappable) moveKey[rn.old_id + '|' + rn.venue_id] = rn.new_id; });
    for (var o = 1; o < oData.length; o++) {
      var mk = String(oData[o][2]) + '|' + String(oData[o][1]);
      if (moveKey[mk]) { oSheet.getRange(o + 1, 3).setValue(moveKey[mk]); outreachMoved++; }
    }
  }

  return jsonResponse_({ status: 'ok', dry_run: !apply, fixed: apply ? renames.length : 0,
    would_fix: renames.length, new_max: next, outreach_rows_moved: outreachMoved,
    renames: renames.slice(0, 200) });
}

// ---------------------------------------------------------------
// fixDuplicateVenueIds_ — Find venue IDs shared by multiple venues and give
// the later rows unique IDs (?action=fix_venue_ids). Dry run unless
// confirm=yes. Contacts, Outreach Log and Past Gigs are remapped in the same
// run, but only when the evidence is unambiguous:
//  - a contact moves when its email domain is the renamed venue's own website
//    domain and not the kept venue's; everything else is listed as unresolved
//  - outreach rows follow their moved contact; past gigs move on a name match
// ---------------------------------------------------------------
function fixDuplicateVenueIds_(params) {
  params = params || {};
  var apply = params.confirm === 'yes';
  var ss = SpreadsheetApp.getActiveSpreadsheet();
  var vSheet = ss.getSheetByName(VENUES);
  var vData = vSheet.getDataRange().getValues();
  var C = venueCols_(vData[0] || []);
  var cSheet = ss.getSheetByName(CONTACTS);
  var cData = cSheet.getDataRange().getValues();

  // Track all IDs and their row indices (0-based, skip header)
  var seen = {};      // id -> [row indices]
  var maxByPrefix = {};  // prefix -> max number

  for (var i = 1; i < vData.length; i++) {
    var id = String(vData[i][0]).trim();
    if (!id) continue;
    // Parse prefix and number
    var lastDash = id.lastIndexOf('-');
    if (lastDash === -1) continue;
    var pfx = id.substring(0, lastDash + 1);
    var num = parseInt(id.substring(lastDash + 1), 10);
    if (!isNaN(num)) {
      if (!maxByPrefix[pfx] || num > maxByPrefix[pfx]) {
        maxByPrefix[pfx] = num;
      }
    }
    if (!seen[id]) seen[id] = [];
    seen[id].push(i);
  }

  var renames = [];  // [{oldId, newId, row, name}]
  var touchedPrefixes = {};
  var contactMoves = [];   // {row, contact_id, from, to}
  var unresolved = [];     // contacts we can't attribute

  for (var oid in seen) {
    if (seen[oid].length <= 1) continue;
    // Keep first occurrence, reassign the rest
    var lastDash2 = oid.lastIndexOf('-');
    var pfx2 = oid.substring(0, lastDash2 + 1);
    var keptDom = venueOwnDomain_(cell_(vData[seen[oid][0]], C.website));
    var group = [];
    for (var j = 1; j < seen[oid].length; j++) {
      var rowIdx = seen[oid][j];
      var n = Math.max(maxByPrefix[pfx2] || 0, peekSeq_('seq_venue_' + pfx2)) + 1;
      maxByPrefix[pfx2] = n;
      touchedPrefixes[pfx2] = n;
      var newId = pfx2 + String(n).padStart(3, '0');
      var rn = { oldId: oid, newId: newId, row: rowIdx + 1, name: String(vData[rowIdx][1]),
                 domain: venueOwnDomain_(cell_(vData[rowIdx], C.website)) };
      renames.push(rn);
      group.push(rn);
    }
    for (var c = 1; c < cData.length; c++) {
      if (String(cData[c][1]).trim() !== oid) continue;
      var eReg = registrableDomain_(String(cData[c][4]).split('@')[1] || '');
      var targets = group.filter(function(g) { return g.domain && g.domain === eReg; });
      if (targets.length === 1 && eReg !== keptDom) {
        contactMoves.push({ row: c + 1, contact_id: String(cData[c][0]), from: oid, to: targets[0].newId });
      } else if (!(keptDom && eReg === keptDom)) {
        unresolved.push({ contact_id: String(cData[c][0]), venue_id: oid, email: String(cData[c][4]) });
      }
    }
  }

  var outreachMoved = 0, gigsMoved = 0;
  if (apply) {
    renames.forEach(function(rn) { vSheet.getRange(rn.row, 1).setValue(rn.newId); });
    for (var tp in touchedPrefixes) setSeq_('seq_venue_' + tp, touchedPrefixes[tp]);
    contactMoves.forEach(function(m) { cSheet.getRange(m.row, 2).setValue(m.to); });
    var moved = {};
    contactMoves.forEach(function(m) { moved[m.contact_id + '|' + m.from] = m.to; });
    var oSheet = ss.getSheetByName(OUTREACH);
    var oData = oSheet ? oSheet.getDataRange().getValues() : [[]];
    for (var o = 1; o < oData.length; o++) {
      var key = String(oData[o][2]) + '|' + String(oData[o][1]);
      if (moved[key]) { oSheet.getRange(o + 1, 2).setValue(moved[key]); outreachMoved++; }
    }
    var gSheet = ss.getSheetByName(PAST_GIGS);
    var gData = gSheet ? gSheet.getDataRange().getValues() : [[]];
    for (var g = 1; g < gData.length; g++) {
      var gVid = String(gData[g][1]);
      var match = renames.filter(function(rn) {
        return rn.oldId === gVid && gigNameMatches_(gigNameTokens_(rn.name), gigNameTokens_(gData[g][2]));
      });
      if (match.length === 1) { gSheet.getRange(g + 1, 2).setValue(match[0].newId); gigsMoved++; }
    }
  }

  return jsonResponse_({
    status: 'ok',
    dry_run: !apply,
    fixed: apply ? renames.length : 0,
    would_fix: renames.length,
    renames: renames.slice(0, 50),  // Return first 50 for logging
    contacts_moved: apply ? contactMoves.length : 0,
    contact_moves: contactMoves.slice(0, 200),
    unresolved_contacts: unresolved.slice(0, 200),
    outreach_rows_moved: outreachMoved,
    gigs_moved: gigsMoved
  });
}

// ---------------------------------------------------------------
// cleanupGenericEmails_ — Report (and optionally delete) contacts whose
// address must never be in the sheet: junk/placeholder addresses and
// hard-reject mailboxes (noreply, privacy, careers...). Role mailboxes
// (info@, events@...) are policy-approved venue contacts: they're only
// counted, never deleted. Dry run unless confirm=yes; emailed rows are kept.
// ---------------------------------------------------------------
function cleanupGenericEmails_(params) {
  params = params || {};
  var apply = params.confirm === 'yes';
  var ss = SpreadsheetApp.getActiveSpreadsheet();
  var sheet = ss.getSheetByName(CONTACTS);
  var data = sheet.getDataRange().getValues();
  var candidates = [];
  var roleCount = 0;

  for (var i = data.length - 1; i >= 1; i--) {
    var raw = String(data[i][4] || '').trim();
    if (!raw || /^(none|null|undefined)$/i.test(raw)) continue;
    var e = normalizeEmail_(raw);
    var reason = e ? (junkEmailReason_(e) || hardRejectReason_(e)) : 'malformed';
    if (!reason) {
      if (isRoleEmail_(e)) roleCount++;
      continue;
    }
    if (sentFlag_(data[i][8]) === 'true') continue;  // keep outreach history
    candidates.push({ row: i + 1, contact_id: String(data[i][0]), venue_id: String(data[i][1]), email: raw, reason: reason });
  }

  if (apply) {
    // candidates are in descending row order, so deleting doesn't shift the rest
    for (var d = 0; d < candidates.length; d++) sheet.deleteRow(candidates[d].row);
  }

  return jsonResponse_({
    status: 'ok',
    dry_run: !apply,
    deletedCount: apply ? candidates.length : 0,
    deletedContacts: apply ? candidates.map(function(c) { return c.contact_id; }) : [],
    candidates: candidates.slice(0, 500),
    candidate_count: candidates.length,
    role_mailboxes_kept: roleCount
  });
}

// ---------------------------------------------------------------
// deleteVenue_ — Delete a venue and all its contacts
// Outreach Log / Past Gigs rows are kept as history; IDs are never reused
// (high-water mark), so they can't attach to a future venue.
// ---------------------------------------------------------------
function deleteVenue_(params) {
  var venueId = params.venue_id || '';
  if (!venueId) return jsonResponse_({ status: 'error', message: 'venue_id required' });

  var ss = SpreadsheetApp.getActiveSpreadsheet();
  var vSheet = ss.getSheetByName(VENUES);
  var vRows = findRowsByColumn_(vSheet, 1, venueId);
  if (!vRows.length) return jsonResponse_({ status: 'error', message: 'Venue not found: ' + venueId });
  if (vRows.length > 1) {
    return jsonResponse_({ status: 'error', ambiguous: true,
      message: 'venue_id ' + venueId + ' is on ' + vRows.length + ' rows; run fix_venue_ids first' });
  }

  // Delete all contacts for this venue (iterate backwards to avoid row shift)
  var cSheet = ss.getSheetByName(CONTACTS);
  var cRows = findRowsByColumn_(cSheet, 2, venueId);
  var cIds = readRows_(cSheet, cRows, 1);
  for (var r in cIds) retireId_('seq_contact', cIds[r][0]);
  for (var c = cRows.length - 1; c >= 0; c--) cSheet.deleteRow(cRows[c]);

  retireId_('seq_venue_' + venueId.substring(0, venueId.lastIndexOf('-') + 1), venueId);
  vSheet.deleteRow(vRows[0]);
  return jsonResponse_({ status: 'ok', deleted: venueId, contacts_deleted: cRows.length });
}

// ---------------------------------------------------------------
// updateContactEmail_ — Update email for a contact matched by name + venue_id
// Used by Apollo enrichment to add emails to LinkedIn-discovered contacts
// Params: venue_id, name, email, verified, source, title, force
// An existing, different email is only replaced with force=true. When no
// contact matches, the new contact goes through add_contact's validation.
// ---------------------------------------------------------------
function updateContactEmail_(params) {
  // reverify.sh historically sent {contact_id, field, value} here.
  if (!params.name && params.contact_id && params.field) return updateContact_(params);

  var venueId = params.venue_id || '';
  var name = params.name || '';
  if (!venueId || !name) return jsonResponse_({ status: 'error', message: 'venue_id and name required' });

  var ss = SpreadsheetApp.getActiveSpreadsheet();
  var sheet = ss.getSheetByName(CONTACTS);

  var c = prepareContact_(ss, {
    venue_id: venueId, name: name, email: params.email, title: params.title,
    source: params.source || 'apollo+linkedin', verified: params.verified,
    allow_off_domain: params.allow_off_domain, is_generic: params.is_generic
  });
  // Email problems are always fatal. A name problem (only possible with no
  // email) still allows updating an existing row matched by that name.
  if (c.error && String(c.reason).indexOf('name:') !== 0) return jsonResponse_(contactErrorResponse_(c));
  var email = c.error ? '' : c.email;

  var data = sheet.getDataRange().getValues();
  var nameKey = normPersonName_(name);
  for (var i = 1; i < data.length; i++) {
    if (String(data[i][1]) !== venueId) continue;
    if (!nameKey || normPersonName_(data[i][2]) !== nameKey) continue;

    var current = normalizeEmail_(data[i][4]) || String(data[i][4] || '').trim().toLowerCase();
    if (email && current && current !== email && params.force !== 'true') {
      return jsonResponse_({ status: 'error', contact_id: String(data[i][0]), existing_email: current,
        reason: 'has_different_email', message: 'Contact already has a different email; pass force=true to replace it' });
    }
    if (email && current !== email) {
      for (var d = 1; d < data.length; d++) {
        if (d !== i && (normalizeEmail_(data[d][4]) || '') === email) {
          return jsonResponse_({ status: 'ok', duplicate: true, created: false, updated: false,
            contact_id: String(data[d][0]), existing_venue_id: String(data[d][1]), email: email,
            message: 'Duplicate contact — email already on ' + String(data[d][0]) });
        }
      }
    }

    // Update email
    if (email) sheet.getRange(i + 1, 5).setValue(email);
    // Update source if provided
    if (params.source) sheet.getRange(i + 1, 6).setValue(safeCell_(params.source));
    // Update verified status. A newly attached email never keeps 'pending'.
    var newVerified = '';
    if (params.verified) newVerified = email ? c.verified : normalizeVerified_(params.verified, !!current);
    else if (email && email !== current) newVerified = c.verified;
    if (newVerified) {
      sheet.getRange(i + 1, 7).setValue(newVerified);
      sheet.getRange(i + 1, 8).setValue(new Date());
    }

    var upd = { status: 'ok', contact_id: String(data[i][0]), email: email, updated: true, created: false };
    if (newVerified) upd.verified_status = newVerified;
    return jsonResponse_(upd);
  }

  // If not found by name, create a new contact (same rules as add_contact)
  if (c.error) return jsonResponse_(contactErrorResponse_(c));
  var res = insertContactLocked_(sheet, c);
  res.updated = false;
  return jsonResponse_(res);
}

// ---------------------------------------------------------------
// logOutreach_ — Record an outreach action
// An email send also marks every OTHER row holding the same address
// (duplicate rows on other venues) as email_sent='sent_elsewhere', so the
// same person isn't queued again from another venue.
// ---------------------------------------------------------------
function logOutreach_(params) {
  var ss = SpreadsheetApp.getActiveSpreadsheet();
  var sheet = ss.getSheetByName(OUTREACH);

  sheet.appendRow([
    new Date(),
    params.venue_id || '',
    params.contact_id || '',
    params.channel || 'email',
    safeCell_(params.template_used || '')
  ]);

  // Increment total counter in Config
  var counterKey = 'total_' + (params.channel || 'email') + 's_sent';
  if (params.channel === 'email') counterKey = 'total_emails_sent';
  if (params.channel === 'instagram') counterKey = 'total_ig_dms';
  if (params.channel === 'facebook') counterKey = 'total_fb_msgs';

  var current = parseInt(getConfig_(counterKey)) || 0;
  setConfig_(counterKey, current + 1);

  var propagated = 0;
  if ((params.channel || 'email') === 'email' && params.contact_id) {
    var cSheet = ss.getSheetByName(CONTACTS);
    var cData = cSheet.getDataRange().getValues();
    var sentEmail = '';
    var sentRows = {};
    var rows = matchContactRows_(cData, String(params.contact_id), params.venue_id || '', '');
    if (rows.length === 1) {
      sentEmail = normalizeEmail_(cData[rows[0]][4]);
      sentRows[rows[0]] = true;
    }
    if (sentEmail) {
      for (var i = 1; i < cData.length; i++) {
        if (sentRows[i]) continue;
        if ((normalizeEmail_(cData[i][4]) || '') !== sentEmail) continue;
        if (sentFlag_(cData[i][8])) continue;
        cSheet.getRange(i + 1, 9).setValue('sent_elsewhere');
        cSheet.getRange(i + 1, 10).setValue(new Date());
        propagated++;
      }
    }
  }

  return jsonResponse_({ status: 'ok', logged: true, propagated: propagated });
}

// ---------------------------------------------------------------
// serveTemplates_ — Return all email templates
// ---------------------------------------------------------------
function serveTemplates_() {
  var ss = SpreadsheetApp.getActiveSpreadsheet();
  var sheet = ss.getSheetByName(TEMPLATES);
  var data = sheet.getDataRange().getValues();

  var templates = {};
  for (var i = 1; i < data.length; i++) {
    if (!data[i][0]) continue;
    templates[String(data[i][0]).toLowerCase()] = {
      category: String(data[i][0]),
      subject: String(data[i][1]),
      body: String(data[i][2])
    };
  }

  return jsonResponse_({ status: 'ok', templates: templates });
}

// ---------------------------------------------------------------
// serveStats_ — Return detailed statistics
// ---------------------------------------------------------------
function serveStats_() {
  var ss = SpreadsheetApp.getActiveSpreadsheet();
  var sheet = ss.getSheetByName(OUTREACH);
  var data = sheet.getDataRange().getValues();

  var byChannel = {};
  var byDate = {};

  for (var i = 1; i < data.length; i++) {
    var ch = String(data[i][3]) || 'unknown';
    byChannel[ch] = (byChannel[ch] || 0) + 1;
    var d = data[i][0] ? new Date(data[i][0]) : null;
    var dt = (d && !isNaN(d.getTime())) ? Utilities.formatDate(d, Session.getScriptTimeZone(), 'yyyy-MM-dd') : '';
    if (dt) byDate[dt] = (byDate[dt] || 0) + 1;
  }

  return jsonResponse_({
    status: 'ok',
    totalOutreach: data.length - 1,
    byChannel: byChannel,
    byDate: byDate
  });
}

// ---------------------------------------------------------------
// serveConfig_ — Return all config values
// ---------------------------------------------------------------
function serveConfig_() {
  var ss = SpreadsheetApp.getActiveSpreadsheet();
  var sheet = ss.getSheetByName(CONFIG);
  var data = sheet.getDataRange().getValues();

  var config = {};
  for (var i = 0; i < data.length; i++) {
    if (data[i][0]) config[String(data[i][0])] = data[i][1];
  }

  return jsonResponse_({ status: 'ok', config: config });
}

// ---------------------------------------------------------------
// Helper: get config value by label
// Config tab layout: Column A = label, Column B = value
// ---------------------------------------------------------------
function getConfig_(label) {
  var ss    = SpreadsheetApp.getActiveSpreadsheet();
  var sheet = ss.getSheetByName(CONFIG);
  var data  = sheet.getDataRange().getValues();
  for (var i = 0; i < data.length; i++) {
    if (String(data[i][0]).toLowerCase() === label.toLowerCase()) return data[i][1];
  }
  return null;
}

// ---------------------------------------------------------------
// Helper: set config value by label (upsert)
// ---------------------------------------------------------------
function setConfig_(label, value) {
  var ss    = SpreadsheetApp.getActiveSpreadsheet();
  var sheet = ss.getSheetByName(CONFIG);
  var data  = sheet.getDataRange().getValues();
  for (var i = 0; i < data.length; i++) {
    if (String(data[i][0]).toLowerCase() === label.toLowerCase()) {
      sheet.getRange(i + 1, 2).setValue(value);
      return;
    }
  }
  sheet.appendRow([label, value]);
}

// ---------------------------------------------------------------
// saveSkipWords_ / getSkipWords_ — Sync title skip words from app
// Stored as JSON array in Config tab under "skip_words"
// ---------------------------------------------------------------
function saveSkipWords_(params) {
  var words = params.words || '[]';
  setConfig_('skip_words', words);
  return jsonResponse_({ status: 'ok' });
}

function getSkipWords_() {
  var raw = getConfig_('skip_words');
  var words = [];
  try { words = JSON.parse(raw || '[]'); } catch(e) {}
  return jsonResponse_({ status: 'ok', words: words });
}

function saveReviewedReports_(params) {
  var data = params.data || '{}';
  setConfig_('reviewed_reports', data);
  return jsonResponse_({ status: 'ok' });
}

function getReviewedReports_() {
  var raw = getConfig_('reviewed_reports');
  var data = {};
  try { data = JSON.parse(raw || '{}'); } catch(e) {}
  return jsonResponse_({ status: 'ok', reviewed: data });
}

// ---------------------------------------------------------------
// calcDistanceForVenue_ — Calculate distance for a single venue if missing
// Called automatically by addContact_ as a safety net. The Maps call runs
// outside the lock; the write re-finds the row by ID under the lock.
// ---------------------------------------------------------------
function calcDistanceForVenue_(venueId) {
  if (!venueId) return;
  var ss = SpreadsheetApp.getActiveSpreadsheet();
  var found = findVenueRow_(ss, venueId);
  if (!found) return;
  var row = found.row, C = found.cols;
  if (C.distance_miles < 0 || cell_(row, C.distance_miles)) return; // already has distance

  var dist = driveDistance_(venueDestination_(cell_(row, C.address), cell_(row, C.city),
                                              cell_(row, C.state), cell_(row, C.name)));
  if (!dist) return;
  withLock_(function() {
    var again = findVenueRow_(ss, venueId);
    if (!again || cell_(again.row, C.distance_miles)) return;
    again.sheet.getRange(again.rowNum, C.distance_miles + 1).setValue(dist.miles);
    if (C.drive_minutes >= 0) again.sheet.getRange(again.rowNum, C.drive_minutes + 1).setValue(dist.mins);
  });
}

// ---------------------------------------------------------------
// calcDistances_ — Calculate driving distance from home to each venue
// Uses Google Maps Directions (built-in, free in Apps Script).
// Stores results in the distance_miles / drive_minutes columns.
// Only calculates for venues missing distance data and with a real location
// (address or city); stops after a time budget so the 6-minute limit isn't
// hit mid-write. Re-run to continue (see 'remaining').
// ---------------------------------------------------------------
var HOME_ADDRESS = 'Dero Drive, Pasadena, MD 21122';
var CALC_DISTANCES_BUDGET_MS = 240000;

function calcDistances_() {
  var started = Date.now();
  var ss = SpreadsheetApp.getActiveSpreadsheet();
  var sheet = ss.getSheetByName(VENUES);
  var data = sheet.getDataRange().getValues();
  var C = venueCols_(data[0] || []);
  var results = [];
  var errors = [];
  var remaining = 0, skippedNoLocation = 0;
  var timedOut = false;

  for (var i = 1; i < data.length; i++) {
    if (!data[i][0]) continue;
    // Skip if already calculated
    if (cell_(data[i], C.distance_miles)) continue;
    var dest = venueDestination_(cell_(data[i], C.address), cell_(data[i], C.city),
                                 cell_(data[i], C.state), cell_(data[i], C.name));
    if (!dest) { skippedNoLocation++; continue; }
    if (timedOut || Date.now() - started > CALC_DISTANCES_BUDGET_MS) { timedOut = true; remaining++; continue; }

    var dist = driveDistance_(dest);
    if (dist) results.push({ venue_id: String(data[i][0]), miles: dist.miles, mins: dist.mins });
    else errors.push(String(cell_(data[i], C.name)) + ': no route for ' + dest);

    // Rate limit — Apps Script Maps has quotas
    Utilities.sleep(200);
  }

  var calculated = 0;
  if (results.length) {
    calculated = withLock_(function() {
      var ids = sheet.getRange(1, 1, sheet.getLastRow(), 1).getValues();
      var rowOf = {};
      for (var r = 1; r < ids.length; r++) {
        var id = String(ids[r][0]);
        if (rowOf[id] === undefined) rowOf[id] = r + 1;
      }
      var n = 0;
      for (var k = 0; k < results.length; k++) {
        var rowNum = rowOf[results[k].venue_id];
        if (!rowNum) continue;
        sheet.getRange(rowNum, C.distance_miles + 1).setValue(results[k].miles);
        if (C.drive_minutes >= 0) sheet.getRange(rowNum, C.drive_minutes + 1).setValue(results[k].mins);
        n++;
      }
      return n;
    });
  }

  return jsonResponse_({
    status: 'ok',
    calculated: calculated,
    errors: errors,
    remaining: remaining,
    timed_out: timedOut,
    skipped_no_location: skippedNoLocation
  });
}

// ---------------------------------------------------------------
// keepAlive — Prevents cold start timeouts
// Set up: Triggers → Add → keepAlive → Time-driven → Every 5 minutes
// ---------------------------------------------------------------
function keepAlive() {
  var ss = SpreadsheetApp.getActiveSpreadsheet();
  ss.getSheetByName(CONFIG);
}

// ---------------------------------------------------------------
// addGig_ — Add a past gig with ratings
// Params: venue_name, date, category, rating_tips, rating_rebooked,
//         rating_audience, rating_venue_quality, notes, venue_id (optional)
// ---------------------------------------------------------------
function addGig_(params) {
  var ss = SpreadsheetApp.getActiveSpreadsheet();
  var sheet = ss.getSheetByName(PAST_GIGS);
  if (!sheet) return jsonResponse_({ status: 'error', message: 'Past Gigs sheet not found. Run setupSheets().' });

  // Generate gig_id
  var data = sheet.getDataRange().getValues();
  var maxId = 0;
  for (var i = 1; i < data.length; i++) {
    var id = String(data[i][0]).replace('G-', '');
    var num = parseInt(id, 10);
    if (num > maxId) maxId = num;
  }
  var gigId = 'G-' + String(nextSeq_('seq_gig', maxId)).padStart(3, '0');

  var tips = Number(params.rating_tips) || 5;
  var rebooked = Number(params.rating_rebooked) || 5;
  var audience = Number(params.rating_audience) || 5;
  var quality = Number(params.rating_venue_quality) || 5;
  var overall = Math.round(((tips + rebooked + audience + quality) / 4) * 10) / 10;

  var newRow = sheet.getLastRow() + 1;
  sheet.getRange(newRow, 1, 1, 12).setValues([[
    gigId,
    params.venue_id || '',
    safeCell_(params.venue_name || ''),
    params.date || new Date().toISOString().split('T')[0],
    params.category || '',
    tips,
    rebooked,
    audience,
    quality,
    overall,
    safeCell_(params.notes || ''),
    params.distance_miles ? Number(params.distance_miles) : ''
  ]]);

  // Calculate distance if we have a venue_id (and no manual distance)
  if (params.venue_id && !params.distance_miles) {
    var found = findVenueRow_(ss, params.venue_id);
    var vDist = found ? cell_(found.row, found.cols.distance_miles) : '';
    if (vDist) sheet.getRange(newRow, 12).setValue(Number(vDist));
  }

  return jsonResponse_({ status: 'ok', gig_id: gigId, overall_score: overall });
}

// ---------------------------------------------------------------
// updateGig_ — Update a past gig's ratings or notes
// Params: gig_id (required), plus any fields to update
// ---------------------------------------------------------------
function updateGig_(params) {
  var gigId = params.gig_id || '';
  if (!gigId) return jsonResponse_({ status: 'error', message: 'gig_id required' });

  var ss = SpreadsheetApp.getActiveSpreadsheet();
  var sheet = ss.getSheetByName(PAST_GIGS);
  if (!sheet) return jsonResponse_({ status: 'error', message: 'Past Gigs sheet not found' });

  var data = sheet.getDataRange().getValues();
  for (var i = 1; i < data.length; i++) {
    if (String(data[i][0]) === gigId) {
      var row = i + 1;
      if (params.venue_id) sheet.getRange(row, 2).setValue(params.venue_id);
      if (params.venue_name) sheet.getRange(row, 3).setValue(safeCell_(params.venue_name));
      if (params.date) sheet.getRange(row, 4).setValue(params.date);
      if (params.category) sheet.getRange(row, 5).setValue(params.category);
      if (params.rating_tips) sheet.getRange(row, 6).setValue(Number(params.rating_tips));
      if (params.rating_rebooked) sheet.getRange(row, 7).setValue(Number(params.rating_rebooked));
      if (params.rating_audience) sheet.getRange(row, 8).setValue(Number(params.rating_audience));
      if (params.rating_venue_quality) sheet.getRange(row, 9).setValue(Number(params.rating_venue_quality));
      if (params.notes) sheet.getRange(row, 11).setValue(safeCell_(params.notes));
      if (params.distance_miles) sheet.getRange(row, 12).setValue(Number(params.distance_miles));

      // Recalculate overall
      var tips = Number(sheet.getRange(row, 6).getValue());
      var reb = Number(sheet.getRange(row, 7).getValue());
      var aud = Number(sheet.getRange(row, 8).getValue());
      var qual = Number(sheet.getRange(row, 9).getValue());
      var overall = Math.round(((tips + reb + aud + qual) / 4) * 10) / 10;
      sheet.getRange(row, 10).setValue(overall);

      return jsonResponse_({ status: 'ok', gig_id: gigId, overall_score: overall });
    }
  }
  return jsonResponse_({ status: 'error', message: 'Gig not found' });
}

// ---------------------------------------------------------------
// deleteGig_ — Delete a past gig by gig_id
// ---------------------------------------------------------------
function deleteGig_(params) {
  var gigId = params.gig_id || '';
  if (!gigId) return jsonResponse_({ status: 'error', message: 'gig_id required' });

  var ss = SpreadsheetApp.getActiveSpreadsheet();
  var sheet = ss.getSheetByName(PAST_GIGS);
  if (!sheet) return jsonResponse_({ status: 'error', message: 'Past Gigs sheet not found' });

  var data = sheet.getDataRange().getValues();
  for (var i = 1; i < data.length; i++) {
    if (String(data[i][0]) === gigId) {
      retireId_('seq_gig', gigId);
      sheet.deleteRow(i + 1);
      return jsonResponse_({ status: 'ok', deleted: gigId });
    }
  }
  return jsonResponse_({ status: 'error', message: 'Gig not found: ' + gigId });
}

// ---------------------------------------------------------------
// getGigs_ — Return all past gigs
// ---------------------------------------------------------------
function getGigs_() {
  var ss = SpreadsheetApp.getActiveSpreadsheet();
  var sheet = ss.getSheetByName(PAST_GIGS);
  if (!sheet) return jsonResponse_({ status: 'ok', gigs: [] });

  var data = sheet.getDataRange().getValues();
  var gigs = [];
  for (var i = 1; i < data.length; i++) {
    var row = data[i];
    if (!row[0]) continue;
    gigs.push({
      gig_id: String(row[0]),
      venue_id: String(row[1]),
      venue_name: String(row[2]),
      date: String(row[3]),
      category: String(row[4]),
      rating_tips: Number(row[5]),
      rating_rebooked: Number(row[6]),
      rating_audience: Number(row[7]),
      rating_venue_quality: Number(row[8]),
      overall_score: Number(row[9]),
      notes: String(row[10] || ''),
      distance_miles: row[11] ? Number(row[11]) : null
    });
  }
  return jsonResponse_({ status: 'ok', gigs: gigs });
}

// ---------------------------------------------------------------
// getRecommendations_ — Score venues based on past gig profile
// Returns venues sorted by recommendation_score (0-100)
// ---------------------------------------------------------------
function getRecommendations_() {
  var ss = SpreadsheetApp.getActiveSpreadsheet();

  // Load past gigs
  var gigSheet = ss.getSheetByName(PAST_GIGS);
  var gigs = [];
  if (gigSheet) {
    var gData = gigSheet.getDataRange().getValues();
    for (var g = 1; g < gData.length; g++) {
      if (!gData[g][0] || isDeletedGigName_(gData[g][2])) continue;  // soft-deleted in the PWA
      gigs.push({
        category: String(gData[g][4]).toLowerCase(),
        overall: Number(gData[g][9]),
        distance: gData[g][11] ? Number(gData[g][11]) : null,
        upscale: Number(gData[g][8]) || 3  // venue_quality as upscale proxy
      });
    }
  }

  if (gigs.length === 0) {
    return jsonResponse_({ status: 'ok', recommendations: [], message: 'No past gigs to build profile from. Add gigs first.' });
  }

  // Build profile from past gigs
  // Category scores: average overall rating per category
  var catScores = {};
  var catCounts = {};
  var distances = [];
  var upscales = [];
  var totalAvg = 0;

  for (var p = 0; p < gigs.length; p++) {
    var cat = gigs[p].category;
    if (!catScores[cat]) { catScores[cat] = 0; catCounts[cat] = 0; }
    catScores[cat] += gigs[p].overall;
    catCounts[cat]++;
    if (gigs[p].distance !== null) distances.push(gigs[p].distance);
    upscales.push(gigs[p].upscale);
    totalAvg += gigs[p].overall;
  }
  totalAvg /= gigs.length;

  // Average per category
  for (var cc in catScores) {
    catScores[cc] = catScores[cc] / catCounts[cc];
  }

  // Distance sweet spot: median of past gig distances
  distances.sort(function(a, b) { return a - b; });
  var medianDist = distances.length > 0 ? distances[Math.floor(distances.length / 2)] : 50;
  var distSpread = distances.length > 1 ? (distances[distances.length - 1] - distances[0]) / 2 : 30;
  if (distSpread < 15) distSpread = 15;

  // Upscale sweet spot: average
  var avgUpscale = 0;
  for (var u = 0; u < upscales.length; u++) avgUpscale += upscales[u];
  avgUpscale /= upscales.length;

  // Load venues
  var vSheet = ss.getSheetByName(VENUES);
  var vData = vSheet.getDataRange().getValues();
  var VC = venueCols_(vData[0] || []);

  // Load contacts for quality scoring
  var cSheet = ss.getSheetByName(CONTACTS);
  var cData = cSheet.getDataRange().getValues();
  var contactsByVenue = {};
  for (var ci = 1; ci < cData.length; ci++) {
    var vid = String(cData[ci][1]);
    if (!contactsByVenue[vid]) contactsByVenue[vid] = [];
    contactsByVenue[vid].push({
      email: String(cData[ci][4]),
      verified: String(cData[ci][6]),
      title: String(cData[ci][3]).toLowerCase(),
      email_sent: sentFlag_(cData[ci][8])
    });
  }

  // Load taste preferences (category tiers + sweet spot locations + junk keywords)
  var tasteSheet = ss.getSheetByName(TASTE);
  var categoryTiers = {};    // category → tier (1-4)
  var sweetSpotCities = {};  // lowercase city name → true
  var junkKeywords = [];     // name keywords to auto-exclude
  if (tasteSheet) {
    var tData = tasteSheet.getDataRange().getValues();
    for (var ti = 1; ti < tData.length; ti++) {
      var tType = String(tData[ti][0]).toLowerCase();
      var tKey = String(tData[ti][1]).toLowerCase().trim();
      var tVal = String(tData[ti][2]);
      if (tType === 'tier') {
        categoryTiers[tKey] = Number(tVal) || 3;
      } else if (tType === 'location') {
        sweetSpotCities[tKey] = true;
      } else if (tType === 'junk') {
        junkKeywords.push(tKey);
      }
    }
  }

  // Past-gig venue IDs AND names (venue_name column) to exclude from recommendations
  var pastGigs = getPastGigVenueIds_(ss);

  // Score each venue
  var recommendations = [];
  var zonePts = { green: 10, yellow: 5, 'default': 0 };
  var goodTitles = ['event', 'manager', 'director', 'coordinator', 'owner', 'general manager', 'marketing', 'hospitality'];
  var now = new Date();

  for (var vi = 1; vi < vData.length; vi++) {
    var row = vData[vi];
    if (!row[0]) continue;
    var venueId = String(row[0]);
    // Skip past gigs by ID or normalized name ("Cosmos Club DC" ~ "Cosmos Club")
    if (isPastGigVenue_({ venue_id: venueId, name: cell_(row, VC.name) }, pastGigs)) continue;
    var vVote = String(cell_(row, VC.venue_vote) || '');
    var vStatus = String(cell_(row, VC.status)) || 'needs_review';
    if (vStatus === 'needs_review') continue; // website/category not verified yet
    if (vStatus === 'closed' || vStatus === 'dismissed') continue;
    if (vVote === 'down') continue; // explicitly rejected = always excluded
    // taste_score.py scores disqualified (non-venue / wrong vibe) venues 0; blank = unscored
    var vTaste = cell_(row, VC.taste_score);
    if (vTaste !== '' && vTaste !== null && !isNaN(Number(vTaste)) && Number(vTaste) === 0) continue;
    var vCat = String(cell_(row, VC.category)).toLowerCase();
    var vUpscale = Number(cell_(row, VC.upscale_score)) || 3;
    var vZone = String(cell_(row, VC.zone_priority)) || 'default';
    var vDist = cell_(row, VC.distance_miles) ? Number(cell_(row, VC.distance_miles)) : null;

    // Hard cutoff: skip venues beyond 150 miles (~2 hours highway)
    if (vDist !== null && vDist > 150) continue;

    // Junk filter: skip venues whose name contains any junk keyword
    var vName = String(cell_(row, VC.name)).toLowerCase();
    var isJunk = false;
    for (var jk = 0; jk < junkKeywords.length; jk++) {
      if (vName.indexOf(junkKeywords[jk]) > -1) { isJunk = true; break; }
    }
    if (isJunk) continue;

    // --- CATEGORY MATCH (0-40 pts) — most important factor ---
    var catPts = 0;
    if (catScores[vCat] !== undefined) {
      catPts = Math.round((catScores[vCat] / 10) * 40);
    } else {
      catPts = Math.round((totalAvg / 10) * 20);  // half weight for unknown
    }

    // --- UPSCALE MATCH (0-30 pts) — quality matters ---
    var upscaleDiff = Math.abs(vUpscale - avgUpscale);
    var upscalePts = Math.round(Math.max(0, 30 * (1 - upscaleDiff / 5)));

    // --- ZONE (0-10 pts) ---
    var zPts = zonePts[vZone] || 0;

    // --- DISTANCE (0-25 pts) — closer venues rank higher, not just a tiebreaker ---
    var distPts = 0;
    if (vDist !== null) {
      if (vDist <= 30) distPts = 25;        // local (DC/MD/NoVA core)
      else if (vDist <= 60) distPts = 20;   // nearby (Bethesda, Alexandria, etc.)
      else if (vDist <= 90) distPts = 15;   // moderate (Frederick, Annapolis, Leesburg)
      else if (vDist <= 120) distPts = 10;  // far (Eastern Shore, PA Main Line)
      else distPts = Math.round(Math.max(0, 5 * (1 - (vDist - 120) / 30)));  // edge of radius
    } else {
      distPts = 10; // neutral if no distance data
    }

    // --- CONTACT QUALITY (0-10 pts) ---
    var cqPts = 0;
    var vContacts = contactsByVenue[venueId] || [];
    if (vContacts.length > 0) {
      cqPts += 3; // has contacts
      var hasVerified = false, hasGoodTitle = false;
      for (var cx = 0; cx < vContacts.length; cx++) {
        if (vContacts[cx].verified === 'valid') hasVerified = true;
        for (var gt = 0; gt < goodTitles.length; gt++) {
          if (vContacts[cx].title.indexOf(goodTitles[gt]) > -1) { hasGoodTitle = true; break; }
        }
      }
      if (hasVerified) cqPts += 4;
      if (hasGoodTitle) cqPts += 3;
    }

    // --- USER VOTE BONUS/PENALTY ---
    var votePts = 0;
    if (vVote === 'up') votePts = 20;
    else if (vVote === 'down') votePts = -30;

    // --- TASTE TIER (-20 to +20 pts) ---
    var tastePts = 0;
    var tier = categoryTiers[vCat] || 3; // default tier 3 (neutral) if unknown
    if (tier === 1) tastePts = 20;
    else if (tier === 2) tastePts = 10;
    else if (tier === 3) tastePts = 0;
    else if (tier === 4) tastePts = -20;

    // --- LOCATION SWEET SPOT (0-15 pts) ---
    var locPts = 0;
    var vCity = String(cell_(row, VC.city)).toLowerCase().trim();
    if (sweetSpotCities[vCity]) {
      locPts = 15;
    }

    // --- STATE PRIORITY (0-20 pts) — DC/MD/VA venues rank above out-of-area ---
    var vState = String(cell_(row, VC.state)).toUpperCase();
    var statePts = (vState === 'DC' || vState === 'MD' || vState === 'VA') ? 20 : 0;

    var totalScore = Math.max(0, Math.min(100, catPts + distPts + upscalePts + zPts + cqPts + votePts + tastePts + locPts + statePts));

    recommendations.push({
      venue_id: venueId,
      name: String(cell_(row, VC.name)),
      category: String(cell_(row, VC.category)),
      city: String(cell_(row, VC.city)),
      state: String(cell_(row, VC.state)),
      upscale_score: vUpscale,
      zone_priority: vZone,
      status: vStatus,
      distance_miles: vDist,
      venue_vote: vVote,
      website: String(cell_(row, VC.website) || ''),
      notes: String(cell_(row, VC.notes) || ''),
      recommendation_score: totalScore,
      score_breakdown: {
        category: catPts,
        distance: distPts,
        upscale: upscalePts,
        zone: zPts,
        contact_quality: cqPts,
        vote: votePts,
        taste_tier: tastePts,
        location: locPts,
        state_priority: statePts
      },
      contact_count: vContacts.length
    });
  }

  // Sort by recommendation score descending
  recommendations.sort(function(a, b) { return b.recommendation_score - a.recommendation_score; });

  // Build taste report: count how many venues got boosted/penalized
  var tasteReport = {
    active: Object.keys(categoryTiers).length > 0 || Object.keys(sweetSpotCities).length > 0,
    tier_count: Object.keys(categoryTiers).length,
    location_count: Object.keys(sweetSpotCities).length,
    tier1_venues: 0, tier2_venues: 0, tier3_venues: 0, tier4_venues: 0,
    location_matches: 0,
    venues_with_feedback: 0
  };
  for (var ri = 0; ri < recommendations.length; ri++) {
    var tbd = recommendations[ri].score_breakdown;
    if (tbd.taste_tier >= 15) tasteReport.tier1_venues++;
    else if (tbd.taste_tier >= 5) tasteReport.tier2_venues++;
    else if (tbd.taste_tier <= -10) tasteReport.tier4_venues++;
    else tasteReport.tier3_venues++;
    if (tbd.location > 0) tasteReport.location_matches++;
  }
  // Count venues with feedback notes
  for (var fi = 1; fi < vData.length; fi++) {
    var fb = cell_(vData[fi], VC.venue_feedback);
    if (fb && String(fb).trim()) tasteReport.venues_with_feedback++;
  }

  return jsonResponse_({
    status: 'ok',
    recommendations: recommendations,
    profile: {
      gig_count: gigs.length,
      best_category: Object.keys(catScores).sort(function(a, b) { return catScores[b] - catScores[a]; })[0] || 'none',
      avg_overall: Math.round(totalAvg * 10) / 10,
      median_distance: Math.round(medianDist),
      avg_upscale: Math.round(avgUpscale * 10) / 10
    },
    taste_report: tasteReport
  });
}

// ---------------------------------------------------------------
// saveMonthly_ — Save monthly tasks + defaults to Config tab
// Params: tasks (JSON string), defaults (JSON string)
// ---------------------------------------------------------------
function saveMonthly_(params) {
  if (params.tasks) setConfig_('monthly_tasks', params.tasks);
  if (params.defaults) setConfig_('monthly_defaults', params.defaults);
  setConfig_('monthly_updated', new Date().toISOString());
  return jsonResponse_({ status: 'ok', saved: true });
}

// ---------------------------------------------------------------
// loadMonthly_ — Load monthly tasks + defaults from Config tab
// ---------------------------------------------------------------
function loadMonthly_() {
  var tasks = getConfig_('monthly_tasks');
  var defaults = getConfig_('monthly_defaults');
  var updated = getConfig_('monthly_updated');
  return jsonResponse_({
    status: 'ok',
    tasks: tasks ? tasks : null,
    defaults: defaults ? defaults : null,
    updated: updated ? String(updated) : null
  });
}

// ---------------------------------------------------------------
// setupSheets — Run ONCE to create all required tabs + headers
// Go to Apps Script editor → Run → setupSheets
// ---------------------------------------------------------------
// ---------------------------------------------------------------
// migrateSchema_ — Add missing columns to existing sheets
// Called via ?action=migrate_schema — dry run unless confirm=yes.
// Safe to run multiple times — only adds columns that don't exist.
// Also reports core Venues columns that are missing or not where the
// historical position expects them (readers now use headers, but a
// renamed header would still read as empty).
// ---------------------------------------------------------------
function migrateSchema_(params) {
  params = params || {};
  var apply = params.confirm === 'yes';
  var ss = SpreadsheetApp.getActiveSpreadsheet();
  var venueSheet = ss.getSheetByName('Venues');
  if (!venueSheet) return jsonResponse_({ status: 'error', message: 'Venues sheet not found' });

  var headers = venueSheet.getRange(1, 1, 1, venueSheet.getLastColumn()).getValues()[0];
  var headerNames = headers.map(function(h) { return String(h).toLowerCase().trim(); });

  var expectedCols = ['taste_score', 'taste_score_version', 'taste_reasons',
                      'classification_confidence', 'location_confidence', 'priority_override'];
  var added = [];
  var missing = [];

  for (var i = 0; i < expectedCols.length; i++) {
    if (headerNames.indexOf(expectedCols[i]) === -1) {
      missing.push(expectedCols[i]);
      if (!apply) continue;
      var newCol = venueSheet.getLastColumn() + 1;
      venueSheet.getRange(1, newCol).setValue(expectedCols[i]);
      venueSheet.getRange(1, newCol).setFontWeight('bold');
      added.push(expectedCols[i]);
    }
  }

  var coreMissing = [], coreMoved = [];
  for (var c = 0; c < 24; c++) {
    var at = headerNames.indexOf(VENUE_COLS[c]);
    if (at === -1) coreMissing.push(VENUE_COLS[c]);
    else if (at !== c) coreMoved.push(VENUE_COLS[c] + '@' + at);
  }

  return jsonResponse_({
    status: 'ok',
    dry_run: !apply,
    message: added.length > 0
      ? 'Added columns: ' + added.join(', ')
      : (missing.length ? 'Dry run — would add: ' + missing.join(', ') + ' (pass confirm=yes)' : 'All columns already exist'),
    added: added,
    would_add: apply ? [] : missing,
    core_missing: coreMissing,
    core_moved: coreMoved
  });
}

function setupSheets() {
  var ss = SpreadsheetApp.getActiveSpreadsheet();

  var tabs = {
    'Venues': ['venue_id', 'name', 'category', 'website', 'city', 'county', 'state', 'address', 'facebook', 'instagram', 'upscale_score', 'zone_priority', 'status', 'source', 'scraped_date', 'notes', 'distance_miles', 'drive_minutes', 'contacted_date', 'contact_form', 'linkedin_pending', 'venue_vote', 'venue_feedback', 'check_status', 'taste_score', 'taste_score_version', 'taste_reasons', 'classification_confidence', 'location_confidence', 'priority_override'],
    'Contacts': ['contact_id', 'venue_id', 'name', 'title', 'email', 'source', 'verified', 'verified_date', 'email_sent', 'email_sent_date', 'ig_dm_sent', 'fb_msg_sent'],
    'Outreach Log': ['timestamp', 'venue_id', 'contact_id', 'channel', 'template_used'],
    'Config': ['key', 'value'],
    'Templates': ['category', 'subject', 'body'],
    'Progress': ['state', 'category', 'last_scraped', 'venues_found', 'status'],
    'Past Gigs': ['gig_id', 'venue_id', 'venue_name', 'date', 'category', 'rating_tips', 'rating_rebooked', 'rating_audience', 'rating_venue_quality', 'overall_score', 'notes', 'distance_miles'],
    'Taste': ['type', 'key', 'value']
  };

  for (var name in tabs) {
    var sheet = ss.getSheetByName(name);
    if (!sheet) {
      sheet = ss.insertSheet(name);
    }
    // Set headers if row 1 is empty
    var firstCell = sheet.getRange(1, 1).getValue();
    if (!firstCell) {
      var headers = tabs[name];
      sheet.getRange(1, 1, 1, headers.length).setValues([headers]);
      sheet.getRange(1, 1, 1, headers.length).setFontWeight('bold');
      sheet.setFrozenRows(1);
    }
  }

  // Seed templates if empty
  var tSheet = ss.getSheetByName('Templates');
  if (tSheet.getLastRow() <= 1) {
    var templates = [
      ['winery', 'Classical Guitarist (Spanish/Brazilian Music) to Perform at your Winery!', ''],
      ['museum', 'Classical Guitarist (Spanish/Brazilian Music) to Perform at your Museum!', ''],
      ['hotel', 'Classical Guitarist (Spanish/Brazilian Music) to Perform at your Hotel!', ''],
      ['country_club', 'Classical Guitarist (Spanish/Brazilian Music) to Perform at your Club!', ''],
      ['event', 'Classical Guitarist (Spanish/Brazilian Music) for your Events!', ''],
      ['restaurant', 'Classical Guitarist (Spanish/Brazilian Music) to Perform at your Restaurant!', '']
    ];
    tSheet.getRange(2, 1, templates.length, 3).setValues(templates);
  }

  // Seed config if empty
  var cSheet = ss.getSheetByName('Config');
  if (cSheet.getLastRow() <= 1) {
    var config = [
      ['total_emails_sent', 0],
      ['total_ig_dms', 0],
      ['total_fb_msgs', 0],
      ['zerobounce_credits', 368]
    ];
    cSheet.getRange(2, 1, config.length, 2).setValues(config);
  }

  // Seed Taste tab with category tiers + sweet spot locations
  var tasteSheet = ss.getSheetByName('Taste');
  if (tasteSheet && tasteSheet.getLastRow() <= 1) {
    var tasteData = [
      // Category tiers (1=dream, 2=good, 3=lower priority, 4=skip)
      ['tier', 'country_club', '1'],
      ['tier', 'private_club', '1'],
      ['tier', 'restaurant', '2'],
      ['tier', 'winery', '2'],
      ['tier', 'hotel', '2'],
      ['tier', 'wine_bar', '2'],
      ['tier', 'museum', '2'],
      ['tier', 'event_space', '2'],
      ['tier', 'golf_club', '3'],
      ['tier', 'mall', '3'],
      ['tier', 'senior_living', '3'],
      ['tier', 'yacht_club', '1'],
      ['tier', 'resort', '2'],
      ['tier', 'event', '2'],
      ['tier', 'event_planner', '2'],
      ['tier', 'art_gallery', '2'],
      ['tier', 'spa', '2'],
      ['tier', 'luxury_apts', '2'],
      ['tier', 'wedding_venue', '3'],
      ['tier', 'corporate', '3'],
      ['tier', 'church', '3'],
      ['tier', 'luxury_retail', '2'],
      ['tier', 'sports_bar', '4'],
      ['tier', 'chain', '4'],
      ['tier', 'bar', '4'],
      ['tier', 'grocery_market', '4'],
      // Sweet spot locations — wealthy areas within 2hr radius
      ['location', 'Georgetown', 'DC'],
      ['location', 'Dupont Circle', 'DC'],
      ['location', 'Kalorama', 'DC'],
      ['location', 'Cleveland Park', 'DC'],
      ['location', 'Woodley Park', 'DC'],
      ['location', 'Spring Valley', 'DC'],
      ['location', 'Washington', 'DC'],
      ['location', 'Potomac', 'MD'],
      ['location', 'Chevy Chase', 'MD'],
      ['location', 'Bethesda', 'MD'],
      ['location', 'Rockville', 'MD'],
      ['location', 'Cabin John', 'MD'],
      ['location', 'Roland Park', 'MD'],
      ['location', 'Guilford', 'MD'],
      ['location', 'Ruxton', 'MD'],
      ['location', 'Lutherville', 'MD'],
      ['location', 'Ellicott City', 'MD'],
      ['location', 'Clarksville', 'MD'],
      ['location', 'St. Michaels', 'MD'],
      ['location', 'St Michaels', 'MD'],
      ['location', 'Easton', 'MD'],
      ['location', 'Oxford', 'MD'],
      ['location', 'Annapolis', 'MD'],
      ['location', 'Severna Park', 'MD'],
      ['location', 'Great Falls', 'VA'],
      ['location', 'McLean', 'VA'],
      ['location', 'Alexandria', 'VA'],
      ['location', 'Reston', 'VA'],
      ['location', 'Vienna', 'VA'],
      ['location', 'Middleburg', 'VA'],
      ['location', 'Leesburg', 'VA'],
      ['location', 'Purcellville', 'VA'],
      ['location', 'Charlottesville', 'VA'],
      ['location', 'Greenville', 'DE'],
      ['location', 'Hockessin', 'DE'],
      ['location', 'Wilmington', 'DE'],
      ['location', 'Rehoboth Beach', 'DE'],
      ['location', 'Gladwyne', 'PA'],
      ['location', 'Bryn Mawr', 'PA'],
      ['location', 'Devon', 'PA'],
      ['location', 'Kennett Square', 'PA'],
      ['location', 'Chadds Ford', 'PA'],
      ['location', 'West Chester', 'PA']
    ];
    tasteSheet.getRange(2, 1, tasteData.length, 3).setValues(tasteData);
  }

  // Delete default Sheet1 if it exists and has no data
  var sheet1 = ss.getSheetByName('Sheet1');
  if (sheet1 && sheet1.getLastRow() <= 1) {
    ss.deleteSheet(sheet1);
  }

  SpreadsheetApp.getUi().alert('Setup complete! All tabs created with headers.');
}

// ---------------------------------------------------------------
// updateTaste_ — Update taste preferences (category tiers + locations)
// Params: data (JSON string with array of [type, key, value] rows)
// If mode=replace, clears and replaces all taste data
// If mode=add, appends new rows
// ---------------------------------------------------------------
function updateTaste_(params) {
  var ss = SpreadsheetApp.getActiveSpreadsheet();
  var sheet = ss.getSheetByName(TASTE);
  if (!sheet) {
    sheet = ss.insertSheet(TASTE);
    sheet.getRange(1, 1, 1, 3).setValues([['type', 'key', 'value']]);
    sheet.getRange(1, 1, 1, 3).setFontWeight('bold');
    sheet.setFrozenRows(1);
  }

  var mode = params.mode || 'replace';
  var dataStr = params.data || '';
  if (!dataStr) return jsonResponse_({ status: 'error', message: 'data parameter required (JSON array)' });

  var rows;
  try {
    rows = JSON.parse(dataStr);
  } catch(e) {
    try {
      rows = JSON.parse(decodeURIComponent(dataStr));
    } catch(e2) {
      return jsonResponse_({ status: 'error', message: 'Invalid JSON: ' + e2.message });
    }
  }

  if (!Array.isArray(rows) || rows.length === 0) {
    return jsonResponse_({ status: 'error', message: 'data must be a non-empty array' });
  }
  for (var r = 0; r < rows.length; r++) {
    if (!Array.isArray(rows[r]) || rows[r].length !== 3) {
      return jsonResponse_({ status: 'error', message: 'Row ' + r + ' must be [type, key, value]; nothing was changed' });
    }
    rows[r] = rows[r].map(function(x) { return safeCell_(x == null ? '' : String(x)); });
  }

  if (mode === 'replace') {
    // Write first, then clear only the leftover rows, so a failure can't leave the sheet empty
    var oldLast = sheet.getLastRow();
    sheet.getRange(2, 1, rows.length, 3).setValues(rows);
    if (oldLast > rows.length + 1) {
      sheet.getRange(rows.length + 2, 1, oldLast - rows.length - 1, 3).clearContent();
    }
  } else {
    // Append
    var startRow = sheet.getLastRow() + 1;
    sheet.getRange(startRow, 1, rows.length, 3).setValues(rows);
  }

  return jsonResponse_({ status: 'ok', mode: mode, rows_written: rows.length });
}

// ---------------------------------------------------------------
// remapContactVenue_ — Change venue_id on contacts
// Params: old_venue_id, new_venue_id
// Updates all contacts where venue_id = old_venue_id
// ---------------------------------------------------------------
function remapContactVenue_(params) {
  var oldId = params.old_venue_id || '';
  var newId = params.new_venue_id || '';
  if (!oldId || !newId) return jsonResponse_({ status: 'error', message: 'old_venue_id and new_venue_id required' });

  var ss = SpreadsheetApp.getActiveSpreadsheet();
  if (!findVenueRow_(ss, newId)) return jsonResponse_({ status: 'error', message: 'new_venue_id not found: ' + newId });
  var sheet = ss.getSheetByName(CONTACTS);
  var data = sheet.getDataRange().getValues();
  var updated = 0;

  for (var i = 1; i < data.length; i++) {
    if (String(data[i][1]) === oldId) {
      sheet.getRange(i + 1, 2).setValue(newId);
      updated++;
    }
  }

  // outreach=true also moves the Outreach Log history (merging duplicate venues)
  var outreachUpdated = 0;
  if (params.outreach === 'true') {
    var oSheet = ss.getSheetByName(OUTREACH);
    var oRows = oSheet ? findRowsByColumn_(oSheet, 2, oldId) : [];
    for (var o = 0; o < oRows.length; o++) { oSheet.getRange(oRows[o], 2).setValue(newId); outreachUpdated++; }
  }

  return jsonResponse_({ status: 'ok', updated: updated, outreach_updated: outreachUpdated, old_venue_id: oldId, new_venue_id: newId });
}

// ---------------------------------------------------------------
// saveDiscovery_ — Save discovery tracker state (swept cities +
// venue counts) as JSON blobs in Config tab.
// Params: swept (JSON object string), venues (JSON object string)
// Keys are MERGED into the stored maps; a key sent with a falsy value
// (null/false/0/'') is removed. replace=true&force=true overwrites the
// whole map. The previous value is kept in discovery_*_backup.
// Malformed or empty payloads are refused (a stray call wiped it on Sep 22).
// ---------------------------------------------------------------
function parseDiscoveryMap_(raw, label) {
  var obj;
  try { obj = JSON.parse(raw); } catch (e) {
    try { obj = JSON.parse(decodeURIComponent(raw)); } catch (e2) { return { error: label + ' is not valid JSON' }; }
  }
  if (!obj || typeof obj !== 'object' || Array.isArray(obj)) return { error: label + ' must be a JSON object' };
  return { map: obj };
}

function saveDiscovery_(params) {
  if (!params.swept && !params.venues) {
    return jsonResponse_({ status: 'error', message: 'Nothing to save: pass swept and/or venues as JSON objects' });
  }
  var replace = params.replace === 'true' && params.force === 'true';
  var incoming = {};
  var keys = [['swept', 'discovery_swept'], ['venues', 'discovery_venues']];
  for (var k = 0; k < keys.length; k++) {
    if (!params[keys[k][0]]) continue;
    var parsed = parseDiscoveryMap_(params[keys[k][0]], keys[k][0]);
    if (parsed.error) return jsonResponse_({ status: 'error', message: parsed.error + '; nothing was saved' });
    if (replace && Object.keys(parsed.map).length === 0) {
      return jsonResponse_({ status: 'error', message: 'Refusing to replace ' + keys[k][0] + ' with an empty map' });
    }
    incoming[keys[k][0]] = parsed.map;
  }

  var summary = {};
  for (var j = 0; j < keys.length; j++) {
    var name = keys[j][0], configKey = keys[j][1];
    if (!incoming[name]) continue;
    var currentRaw = getConfig_(configKey);
    var current = {};
    if (currentRaw) {
      try { current = JSON.parse(currentRaw) || {}; } catch (e) { current = {}; }
      setConfig_(configKey + '_backup', String(currentRaw));
    }
    var before = Object.keys(current).length;
    var merged = replace ? {} : current;
    var removed = 0;
    for (var key in incoming[name]) {
      var val = incoming[name][key];
      if (!replace && (val === null || val === false || val === 0 || val === '')) {
        if (merged.hasOwnProperty(key)) { delete merged[key]; removed++; }
      } else {
        merged[key] = val;
      }
    }
    setConfig_(configKey, JSON.stringify(merged));
    summary[name] = { before: before, after: Object.keys(merged).length, removed: removed };
  }
  setConfig_('discovery_updated', new Date().toISOString());
  return jsonResponse_({ status: 'ok', mode: replace ? 'replace' : 'merge', summary: summary });
}

// ---------------------------------------------------------------
// loadDiscovery_ — Load discovery tracker state from Config tab
// ---------------------------------------------------------------
function loadDiscovery_() {
  var swept   = getConfig_('discovery_swept');
  var venues  = getConfig_('discovery_venues');
  var updated = getConfig_('discovery_updated');
  return jsonResponse_({
    status:  'ok',
    swept:   swept   || null,
    venues:  venues  || null,
    updated: updated || null
  });
}

// ---------------------------------------------------------------
// VERIFICATION STEP MODEL
//
// Each pipelined venue must complete ALL required verification steps.
// Steps are tracked individually in check_status (column X, index 23)
// as a pipe-delimited string: "web:MANUAL_VERIFIED|apollo:AUTO_FOUND:3|li:MANUAL_VERIFIED:0|..."
//
// Step statuses:
//   NOT_RUN      — step hasn't been executed (absent from string)
//   AUTO_FOUND   — automation found results
//   AUTO_NONE    — automation ran but found nothing
//   MANUAL_VERIFIED — human/agent manually confirmed
//   MANUAL_FOUND — manual check found new contacts
//   FAILED       — step failed, needs retry
//
// Required steps (ALL must be non-NOT_RUN and non-FAILED):
//   web     — venue website checked for contacts/forms
//   apollo  — Apollo MCP search by domain + company name
//   li      — LinkedIn People search for venue employees
//   google  — Google "[venue] contact email" search
//   socials — IG/FB links verified as correct for this venue
//   enrich  — all named contacts without email enriched via Apollo
//
// A venue is FULLY CHECKED only when every required step has a
// terminal status. The audit endpoint reports exactly which steps
// are missing per venue — no more inferring from contact count.
// ---------------------------------------------------------------
var REQUIRED_STEPS = ['web', 'apollo', 'li', 'google', 'socials', 'enrich'];
// NOTE: the run ledger (mark_step.sh / verify_run.sh) is the source of truth
// for pipeline completion. This model only helps if something mirrors ledger
// steps here via save_step; it accepts the ledger/[STEP] names and statuses.
var STEP_ALIASES = { 'linkedin': 'li', 'fb': 'socials', 'ig': 'socials', 'social': 'socials' };
var STEP_STATUS_ALIASES = {
  'ok': 'AUTO_FOUND', 'done': 'MANUAL_VERIFIED', 'empty': 'AUTO_NONE',
  'failed': 'FAILED', 'blocked': 'BLOCKED', 'skipped': 'SKIPPED'
};

// Parse check_status string into {step: {status, detail}} map.
// Free-text segments (not "step:STATUS") are kept under _text so a merge
// never drops notes someone typed into check_status.
function parseCheckStatus_(checkStr) {
  var steps = {};
  if (!checkStr) return steps;
  var parts = checkStr.split('|');
  for (var i = 0; i < parts.length; i++) {
    var part = parts[i].trim();
    if (!part) continue;
    // Legacy: skip "CHECKED:date" prefix from old format
    if (part.indexOf('CHECKED:') === 0) continue;
    // Format: "step:STATUS" or "step:STATUS:detail"
    var segs = part.split(':');
    if (segs.length >= 2 && /^[a-z_]{2,20}$/.test(segs[0])) {
      steps[segs[0]] = {
        status: segs[1],
        detail: segs.length > 2 ? segs.slice(2).join(':') : ''
      };
    } else {
      if (!steps._text) steps._text = [];
      steps._text.push(part);
    }
  }
  return steps;
}

// Serialize steps map back to check_status string
function serializeCheckStatus_(steps) {
  var parts = [];
  for (var step in steps) {
    if (step === '_text') continue;
    var entry = step + ':' + steps[step].status;
    if (steps[step].detail) entry += ':' + steps[step].detail;
    parts.push(entry);
  }
  return parts.concat(steps._text || []).join('|');
}

function stepCount_(steps) {
  return Object.keys(steps).filter(function(k) { return k !== '_text'; }).length;
}

// ---------------------------------------------------------------
// saveStep_ — Save a single verification step for a venue
// Params: venue_id, step (web|apollo|li|google|socials|enrich),
//         status (AUTO_FOUND|AUTO_NONE|MANUAL_VERIFIED|MANUAL_FOUND|FAILED),
//         detail (optional, e.g. "found 2 emails" or "0 results")
// Merges into existing check_status — does not overwrite other steps.
// ---------------------------------------------------------------
function saveStep_(params) {
  var venueId = params.venue_id || '';
  var step = String(params.step || '').toLowerCase();
  var stepStatus = params.status || 'MANUAL_VERIFIED';
  var detail = String(params.detail || '').replace(/\|/g, '/');

  if (!venueId || !step) return jsonResponse_({ status: 'error', message: 'venue_id and step required' });
  if (STEP_ALIASES.hasOwnProperty(step)) step = STEP_ALIASES[step];
  if (STEP_STATUS_ALIASES.hasOwnProperty(String(stepStatus).toLowerCase())) stepStatus = STEP_STATUS_ALIASES[String(stepStatus).toLowerCase()];

  var validSteps = ['web', 'apollo', 'li', 'google', 'socials', 'enrich'];
  if (validSteps.indexOf(step) === -1) {
    return jsonResponse_({ status: 'error', message: 'Invalid step: ' + step + '. Must be one of: ' + validSteps.join(', ') });
  }

  var validStatuses = ['AUTO_FOUND', 'AUTO_NONE', 'MANUAL_VERIFIED', 'MANUAL_FOUND', 'FAILED', 'BLOCKED', 'SKIPPED'];
  if (validStatuses.indexOf(stepStatus) === -1) {
    return jsonResponse_({ status: 'error', message: 'Invalid status: ' + stepStatus + '. Must be one of: ' + validStatuses.join(', ') });
  }

  var ss = SpreadsheetApp.getActiveSpreadsheet();
  var sheet = ss.getSheetByName(VENUES);
  var data = sheet.getDataRange().getValues();
  var C = venueCols_(data[0] || []);
  if (C.check_status < 0) return jsonResponse_({ status: 'error', message: 'Venues sheet has no check_status column' });

  for (var i = 1; i < data.length; i++) {
    if (String(data[i][0]) === venueId) {
      // Postcondition: socials step with MANUAL_VERIFIED requires facebook or instagram to actually exist
      if (step === 'socials' && (stepStatus === 'MANUAL_VERIFIED' || stepStatus === 'MANUAL_FOUND')) {
        var fb = String(cell_(data[i], C.facebook) || '').trim();
        var ig = String(cell_(data[i], C.instagram) || '').trim();
        if (!fb && !ig) {
          return jsonResponse_({
            status: 'error',
            message: 'Cannot mark socials as ' + stepStatus + ' — no facebook or instagram URL saved on venue. Call update_venue first, then save_step.'
          });
        }
      }

      var existing = parseCheckStatus_(String(cell_(data[i], C.check_status) || ''));
      existing[step] = { status: stepStatus, detail: detail };
      var newStr = serializeCheckStatus_(existing);
      sheet.getRange(i + 1, C.check_status + 1).setValue(safeCell_(newStr));
      return jsonResponse_({
        status: 'ok',
        venue_id: venueId,
        step: step,
        step_status: stepStatus,
        detail: detail,
        check_status: newStr,
        steps_complete: stepCount_(existing),
        steps_required: REQUIRED_STEPS.length
      });
    }
  }
  return jsonResponse_({ status: 'error', message: 'Venue not found: ' + venueId });
}

// ---------------------------------------------------------------
// saveCheck_ — Save manual check evidence for a venue (LEGACY)
// Still works for backward compat but prefer save_step for new code.
// Params: venue_id, evidence (pipe-delimited step results)
// ---------------------------------------------------------------
function saveCheck_(params) {
  var venueId = params.venue_id || '';
  var evidence = String(params.evidence || '').trim();
  if (!venueId) return jsonResponse_({ status: 'error', message: 'venue_id required' });
  if (!evidence) return jsonResponse_({ status: 'error', message: 'evidence required (refusing to rewrite check_status with nothing)' });

  var ss = SpreadsheetApp.getActiveSpreadsheet();
  var sheet = ss.getSheetByName(VENUES);
  var data = sheet.getDataRange().getValues();
  var C = venueCols_(data[0] || []);
  if (C.check_status < 0) return jsonResponse_({ status: 'error', message: 'Venues sheet has no check_status column' });

  for (var i = 1; i < data.length; i++) {
    if (String(data[i][0]) === venueId) {
      // Merge with existing steps rather than overwriting
      var existing = parseCheckStatus_(String(cell_(data[i], C.check_status) || ''));
      var newSteps = parseCheckStatus_(evidence);
      for (var step in newSteps) {
        if (step === '_text') {
          existing._text = (existing._text || []).concat(newSteps._text.filter(function(t) {
            return (existing._text || []).indexOf(t) === -1;
          }));
        } else {
          existing[step] = newSteps[step];
        }
      }
      var checkStr = serializeCheckStatus_(existing);
      sheet.getRange(i + 1, C.check_status + 1).setValue(safeCell_(checkStr));
      return jsonResponse_({ status: 'ok', venue_id: venueId, check_status: checkStr });
    }
  }
  return jsonResponse_({ status: 'error', message: 'Venue not found: ' + venueId });
}

// ---------------------------------------------------------------
// auditPipeline_ — Per-step audit of pipelined venue verification
//
// Returns exactly which verification steps are missing per venue.
// The run is NOT done until every venue has all 6 required steps
// in a terminal status (not NOT_RUN, not FAILED).
//
// Response includes:
//   incomplete_venues[] — venues missing any required step, with
//       missing_steps[] listing exactly what needs to be done
//   complete_venues[] — venues with all steps done
//   pending_enrichments[] — contacts with name but no email
//   failed_steps[] — steps that failed and need retry
// ---------------------------------------------------------------
function auditPipeline_() {
  var ss = SpreadsheetApp.getActiveSpreadsheet();

  // Load venues
  var vSheet = ss.getSheetByName(VENUES);
  var vData = vSheet.getDataRange().getValues();
  var VC = venueCols_(vData[0] || []);
  var pipelinedIds = {};
  for (var pv = 1; pv < vData.length; pv++) {
    if (String(cell_(vData[pv], VC.status)) === 'pipelined') pipelinedIds[String(vData[pv][0])] = true;
  }

  // Load contacts
  var cSheet = ss.getSheetByName(CONTACTS);
  var cData = cSheet.getDataRange().getValues();

  // Build contacts by venue + find pending enrichments (pipelined venues only;
  // masked Apollo names like 'Ke***e' can't be enriched by name)
  var contactsByVenue = {};
  var pendingEnrich = [];
  for (var j = 1; j < cData.length; j++) {
    var cr = cData[j];
    if (!cr[0]) continue;
    var vid = String(cr[1]);
    if (!contactsByVenue[vid]) contactsByVenue[vid] = [];
    contactsByVenue[vid].push({
      contact_id: String(cr[0]),
      name: String(cr[2]),
      title: String(cr[3]),
      email: String(cr[4]),
      source: String(cr[5]),
      verified: String(cr[6])
    });
    // Flag contacts with name but no email — need enrichment
    var hasName = String(cr[2]).trim().length > 0;
    var hasEmail = String(cr[4]).trim().length > 0 && String(cr[4]).trim() !== 'undefined';
    if (hasName && !hasEmail && pipelinedIds[vid] && String(cr[2]).indexOf('*') === -1) {
      pendingEnrich.push({
        contact_id: String(cr[0]),
        venue_id: vid,
        name: String(cr[2]),
        title: String(cr[3]),
        source: String(cr[5])
      });
    }
  }

  // Audit each pipelined venue against required steps
  var incomplete = [];
  var complete = [];
  var failedSteps = [];
  var terminalStatuses = ['AUTO_FOUND', 'AUTO_NONE', 'MANUAL_VERIFIED', 'MANUAL_FOUND', 'BLOCKED', 'SKIPPED'];

  for (var i = 1; i < vData.length; i++) {
    var row = vData[i];
    if (!row[0]) continue;
    var status = String(cell_(row, VC.status)) || 'needs_review';
    if (status !== 'pipelined') continue;

    var venueId = String(row[0]);
    var checkStatus = String(cell_(row, VC.check_status) || '');
    var steps = parseCheckStatus_(checkStatus);
    var vc = contactsByVenue[venueId] || [];

    // Count contacts
    var validEmails = 0;
    var noEmailContacts = 0;
    for (var c = 0; c < vc.length; c++) {
      if (vc[c].email && vc[c].email.trim() && vc[c].email !== 'undefined') {
        validEmails++;
      } else if (vc[c].name && vc[c].name.trim()) {
        noEmailContacts++;
      }
    }

    // Determine which steps are missing or failed
    var missing = [];
    var completed = [];
    var failed = [];
    for (var s = 0; s < REQUIRED_STEPS.length; s++) {
      var stepName = REQUIRED_STEPS[s];
      var stepData = steps[stepName];
      if (!stepData) {
        missing.push(stepName);
      } else if (stepData.status === 'FAILED') {
        failed.push(stepName);
        failedSteps.push({ venue_id: venueId, name: String(cell_(row, VC.name)), step: stepName, detail: stepData.detail });
      } else if (terminalStatuses.indexOf(stepData.status) > -1) {
        completed.push(stepName);
      } else {
        missing.push(stepName);
      }
    }

    var entry = {
      venue_id: venueId,
      name: String(cell_(row, VC.name)),
      city: String(cell_(row, VC.city)),
      state: String(cell_(row, VC.state)),
      website: String(cell_(row, VC.website)),
      contact_count: vc.length,
      valid_emails: validEmails,
      no_email_contacts: noEmailContacts,
      check_status: checkStatus,
      steps: steps,
      completed_steps: completed,
      missing_steps: missing,
      failed_steps: failed,
      is_complete: missing.length === 0 && failed.length === 0
    };

    if (entry.is_complete) {
      complete.push(entry);
    } else {
      incomplete.push(entry);
    }
  }

  // Build step-level summary: how many venues are missing each step
  var stepSummary = {};
  for (var si = 0; si < REQUIRED_STEPS.length; si++) {
    var sn = REQUIRED_STEPS[si];
    stepSummary[sn] = { missing: 0, failed: 0, done: 0 };
  }
  for (var ii = 0; ii < incomplete.length; ii++) {
    for (var mi = 0; mi < incomplete[ii].missing_steps.length; mi++) {
      stepSummary[incomplete[ii].missing_steps[mi]].missing++;
    }
    for (var fi = 0; fi < incomplete[ii].failed_steps.length; fi++) {
      stepSummary[incomplete[ii].failed_steps[fi]].failed++;
    }
  }
  for (var ci = 0; ci < complete.length; ci++) {
    for (var di = 0; di < complete[ci].completed_steps.length; di++) {
      stepSummary[complete[ci].completed_steps[di]].done++;
    }
  }

  return jsonResponse_({
    status: 'ok',
    note: 'Legacy check_status model. The run ledger (mark_step.sh / verify_run.sh) is the source of truth for pipeline completion.',
    incomplete_venues: incomplete,
    complete_venues: complete,
    pending_enrichments: pendingEnrich,
    failed_steps: failedSteps,
    step_summary: stepSummary,
    summary: {
      total_pipelined: incomplete.length + complete.length,
      incomplete: incomplete.length,
      complete: complete.length,
      pending_enrichments: pendingEnrich.length,
      failed_steps: failedSteps.length
    }
  });
}

// find_by_domain — look up a venue by its website domain
// Returns {status:'ok', venue_id, name} or {status:'error', message}
function findByDomain_(params) {
  var raw = (params.domain || '').toLowerCase().replace(/^www\./, '').replace(/\/$/, '');
  if (!raw) return jsonResponse_({ status: 'error', message: 'No domain provided' });

  var sheet = SpreadsheetApp.getActiveSpreadsheet().getSheetByName(VENUES);
  var data  = sheet.getDataRange().getValues();
  var C = venueCols_(data[0] || []);

  var matches = [];
  for (var i = 1; i < data.length; i++) {
    var website = String(cell_(data[i], C.website)).trim();
    if (!website) continue;
    try {
      var hostname = website.replace(/^https?:\/\//, '').split('/')[0]
                            .toLowerCase().replace(/^www\./, '');
      if (hostname === raw) matches.push({ venue_id: String(data[i][0]), name: String(cell_(data[i], C.name)) });
    } catch (e) {}
  }
  if (matches.length === 1) {
    return jsonResponse_({ status: 'ok', venue_id: matches[0].venue_id, name: matches[0].name, matches: matches });
  }
  if (matches.length > 1) {
    // Shared domains (hotel brands, restaurant groups) must never pick "the first" venue.
    return jsonResponse_({ status: 'error', ambiguous: true,
      message: 'Ambiguous: ' + matches.length + ' venues use ' + raw, matches: matches.slice(0, 50) });
  }
  return jsonResponse_({ status: 'error', message: 'Not found', matches: [] });
}
