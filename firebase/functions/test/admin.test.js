'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');

const {
  isAdmin,
  validateUserUpdate,
  validateRetryRequest,
} = require('../lib/admin');

test('hanya admin yang boleh mengelola user', () => {
  assert.equal(isAdmin('admin'), true);
  assert.equal(isAdmin('supervisor'), false);
  assert.equal(isAdmin('operator'), false);
});

test('perubahan role/active wajib disertai alasan yang cukup', () => {
  assert.deepEqual(
    validateUserUpdate({ role: 'supervisor', active: true, reason: 'mutasi jabatan gudang' }),
    {
      ok: true,
      changes: {
        role: 'supervisor',
        active: true,
        reason: 'mutasi jabatan gudang',
      },
    },
  );
  assert.equal(validateUserUpdate({ role: 'owner', reason: 'alasan yang panjang' }).error, 'invalid_role');
  assert.equal(validateUserUpdate({ active: 'ya', reason: 'alasan yang panjang' }).error, 'invalid_active');
  assert.equal(validateUserUpdate({ reason: 'alasan yang panjang' }).error, 'no_changes');
  assert.equal(validateUserUpdate({ active: false, reason: 'pendek' }).error, 'reason_too_short');
});

test('retry paksa butuh ID transaksi dan alasan', () => {
  assert.equal(validateRetryRequest({ reason: 'alasan yang panjang' }).error, 'missing_transaction_id');
  assert.equal(
    validateRetryRequest({ transactionId: 'tx-1', reason: 'pendek' }).error,
    'reason_too_short',
  );
  assert.deepEqual(
    validateRetryRequest({ transactionId: ' tx-1 ', reason: ' transaksi sempat tertolak ' }),
    { ok: true, transactionId: 'tx-1', reason: 'transaksi sempat tertolak' },
  );
});
