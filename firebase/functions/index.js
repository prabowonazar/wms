'use strict';

const { onCall, HttpsError } = require('firebase-functions/v2/https');
const { initializeApp } = require('firebase-admin/app');

const { buildHealthPayload } = require('./lib/health');

initializeApp();

/**
 * Endpoint diagnostik: memastikan Functions v2 bisa dipanggil dengan token
 * pengguna. Tidak menyentuh Firestore, jadi aman dipanggil kapan saja.
 */
exports.health = onCall({ region: 'asia-southeast2' }, (request) => {
  if (!request.auth) {
    throw new HttpsError('unauthenticated', 'Butuh login.');
  }
  return buildHealthPayload({
    uid: request.auth.uid,
    now: new Date(),
  });
});
