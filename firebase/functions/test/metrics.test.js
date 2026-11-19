'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');

const { percentile, computeMetrics, THRESHOLDS } = require('../lib/metrics');

function txn(id, minutesAgo, status, lagMinutes = 1) {
  const created = new Date(Date.now() - minutesAgo * 60000);
  return {
    transactionId: id,
    serverStatus: status,
    createdAtServer: created,
    createdAtClient: created,
    processedAt: new Date(created.getTime() + lagMinutes * 60000),
    occurredAt: created,
  };
}

test('p95 mengambil nilai dengan indeks paling dekat ke atas', () => {
  assert.equal(percentile([1, 2, 3, 4, 100], 95), 100);
  assert.equal(percentile([1, 2, 3, 4], 50), 2);
  assert.equal(percentile([], 95), 0);
});

test('metrik sehat tidak memicu alarm', () => {
  const now = Date.now();
  const result = computeMetrics({
    transactions: [
      txn('a', 10, 'applied', 2),
      txn('b', 20, 'applied', 3),
      txn('c', 30, 'rejected', 1),
    ],
    cycles: [
      {
        lineCount: 100,
        varianceLineCount: 1,
        startedAt: new Date(now - 4 * 60 * 60000),
        submittedAt: new Date(now - 3 * 60 * 60000),
      },
    ],
    audits: [
      { action: 'transaction.saved', actorUid: 'op1' },
      { action: 'cycleCount.approve', actorUid: 'sv1' },
    ],
    userCount: 2,
  });

  assert.equal(result.metrics.m2, 66.67);
  assert.equal(result.metrics.m1, 99);
  assert.equal(result.alarms.includes('m3_sync_lag'), false);
  assert.equal(result.alarms.includes('m7_cycle_count_duration'), false);
  assert.equal(result.metrics.m6, 100);
  assert.equal(result.thresholds, THRESHOLDS);
});

test('alarm menyala saat success rate dan lag melewati ambang', () => {
  const now = Date.now();
  const result = computeMetrics({
    transactions: [
      {
        transactionId: 'slow',
        serverStatus: 'applied',
        createdAtServer: new Date(now - 30 * 60000),
        createdAtClient: new Date(now - 30 * 60000),
        processedAt: new Date(now),
      },
      {
        transactionId: 'bad',
        serverStatus: 'rejected',
        createdAtServer: new Date(now - 1000),
      },
    ],
    cycles: [],
    audits: [],
    userCount: 10,
  });

  assert.equal(result.metrics.m2, 50);
  assert.equal(result.metrics.m3, 30);
  assert.equal(result.alarms.includes('m2_sync_success_rate'), true);
  assert.equal(result.alarms.includes('m3_sync_lag'), true);
  assert.equal(result.alarms.includes('m6_adoption'), true);
});

test('accuracy 98% dan durasi sesi lebih dari sehari memicu alarm', () => {
  const now = Date.now();
  const result = computeMetrics({
    transactions: [],
    cycles: [
      {
        lineCount: 100,
        varianceLineCount: 3,
        startedAt: new Date(now - 50 * 60 * 60000),
        submittedAt: new Date(now - 1 * 60 * 60000),
      },
    ],
    audits: [],
    userCount: 1,
  });

  assert.equal(result.metrics.m1, 97);
  assert.equal(result.metrics.m7, 49);
  assert.equal(result.alarms.includes('m1_stock_accuracy'), true);
  assert.equal(result.alarms.includes('m7_cycle_count_duration'), true);
});
