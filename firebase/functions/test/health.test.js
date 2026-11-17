'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');

const { buildHealthPayload } = require('../lib/health');

const NOW = new Date('2026-11-17T08:00:00.000Z');

test('health mengembalikan uid dan waktu server', () => {
  const payload = buildHealthPayload({ uid: 'op1', now: NOW });

  assert.equal(payload.ok, true);
  assert.equal(payload.uid, 'op1');
  assert.equal(payload.serverTime, '2026-11-17T08:00:00.000Z');
  assert.equal(payload.schemaVersion, 1);
});

test('health menolak uid kosong', () => {
  assert.throws(() => buildHealthPayload({ uid: '', now: NOW }), /uid wajib/);
});

test('health menolak waktu yang tidak valid', () => {
  assert.throws(
    () => buildHealthPayload({ uid: 'op1', now: new Date('invalid') }),
    /now harus Date/,
  );
});
