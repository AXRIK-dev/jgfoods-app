#!/usr/bin/env node
// portal-update.js
// Posts a build update to the AXRIK client portal (Supabase)
// Usage: node portal-update.js "Your message here" build
//
// Args:
//   1 - message  : update text shown to the client
//   2 - stage    : current stage (discovery | design | build | review | live)

const https = require('https');

const SUPABASE_URL  = 'udwnvezlxdscpvsyuyhe.supabase.co';
const SUPABASE_KEY  = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InVkd252ZXpseGRzY3B2c3l1eWhlIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODAzMzMyNzYsImV4cCI6MjA5NTkwOTI3Nn0.NYmKm6MK9j5O40hZUazwHzkKzsQx_6stKHCYDFoZNpo';
const PROJECT_ID    = '36edaf0b-c8b2-4ba4-985e-c32891b5c1f1';

const message = process.argv[2];
const stage   = process.argv[3] || 'build';

if (!message) {
  console.error('Usage: node portal-update.js "Your message" build');
  process.exit(1);
}

const payload = JSON.stringify({
  project_id   : PROJECT_ID,
  message      : message,
  stage_at_time: stage,
  posted_at    : new Date().toISOString()
});

const options = {
  hostname: SUPABASE_URL,
  path    : '/rest/v1/project_updates',
  method  : 'POST',
  headers : {
    'apikey'        : SUPABASE_KEY,
    'Authorization' : 'Bearer ' + SUPABASE_KEY,
    'Content-Type'  : 'application/json',
    'Prefer'        : 'return=representation'
  }
};

const req = https.request(options, res => {
  let body = '';
  res.on('data', chunk => body += chunk);
  res.on('end', () => {
    if (res.statusCode === 201 || res.statusCode === 200) {
      console.log('✅ Portal updated successfully.');
    } else {
      console.error('❌ Portal update failed:', res.statusCode, body);
      process.exit(1);
    }
  });
});

req.on('error', e => {
  console.error('❌ Network error:', e.message);
  process.exit(1);
});

req.write(payload);
req.end();
