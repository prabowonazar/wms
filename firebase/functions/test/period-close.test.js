'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');

const {
  periodKeyFor,
  previousPeriodKey,
  checksumOf,
  buildStockCards,
  buildPeriodSnapshot,
} = require('../lib/period-close');

test('periode memakai WIB (UTC+7) tanpa DST', () => {
  assert.equal(
    periodKeyFor(new Date('2026-11-18T17:30:00.000Z')),
    '2026-11-19',
  );
  assert.equal(
    periodKeyFor(new Date('2026-11-18T16:59:00.000Z')),
    '2026-11-18',
  );
});

test('D-1 dihitung dari jam WIB', () => {
  assert.equal(
    previousPeriodKey(new Date('2026-11-18T17:30:00.000Z')),
    '2026-11-18',
  );
});

test('checksum stabil walau urutan kunci berbeda', () => {
  assert.equal(
    checksumOf({ a: 1, b: 2 }),
    checksumOf({ b: 2, a: 1 }),
  );
  assert.notEqual(checksumOf([1, 2]), checksumOf([2, 1]));
});

test('stock card seimbang: opening + masuk - keluar + adj = ending', () => {
  const cards = buildStockCards({
    periodKey: '2026-11-18',
    transactions: [
      {
        productId: 'p1',
        periodKey: '2026-11-18',
        serverStatus: 'applied',
        type: 'incoming',
        qty: 5,
        signedQty: 5,
      },
      {
        productId: 'p1',
        periodKey: '2026-11-18',
        serverStatus: 'applied',
        type: 'outgoing',
        qty: 2,
        signedQty: -2,
      },
      {
        productId: 'p2',
        periodKey: '2026-11-17',
        serverStatus: 'applied',
        type: 'incoming',
        qty: 99,
        signedQty: 99,
      },
      {
        productId: 'p1',
        periodKey: '2026-11-18',
        serverStatus: 'rejected',
        type: 'outgoing',
        qty: 1,
        signedQty: -1,
      },
    ],
    products: [
      { productId: 'p1', productCode: 'BRG-001', productName: 'Sarung', uom: 'box' },
    ],
    balances: [{ productId: 'p1', warehouseId: 'wh1', endingQty: 8 }],
  });

  assert.equal(cards.length, 1);
  const card = cards[0];
  assert.equal(card.openingQty, 5);
  assert.equal(card.incomingQty, 5);
  assert.equal(card.outgoingQty, 2);
  assert.equal(card.endingQty, 8);
  assert.equal(
    card.openingQty + card.incomingQty - card.outgoingQty + card.adjustmentQty,
    card.endingQty,
  );
  assert.equal(card.transactionCount, 2);
});

test('snapshot periode memuat jumlah transaksi dan checksum', () => {
  const cards = [
    {
      productId: 'p1',
      productCode: 'BRG-001',
      openingQty: 0,
      incomingQty: 5,
      outgoingQty: 0,
      adjustmentQty: 0,
      endingQty: 5,
      transactionCount: 1,
    },
  ];
  const snapshot = buildPeriodSnapshot(
    cards,
    '2026-11-18',
    new Date('2026-11-19T00:05:00.000Z'),
  );

  assert.equal(snapshot.status, 'closed');
  assert.equal(snapshot.transactionCount, 1);
  assert.equal(snapshot.snapshotChecksum, checksumOf(cards));
});
