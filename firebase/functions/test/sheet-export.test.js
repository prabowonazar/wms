'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');

const {
  HEADER,
  formatWib,
  buildExportRows,
  planExport,
  reconcile,
} = require('../lib/sheet-export');

function txn(id, occurredAt, overrides = {}) {
  return {
    transactionId: id,
    periodKey: '2026-11-18',
    serverStatus: 'applied',
    occurredAt: new Date(occurredAt),
    productCode: 'BRG-001',
    productName: 'Sarung',
    type: 'incoming',
    qty: 5,
    uom: 'box',
    userName: 'Operator 1',
    ...overrides,
  };
}

test('waktu Sheet ditampilkan dalam WIB', () => {
  assert.equal(
    formatWib(new Date('2026-11-18T17:30:00.000Z')),
    '2026-11-19 00:30:00',
  );
});

test('baris ekspor hanya applied pada periode yang diminta dan terurut', () => {
  const rows = buildExportRows(
    [
      txn('tx-late', '2026-11-18T10:00:00.000Z'),
      txn('tx-early', '2026-11-18T02:00:00.000Z'),
      txn('tx-reject', '2026-11-18T01:00:00.000Z', {
        serverStatus: 'rejected',
      }),
      txn('tx-other', '2026-11-17T09:00:00.000Z', {
        periodKey: '2026-11-17',
      }),
    ],
    '2026-11-18',
  );

  assert.deepEqual(
    rows.map((row) => row[0]),
    ['tx-early', 'tx-late'],
  );
  assert.equal(rows[0].length, HEADER.length);
});

test('export ulang tidak menggandakan transactionId', () => {
  const rows = [
    ['tx-1', 1],
    ['tx-2', 2],
    ['tx-3', 3],
  ];
  const plan = planExport(rows, ['tx-1', 'tx-3']);

  assert.deepEqual(plan.toAppend, [['tx-2', 2]]);
  assert.equal(plan.duplicates, 2);
  assert.equal(planExport(rows, []).duplicates, 0);
});

test('rekonsiliasi verified bila isi Sheet identik', () => {
  const expected = [
    ['tx-1', 'BRG-001', '5'],
    ['tx-2', 'BRG-002', '3'],
  ];
  const result = reconcile({
    expectedRows: expected,
    sheetRows: [HEADER, ...expected.map((row) => [...row, ''])],
  });

  assert.equal(result.status, 'verified');
  assert.equal(result.checksumMatch, true);
  assert.equal(result.rowCount, 2);
});

test('rekonsiliasi mendeteksi baris ganda dan baris hilang', () => {
  const expected = [['tx-1', '5'], ['tx-2', '3']];
  const partial = reconcile({
    expectedRows: expected,
    sheetRows: [HEADER, ['tx-1', '5'], ['tx-1', '5']],
  });

  assert.equal(partial.status, 'partial');
  assert.equal(partial.duplicates, 1);
  assert.deepEqual(partial.missing, ['tx-2']);
});

test('rekonsiliasi menandai tampered bila jumlah sama tetapi isi diubah', () => {
  const expected = [['tx-1', '5'], ['tx-2', '3']];
  const result = reconcile({
    expectedRows: expected,
    sheetRows: [['tx-1', '5'], ['tx-2', '99']],
  });

  assert.equal(result.status, 'tampered');
  assert.equal(result.checksumMatch, false);
  assert.notEqual(result.expectedChecksum, result.actualChecksum);
});
