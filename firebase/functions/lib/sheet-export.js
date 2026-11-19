'use strict';

/**
 * Logika murni ekspor & rekonsiliasi Google Sheets (FR-SYN-05..07, BR-05).
 * Tidak bergantung pada `googleapis`: trigger memakai REST + JWT, sedangkan
 * modul ini hanya menyiapkan data dan keputusan yang bisa diuji.
 */

const { checksumOf, WIB_OFFSET_MS } = require('./period-close');

const HEADER = [
  'TransactionID',
  'Periode',
  'Waktu (WIB)',
  'Kode',
  'Nama',
  'Jenis',
  'Qty',
  'UoM',
  'Operator',
  'Catatan',
];

function toDate(value) {
  if (value instanceof Date) {
    return value;
  }
  if (value && typeof value.toDate === 'function') {
    return value.toDate();
  }
  return new Date(0);
}

/** Waktu transaksi ditampilkan dalam WIB agar sesuai periodKey. */
function formatWib(value) {
  return new Date(toDate(value).getTime() + WIB_OFFSET_MS)
    .toISOString()
    .replace('T', ' ')
    .slice(0, 19);
}

/** Baris Sheet untuk transaksi yang sudah `applied` pada [periodKey]. */
function buildExportRows(transactions, periodKey) {
  return (transactions || [])
    .filter(
      (txn) =>
        txn.periodKey === periodKey && txn.serverStatus === 'applied',
    )
    .sort((a, b) => {
      const byTime = toDate(a.occurredAt) - toDate(b.occurredAt);
      return byTime !== 0
        ? byTime
        : String(a.transactionId).localeCompare(String(b.transactionId));
    })
    .map((txn) => [
      txn.transactionId,
      txn.periodKey,
      formatWib(txn.occurredAt),
      txn.productCode || '',
      txn.productName || '',
      txn.type || '',
      txn.qty,
      txn.uom || '',
      txn.userName || '',
      txn.note || '',
    ]);
}

/**
 * Idempotensi ekspor: baris dengan TransactionID yang sudah ada tidak
 * dikirim ulang (FR-SYN-06).
 */
function planExport(rows, existingIds) {
  const known = existingIds instanceof Set
    ? existingIds
    : new Set(existingIds || []);
  const toAppend = [];
  const duplicateIds = [];
  for (const row of rows || []) {
    const id = String(row[0]);
    if (known.has(id)) {
      duplicateIds.push(id);
    } else {
      toAppend.push(row);
      known.add(id);
    }
  }
  return {
    toAppend,
    duplicates: duplicateIds.length,
    duplicateIds,
  };
}

function normalizeRow(row) {
  const values = (row || []).map((value) =>
    value === null || value === undefined ? '' : String(value),
  );
  while (values.length > 0 && values[values.length - 1] === '') {
    values.pop();
  }
  return values;
}

/** Checksum atas baris yang dikirim/terbaca, dipakai deteksi edit manual. */
function rowsChecksum(rows) {
  return checksumOf((rows || []).map(normalizeRow));
}

/**
 * Membandingkan isi Sheet dengan sumber Firestore.
 *
 * - `partial`: ada baris ganda, hilang, atau tambahan.
 * - `tampered`: jumlah baris sama tetapi isi berubah.
 * - `verified`: identik.
 */
function reconcile({ expectedRows, sheetRows }) {
  const expected = (expectedRows || []).map(normalizeRow);
  const actual = (sheetRows || [])
    .filter((row) => {
      const first = row && row.length ? String(row[0]) : '';
      return first !== '' && first !== HEADER[0];
    })
    .map(normalizeRow);

  const expectedIds = expected.map((row) => row[0]);
  const expectedIdSet = new Set(expectedIds);
  const actualIds = actual.map((row) => row[0]);
  const actualIdSet = new Set(actualIds);
  const duplicates = actualIds.length - actualIdSet.size;
  const missing = expectedIds.filter((id) => !actualIdSet.has(id));
  const extra = actualIds.filter((id) => !expectedIdSet.has(id));

  const expectedChecksum = rowsChecksum(expected);
  const actualChecksum = rowsChecksum(actual);
  const checksumMatch = expectedChecksum === actualChecksum;

  let status;
  if (duplicates > 0 || missing.length > 0 || extra.length > 0) {
    status = 'partial';
  } else if (!checksumMatch) {
    status = 'tampered';
  } else {
    status = 'verified';
  }

  return {
    status,
    rowCount: actual.length,
    expectedRowCount: expected.length,
    duplicates,
    missing,
    extra,
    expectedChecksum,
    actualChecksum,
    checksumMatch,
  };
}

module.exports = {
  HEADER,
  formatWib,
  buildExportRows,
  planExport,
  normalizeRow,
  rowsChecksum,
  reconcile,
};
