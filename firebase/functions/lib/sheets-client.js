'use strict';

/**
 * Klien Google Sheets minimal lewat REST (tanpaket `googleapis`).
 *
 * Kredensial service account dibaca dari Firebase Secret, bukan dari repo.
 * [fetchImpl] bisa disuntik di test.
 */

const crypto = require('node:crypto');

const SHEETS_SCOPE = 'https://www.googleapis.com/auth/spreadsheets';
const TOKEN_URL = 'https://oauth2.googleapis.com/token';

function base64url(value) {
  return Buffer.from(value).toString('base64url');
}

/** JWT RS256 untuk pertukaran token OAuth (claims bisa diuji terpisah). */
function buildAssertion(credentials, nowMs = Date.now()) {
  const now = Math.floor(nowMs / 1000);
  const header = { alg: 'RS256', typ: 'JWT' };
  const claims = {
    iss: credentials.client_email,
    scope: SHEETS_SCOPE,
    aud: TOKEN_URL,
    iat: now,
    exp: now + 3600,
  };
  const unsigned = `${base64url(JSON.stringify(header))}.${base64url(
    JSON.stringify(claims),
  )}`;
  const signature = crypto
    .createSign('RSA-SHA256')
    .update(unsigned)
    .sign(credentials.private_key)
    .toString('base64url');
  return `${unsigned}.${signature}`;
}

async function fetchAccessToken(credentials, fetchImpl = fetch) {
  const response = await fetchImpl(TOKEN_URL, {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({
      grant_type: 'urn:ietf:params:oauth:grant-type:jwt-bearer',
      assertion: buildAssertion(credentials),
    }),
  });
  if (!response.ok) {
    throw new Error(`oauth_token_failed_${response.status}`);
  }
  const data = await response.json();
  if (!data.access_token) {
    throw new Error('oauth_token_missing');
  }
  return data.access_token;
}

function sheetsUrl(spreadsheetId, range, suffix = '') {
  return (
    `https://sheets.googleapis.com/v4/spreadsheets/` +
    `${encodeURIComponent(spreadsheetId)}/values/` +
    `${encodeURIComponent(range)}${suffix}`
  );
}

async function readRange(token, spreadsheetId, range, fetchImpl = fetch) {
  const response = await fetchImpl(sheetsUrl(spreadsheetId, range), {
    headers: { Authorization: `Bearer ${token}` },
  });
  if (!response.ok) {
    throw new Error(`sheets_read_failed_${response.status}`);
  }
  const data = await response.json();
  return data.values || [];
}

async function appendRange(
  token,
  spreadsheetId,
  range,
  values,
  fetchImpl = fetch,
) {
  const response = await fetchImpl(
    sheetsUrl(spreadsheetId, range, ':append?valueInputOption=RAW'),
    {
      method: 'POST',
      headers: {
        Authorization: `Bearer ${token}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({ values }),
    },
  );
  if (!response.ok) {
    throw new Error(`sheets_append_failed_${response.status}`);
  }
  const data = await response.json();
  return data.updates ? data.updates.updatedRows : values.length;
}

module.exports = {
  SHEETS_SCOPE,
  base64url,
  buildAssertion,
  fetchAccessToken,
  sheetsUrl,
  readRange,
  appendRange,
};
