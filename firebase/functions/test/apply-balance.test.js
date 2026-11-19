'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');

const {
  expectedSignedQty,
  decideApply,
} = require('../lib/apply-balance');

function txn(overrides = {}) {
  return {
    type: 'incoming',
    qty: 3,
    signedQty: 3,
    userId: 'op1',
    ...overrides,
  };
}

test('expectedSignedQty mengikuti BR-01 dan menolak qty 0', () => {
  assert.equal(expectedSignedQty('incoming', 5), 5);
  assert.equal(expectedSignedQty('outgoing', 5), -5);
  assert.equal(expectedSignedQty('adjustment', -4), -4);
  assert.equal(expectedSignedQty('reversal', 2), 2);
  assert.equal(expectedSignedQty('incoming', 0), null);
  assert.equal(expectedSignedQty('outgoing', -5), null);
  assert.equal(expectedSignedQty('unknown', 5), null);
});

test('barang masuk menambah saldo', () => {
  const result = decideApply({
    transaction: txn({ qty: 3, signedQty: 3 }),
    balance: { endingQty: 10, lastTransactionId: 'old' },
    actorRole: 'operator',
    transactionId: 'tx-1',
  });

  assert.equal(result.action, 'apply');
  assert.equal(result.endingQty, 13);
  assert.equal(result.override, false);
});

test('barang keluar mengurangi saldo', () => {
  const result = decideApply({
    transaction: txn({ type: 'outgoing', qty: 4, signedQty: -4 }),
    balance: { endingQty: 10 },
    actorRole: 'operator',
    transactionId: 'tx-2',
  });

  assert.equal(result.action, 'apply');
  assert.equal(result.endingQty, 6);
});

test('signedQty yang tidak cocok ditolak tanpa menyentuh saldo', () => {
  const result = decideApply({
    transaction: txn({ type: 'outgoing', qty: 4, signedQty: 4 }),
    balance: { endingQty: 10 },
    actorRole: 'operator',
    transactionId: 'tx-3',
  });

  assert.equal(result.action, 'reject');
  assert.equal(result.reason, 'signed_mismatch');
  assert.equal(result.endingQty, undefined);
});

test('stok negatif tanpa override ditolak', () => {
  const result = decideApply({
    transaction: txn({ type: 'outgoing', qty: 12, signedQty: -12 }),
    balance: { endingQty: 10 },
    actorRole: 'operator',
    transactionId: 'tx-4',
  });

  assert.equal(result.action, 'reject');
  assert.equal(result.reason, 'negative_stock');
  assert.equal(result.endingQty, -2);
});

test('override oleh operator ditolak meski alasan ada', () => {
  const result = decideApply({
    transaction: txn({
      type: 'outgoing',
      qty: 12,
      signedQty: -12,
      approval: { status: 'pending', reason: 'stok fisik lebih banyak' },
    }),
    balance: { endingQty: 10 },
    actorRole: 'operator',
    transactionId: 'tx-5',
  });

  assert.equal(result.action, 'reject');
  assert.equal(result.reason, 'override_not_allowed');
});

test('override supervisor dengan alasan diterapkan dan ditandai', () => {
  const result = decideApply({
    transaction: txn({
      type: 'outgoing',
      qty: 12,
      signedQty: -12,
      approval: { status: 'pending', reason: 'barang keluar belum tercatat' },
    }),
    balance: { endingQty: 10 },
    actorRole: 'supervisor',
    transactionId: 'tx-6',
  });

  assert.equal(result.action, 'apply');
  assert.equal(result.endingQty, -2);
  assert.equal(result.override, true);
  assert.equal(result.reason, 'barang keluar belum tercatat');
});

test('alasan override terlalu pendek diperlakukan seperti tanpa override', () => {
  const result = decideApply({
    transaction: txn({
      type: 'outgoing',
      qty: 12,
      signedQty: -12,
      approval: { status: 'pending', reason: '  x ' },
    }),
    balance: { endingQty: 10 },
    actorRole: 'supervisor',
    transactionId: 'tx-7',
  });

  assert.equal(result.action, 'reject');
  assert.equal(result.reason, 'negative_stock');
});

test('replay dengan lastTransactionId sama dilewati', () => {
  const result = decideApply({
    transaction: txn(),
    balance: { endingQty: 13, lastTransactionId: 'tx-8' },
    actorRole: 'operator',
    transactionId: 'tx-8',
  });

  assert.equal(result.action, 'skip');
  assert.equal(result.reason, 'replay');
});

test('saldo belum ada dianggap 0', () => {
  const incoming = decideApply({
    transaction: txn({ qty: 2, signedQty: 2 }),
    balance: null,
    actorRole: 'operator',
    transactionId: 'tx-9',
  });
  assert.equal(incoming.endingQty, 2);

  const outgoing = decideApply({
    transaction: txn({ type: 'outgoing', qty: 2, signedQty: -2 }),
    balance: null,
    actorRole: 'operator',
    transactionId: 'tx-10',
  });
  assert.equal(outgoing.action, 'reject');
  assert.equal(outgoing.reason, 'negative_stock');
});

function reversalTxn(signedQty) {
  return txn({
    type: 'reversal',
    qty: signedQty,
    signedQty,
    refTransactionId: 'tx-original',
  });
}

test('reversal sah mengembalikan saldo ke nilai sebelum transaksi asli', () => {
  const result = decideApply({
    transaction: reversalTxn(-5),
    balance: { endingQty: 5 },
    actorRole: 'supervisor',
    transactionId: 'tx-rev',
    reversal: {
      originalStatus: 'applied',
      alreadyReversed: false,
      originalSignedQty: 5,
    },
  });

  assert.equal(result.action, 'apply');
  assert.equal(result.endingQty, 0);
});

test('reversal ditolak bila transaksi asli belum diterapkan', () => {
  const result = decideApply({
    transaction: reversalTxn(-5),
    balance: { endingQty: 5 },
    actorRole: 'supervisor',
    transactionId: 'tx-rev',
    reversal: {
      originalStatus: 'pending',
      alreadyReversed: false,
      originalSignedQty: 5,
    },
  });

  assert.equal(result.action, 'reject');
  assert.equal(result.reason, 'original_not_applied');
});

test('reversal kedua ditolak walaupun datang dari device berbeda', () => {
  const result = decideApply({
    transaction: reversalTxn(-5),
    balance: { endingQty: 0 },
    actorRole: 'supervisor',
    transactionId: 'tx-rev-2',
    reversal: {
      originalStatus: 'applied',
      alreadyReversed: true,
      originalSignedQty: 5,
    },
  });

  assert.equal(result.action, 'reject');
  assert.equal(result.reason, 'already_reversed');
});

test('reversal dengan jumlah bukan kebalikan ditolak', () => {
  const result = decideApply({
    transaction: reversalTxn(-4),
    balance: { endingQty: 5 },
    actorRole: 'supervisor',
    transactionId: 'tx-rev',
    reversal: {
      originalStatus: 'applied',
      alreadyReversed: false,
      originalSignedQty: 5,
    },
  });

  assert.equal(result.action, 'reject');
  assert.equal(result.reason, 'reversal_qty_mismatch');
});
