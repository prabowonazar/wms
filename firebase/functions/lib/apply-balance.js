'use strict';

/**
 * Logika murni penerapan transaksi ke saldo (BR-01, BR-03, BR-04).
 *
 * Dipisah dari Firestore agar bisa diuji tanpa emulator. Trigger
 * `applyBalance` hanya membaca/menulis dokumen dan memanggil fungsi ini.
 */

const TXN_TYPES = ['incoming', 'outgoing', 'adjustment', 'reversal'];

/** Role yang boleh override stok negatif (BR-03). */
const OVERRIDE_ROLES = ['supervisor', 'admin'];

/** Panjang minimum alasan override agar tidak diisi asal-asalan (UC-SCN-05). */
const MIN_OVERRIDE_REASON = 10;

/**
 * Qty bertanda yang benar untuk jenis transaksi. `null` bila kombinasi tidak
 * sah. Harus identik dengan CHECK di SQLite dan rules Firestore.
 */
function expectedSignedQty(type, qty) {
  if (!TXN_TYPES.includes(type)) {
    return null;
  }
  if (!Number.isInteger(qty) || qty === 0) {
    return null;
  }
  if (type === 'incoming') {
    return qty > 0 ? qty : null;
  }
  if (type === 'outgoing') {
    return qty > 0 ? -qty : null;
  }
  return qty;
}

function readBalanceQty(balance) {
  if (!balance || !Number.isInteger(balance.endingQty)) {
    return 0;
  }
  return balance.endingQty;
}

/**
 * Memutuskan apakah transaksi diterapkan, ditolak, atau dilewati.
 *
 * @param {object} args
 * @param {object} args.transaction data dokumen `transactions/{id}`.
 * @param {object|null} args.balance dokumen saldo saat ini (belum ada = null).
 * @param {string|null} args.actorRole role pengguna dari `users/{uid}`.
 * @param {string} args.transactionId document ID (= idempotency key).
 * @param {object|null} [args.reversal] konteks reversal dari server:
 *   `{ originalStatus, alreadyReversed, originalSignedQty }`.
 * @returns {{action: 'apply'|'reject'|'skip', reason: string,
 *   endingQty?: number, override?: boolean}}
 */
function decideApply({
  transaction,
  balance,
  actorRole,
  transactionId,
  reversal,
}) {
  if (!transaction || typeof transaction !== 'object') {
    return { action: 'reject', reason: 'missing_transaction' };
  }

  // Replay guard (BR-04): transaksi yang sudah pernah diterapkan tidak boleh
  // mengubah saldo lagi. Ini yang membuat retry 100x tetap satu kali.
  if (balance && balance.lastTransactionId === transactionId) {
    return { action: 'skip', reason: 'replay' };
  }

  const expected = expectedSignedQty(transaction.type, transaction.qty);
  if (expected === null) {
    return { action: 'reject', reason: 'invalid_type_or_qty' };
  }
  if (!Number.isInteger(transaction.signedQty) ||
      transaction.signedQty !== expected) {
    return { action: 'reject', reason: 'signed_mismatch' };
  }

  // BR-06: reversal hanya boleh untuk transaksi yang sudah diterapkan,
  // belum pernah dibatalkan, dan jumlahnya tepat kebalikan. Pemeriksaan ini
  // di server karena dua device bisa mengirim reversal berbeda bersamaan.
  if (transaction.type === 'reversal') {
    if (!reversal || reversal.originalStatus !== 'applied') {
      return { action: 'reject', reason: 'original_not_applied' };
    }
    if (reversal.alreadyReversed) {
      return { action: 'reject', reason: 'already_reversed' };
    }
    if (Number.isInteger(reversal.originalSignedQty) &&
        transaction.signedQty !== -reversal.originalSignedQty) {
      return { action: 'reject', reason: 'reversal_qty_mismatch' };
    }
  }

  const current = readBalanceQty(balance);
  const endingQty = current + expected;

  const approval = transaction.approval || {};
  const reason = typeof approval.reason === 'string'
    ? approval.reason.trim()
    : '';
  const requestedOverride =
    approval.status === 'pending' && reason.length >= MIN_OVERRIDE_REASON;

  if (endingQty < 0) {
    if (!requestedOverride) {
      return { action: 'reject', reason: 'negative_stock', endingQty };
    }
    if (!OVERRIDE_ROLES.includes(actorRole)) {
      return { action: 'reject', reason: 'override_not_allowed', endingQty };
    }
    return { action: 'apply', reason, endingQty, override: true };
  }

  return { action: 'apply', reason: '', endingQty, override: false };
}

module.exports = {
  TXN_TYPES,
  OVERRIDE_ROLES,
  MIN_OVERRIDE_REASON,
  expectedSignedQty,
  decideApply,
};
