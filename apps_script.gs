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
  if (action === 'get_gigs')        return getGigs_();
  if (action === 'get_recommendations') return getRecommendations_();
  if (action === 'save_monthly')     return saveMonthly_(e.parameter);
  if (action === 'load_monthly')     return loadMonthly_();

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
function serveDashboardJSON_() {
  var ss = SpreadsheetApp.getActiveSpreadsheet();

  // Read all venues
  var venueSheet = ss.getSheetByName(VENUES);
  var venueData = venueSheet ? venueSheet.getDataRange().getValues() : [[]];
  var venueHeaders = venueData[0] || [];

  // Read all contacts
  var contactSheet = ss.getSheetByName(CONTACTS);
  var contactData = contactSheet ? contactSheet.getDataRange().getValues() : [[]];
  var contactHeaders = contactData[0] || [];

  // Read outreach log
  var outreachSheet = ss.getSheetByName(OUTREACH);
  var outreachData = outreachSheet ? outreachSheet.getDataRange().getValues() : [[]];

  // Build venues array
  var venues = [];
  for (var i = 1; i < venueData.length; i++) {
    var row = venueData[i];
    if (!row[0]) continue; // skip empty rows
    venues.push({
      venue_id:       String(row[0]),
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
      contact_form:   String(row[19] || '')
    });
  }

  // Build contacts array
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
      email_sent:     String(cr[8]).toLowerCase() === 'true',
      email_sent_date: cr[9] ? new Date(cr[9]).toISOString() : '',
      ig_dm_sent:     String(cr[10]).toLowerCase() === 'true',
      fb_msg_sent:    String(cr[11]).toLowerCase() === 'true'
    });
  }

  // Build contact map by venue_id
  var contactsByVenue = {};
  for (var c = 0; c < contacts.length; c++) {
    var vid = contacts[c].venue_id;
    if (!contactsByVenue[vid]) contactsByVenue[vid] = [];
    contactsByVenue[vid].push(contacts[c]);
  }

  // Calculate stats
  var totalVenues = venues.length;
  var totalContacts = contacts.length;
  var emailsSent = 0, igDmsSent = 0, fbMsgsSent = 0;
  var pendingEmails = 0, pendingVerify = 0;

  for (var k = 0; k < contacts.length; k++) {
    if (contacts[k].email_sent) emailsSent++;
    if (contacts[k].ig_dm_sent) igDmsSent++;
    if (contacts[k].fb_msg_sent) fbMsgsSent++;
    if (contacts[k].verified === 'valid' && !contacts[k].email_sent) pendingEmails++;
    if (contacts[k].verified === 'pending') pendingVerify++;
  }

  var totalOutreach = emailsSent + igDmsSent + fbMsgsSent;

  // Build set of past-gig venue IDs so we exclude them from Top Picks
  var gigSheet2 = ss.getSheetByName(PAST_GIGS);
  var pastGigVenueIds = {};
  if (gigSheet2) {
    var gd = gigSheet2.getDataRange().getValues();
    for (var pg = 1; pg < gd.length; pg++) {
      if (gd[pg][1]) pastGigVenueIds[String(gd[pg][1])] = true;
    }
  }

  // Build action needed — venues with pending actions
  var actionNeeded = [];
  for (var v = 0; v < venues.length; v++) {
    var venue = venues[v];
    if (venue.status === 'contacted') continue; // skip fully done
    if (pastGigVenueIds[venue.venue_id]) continue; // skip past gigs
    var vc = contactsByVenue[venue.venue_id] || [];
    var pendingEmailContacts = [];
    var hasIg = venue.instagram && venue.instagram.length > 5;
    var hasFb = venue.facebook && venue.facebook.length > 5;
    var igDone = false, fbDone = false;

    for (var cc = 0; cc < vc.length; cc++) {
      if (vc[cc].verified === 'valid' && !vc[cc].email_sent) {
        pendingEmailContacts.push(vc[cc]);
      }
      if (vc[cc].ig_dm_sent) igDone = true;
      if (vc[cc].fb_msg_sent) fbDone = true;
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

  // Sort action needed by upscale_score desc, then zone_priority (green > yellow > default)
  var zonePriority = { green: 3, yellow: 2, 'default': 1 };
  actionNeeded.sort(function(a, b) {
    var zoneA = zonePriority[a.venue.zone_priority] || 1;
    var zoneB = zonePriority[b.venue.zone_priority] || 1;
    if (zoneB !== zoneA) return zoneB - zoneA;
    return (b.venue.upscale_score || 3) - (a.venue.upscale_score || 3);
  });

  // Top picks = first 10 action needed
  var topPicks = actionNeeded.slice(0, 10);

  // State breakdown
  var stateBreakdown = {};
  for (var sv = 0; sv < venues.length; sv++) {
    var st = venues[sv].state || 'Unknown';
    if (!stateBreakdown[st]) stateBreakdown[st] = { total: 0, contacted: 0, pending: 0 };
    stateBreakdown[st].total++;
    if (venues[sv].status === 'contacted') stateBreakdown[st].contacted++;
    else stateBreakdown[st].pending++;
  }

  // Category breakdown
  var categoryBreakdown = {};
  for (var cv = 0; cv < venues.length; cv++) {
    var cat = venues[cv].category || 'other';
    if (!categoryBreakdown[cat]) categoryBreakdown[cat] = { total: 0, contacted: 0, pending: 0 };
    categoryBreakdown[cat].total++;
    if (venues[cv].status === 'contacted') categoryBreakdown[cat].contacted++;
    else categoryBreakdown[cat].pending++;
  }

  // Recent outreach (last 20)
  var recentOutreach = [];
  for (var ro = Math.max(1, outreachData.length - 20); ro < outreachData.length; ro++) {
    var or = outreachData[ro];
    if (!or[0]) continue;
    recentOutreach.push({
      timestamp: or[0] ? new Date(or[0]).toISOString() : '',
      venue_id: String(or[1]),
      contact_id: String(or[2]),
      channel: String(or[3]),
      template_used: String(or[4])
    });
  }
  recentOutreach.reverse();

  // Load past gigs for dashboard
  var gigSheet = ss.getSheetByName(PAST_GIGS);
  var gigs = [];
  if (gigSheet) {
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
  }

  return jsonResponse_({
    status: 'ok',
    stats: {
      totalVenues: totalVenues,
      totalContacts: totalContacts,
      emailsSent: emailsSent,
      igDmsSent: igDmsSent,
      fbMsgsSent: fbMsgsSent,
      pendingEmails: pendingEmails,
      pendingVerify: pendingVerify,
      totalOutreach: totalOutreach
    },
    topPicks: topPicks,
    actionNeeded: actionNeeded,
    venues: venues,
    contacts: contacts,
    gigs: gigs,
    recentOutreach: recentOutreach,
    stateBreakdown: stateBreakdown,
    categoryBreakdown: categoryBreakdown
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
      status: String(row[12]) || 'untouched', contact_form: String(row[19] || '')
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
        contact_form: String(row[19] || '')
      };
      break;
    }
  }
  if (!venue) return jsonResponse_({ status: 'error', message: 'Venue not found' });

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
        email_sent: String(cData[j][8]).toLowerCase() === 'true',
        ig_dm_sent: String(cData[j][10]).toLowerCase() === 'true',
        fb_msg_sent: String(cData[j][11]).toLowerCase() === 'true'
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

  // Check for duplicate by name + state
  var data = sheet.getDataRange().getValues();
  for (var i = 1; i < data.length; i++) {
    if (String(data[i][1]).toLowerCase() === (params.name || '').toLowerCase() &&
        String(data[i][6]).toUpperCase() === (params.state || '').toUpperCase()) {
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
    params.notes || ''
  ]);

  // Auto-calculate distance for new venue
  var newRow = sheet.getLastRow();
  var dest = params.address || '';
  if (!dest) dest = (params.city || '') + ', ' + (params.state || '');
  if (dest && dest !== ', ') {
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

  // Check for duplicate email at same venue
  var data = sheet.getDataRange().getValues();
  for (var i = 1; i < data.length; i++) {
    if (String(data[i][4]).toLowerCase() === (params.email || '').toLowerCase() &&
        String(data[i][1]) === (params.venue_id || '')) {
      return jsonResponse_({ status: 'ok', message: 'Duplicate contact — skipped', contact_id: String(data[i][0]) });
    }
  }

  // Generate contact_id
  var contactId = params.contact_id || 'C-' + String(data.length).padStart(3, '0');

  sheet.appendRow([
    contactId,
    params.venue_id || '',
    params.name || '',
    params.title || '',
    params.email || '',
    params.source || 'website',
    params.verified || 'pending',
    params.verified === 'valid' || params.verified === 'invalid' ? new Date() : '',
    false,  // email_sent
    '',     // email_sent_date
    false,  // ig_dm_sent
    false   // fb_msg_sent
  ]);

  // Auto-calculate distance if venue is missing it
  calcDistanceForVenue_(params.venue_id || '');

  return jsonResponse_({ status: 'ok', contact_id: contactId, email: params.email });
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
      return jsonResponse_({ status: 'ok', venue_id: venueId, field: field, value: value });
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
  var field = params.field || '';
  var value = params.value || '';
  if (!contactId || !field) return jsonResponse_({ status: 'error', message: 'contact_id and field required' });

  var ss = SpreadsheetApp.getActiveSpreadsheet();
  var sheet = ss.getSheetByName(CONTACTS);
  var data = sheet.getDataRange().getValues();

  // Column mapping
  var fieldMap = {
    'email_sent': 8, 'email_sent_date': 9, 'ig_dm_sent': 10, 'fb_msg_sent': 11,
    'verified': 6, 'verified_date': 7, 'name': 2, 'title': 3, 'email': 4
  };

  var colIdx = fieldMap[field];
  if (colIdx === undefined) return jsonResponse_({ status: 'error', message: 'Unknown field: ' + field });

  for (var i = 1; i < data.length; i++) {
    if (String(data[i][0]) === contactId) {
      // Handle boolean fields
      if (field === 'email_sent' || field === 'ig_dm_sent' || field === 'fb_msg_sent') {
        sheet.getRange(i + 1, colIdx + 1).setValue(value === 'true');
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
  var contactId = 'C-' + String(data.length).padStart(3, '0');
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
  var contactSheet = ss.getSheetByName(CONTACTS);
  var cData = contactSheet.getDataRange().getValues();

  var hasContacts = false;
  var allEmailsSent = true;
  var anyEmailSent = false;

  for (var i = 1; i < cData.length; i++) {
    if (String(cData[i][1]) !== venueId) continue;
    hasContacts = true;
    var verified = String(cData[i][6]);
    var sent = String(cData[i][8]).toLowerCase() === 'true';
    if (verified === 'valid' && !sent) allEmailsSent = false;
    if (sent) anyEmailSent = true;
  }

  if (!hasContacts) return;

  var venueSheet = ss.getSheetByName(VENUES);
  var vData = venueSheet.getDataRange().getValues();
  for (var v = 1; v < vData.length; v++) {
    if (String(vData[v][0]) === venueId) {
      var oldStatus = String(vData[v][12]);
      var newStatus = allEmailsSent && anyEmailSent ? 'contacted' : anyEmailSent ? 'in_progress' : 'untouched';
      venueSheet.getRange(v + 1, 13).setValue(newStatus); // Column M = status
      // Stamp contacted_date when newly contacted
      if (newStatus === 'contacted' && oldStatus !== 'contacted') {
        venueSheet.getRange(v + 1, 19).setValue(new Date()); // Column S
      }
      break;
    }
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
    if (!dest || dest === ', ') return;

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

    // Need an address or city+state
    var dest = String(data[i][7] || ''); // address column
    if (!dest || dest === 'undefined') {
      dest = String(data[i][4] || '') + ', ' + String(data[i][6] || ''); // city, state
    }
    if (!dest || dest === ', ') continue;

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
      email_sent: String(cData[ci][8]).toLowerCase() === 'true'
    });
  }

  // Build set of past-gig venue IDs to exclude from recommendations
  var pastGigVids = {};
  if (gigSheet) {
    var pgData = gigSheet.getDataRange().getValues();
    for (var pg = 1; pg < pgData.length; pg++) {
      if (pgData[pg][1]) pastGigVids[String(pgData[pg][1])] = true;
    }
  }

  // Score each venue
  var recommendations = [];
  var zonePts = { green: 10, yellow: 5, 'default': 0 };
  var goodTitles = ['event', 'manager', 'director', 'coordinator', 'owner', 'general manager', 'marketing', 'hospitality'];

  for (var vi = 1; vi < vData.length; vi++) {
    var row = vData[vi];
    if (!row[0]) continue;
    var venueId = String(row[0]);
    if (pastGigVids[venueId]) continue; // skip past gigs
    var vCat = String(row[2]).toLowerCase();
    var vUpscale = Number(row[10]) || 3;
    var vZone = String(row[11]) || 'default';
    var vStatus = String(row[12]) || 'untouched';
    var vDist = row[16] ? Number(row[16]) : null;

    // --- CATEGORY MATCH (0-30 pts) ---
    var catPts = 0;
    if (catScores[vCat] !== undefined) {
      // Scale: category avg score (1-10) maps to 0-30 pts
      catPts = Math.round((catScores[vCat] / 10) * 30);
    } else {
      // Unknown category: give neutral score based on overall average
      catPts = Math.round((totalAvg / 10) * 15);  // half weight for unknown
    }

    // --- DISTANCE MATCH (0-25 pts) ---
    var distPts = 0;
    if (vDist !== null && distances.length > 0) {
      var distDiff = Math.abs(vDist - medianDist);
      // Closer to median = more points. Falls off with distSpread
      distPts = Math.round(Math.max(0, 25 * (1 - distDiff / (distSpread * 2))));
    } else {
      distPts = 10; // neutral if no distance data
    }

    // --- UPSCALE MATCH (0-25 pts) ---
    var upscaleDiff = Math.abs(vUpscale - avgUpscale);
    var upscalePts = Math.round(Math.max(0, 25 * (1 - upscaleDiff / 5)));

    // --- ZONE BONUS (0-10 pts) ---
    var zPts = zonePts[vZone] || 0;

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

    var totalScore = Math.min(100, catPts + distPts + upscalePts + zPts + cqPts);

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
      recommendation_score: totalScore,
      score_breakdown: {
        category: catPts,
        distance: distPts,
        upscale: upscalePts,
        zone: zPts,
        contact_quality: cqPts
      },
      contact_count: vContacts.length
    });
  }

  // Sort by recommendation score descending
  recommendations.sort(function(a, b) { return b.recommendation_score - a.recommendation_score; });

  return jsonResponse_({
    status: 'ok',
    recommendations: recommendations,
    profile: {
      gig_count: gigs.length,
      best_category: Object.keys(catScores).sort(function(a, b) { return catScores[b] - catScores[a]; })[0] || 'none',
      avg_overall: Math.round(totalAvg * 10) / 10,
      median_distance: Math.round(medianDist),
      avg_upscale: Math.round(avgUpscale * 10) / 10
    }
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
    'Venues': ['venue_id', 'name', 'category', 'website', 'city', 'county', 'state', 'address', 'facebook', 'instagram', 'upscale_score', 'zone_priority', 'status', 'source', 'scraped_date', 'notes', 'distance_miles', 'drive_minutes', 'contacted_date', 'contact_form'],
    'Contacts': ['contact_id', 'venue_id', 'name', 'title', 'email', 'source', 'verified', 'verified_date', 'email_sent', 'email_sent_date', 'ig_dm_sent', 'fb_msg_sent'],
    'Outreach Log': ['timestamp', 'venue_id', 'contact_id', 'channel', 'template_used'],
    'Config': ['key', 'value'],
    'Templates': ['category', 'subject', 'body'],
    'Progress': ['state', 'category', 'last_scraped', 'venues_found', 'status'],
    'Past Gigs': ['gig_id', 'venue_id', 'venue_name', 'date', 'category', 'rating_tips', 'rating_rebooked', 'rating_audience', 'rating_venue_quality', 'overall_score', 'notes', 'distance_miles']
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

  // Delete default Sheet1 if it exists and has no data
  var sheet1 = ss.getSheetByName('Sheet1');
  if (sheet1 && sheet1.getLastRow() <= 1) {
    ss.deleteSheet(sheet1);
  }

  SpreadsheetApp.getUi().alert('Setup complete! All tabs created with headers.');
}
