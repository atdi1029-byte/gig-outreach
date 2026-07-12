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

// Generate next unique contact ID by finding the max existing ID
function nextContactId_(data) {
  var max = 0;
  for (var i = 1; i < data.length; i++) {
    var id = String(data[i][0]);
    if (id.startsWith('C-')) {
      var num = parseInt(id.substring(2), 10);
      if (!isNaN(num) && num > max) max = num;
    }
  }
  return 'C-' + String(max + 1).padStart(3, '0');
}
var TASTE       = 'Taste';

// ---------------------------------------------------------------
// doGet — Main API router
// All actions via GET query params: ?action=dashboard&...
// ---------------------------------------------------------------
// Global callback for JSONP support — set by doGet, used by jsonResponse_
var _jsonpCallback = '';

function doGet(e) {
  var action = (e && e.parameter && e.parameter.action) || '';
  _jsonpCallback = (e && e.parameter && e.parameter.callback) || '';

  if (action === 'dashboard')       return serveDashboardJSON_();
  if (action === 'venues')          return serveVenuesJSON_(e.parameter);
  if (action === 'venue_detail')    return serveVenueDetail_(e.parameter);
  if (action === 'update_venue')    return updateVenue_(e.parameter);
  if (action === 'update_contact')  return updateContact_(e.parameter);
  if (action === 'log_outreach')    return logOutreach_(e.parameter);
  if (action === 'add_venue')       return addVenue_(e.parameter);
  if (action === 'add_contact')     return addContact_(e.parameter);
  if (action === 'update_contact_email') return updateContactEmail_(e.parameter);
  if (action === 'templates')       return serveTemplates_();
  if (action === 'stats')           return serveStats_();
  if (action === 'config')          return serveConfig_();
  if (action === 'calc_distances')  return calcDistances_();
  if (action === 'add_gig')         return addGig_(e.parameter);
  if (action === 'update_gig')      return updateGig_(e.parameter);
  if (action === 'delete_gig')      return deleteGig_(e.parameter);
  if (action === 'get_gigs')        return getGigs_();
  if (action === 'get_recommendations') return getRecommendations_();
  if (action === 'save_monthly')     return saveMonthly_(e.parameter);
  if (action === 'load_monthly')     return loadMonthly_();
  if (action === 'delete_contact')   return deleteContact_(e.parameter);
  if (action === 'delete_venue')     return deleteVenue_(e.parameter);
  if (action === 'cleanup_generic')  return cleanupGenericEmails_();
  if (action === 'update_taste')     return updateTaste_(e.parameter);
  if (action === 'save_skip_words')  return saveSkipWords_(e.parameter);
  if (action === 'get_skip_words')   return getSkipWords_();
  if (action === 'remap_contact_venue') return remapContactVenue_(e.parameter);
  if (action === 'find_by_domain')     return findByDomain_(e.parameter);
  if (action === 'save_discovery')     return saveDiscovery_(e.parameter);
  if (action === 'load_discovery')     return loadDiscovery_();
  if (action === 'save_check')         return saveCheck_(e.parameter);
  if (action === 'save_step')          return saveStep_(e.parameter);
  if (action === 'audit_pipeline')     return auditPipeline_();

  // Default health check
  return jsonResponse_({ status: 'ok', message: 'Gig Outreach API is live', timestamp: new Date().toISOString() });
}

// ---------------------------------------------------------------
// JSON response helper
// ---------------------------------------------------------------
function jsonResponse_(obj) {
  var json = JSON.stringify(obj);
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
// Returns { form: {venueId: true}, ig: {}, fb: {} }
function buildOutreachSentMaps_(outreachData) {
  var form = {}, ig = {}, fb = {};
  for (var i = 1; i < outreachData.length; i++) {
    var chan = String(outreachData[i][3]);
    var vid = String(outreachData[i][1]);
    if (chan === 'contact_form' || chan === 'contact_form_skip') form[vid] = true;
    if (chan === 'instagram' || chan === 'instagram_skip') ig[vid] = true;
    if (chan === 'facebook' || chan === 'facebook_skip') fb[vid] = true;
  }
  return { form: form, ig: ig, fb: fb };
}

// Parse raw venue sheet rows into venue objects.
// sentMaps comes from buildOutreachSentMaps_.
function buildVenues_(venueData, sentMaps) {
  var venues = [];
  for (var i = 1; i < venueData.length; i++) {
    var row = venueData[i];
    if (!row[0]) continue;
    var vid = String(row[0]);
    venues.push({
      venue_id:       vid,
      name:           String(row[1]),
      category:       String(row[2]),
      website:        String(row[3]),
      city:           String(row[4]),
      county:         String(row[5]),
      state:          String(row[6]),
      address:        String(row[7]),
      facebook:       String(row[8]),
      instagram:      String(row[9]),
      upscale_score:  Number(row[10]) || 3,
      zone_priority:  String(row[11]) || 'default',
      status:         String(row[12]) || 'untouched',
      source:         String(row[13]),
      scraped_date:   row[14] ? new Date(row[14]).toISOString() : '',
      notes:          String(row[15] || ''),
      distance_miles: row[16] ? Number(row[16]) : null,
      drive_minutes:  row[17] ? Number(row[17]) : null,
      contacted_date: row[18] ? new Date(row[18]).toISOString() : '',
      contact_form:   String(row[19] || ''),
      linkedin_pending: String(row[20]).toLowerCase() === 'true',
      venue_vote:     String(row[21] || ''),
      venue_feedback: String(row[22] || ''),
      check_status:   String(row[23] || ''),
      contact_form_sent: !!sentMaps.form[vid],
      ig_dm_sent: !!sentMaps.ig[vid],
      fb_msg_sent: !!sentMaps.fb[vid]
    });
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
      verified_date:  cr[7] ? new Date(cr[7]).toISOString() : '',
      email_sent:     (String(cr[8]).toLowerCase() === 'true' || String(cr[8]).toLowerCase() === 'skipped') ? String(cr[8]).toLowerCase() : false,
      email_sent_date: cr[9] ? new Date(cr[9]).toISOString() : '',
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
function getVenueStats_(venues, contacts) {
  var emailsSent = 0, igDmsSent = 0, fbMsgsSent = 0;
  var pendingEmails = 0, pendingVerify = 0;

  for (var k = 0; k < contacts.length; k++) {
    if (contacts[k].email_sent) emailsSent++;
    if (contacts[k].verified === 'valid' && !contacts[k].email_sent) pendingEmails++;
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

// Build the set of venue IDs AND names that have a past gig logged.
// Returns { ids: {vid: true}, namesList: [lowercase names] }
function getPastGigVenueIds_(ss) {
  var gigSheet = ss.getSheetByName(PAST_GIGS);
  var ids = {};
  var namesList = [];
  if (gigSheet) {
    var gd = gigSheet.getDataRange().getValues();
    for (var pg = 1; pg < gd.length; pg++) {
      if (gd[pg][1]) ids[String(gd[pg][1])] = true;
      if (gd[pg][0]) namesList.push(String(gd[pg][0]).toLowerCase().trim());
    }
  }
  ids._namesList = namesList;
  return ids;
}

// Build and sort the action-needed list (pipelined venues with
// unsent emails, IG, or FB). Returns the full sorted array.
function buildActionNeeded_(venues, contactsByVenue, pastGigVenueIds) {
  var actionNeeded = [];

  for (var v = 0; v < venues.length; v++) {
    var venue = venues[v];
    if (venue.status === 'contacted') continue;
    if (venue.status === 'untouched') continue;
    if (pastGigVenueIds[venue.venue_id]) continue;
    // Substring match: skip if venue name contains a past gig name or vice versa
    var vnLower = String(venue.name || '').toLowerCase().trim();
    var pgNames = pastGigVenueIds._namesList || [];
    var matchedPg = false;
    for (var pn = 0; pn < pgNames.length; pn++) {
      if (vnLower.indexOf(pgNames[pn]) > -1 || pgNames[pn].indexOf(vnLower) > -1) {
        matchedPg = true; break;
      }
    }
    if (matchedPg) continue;

    var vc = contactsByVenue[venue.venue_id] || [];
    var pendingEmailContacts = [];
    var hasIg = venue.instagram && venue.instagram.length > 5;
    var hasFb = venue.facebook && venue.facebook.length > 5;
    var igDone = !!venue.ig_dm_sent;
    var fbDone = !!venue.fb_msg_sent;

    for (var cc = 0; cc < vc.length; cc++) {
      var v2 = vc[cc].verified;
      if ((v2 === 'valid' || v2 === 'catch-all' || v2 === 'unknown') && !vc[cc].email_sent) {
        pendingEmailContacts.push(vc[cc]);
      }
    }

    var needsAction = pendingEmailContacts.length > 0 || (hasIg && !igDone) || (hasFb && !fbDone);
    if (needsAction) {
      actionNeeded.push({
        venue: venue,
        contacts: vc,
        pendingEmails: pendingEmailContacts,
        igPending: hasIg && !igDone,
        fbPending: hasFb && !fbDone
      });
    }
  }

  // Load taste tiers for scoring
  var ss = SpreadsheetApp.getActiveSpreadsheet();
  var tasteSheet = ss.getSheetByName(TASTE);
  var categoryTiers = {};
  var sweetSpotCities = {};
  if (tasteSheet) {
    var tData = tasteSheet.getDataRange().getValues();
    for (var ti = 1; ti < tData.length; ti++) {
      var tType = String(tData[ti][0]).toLowerCase();
      var tKey = String(tData[ti][1]).toLowerCase().trim();
      var tVal = String(tData[ti][2]);
      if (tType === 'tier') categoryTiers[tKey] = Number(tVal) || 3;
      else if (tType === 'location') sweetSpotCities[tKey] = true;
    }
  }

  // Taste tier points: tier 1 = 50, tier 2 = 30, tier 3 = 10, tier 4 = -20
  var tierPts = { 1: 50, 2: 30, 3: 10, 4: -20 };

  // Name-based taste boost for restaurants — French/European score like tier 1,
  // upscale/fine dining like tier 2, junk like tier 4
  var nameBoostWords = [
    'french', 'bistro', 'brasserie', 'boucherie', 'chaumiere', 'auberge',
    'la ferme', 'le chat', 'le comptoir', 'le refuge', 'petit louis',
    'european', 'portuguese', 'italia', 'trattoria', 'ristorante', 'osteria'
  ];
  var nameGoodWords = [
    'fine dining', 'steakhouse', 'prime', 'chophouse', 'grille',
    'tavern', 'inn ', ' inn', 'manor', 'estate'
  ];
  var nameJunkWords = [
    'ice cream', 'gelato', 'frozen', 'toast', 'bakery', 'pastry',
    'slice', 'cupcake', 'smoothie', 'juice', 'bagel', 'donut',
    'cafe', 'coffee', 'deli', 'sandwich', 'pizza', 'taco', 'burger',
    'pub', 'irish', 'beer garden', 'sports bar', 'hookah',
    'sweets', 'candy', 'dessert', 'acai', 'poke', 'bubble tea',
    'chicken', 'ramen', 'noodle', 'kebab', 'gyro', 'sushi',
    'clubhouse', 'pool', 'swim', 'tennis', 'golf', 'recreation',
    'liquor', 'wine shop', 'wine store', 'spirits'
  ];

  // Venue type ranking — matches alex_taste.md exactly
  // 1. Upscale French/European restaurants
  // 2. Historic private clubs
  // 3. Upscale country clubs with wine dinners
  // 4. Luxury boutique hotels
  // 5. Mountain/architectural wineries
  // 6. Nice restaurants in upscale areas
  // 7. Wine bars in wealthy neighborhoods
  // 8. Eastern Shore venues
  // 9. Average wineries
  // 10. Sports-focused country clubs
  var nameBoostWords = [
    'french', 'bistro', 'brasserie', 'boucherie', 'chaumiere', 'auberge',
    'la ferme', 'le chat', 'le comptoir', 'le refuge', 'petit louis',
    'european', 'portuguese', 'italia', 'trattoria', 'ristorante', 'osteria'
  ];
  var nameJunkWords = [
    'ice cream', 'gelato', 'frozen', 'toast', 'bakery', 'pastry',
    'slice', 'cupcake', 'smoothie', 'juice', 'bagel', 'donut',
    'cafe', 'coffee', 'deli', 'sandwich', 'pizza', 'taco', 'burger',
    'pub', 'irish', 'beer garden', 'sports bar', 'hookah',
    'sweets', 'candy', 'dessert', 'acai', 'poke', 'bubble tea',
    'chicken', 'ramen', 'noodle', 'kebab', 'gyro', 'sushi',
    'clubhouse', 'pool', 'swim', 'tennis', 'golf', 'recreation',
    'liquor', 'wine shop', 'wine store', 'spirits'
  ];

  // Score = taste rank (primary), distance as tiebreaker within same rank
  actionNeeded.forEach(function(item) {
    var v = item.venue;
    var cat = String(v.category || '').toLowerCase();
    var name = String(v.name || '').toLowerCase();
    var notes = String(v.notes || '').toLowerCase();
    var nameText = name + ' ' + notes;
    var vote = String(v.venue_vote || '');

    // Assign taste rank (lower = better, 1-10 matching the taste profile)
    var tasteRank = 6; // default: nice restaurant

    // Check for junk first — always last
    var isJunk = false;
    for (var nj = 0; nj < nameJunkWords.length; nj++) {
      if (name.indexOf(nameJunkWords[nj]) > -1) { isJunk = true; break; }
    }
    if (isJunk || vote === 'down') {
      tasteRank = 99;
    } else if (cat === 'restaurant' || cat === 'rest') {
      // Check if French/European
      var isFrenchEuro = false;
      for (var nb = 0; nb < nameBoostWords.length; nb++) {
        if (nameText.indexOf(nameBoostWords[nb]) > -1) { isFrenchEuro = true; break; }
      }
      if (isFrenchEuro) tasteRank = 1;  // #1 French/European
      else tasteRank = 6;               // #6 nice restaurant
    } else if (cat === 'private_club') {
      tasteRank = 2;                     // #2 historic private clubs
    } else if (cat === 'country_club') {
      tasteRank = 3;                     // #3 country clubs
    } else if (cat === 'hotel') {
      tasteRank = 4;                     // #4 luxury hotels
    } else if (cat === 'winery') {
      tasteRank = 5;                     // #5 wineries
    } else if (cat === 'wine_bar') {
      tasteRank = 5;                     // #5 wine bars (same tier as wineries)
    } else if (cat === 'art_gallery' || cat === 'museum') {
      tasteRank = 5;                     // #5 art/museum
    } else if (cat === 'yacht_club') {
      tasteRank = 3;                     // same as country clubs
    } else if (cat === 'event' || cat === 'event_venue') {
      tasteRank = 7;                     // events lower
    }

    // Vote boost: thumbs up moves venue up 2 ranks
    if (vote === 'up' && tasteRank > 1) tasteRank = Math.max(1, tasteRank - 2);

    // Distance as tiebreaker within rank (closer = higher score)
    var dist = v.distance_miles ? Number(v.distance_miles) : 50;
    var distTiebreak = Math.max(0, 100 - dist); // 0-100, closer = higher

    // Final score: rank is primary (inverted so higher = better), distance breaks ties
    item._topPickScore = (100 - tasteRank) * 1000 + distTiebreak;
  });

  actionNeeded.sort(function(a, b) {
    return (b._topPickScore || 0) - (a._topPickScore || 0);
  });

  return actionNeeded;
}

// Build state and category breakdowns from the venues array.
function buildBreakdowns_(venues) {
  var stateBreakdown = {};
  var categoryBreakdown = {};

  for (var i = 0; i < venues.length; i++) {
    var v = venues[i];
    var st = v.state || 'Unknown';
    if (!stateBreakdown[st]) stateBreakdown[st] = { total: 0, contacted: 0, pending: 0 };
    stateBreakdown[st].total++;
    if (v.status === 'contacted') stateBreakdown[st].contacted++;
    else stateBreakdown[st].pending++;

    var cat = v.category || 'other';
    if (!categoryBreakdown[cat]) categoryBreakdown[cat] = { total: 0, contacted: 0, pending: 0 };
    categoryBreakdown[cat].total++;
    if (v.status === 'contacted') categoryBreakdown[cat].contacted++;
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
      timestamp: r[0] ? new Date(r[0]).toISOString() : '',
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
// serveDashboardJSON_ — Assembles the full dashboard payload
// from the helper functions above.
// ---------------------------------------------------------------
function serveDashboardJSON_() {
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
  var venues = buildVenues_(venueData, sentMaps);
  var contacts = buildContacts_(contactData);
  var contactsByVenue = groupContactsByVenue_(contacts);

  // Build each dashboard section
  var stats = getVenueStats_(venues, contacts);
  var pastGigVenueIds = getPastGigVenueIds_(ss);
  var actionNeeded = buildActionNeeded_(venues, contactsByVenue, pastGigVenueIds);
  var topPicks = actionNeeded.slice(0, 10);
  var breakdowns = buildBreakdowns_(venues);
  var recentOutreach = getRecentOutreach_(outreachData);
  var gigs = loadGigs_(ss);
  var counts = getOutreachCounts_(outreachData);

  return jsonResponse_({
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
    categoryBreakdown: breakdowns.category
  });
}

// ---------------------------------------------------------------
// serveVenuesJSON_ — Return filtered venues
// Params: state, category, city, status
// ---------------------------------------------------------------
function serveVenuesJSON_(params) {
  var ss = SpreadsheetApp.getActiveSpreadsheet();
  var sheet = ss.getSheetByName(VENUES);
  var data = sheet.getDataRange().getValues();

  var filterState = (params.state || '').toUpperCase();
  var filterCategory = (params.category || '').toLowerCase();
  var filterCity = (params.city || '').toLowerCase();
  var filterStatus = (params.status || '').toLowerCase();

  var venues = [];
  for (var i = 1; i < data.length; i++) {
    var row = data[i];
    if (!row[0]) continue;
    if (filterState && String(row[6]).toUpperCase() !== filterState) continue;
    if (filterCategory && String(row[2]).toLowerCase() !== filterCategory) continue;
    if (filterCity && String(row[4]).toLowerCase().indexOf(filterCity) === -1) continue;
    if (filterStatus && String(row[12]).toLowerCase() !== filterStatus) continue;

    venues.push({
      venue_id: String(row[0]), name: String(row[1]), category: String(row[2]),
      website: String(row[3]), city: String(row[4]), county: String(row[5]),
      state: String(row[6]), facebook: String(row[8]), instagram: String(row[9]),
      upscale_score: Number(row[10]) || 3, zone_priority: String(row[11]) || 'default',
      status: String(row[12]) || 'untouched', contact_form: String(row[19] || ''),
      linkedin_pending: String(row[20]).toLowerCase() === 'true',
      check_status: String(row[23] || '')
    });
  }

  return jsonResponse_({ status: 'ok', venues: venues, count: venues.length });
}

// ---------------------------------------------------------------
// serveVenueDetail_ — Single venue with all its contacts
// ---------------------------------------------------------------
function serveVenueDetail_(params) {
  var venueId = params.venue_id || '';
  if (!venueId) return jsonResponse_({ status: 'error', message: 'venue_id required' });

  var ss = SpreadsheetApp.getActiveSpreadsheet();

  // Find venue
  var vSheet = ss.getSheetByName(VENUES);
  var vData = vSheet.getDataRange().getValues();
  var venue = null;
  for (var i = 1; i < vData.length; i++) {
    if (String(vData[i][0]) === venueId) {
      var row = vData[i];
      venue = {
        venue_id: String(row[0]), name: String(row[1]), category: String(row[2]),
        website: String(row[3]), city: String(row[4]), county: String(row[5]),
        state: String(row[6]), address: String(row[7]), facebook: String(row[8]),
        instagram: String(row[9]), upscale_score: Number(row[10]) || 3,
        zone_priority: String(row[11]) || 'default', status: String(row[12]) || 'untouched',
        source: String(row[13]), notes: String(row[15] || ''),
        contact_form: String(row[19] || ''),
        linkedin_pending: String(row[20]).toLowerCase() === 'true',
        venue_vote: String(row[21] || ''),
        venue_feedback: String(row[22] || ''),
        check_status: String(row[23] || '')
      };
      break;
    }
  }
  if (!venue) return jsonResponse_({ status: 'error', message: 'Venue not found' });

  // Check outreach log for IG/FB/form sent status
  var oSheet = ss.getSheetByName(OUTREACH);
  var oData = oSheet ? oSheet.getDataRange().getValues() : [[]];
  for (var ol = 1; ol < oData.length; ol++) {
    if (String(oData[ol][1]) === venueId) {
      var ch = String(oData[ol][3]);
      if (ch === 'instagram' || ch === 'instagram_skip') venue.ig_dm_sent = true;
      if (ch === 'facebook' || ch === 'facebook_skip') venue.fb_msg_sent = true;
      if (ch === 'contact_form' || ch === 'contact_form_skip') venue.contact_form_sent = true;
    }
  }

  // Find contacts
  var cSheet = ss.getSheetByName(CONTACTS);
  var cData = cSheet.getDataRange().getValues();
  var contacts = [];
  for (var j = 1; j < cData.length; j++) {
    if (String(cData[j][1]) === venueId) {
      contacts.push({
        contact_id: String(cData[j][0]), name: String(cData[j][2]),
        title: String(cData[j][3]), email: String(cData[j][4]),
        source: String(cData[j][5]), verified: String(cData[j][6]),
        email_sent: (String(cData[j][8]).toLowerCase() === 'true' || String(cData[j][8]).toLowerCase() === 'skipped') ? String(cData[j][8]).toLowerCase() : false,
        ig_dm_sent: (String(cData[j][10]).toLowerCase() === 'true' || String(cData[j][10]).toLowerCase() === 'skipped') ? String(cData[j][10]).toLowerCase() : false,
        fb_msg_sent: (String(cData[j][11]).toLowerCase() === 'true' || String(cData[j][11]).toLowerCase() === 'skipped') ? String(cData[j][11]).toLowerCase() : false
      });
    }
  }

  return jsonResponse_({ status: 'ok', venue: venue, contacts: contacts });
}

// ---------------------------------------------------------------
// addVenue_ — Add a new venue (called by scraper)
// ---------------------------------------------------------------
function addVenue_(params) {
  var ss = SpreadsheetApp.getActiveSpreadsheet();
  var sheet = ss.getSheetByName(VENUES);

  // Check for duplicate by name only (ignore state — same venue appears in MD/VA/DC searches)
  var data = sheet.getDataRange().getValues();
  for (var i = 1; i < data.length; i++) {
    if (String(data[i][1]).toLowerCase().trim() === (params.name || '').toLowerCase().trim()) {
      return jsonResponse_({ status: 'ok', message: 'Duplicate — skipped', venue_id: String(data[i][0]) });
    }
  }

  // Generate venue_id
  var venueId = params.venue_id || (params.state || 'XX').toUpperCase() + '-' +
    (params.category || 'OTHER').toUpperCase().substring(0, 4) + '-' +
    String(data.length).padStart(3, '0');

  sheet.appendRow([
    venueId,
    params.name || '',
    params.category || '',
    params.website || '',
    params.city || '',
    params.county || '',
    (params.state || '').toUpperCase(),
    params.address || '',
    params.facebook || '',
    params.instagram || '',
    Number(params.upscale_score) || 3,
    params.zone_priority || 'default',
    'untouched',
    params.source || '',
    new Date(),
    params.notes || '',
    '',    // distance_miles (16)
    '',    // drive_minutes (17)
    '',    // contacted_date (18)
    '',    // contact_form (19)
    false, // linkedin_pending (20)
    '',    // venue_vote (21)
    '',    // venue_feedback (22)
    ''     // check_status (23)
  ]);

  // Auto-calculate distance for new venue
  var newRow = sheet.getLastRow();
  var dest = params.address || '';
  if (!dest) dest = (params.city || '') + ', ' + (params.state || '');
  if (!dest || dest === ', ') dest = params.name || '';
  if (dest) {
    try {
      var directions = Maps.newDirectionFinder()
        .setOrigin(HOME_ADDRESS)
        .setDestination(dest)
        .setMode(Maps.DirectionFinder.Mode.DRIVING)
        .getDirections();
      if (directions.routes && directions.routes.length > 0) {
        var leg = directions.routes[0].legs[0];
        var miles = Math.round(leg.distance.value / 1609.34 * 10) / 10;
        var mins = Math.round(leg.duration.value / 60);
        sheet.getRange(newRow, 17).setValue(miles);
        sheet.getRange(newRow, 18).setValue(mins);
      }
    } catch(e) { /* Distance calc failed — run calc_distances later */ }
  }

  return jsonResponse_({ status: 'ok', venue_id: venueId, name: params.name });
}

// ---------------------------------------------------------------
// addContact_ — Add a contact for a venue (called by scraper)
// ---------------------------------------------------------------
function addContact_(params) {
  var ss = SpreadsheetApp.getActiveSpreadsheet();
  var sheet = ss.getSheetByName(CONTACTS);

  // Reject generic emails unless explicitly flagged
  var GENERIC_PREFIXES = [
    'info', 'manager', 'admin', 'office', 'contact', 'sales',
    'events', 'hello', 'support', 'reservations', 'frontdesk',
    'catering', 'eat', 'dine', 'host', 'general', 'mail'
  ];
  var emailLocal = (params.email || '').split('@')[0].toLowerCase();
  if (GENERIC_PREFIXES.indexOf(emailLocal) !== -1 && params.is_generic !== 'true') {
    return jsonResponse_({
      status: 'error',
      message: 'Generic email (' + emailLocal + '@) cannot be a contact. Use update_venue to store venue-level emails, or pass is_generic=true to override.'
    });
  }

  // Reject contacts without a real person name
  var name = (params.name || '').trim();
  if (!name) {
    return jsonResponse_({ status: 'error', message: 'Contact must have a name.' });
  }
  // Reject if name equals the email prefix, title, or is a generic role word
  var FAKE_NAMES = ['manager', 'admin', 'owner', 'chef', 'host', 'staff',
    'catering', 'events', 'private events', 'general', 'front desk', 'reception'];
  if (FAKE_NAMES.indexOf(name.toLowerCase()) !== -1) {
    return jsonResponse_({ status: 'error', message: 'Contact name "' + name + '" looks like a role, not a person. Provide a real first and last name.' });
  }
  if (name.toLowerCase() === emailLocal) {
    return jsonResponse_({ status: 'error', message: 'Contact name "' + name + '" matches email prefix. Provide a real person name.' });
  }

  // Check for duplicate email at same venue
  var data = sheet.getDataRange().getValues();
  for (var i = 1; i < data.length; i++) {
    if (String(data[i][4]).toLowerCase() === (params.email || '').toLowerCase() &&
        String(data[i][1]) === (params.venue_id || '')) {
      return jsonResponse_({ status: 'ok', message: 'Duplicate contact — skipped', contact_id: String(data[i][0]) });
    }
  }

  // Generate contact_id
  var contactId = params.contact_id || nextContactId_(data);

  sheet.appendRow([
    contactId,
    params.venue_id || '',
    params.name || '',
    params.title || '',
    params.email || '',
    params.source || 'website',
    params.verified || 'valid',
    new Date(),
    false,  // email_sent
    '',     // email_sent_date
    false,  // ig_dm_sent
    false   // fb_msg_sent
  ]);

  // Auto-calculate distance if venue is missing it
  calcDistanceForVenue_(params.venue_id || '');

  // Read-after-write: confirm the contact persisted
  SpreadsheetApp.flush();
  var lastRow = sheet.getLastRow();
  var persisted = sheet.getRange(lastRow, 1, 1, 5).getValues()[0];
  return jsonResponse_({
    status: 'ok',
    contact_id: contactId,
    email: params.email,
    persisted_name: String(persisted[2]),
    persisted_email: String(persisted[4]),
    verified: String(persisted[0]) === contactId
  });
}

// ---------------------------------------------------------------
// updateVenue_ — Update a venue field
// Params: venue_id, field, value
// ---------------------------------------------------------------
function updateVenue_(params) {
  var venueId = params.venue_id || '';
  var field = params.field || '';
  var value = params.value || '';
  if (!venueId || !field) return jsonResponse_({ status: 'error', message: 'venue_id and field required' });

  var ss = SpreadsheetApp.getActiveSpreadsheet();
  var sheet = ss.getSheetByName(VENUES);
  var data = sheet.getDataRange().getValues();
  var headers = data[0];

  // Find column index by header name
  var colIdx = -1;
  for (var h = 0; h < headers.length; h++) {
    if (String(headers[h]).toLowerCase().replace(/[_ ]/g, '') === field.toLowerCase().replace(/[_ ]/g, '')) {
      colIdx = h;
      break;
    }
  }
  if (colIdx === -1) return jsonResponse_({ status: 'error', message: 'Unknown field: ' + field });

  // Validate social URLs
  if ((field === 'facebook' || field === 'instagram') && value) {
    if (value.indexOf('http') !== 0 && value.indexOf('//') !== 0) {
      return jsonResponse_({ status: 'error', message: field + ' must be a full URL (got: ' + value + ')' });
    }
  }

  // Find venue row
  for (var i = 1; i < data.length; i++) {
    if (String(data[i][0]) === venueId) {
      sheet.getRange(i + 1, colIdx + 1).setValue(value);
      // Stamp contacted_date when marking as contacted, clear when resetting
      if (field === 'status' && value === 'contacted') {
        sheet.getRange(i + 1, 19).setValue(new Date()); // Column S = contacted_date
      } else if (field === 'status' && value === 'untouched') {
        sheet.getRange(i + 1, 19).setValue(''); // Clear contacted_date on reset
      }
      // Read-after-write: confirm the value persisted
      SpreadsheetApp.flush();
      var persisted = String(sheet.getRange(i + 1, colIdx + 1).getValue());
      return jsonResponse_({
        status: 'ok', venue_id: venueId, field: field,
        value: value, persisted: persisted,
        verified: persisted === value
      });
    }
  }

  return jsonResponse_({ status: 'error', message: 'Venue not found: ' + venueId });
}

// ---------------------------------------------------------------
// updateContact_ — Update a contact field
// Params: contact_id, field, value
// ---------------------------------------------------------------
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

  var colIdx = fieldMap[field];
  if (colIdx === undefined) return jsonResponse_({ status: 'error', message: 'Unknown field: ' + field });

  for (var i = 1; i < data.length; i++) {
    if (String(data[i][0]) === contactId && (!venueId || String(data[i][1]) === venueId)) {
      // Handle boolean/skipped fields
      if (field === 'email_sent' || field === 'ig_dm_sent' || field === 'fb_msg_sent') {
        if (value === 'skipped') {
          sheet.getRange(i + 1, colIdx + 1).setValue('skipped');
        } else {
          sheet.getRange(i + 1, colIdx + 1).setValue(value === 'true');
        }
        // Also set date if marking as sent
        if (value === 'true' && field === 'email_sent') {
          sheet.getRange(i + 1, 10).setValue(new Date()); // email_sent_date
        }
      } else {
        sheet.getRange(i + 1, colIdx + 1).setValue(value);
      }

      // Update venue status
      updateVenueStatus_(String(data[i][1]));

      return jsonResponse_({ status: 'ok', contact_id: contactId, field: field, value: value });
    }
  }

  return jsonResponse_({ status: 'error', message: 'Contact not found: ' + contactId });
}

// ---------------------------------------------------------------
// deleteContact_ — Delete a contact row by contact_id
// ---------------------------------------------------------------
function deleteContact_(params) {
  var contactId = params.contact_id || '';
  if (!contactId) return jsonResponse_({ status: 'error', message: 'contact_id required' });

  var ss = SpreadsheetApp.getActiveSpreadsheet();
  var sheet = ss.getSheetByName(CONTACTS);
  var data = sheet.getDataRange().getValues();

  for (var i = 1; i < data.length; i++) {
    if (String(data[i][0]) === contactId) {
      var venueId = String(data[i][1]);
      sheet.deleteRow(i + 1);
      updateVenueStatus_(venueId);
      return jsonResponse_({ status: 'ok', deleted: contactId });
    }
  }

  return jsonResponse_({ status: 'error', message: 'Contact not found: ' + contactId });
}

// ---------------------------------------------------------------
// fixDuplicateContactIds_ — Re-number contacts with duplicate IDs
// Run once to fix existing dupes, then remove. Safe: only changes
// column A (contact_id), preserves all other data.
// ---------------------------------------------------------------
function fixDuplicateContactIds_() {
  var ss = SpreadsheetApp.getActiveSpreadsheet();
  var sheet = ss.getSheetByName(CONTACTS);
  var data = sheet.getDataRange().getValues();
  var seen = {};
  var fixed = 0;
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

  // Second pass: re-number duplicates
  for (var id in seen) {
    if (seen[id].length <= 1) continue;
    // Keep the first occurrence, re-number the rest
    for (var j = 1; j < seen[id].length; j++) {
      max++;
      var newId = 'C-' + String(max).padStart(3, '0');
      var row = seen[id][j] + 1; // 1-indexed
      sheet.getRange(row, 1).setValue(newId);
      fixed++;
    }
  }

  return jsonResponse_({ status: 'ok', fixed: fixed, new_max: max });
}

// ---------------------------------------------------------------
// cleanupGenericEmails_ — Delete all contacts with generic/role-based emails
// ---------------------------------------------------------------
function cleanupGenericEmails_() {
  var generic = ['noreply@','no-reply@','support@','admin@','webmaster@','billing@',
    'info@','hello@','contact@','sales@','events@','reservations@','booking@',
    'enquiries@','inquiries@','office@','general@','frontdesk@','reception@',
    'dataremoval@','privacy@','careers@','jobs@','hr@','marketing@','press@',
    'media@','eat@','dine@','wine@','music@','art@','mail@'];

  var ss = SpreadsheetApp.getActiveSpreadsheet();
  var sheet = ss.getSheetByName(CONTACTS);
  var data = sheet.getDataRange().getValues();
  var deleted = [];
  var affectedVenues = {};

  // Iterate backwards to avoid row shift issues
  for (var i = data.length - 1; i >= 1; i--) {
    var email = String(data[i][4] || '').toLowerCase().trim();
    if (!email) continue;

    var isGeneric = false;
    for (var g = 0; g < generic.length; g++) {
      if (email.startsWith(generic[g])) {
        isGeneric = true;
        break;
      }
    }

    if (isGeneric) {
      var contactId = String(data[i][0]);
      var venueId = String(data[i][1]);

      sheet.deleteRow(i + 1);
      deleted.push(contactId);
      affectedVenues[venueId] = true;
    }
  }

  // Update venue statuses for any venue that lost a contact
  for (var vId in affectedVenues) {
    if (typeof updateVenueStatus_ === 'function') {
      updateVenueStatus_(vId);
    }
  }

  return jsonResponse_({
    status: 'ok',
    deletedCount: deleted.length,
    deletedContacts: deleted
  });
}

// ---------------------------------------------------------------
// deleteVenue_ — Delete a venue and all its contacts
// ---------------------------------------------------------------
function deleteVenue_(params) {
  var venueId = params.venue_id || '';
  if (!venueId) return jsonResponse_({ status: 'error', message: 'venue_id required' });

  var ss = SpreadsheetApp.getActiveSpreadsheet();

  // Delete all contacts for this venue (iterate backwards to avoid row shift)
  var cSheet = ss.getSheetByName(CONTACTS);
  var cData = cSheet.getDataRange().getValues();
  var deletedContacts = 0;
  for (var c = cData.length - 1; c >= 1; c--) {
    if (String(cData[c][1]) === venueId) {
      cSheet.deleteRow(c + 1);
      deletedContacts++;
    }
  }

  // Delete the venue row
  var vSheet = ss.getSheetByName(VENUES);
  var vData = vSheet.getDataRange().getValues();
  for (var v = 1; v < vData.length; v++) {
    if (String(vData[v][0]) === venueId) {
      vSheet.deleteRow(v + 1);
      return jsonResponse_({ status: 'ok', deleted: venueId, contacts_deleted: deletedContacts });
    }
  }

  return jsonResponse_({ status: 'error', message: 'Venue not found: ' + venueId });
}

// ---------------------------------------------------------------
// updateContactEmail_ — Update email for a contact matched by name + venue_id
// Used by Apollo enrichment to add emails to LinkedIn-discovered contacts
// Params: venue_id, name, email, verified, source
// ---------------------------------------------------------------
function updateContactEmail_(params) {
  var venueId = params.venue_id || '';
  var name = params.name || '';
  var email = params.email || '';
  if (!venueId || !name) return jsonResponse_({ status: 'error', message: 'venue_id and name required' });

  var ss = SpreadsheetApp.getActiveSpreadsheet();
  var sheet = ss.getSheetByName(CONTACTS);
  var data = sheet.getDataRange().getValues();

  // Find contact by name + venue_id (case-insensitive name match)
  var nameLower = name.toLowerCase().trim();
  for (var i = 1; i < data.length; i++) {
    if (String(data[i][1]) !== venueId) continue;
    if (String(data[i][2]).toLowerCase().trim() !== nameLower) continue;

    // Update email
    if (email) sheet.getRange(i + 1, 5).setValue(email);
    // Update source if provided
    if (params.source) sheet.getRange(i + 1, 6).setValue(params.source);
    // Update verified status
    if (params.verified) {
      sheet.getRange(i + 1, 7).setValue(params.verified);
      sheet.getRange(i + 1, 8).setValue(new Date());
    }

    return jsonResponse_({ status: 'ok', contact_id: String(data[i][0]), email: email, updated: true });
  }

  // If not found by name, create a new contact
  var contactId = nextContactId_(data);
  sheet.appendRow([
    contactId, venueId, name, params.title || '', email,
    params.source || 'apollo+linkedin', params.verified || 'pending',
    params.verified ? new Date() : '', false, '', false, false
  ]);

  return jsonResponse_({ status: 'ok', contact_id: contactId, email: email, created: true });
}

// ---------------------------------------------------------------
// updateVenueStatus_ — Auto-update venue status based on contacts
// ---------------------------------------------------------------
function updateVenueStatus_(venueId) {
  var ss = SpreadsheetApp.getActiveSpreadsheet();
  var venueSheet = ss.getSheetByName(VENUES);
  var vData = venueSheet.getDataRange().getValues();

  for (var v = 1; v < vData.length; v++) {
    if (String(vData[v][0]) !== venueId) continue;
    var oldStatus = String(vData[v][12]);

    // Only upgrade to 'contacted' — never downgrade pipelined/contacted
    if (oldStatus === 'contacted') break; // already at final state

    // Check if all valid emails have been sent
    var contactSheet = ss.getSheetByName(CONTACTS);
    var cData = contactSheet.getDataRange().getValues();
    var anyEmailSent = false;
    var allEmailsSent = true;

    for (var i = 1; i < cData.length; i++) {
      if (String(cData[i][1]) !== venueId) continue;
      var verified = String(cData[i][6]);
      var sent = String(cData[i][8]).toLowerCase() === 'true';
      if (sent) anyEmailSent = true;
      if ((verified === 'valid' || verified === 'catch-all' || verified === 'unknown') && !sent) allEmailsSent = false;
    }

    // Don't auto-set status — user must explicitly mark a venue done.
    // (Removed auto 'sent' status that was hiding venues prematurely.)
    break;
  }
}

// ---------------------------------------------------------------
// logOutreach_ — Record an outreach action
// ---------------------------------------------------------------
function logOutreach_(params) {
  var ss = SpreadsheetApp.getActiveSpreadsheet();
  var sheet = ss.getSheetByName(OUTREACH);

  sheet.appendRow([
    new Date(),
    params.venue_id || '',
    params.contact_id || '',
    params.channel || 'email',
    params.template_used || ''
  ]);

  // Increment total counter in Config
  var counterKey = 'total_' + (params.channel || 'email') + 's_sent';
  if (params.channel === 'email') counterKey = 'total_emails_sent';
  if (params.channel === 'instagram') counterKey = 'total_ig_dms';
  if (params.channel === 'facebook') counterKey = 'total_fb_msgs';

  var current = parseInt(getConfig_(counterKey)) || 0;
  setConfig_(counterKey, current + 1);

  return jsonResponse_({ status: 'ok', logged: true });
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
    var dt = data[i][0] ? Utilities.formatDate(new Date(data[i][0]), Session.getScriptTimeZone(), 'yyyy-MM-dd') : '';
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

// ---------------------------------------------------------------
// calcDistanceForVenue_ — Calculate distance for a single venue if missing
// Called automatically by addContact_ as a safety net
// ---------------------------------------------------------------
function calcDistanceForVenue_(venueId) {
  if (!venueId) return;
  var ss = SpreadsheetApp.getActiveSpreadsheet();
  var sheet = ss.getSheetByName(VENUES);
  var data = sheet.getDataRange().getValues();

  for (var i = 1; i < data.length; i++) {
    if (String(data[i][0]) !== venueId) continue;
    if (data[i][16]) return; // already has distance

    var dest = String(data[i][7] || '');
    if (!dest || dest === 'undefined') {
      dest = String(data[i][4] || '') + ', ' + String(data[i][6] || '');
    }
    if (!dest || dest === ', ') {
      dest = String(data[i][1] || ''); // fallback to venue name for geocoding
    }
    if (!dest) return;

    try {
      var directions = Maps.newDirectionFinder()
        .setOrigin(HOME_ADDRESS)
        .setDestination(dest)
        .setMode(Maps.DirectionFinder.Mode.DRIVING)
        .getDirections();
      if (directions.routes && directions.routes.length > 0) {
        var leg = directions.routes[0].legs[0];
        var miles = Math.round(leg.distance.value / 1609.34 * 10) / 10;
        var mins = Math.round(leg.duration.value / 60);
        sheet.getRange(i + 1, 17).setValue(miles);
        sheet.getRange(i + 1, 18).setValue(mins);
      }
    } catch(e) { /* silent fail */ }
    return;
  }
}

// ---------------------------------------------------------------
// calcDistances_ — Calculate driving distance from home to each venue
// Uses Google Maps Directions (built-in, free in Apps Script).
// Stores results in columns Q (distance_miles) and R (drive_minutes).
// Only calculates for venues missing distance data.
// ---------------------------------------------------------------
var HOME_ADDRESS = 'Dero Drive, Pasadena, MD 21122';

function calcDistances_() {
  var ss = SpreadsheetApp.getActiveSpreadsheet();
  var sheet = ss.getSheetByName(VENUES);
  var data = sheet.getDataRange().getValues();
  var calculated = 0;
  var errors = [];

  for (var i = 1; i < data.length; i++) {
    // Skip if already calculated
    if (data[i][16]) continue;

    // Need an address, city+state, or venue name as fallback
    var dest = String(data[i][7] || ''); // address column
    if (!dest || dest === 'undefined') {
      dest = String(data[i][4] || '') + ', ' + String(data[i][6] || ''); // city, state
    }
    if (!dest || dest === ', ') {
      dest = String(data[i][1] || ''); // fallback to venue name for geocoding
    }
    if (!dest) continue;

    try {
      var directions = Maps.newDirectionFinder()
        .setOrigin(HOME_ADDRESS)
        .setDestination(dest)
        .setMode(Maps.DirectionFinder.Mode.DRIVING)
        .getDirections();

      if (directions.routes && directions.routes.length > 0) {
        var leg = directions.routes[0].legs[0];
        var miles = Math.round(leg.distance.value / 1609.34 * 10) / 10;
        var mins = Math.round(leg.duration.value / 60);
        sheet.getRange(i + 1, 17).setValue(miles);    // Column Q
        sheet.getRange(i + 1, 18).setValue(mins);     // Column R
        calculated++;
      }
    } catch(e) {
      errors.push(String(data[i][1]) + ': ' + e.message);
    }

    // Rate limit — Apps Script Maps has quotas
    Utilities.sleep(200);
  }

  return jsonResponse_({
    status: 'ok',
    calculated: calculated,
    errors: errors
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
  var gigId = 'G-' + String(maxId + 1).padStart(3, '0');

  var tips = Number(params.rating_tips) || 5;
  var rebooked = Number(params.rating_rebooked) || 5;
  var audience = Number(params.rating_audience) || 5;
  var quality = Number(params.rating_venue_quality) || 5;
  var overall = Math.round(((tips + rebooked + audience + quality) / 4) * 10) / 10;

  var newRow = sheet.getLastRow() + 1;
  sheet.getRange(newRow, 1, 1, 12).setValues([[
    gigId,
    params.venue_id || '',
    params.venue_name || '',
    params.date || new Date().toISOString().split('T')[0],
    params.category || '',
    tips,
    rebooked,
    audience,
    quality,
    overall,
    params.notes || '',
    params.distance_miles ? Number(params.distance_miles) : ''
  ]]);

  // Calculate distance if we have a venue_id (and no manual distance)
  if (params.venue_id && !params.distance_miles) {
    var vSheet = ss.getSheetByName(VENUES);
    var vData = vSheet.getDataRange().getValues();
    for (var v = 1; v < vData.length; v++) {
      if (String(vData[v][0]) === params.venue_id && vData[v][16]) {
        sheet.getRange(newRow, 12).setValue(Number(vData[v][16]));
        break;
      }
    }
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
      if (params.venue_name) sheet.getRange(row, 3).setValue(params.venue_name);
      if (params.date) sheet.getRange(row, 4).setValue(params.date);
      if (params.category) sheet.getRange(row, 5).setValue(params.category);
      if (params.rating_tips) sheet.getRange(row, 6).setValue(Number(params.rating_tips));
      if (params.rating_rebooked) sheet.getRange(row, 7).setValue(Number(params.rating_rebooked));
      if (params.rating_audience) sheet.getRange(row, 8).setValue(Number(params.rating_audience));
      if (params.rating_venue_quality) sheet.getRange(row, 9).setValue(Number(params.rating_venue_quality));
      if (params.notes) sheet.getRange(row, 11).setValue(params.notes);
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
      if (!gData[g][0]) continue;
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
      email_sent: (String(cData[ci][8]).toLowerCase() === 'true' || String(cData[ci][8]).toLowerCase() === 'skipped') ? String(cData[ci][8]).toLowerCase() : false
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

  // Build set of past-gig venue IDs AND names to exclude from recommendations
  var pastGigVids = {};
  var pastGigNamesList = [];
  if (gigSheet) {
    var pgData = gigSheet.getDataRange().getValues();
    for (var pg = 1; pg < pgData.length; pg++) {
      if (pgData[pg][1]) pastGigVids[String(pgData[pg][1])] = true;
      if (pgData[pg][0]) pastGigNamesList.push(String(pgData[pg][0]).toLowerCase().trim());
    }
  }

  // Score each venue
  var recommendations = [];
  var zonePts = { green: 10, yellow: 5, 'default': 0 };
  var goodTitles = ['event', 'manager', 'director', 'coordinator', 'owner', 'general manager', 'marketing', 'hospitality'];
  var now = new Date();

  for (var vi = 1; vi < vData.length; vi++) {
    var row = vData[vi];
    if (!row[0]) continue;
    var venueId = String(row[0]);
    if (pastGigVids[venueId]) continue; // skip past gigs by ID
    // Substring match: skip if venue name contains a past gig name or vice versa
    // (catches "Bistrot Lepic" matching "Bistrot Lepic & Wine Bar")
    var vNameLower = String(row[1] || '').toLowerCase().trim();
    var isPastGig = false;
    for (var pn = 0; pn < pastGigNamesList.length; pn++) {
      if (vNameLower.indexOf(pastGigNamesList[pn]) > -1 || pastGigNamesList[pn].indexOf(vNameLower) > -1) {
        isPastGig = true; break;
      }
    }
    if (isPastGig) continue;
    var vVote = String(row[21] || '');
    var vStatus = String(row[12]) || 'untouched';
    if (vVote === 'down') continue; // explicitly rejected = always excluded
    var vCat = String(row[2]).toLowerCase();
    var vUpscale = Number(row[10]) || 3;
    var vZone = String(row[11]) || 'default';
    var vDist = row[16] ? Number(row[16]) : null;

    // Hard cutoff: skip venues beyond 150 miles (~2 hours highway)
    if (vDist !== null && vDist > 150) continue;

    // Junk filter: skip venues whose name contains any junk keyword
    var vName = String(row[1]).toLowerCase();
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

    // --- DISTANCE (0-10 pts) — just a tiebreaker, will drive for great gigs ---
    var distPts = 0;
    if (vDist !== null) {
      if (vDist <= 80) distPts = 10;
      else distPts = Math.round(Math.max(0, 10 * (1 - (vDist - 80) / 70)));
    } else {
      distPts = 5; // neutral if no distance data
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
    var vCity = String(row[4]).toLowerCase().trim();
    if (sweetSpotCities[vCity]) {
      locPts = 15;
    }

    var totalScore = Math.max(0, Math.min(100, catPts + distPts + upscalePts + zPts + cqPts + votePts + tastePts + locPts));

    recommendations.push({
      venue_id: venueId,
      name: String(row[1]),
      category: String(row[2]),
      city: String(row[4]),
      state: String(row[6]),
      upscale_score: vUpscale,
      zone_priority: vZone,
      status: vStatus,
      distance_miles: vDist,
      venue_vote: vVote,
      recommendation_score: totalScore,
      score_breakdown: {
        category: catPts,
        distance: distPts,
        upscale: upscalePts,
        zone: zPts,
        contact_quality: cqPts,
        vote: votePts,
        taste_tier: tastePts,
        location: locPts
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
    if (vData[fi][22] && String(vData[fi][22]).trim()) tasteReport.venues_with_feedback++;
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
function setupSheets() {
  var ss = SpreadsheetApp.getActiveSpreadsheet();

  var tabs = {
    'Venues': ['venue_id', 'name', 'category', 'website', 'city', 'county', 'state', 'address', 'facebook', 'instagram', 'upscale_score', 'zone_priority', 'status', 'source', 'scraped_date', 'notes', 'distance_miles', 'drive_minutes', 'contacted_date', 'contact_form', 'linkedin_pending', 'venue_vote', 'venue_feedback', 'check_status'],
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
    rows = JSON.parse(decodeURIComponent(dataStr));
  } catch(e) {
    return jsonResponse_({ status: 'error', message: 'Invalid JSON: ' + e.message });
  }

  if (!Array.isArray(rows) || rows.length === 0) {
    return jsonResponse_({ status: 'error', message: 'data must be a non-empty array' });
  }

  if (mode === 'replace') {
    // Clear everything except header
    if (sheet.getLastRow() > 1) {
      sheet.getRange(2, 1, sheet.getLastRow() - 1, 3).clearContent();
    }
    sheet.getRange(2, 1, rows.length, 3).setValues(rows);
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
  var sheet = ss.getSheetByName(CONTACTS);
  var data = sheet.getDataRange().getValues();
  var updated = 0;

  for (var i = 1; i < data.length; i++) {
    if (String(data[i][1]) === oldId) {
      sheet.getRange(i + 1, 2).setValue(newId);
      updated++;
    }
  }

  return jsonResponse_({ status: 'ok', updated: updated, old_venue_id: oldId, new_venue_id: newId });
}

// ---------------------------------------------------------------
// saveDiscovery_ — Save discovery tracker state (swept cities +
// venue counts) as JSON blobs in Config tab.
// Params: swept (JSON string), venues (JSON string)
// Only stores non-empty data — caller trims zero-count entries.
// ---------------------------------------------------------------
function saveDiscovery_(params) {
  if (params.swept)  setConfig_('discovery_swept',  params.swept);
  if (params.venues) setConfig_('discovery_venues', params.venues);
  setConfig_('discovery_updated', new Date().toISOString());
  return jsonResponse_({ status: 'ok' });
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

// Parse check_status string into {step: {status, detail}} map
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
    if (segs.length >= 2) {
      steps[segs[0]] = {
        status: segs[1],
        detail: segs.length > 2 ? segs.slice(2).join(':') : ''
      };
    }
  }
  return steps;
}

// Serialize steps map back to check_status string
function serializeCheckStatus_(steps) {
  var parts = [];
  for (var step in steps) {
    var entry = step + ':' + steps[step].status;
    if (steps[step].detail) entry += ':' + steps[step].detail;
    parts.push(entry);
  }
  return parts.join('|');
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
  var step = params.step || '';
  var stepStatus = params.status || 'MANUAL_VERIFIED';
  var detail = params.detail || '';

  if (!venueId || !step) return jsonResponse_({ status: 'error', message: 'venue_id and step required' });

  var validSteps = ['web', 'apollo', 'li', 'google', 'socials', 'enrich'];
  if (validSteps.indexOf(step) === -1) {
    return jsonResponse_({ status: 'error', message: 'Invalid step: ' + step + '. Must be one of: ' + validSteps.join(', ') });
  }

  var validStatuses = ['AUTO_FOUND', 'AUTO_NONE', 'MANUAL_VERIFIED', 'MANUAL_FOUND', 'FAILED'];
  if (validStatuses.indexOf(stepStatus) === -1) {
    return jsonResponse_({ status: 'error', message: 'Invalid status: ' + stepStatus + '. Must be one of: ' + validStatuses.join(', ') });
  }

  var ss = SpreadsheetApp.getActiveSpreadsheet();
  var sheet = ss.getSheetByName(VENUES);
  var data = sheet.getDataRange().getValues();

  for (var i = 1; i < data.length; i++) {
    if (String(data[i][0]) === venueId) {
      // Postcondition: socials step with MANUAL_VERIFIED requires facebook or instagram to actually exist
      if (step === 'socials' && (stepStatus === 'MANUAL_VERIFIED' || stepStatus === 'MANUAL_FOUND')) {
        var fb = String(data[i][8] || '').trim();
        var ig = String(data[i][9] || '').trim();
        if (!fb && !ig) {
          return jsonResponse_({
            status: 'error',
            message: 'Cannot mark socials as ' + stepStatus + ' — no facebook or instagram URL saved on venue. Call update_venue first, then save_step.'
          });
        }
      }

      var existing = parseCheckStatus_(String(data[i][23] || ''));
      existing[step] = { status: stepStatus, detail: detail };
      var newStr = serializeCheckStatus_(existing);
      sheet.getRange(i + 1, 24).setValue(newStr);
      return jsonResponse_({
        status: 'ok',
        venue_id: venueId,
        step: step,
        step_status: stepStatus,
        detail: detail,
        check_status: newStr,
        steps_complete: Object.keys(existing).length,
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
  var evidence = params.evidence || '';
  if (!venueId) return jsonResponse_({ status: 'error', message: 'venue_id required' });

  var ss = SpreadsheetApp.getActiveSpreadsheet();
  var sheet = ss.getSheetByName(VENUES);
  var data = sheet.getDataRange().getValues();

  for (var i = 1; i < data.length; i++) {
    if (String(data[i][0]) === venueId) {
      // Merge with existing steps rather than overwriting
      var existing = parseCheckStatus_(String(data[i][23] || ''));
      var newSteps = parseCheckStatus_(evidence);
      for (var step in newSteps) {
        existing[step] = newSteps[step];
      }
      var checkStr = serializeCheckStatus_(existing);
      sheet.getRange(i + 1, 24).setValue(checkStr);
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

  // Load contacts
  var cSheet = ss.getSheetByName(CONTACTS);
  var cData = cSheet.getDataRange().getValues();

  // Build contacts by venue + find pending enrichments
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
    if (hasName && !hasEmail) {
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
  var terminalStatuses = ['AUTO_FOUND', 'AUTO_NONE', 'MANUAL_VERIFIED', 'MANUAL_FOUND'];

  for (var i = 1; i < vData.length; i++) {
    var row = vData[i];
    if (!row[0]) continue;
    var status = String(row[12]) || 'untouched';
    if (status !== 'pipelined') continue;

    var venueId = String(row[0]);
    var checkStatus = String(row[23] || '');
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
        failedSteps.push({ venue_id: venueId, name: String(row[1]), step: stepName, detail: stepData.detail });
      } else if (terminalStatuses.indexOf(stepData.status) > -1) {
        completed.push(stepName);
      } else {
        missing.push(stepName);
      }
    }

    var entry = {
      venue_id: venueId,
      name: String(row[1]),
      city: String(row[4]),
      state: String(row[6]),
      website: String(row[3]),
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

  for (var i = 1; i < data.length; i++) {
    var website = String(data[i][3]).trim();
    if (!website) continue;
    try {
      var hostname = website.replace(/^https?:\/\//, '').split('/')[0]
                            .toLowerCase().replace(/^www\./, '');
      if (hostname === raw) {
        return jsonResponse_({ status: 'ok', venue_id: String(data[i][0]), name: String(data[i][1]) });
      }
    } catch (e) {}
  }
  return jsonResponse_({ status: 'error', message: 'Not found' });
}
