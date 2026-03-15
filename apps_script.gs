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
      drive_minutes:  row[17] ? Number(row[17]) : null
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

  // Build action needed — venues with pending actions
  var actionNeeded = [];
  for (var v = 0; v < venues.length; v++) {
    var venue = venues[v];
    if (venue.status === 'contacted') continue; // skip fully done
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
      status: String(row[12]) || 'untouched'
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
        source: String(row[13]), notes: String(row[15] || '')
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
      var newStatus = allEmailsSent && anyEmailSent ? 'contacted' : anyEmailSent ? 'in_progress' : 'untouched';
      venueSheet.getRange(v + 1, 13).setValue(newStatus); // Column M = status
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
// setupSheets — Run ONCE to create all required tabs + headers
// Go to Apps Script editor → Run → setupSheets
// ---------------------------------------------------------------
function setupSheets() {
  var ss = SpreadsheetApp.getActiveSpreadsheet();

  var tabs = {
    'Venues': ['venue_id', 'name', 'category', 'website', 'city', 'county', 'state', 'address', 'facebook', 'instagram', 'upscale_score', 'zone_priority', 'status', 'source', 'scraped_date', 'notes', 'distance_miles', 'drive_minutes'],
    'Contacts': ['contact_id', 'venue_id', 'name', 'title', 'email', 'source', 'verified', 'verified_date', 'email_sent', 'email_sent_date', 'ig_dm_sent', 'fb_msg_sent'],
    'Outreach Log': ['timestamp', 'venue_id', 'contact_id', 'channel', 'template_used'],
    'Config': ['key', 'value'],
    'Templates': ['category', 'subject', 'body'],
    'Progress': ['state', 'category', 'last_scraped', 'venues_found', 'status']
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
