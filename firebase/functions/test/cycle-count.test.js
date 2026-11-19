'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');

const {
  varianceOf,
  summarizeSession,
  planAdjustments,
  decideApproval,
} = require('../lib/cycle-count');

function line(productId, systemQty, countedQty) {
  return {
    productId,
    productCode: `BRG-${productId}`,
    productName: 'Produk',
    uom: 'box',
    systemQty,
    countedQty,
    variance: varianceOf(systemQty, countedQty),
  };
}

const session = {
  cycleCountId: 'cc-1',
  warehouseId: 'wh1',
  periodKey: '2026-11-19',
  status: 'submitted',
  startedBy: 'op1',
  reviewedBy: 'sv1',
};

test('variance = fisik dikurangi sistem', () => {
  assert.equal(varianceOf(10, 8), -2);
  assert.equal(varianceOf(10, 10), 0);
  assert.equal(varianceOf(10, 12), 2);
});

test('ringkasan menghitung baris dan total variance', () => {
  const summary = summarizeSession([line('p1', 10, 8), line('p2', 5, 5)]);
  assert.equal(summary.lineCount, 2);
  assert.equal(summary.varianceLineCount, 1);
  assert.equal(summary.totalVarianceQty, -2);
});

test('rencana adjustment hanya untuk baris yang berubah', () => {
  const plan = planAdjustments(
    [line('p1', 10, 8), line('p2', 5, 5), line('p3', 7, 9)],
    session,
  );
  assert.equal(plan.length, 2);
  assert.equal(plan[0].qty, -2);
  assert.equal(plan[0].signedQty, -2);
  assert.equal(plan[0].cycleCountId, 'cc-1');
  assert.equal(plan[1].qty, 2);
});

test('semua variance nol langsung disetujui tanpa adjustment', () => {
  const decision = decideApproval(session, [line('p1', 10, 10)]);
  assert.equal(decision.action, 'auto_approve');
  assert.equal(decision.adjustments.length, 0);
});

test('approve dua kali tidak menggandakan adjustment', () => {
  const first = decideApproval(session, [line('p1', 10, 8)]);
  assert.equal(first.action, 'approve');
  assert.equal(first.adjustments.length, 1);

  const second = decideApproval(
    { ...session, status: 'approved', adjustmentTxnIds: ['adj-1'] },
    [line('p1', 10, 8)],
  );
  assert.equal(second.action, 'noop');
  assert.equal(second.adjustments, undefined);

  const third = decideApproval(
    { ...session, adjustmentTxnIds: ['adj-1'] },
    [line('p1', 10, 8)],
  );
  assert.equal(third.action, 'noop');
});

test('sesi belum submitted tidak bisa disetujui', () => {
  assert.equal(
    decideApproval({ ...session, status: 'open' }, [line('p1', 10, 8)]).reason,
    'session_not_submitted',
  );
});
