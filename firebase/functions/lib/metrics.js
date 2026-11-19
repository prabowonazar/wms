'use strict';

/** M1-M7: metrik operasional pilot (lihat PRD bagian Metrik). */

const THRESHOLDS = {
  m1Accuracy: 98,
  m2SuccessRate: 99.5,
  m3LagMinutes: 15,
  m4ErrorRate: 0.5,
  m6Adoption: 80,
  m7Hours: 24,
};

function toMillis(value) {
  if (!value) {
    return 0;
  }
  if (value instanceof Date) {
    return value.getTime();
  }
  if (typeof value.toMillis === 'function') {
    return value.toMillis();
  }
  return 0;
}

/** p95 dengan interpolasi indeks sederhana (paling dekat ke atas). */
function percentile(values, p = 95) {
  const sorted = values
    .filter((value) => Number.isFinite(value))
    .sort((a, b) => a - b);
  if (sorted.length === 0) {
    return 0;
  }
  const index = Math.max(
    0,
    Math.ceil((p / 100) * sorted.length) - 1,
  );
  return sorted[index];
}

function round(value, digits = 2) {
  const factor = 10 ** digits;
  return Math.round(value * factor) / factor;
}

/**
 * @param {object} args
 * @param {Array} args.transactions transaksi 24 jam terakhir.
 * @param {Array} args.cycles sesi cycle-count 7 hari terakhir.
 * @param {Array} args.audits audit log 7 hari terakhir.
 * @param {number} args.userCount jumlah operator terdaftar.
 */
function computeMetrics({ transactions, cycles, audits, userCount }) {
  const txns = transactions || [];
  const sessions = cycles || [];
  const logs = audits || [];
  const dayMs = 24 * 60 * 60 * 1000;
  const now = Date.now();

  const recentTxns = txns.filter(
    (txn) => now - toMillis(txn.createdAtServer || txn.occurredAt) <= dayMs,
  );
  const posted = recentTxns.filter((txn) => txn.serverStatus);
  const applied = posted.filter((txn) => txn.serverStatus === 'applied');
  const m2 = posted.length === 0
    ? 100
    : (applied.length / posted.length) * 100;

  const lags = applied
    .filter((txn) => txn.createdAtClient && txn.processedAt)
    .map((txn) =>
      (toMillis(txn.processedAt) - toMillis(txn.createdAtClient)) / 60000,
    )
    .filter((value) => value >= 0);
  const m3 = percentile(lags, 95);

  const reversals = logs.filter(
    (log) => log.action === 'transaction.reversal',
  ).length;
  const denominator = Math.max(posted.length, 1);
  const m4 = (reversals / denominator) * 100;

  const withLines = sessions.filter(
    (session) => Number.isInteger(session.lineCount) && session.lineCount > 0,
  );
  const m1 = withLines.length === 0
    ? 100
    : (withLines.reduce((sum, session) => {
        const varianceLines = session.varianceLineCount || 0;
        return sum + (1 - varianceLines / session.lineCount) * 100;
      }, 0) / withLines.length);

  const durations = sessions
    .filter((session) => session.startedAt && session.submittedAt)
    .map((session) =>
      (toMillis(session.submittedAt) - toMillis(session.startedAt)) /
      (60 * 60 * 1000),
    )
    .filter((value) => value >= 0);
  const m7 = percentile(durations, 95);

  const activeActors = new Set(
    logs
      .filter((log) => log.actorUid && log.actorUid !== 'system')
      .map((log) => log.actorUid),
  );
  const m6 = userCount > 0 ? (activeActors.size / userCount) * 100 : 0;

  const metrics = {
    m1: round(m1),
    m2: round(m2),
    m3: round(m3),
    m4: round(m4),
    m6: round(m6),
    m7: round(m7),
    computedAt: new Date(now).toISOString(),
  };
  const alarms = [];
  if (m1 < THRESHOLDS.m1Accuracy) {
    alarms.push('m1_stock_accuracy');
  }
  if (m2 < THRESHOLDS.m2SuccessRate) {
    alarms.push('m2_sync_success_rate');
  }
  if (m3 > THRESHOLDS.m3LagMinutes) {
    alarms.push('m3_sync_lag');
  }
  if (m4 > THRESHOLDS.m4ErrorRate) {
    alarms.push('m4_transaction_error');
  }
  if (m6 < THRESHOLDS.m6Adoption) {
    alarms.push('m6_adoption');
  }
  if (m7 > THRESHOLDS.m7Hours) {
    alarms.push('m7_cycle_count_duration');
  }
  return { metrics, alarms, thresholds: THRESHOLDS };
}

module.exports = {
  THRESHOLDS,
  percentile,
  computeMetrics,
};
