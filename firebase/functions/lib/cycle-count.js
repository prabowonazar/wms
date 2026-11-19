'use strict';

/**
 * Logika murni cycle-count (FR-STK-03..07, BR-02/10).
 *
 * Adjustmentselalu berupa transaksi baru; saldo tidak pernah ditimpa.
 * Fungsi ini tidak mengakses Firestore agar bisa diuji tanpa emulator.
 */

/** variance = fisik - sistem (BR-02). */
function varianceOf(systemQty, countedQty) {
  return countedQty - systemQty;
}

/** Ringkasan sesi yang disimpan di dokumen cycleCounts. */
function summarizeSession(lines) {
  let varianceLineCount = 0;
  let totalVarianceQty = 0;
  for (const line of lines || []) {
    const variance = Number.isInteger(line.variance)
      ? line.variance
      : varianceOf(line.systemQty, line.countedQty);
    if (variance !== 0) {
      varianceLineCount++;
      totalVarianceQty += variance;
    }
  }
  return {
    lineCount: (lines || []).length,
    varianceLineCount,
    totalVarianceQty,
  };
}

/**
 * Rencana adjustment: satu baris per variance != 0.
 *
 * Product uncounted sudah diisi `countedQty = systemQty` oleh client, sehingga
 * tidak muncul dalam rencana.
 */
function planAdjustments(lines, session) {
  const adjustments = [];
  for (const line of lines || []) {
    const variance = Number.isInteger(line.variance)
      ? line.variance
      : varianceOf(line.systemQty, line.countedQty);
    if (variance === 0) {
      continue;
    }
    adjustments.push({
      type: 'adjustment',
      qty: variance,
      signedQty: variance,
      cycleCountId: session.cycleCountId,
      productId: line.productId,
      productCode: line.productCode || '',
      productName: line.productName || '',
      uom: line.uom || '',
      periodKey: session.periodKey,
      warehouseId: session.warehouseId,
      userId: session.reviewedBy || session.startedBy,
      refLineProductId: line.productId,
      note: 'Penyesuaian hasil cycle-count',
    });
  }
  return adjustments;
}

/**
 * Keputusan approval. Idempoten: bila sesi sudah punya adjustmentTxnIds,
 * jangan membuat set baru (approve 2x = 1 set).
 */
function decideApproval(session, lines) {
  if (!session) {
    return { action: 'reject', reason: 'session_missing' };
  }
  if (session.status === 'approved') {
    return { action: 'noop', reason: 'already_approved' };
  }
  if (session.status !== 'submitted') {
    return { action: 'reject', reason: 'session_not_submitted' };
  }
  if (
    Array.isArray(session.adjustmentTxnIds) &&
    session.adjustmentTxnIds.length > 0
  ) {
    return { action: 'noop', reason: 'adjustments_already_created' };
  }
  const adjustments = planAdjustments(lines, session);
  const summary = summarizeSession(lines);
  if (adjustments.length === 0) {
    return { action: 'auto_approve', adjustments: [], summary };
  }
  return { action: 'approve', adjustments, summary };
}

module.exports = {
  varianceOf,
  summarizeSession,
  planAdjustments,
  decideApproval,
};
