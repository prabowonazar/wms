'use strict';

/**
 * Logika murni closing harian (FR-STK-08, BR-05).
 *
 * Semua perhitungan memakai periode WIB (UTC+7, tanpa DST). Fungsi ini sengaja
 * tidak menyentuh Firestore supaya bisa diuji tanpa emulator.
 */

const crypto = require('node:crypto');

const WIB_OFFSET_MS = 7 * 60 * 60 * 1000;
const DAY_MS = 24 * 60 * 60 * 1000;

/** Kunci periode `YYYY-MM-DD` menurut WIB. */
function periodKeyFor(date) {
  return new Date(date.getTime() + WIB_OFFSET_MS).toISOString().slice(0, 10);
}

/** Periode kemarin relatif terhadap [now] (D-1). */
function previousPeriodKey(now = new Date()) {
  return periodKeyFor(new Date(now.getTime() - DAY_MS));
}

/** JSON kanonik: urutan kunci stabil supaya checksum deterministik. */
function canonical(value) {
  if (Array.isArray(value)) {
    return value.map(canonical);
  }
  if (value && typeof value === 'object') {
    const result = {};
    for (const key of Object.keys(value).sort()) {
      result[key] = canonical(value[key]);
    }
    return result;
  }
  return value;
}

/** SHA-256 atas representasi kanonik (hex). */
function checksumOf(value) {
  return crypto
    .createHash('sha256')
    .update(JSON.stringify(canonical(value)))
    .digest('hex');
}

/**
 * Menyusun stock card satu periode dari ledger yang sudah `applied`.
 *
 * `opening` diambil dari saldo akhir server dikurangi mutasi periode ini,
 * sehingga berlaku juga untuk produk tanpa transaksi di periode sebelumnya.
 */
function buildStockCards({ transactions, products, balances, periodKey }) {
  const productMap = new Map(
    (products || []).map((product) => [product.productId, product]),
  );
  const balanceMap = new Map(
    (balances || []).map((balance) => [balance.productId, balance]),
  );
  const grouped = new Map();

  for (const txn of transactions || []) {
    if (txn.periodKey !== periodKey || txn.serverStatus !== 'applied') {
      continue;
    }
    if (!grouped.has(txn.productId)) {
      grouped.set(txn.productId, []);
    }
    grouped.get(txn.productId).push(txn);
  }

  const cards = [];
  for (const [productId, rows] of grouped) {
    const product = productMap.get(productId) || {};
    const balance = balanceMap.get(productId) || {};
    const signedTotal = rows.reduce(
      (sum, row) => sum + (Number.isInteger(row.signedQty) ? row.signedQty : 0),
      0,
    );
    const endingFromServer = Number.isInteger(balance.endingQty)
      ? balance.endingQty
      : signedTotal;
    const opening = endingFromServer - signedTotal;

    let incomingQty = 0;
    let outgoingQty = 0;
    let adjustmentQty = 0;
    for (const row of rows) {
      if (row.type === 'incoming') {
        incomingQty += row.qty;
      } else if (row.type === 'outgoing') {
        outgoingQty += row.qty;
      } else if (row.type === 'adjustment' || row.type === 'reversal') {
        adjustmentQty += row.signedQty;
      }
    }

    cards.push({
      warehouseId: balance.warehouseId || product.warehouseId || '',
      periodKey,
      productId,
      productCode: product.productCode || '',
      productName: product.productName || '',
      uom: product.uom || '',
      openingQty: opening,
      incomingQty,
      outgoingQty,
      adjustmentQty,
      endingQty: opening + incomingQty - outgoingQty + adjustmentQty,
      transactionCount: rows.length,
    });
  }

  cards.sort((a, b) => a.productCode.localeCompare(b.productCode));
  return cards;
}

/** Ringkasan periode yang ditutup; checksum dipakai verifikasi closing. */
function buildPeriodSnapshot(cards, periodKey, closedAt = new Date()) {
  return {
    status: 'closed',
    periodKey,
    openedAt: closedAt,
    closedAt,
    closedBy: 'system',
    transactionCount: cards.reduce(
      (sum, card) => sum + card.transactionCount,
      0,
    ),
    productCount: cards.length,
    snapshotChecksum: checksumOf(cards),
  };
}

module.exports = {
  WIB_OFFSET_MS,
  periodKeyFor,
  previousPeriodKey,
  canonical,
  checksumOf,
  buildStockCards,
  buildPeriodSnapshot,
};
