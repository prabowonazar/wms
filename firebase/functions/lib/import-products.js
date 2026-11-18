'use strict';

const crypto = require('node:crypto');

/**
 * Logika murni import produk (FR-MST-04/05, BR-13) tanpa Firestore, supaya
 * bisa diuji `node --test` tanpa emulator.
 *
 * Aturan bisnis mengikuti docs/product-import-spec.md. File CSV divalidasi
 * lebih dulu oleh Apps Script / tools/validate-products.ps1; modul ini adalah
 * pertahanan terakhir di server sebelum satu pun dokumen ditulis.
 */

const PRODUCT_TYPES = Object.freeze([
  'consumable',
  'spare_part',
  'tool',
  'packaging',
  'other',
]);

const UOMS = Object.freeze([
  'pcs',
  'box',
  'pack',
  'roll',
  'kg',
  'g',
  'liter',
  'ml',
  'meter',
  'set',
  'unit',
]);

/**
 * Batas per panggilan. Firestore membatasi ~500 dokumen per transaksi; satu
 * baris memakai 1 dokumen produk + minimal 1 barcode, jadi 100 baris masih
 * aman. File 5.000 baris dipecah menjadi beberapa batch oleh klien.
 */
const MAX_ROWS = 100;
const MAX_TRANSACTION_DOCS = 450;

const CODE_PATTERN = /^[A-Z0-9][A-Z0-9._-]{2,31}$/;
const BARCODE_PATTERN = /^[A-Z0-9._-]{4,48}$/;
const WAREHOUSE_PATTERN = /^[A-Z0-9][A-Z0-9._-]{1,31}$/;
const INJECTION_PREFIX = /^[=+\-@]/;

function normalizeText(value) {
  return typeof value === 'string' ? value.trim() : '';
}

function normalizeRow(row, warehouseId) {
  const barcodes = [];
  const rawBarcodes = Array.isArray(row.barcodes) ? row.barcodes : [];
  for (const raw of rawBarcodes) {
    const barcode = normalizeText(raw).toUpperCase();
    if (barcode !== '' && !barcodes.includes(barcode)) {
      barcodes.push(barcode);
    }
  }

  const rawMinStock = row.minStock;
  const minStock =
    rawMinStock === undefined || rawMinStock === null || rawMinStock === ''
      ? 0
      : Number(rawMinStock);

  return {
    code: normalizeText(row.code).toUpperCase(),
    name: normalizeText(row.name),
    type: normalizeText(row.type).toLowerCase(),
    uom: normalizeText(row.uom).toLowerCase(),
    barcodes,
    minStock,
    active: row.active === undefined ? true : row.active,
    warehouseId: (normalizeText(row.warehouseId) || warehouseId).toUpperCase(),
    note: normalizeText(row.note),
  };
}

function pushError(errors, line, field, code, message) {
  errors.push({ line, field, code, message });
}

/**
 * Memvalidasi seluruh baris sekaligus (semua error dikumpulkan).
 *
 * @param {Array<object>} rows baris hasil parse CSV oleh klien
 * @param {string} warehouseId gudang tujuan; semua baris harus untuk gudang ini
 * @returns {{ok: boolean, rows: Array<object>, errors: Array<object>, warnings: Array<object>}}
 */
function validateImportRows(rows, warehouseId) {
  const errors = [];
  const warnings = [];
  const normalized = [];

  if (!Array.isArray(rows) || rows.length === 0) {
    pushError(errors, 0, '-', 'E-EMPTY', 'File tidak berisi baris produk.');
    return { ok: false, rows: [], errors, warnings };
  }
  if (rows.length > MAX_ROWS) {
    pushError(
      errors,
      0,
      '-',
      'E-IMPORT-BATCH',
      `Maksimum ${MAX_ROWS} baris per kiriman; pecah file menjadi beberapa batch.`,
    );
  }

  const seenCodes = new Map();
  const seenBarcodes = new Map();

  rows.forEach((raw, index) => {
    const line = index + 1;
    const row = normalizeRow(raw, warehouseId);

    if (row.code === '') {
      pushError(errors, line, 'code', 'E-CODE-REQUIRED', 'Kode produk wajib diisi.');
    } else if (!CODE_PATTERN.test(row.code)) {
      pushError(errors, line, 'code', 'E-CODE-FORMAT', 'Format kode tidak valid.');
    } else if (seenCodes.has(row.code)) {
      pushError(
        errors,
        line,
        'code',
        'E-CODE-DUPLICATE',
        `Kode sudah dipakai baris ${seenCodes.get(row.code)}.`,
      );
    } else {
      seenCodes.set(row.code, line);
    }

    if (row.name === '') {
      pushError(errors, line, 'name', 'E-NAME-REQUIRED', 'Nama produk wajib diisi.');
    } else if (row.name.length < 3 || row.name.length > 200) {
      pushError(errors, line, 'name', 'E-NAME-LENGTH', 'Nama harus 3-200 karakter.');
    }
    if (INJECTION_PREFIX.test(row.name)) {
      pushError(
        errors,
        line,
        'name',
        'E-CSV-INJECTION',
        'Nama tidak boleh diawali = + - @.',
      );
    }

    if (!PRODUCT_TYPES.includes(row.type)) {
      pushError(errors, line, 'type', 'E-TYPE-INVALID', 'Tipe tidak dikenal.');
    }
    if (!UOMS.includes(row.uom)) {
      pushError(errors, line, 'uom', 'E-UOM-INVALID', 'Satuan tidak dikenal.');
    }

    if (row.barcodes.length === 0) {
      pushError(
        errors,
        line,
        'barcodes',
        'E-BARCODE-REQUIRED',
        'Minimal satu barcode wajib diisi.',
      );
    }
    for (const barcode of row.barcodes) {
      if (!BARCODE_PATTERN.test(barcode)) {
        pushError(
          errors,
          line,
          'barcodes',
          'E-BARCODE-FORMAT',
          `Format barcode ${barcode} tidak valid.`,
        );
        continue;
      }
      const owner = seenBarcodes.get(barcode);
      if (owner !== undefined && owner !== line) {
        pushError(
          errors,
          line,
          'barcodes',
          'E-BARCODE-DUPLICATE',
          `Barcode sudah dipakai baris ${owner}.`,
        );
      } else {
        seenBarcodes.set(barcode, line);
      }
    }
    const rawCount = Array.isArray(raw.barcodes) ? raw.barcodes.length : 0;
    if (rawCount > row.barcodes.length) {
      warnings.push({
        line,
        field: 'barcodes',
        code: 'W-BARCODE-SELF',
        message: 'Barcode berulang dalam satu produk; hanya satu yang disimpan.',
      });
    }

    if (!Number.isInteger(row.minStock)) {
      pushError(
        errors,
        line,
        'minStock',
        'E-MINSTOCK-NUMBER',
        'Stok minimum harus bilangan bulat.',
      );
    } else if (row.minStock < 0 || row.minStock > 1000000) {
      pushError(
        errors,
        line,
        'minStock',
        'E-MINSTOCK-RANGE',
        'Stok minimum 0-1.000.000.',
      );
    }

    if (typeof row.active !== 'boolean') {
      pushError(errors, line, 'active', 'E-STATUS-INVALID', 'Status tidak dikenal.');
    }

    if (!WAREHOUSE_PATTERN.test(row.warehouseId)) {
      pushError(
        errors,
        line,
        'warehouseId',
        'E-WAREHOUSE-INVALID',
        'Kode gudang tidak valid.',
      );
    } else if (row.warehouseId !== warehouseId.toUpperCase()) {
      pushError(
        errors,
        line,
        'warehouseId',
        'E-WAREHOUSE-INVALID',
        'Semua baris harus untuk gudang tujuan impor.',
      );
    }

    if (row.note.length > 200) {
      pushError(errors, line, 'note', 'E-NOTE-LENGTH', 'Keterangan maksimal 200 karakter.');
    }
    if (INJECTION_PREFIX.test(row.note)) {
      pushError(
        errors,
        line,
        'note',
        'E-CSV-INJECTION',
        'Keterangan tidak boleh diawali = + - @.',
      );
    }

    normalized.push({ ...row, line });
  });

  return { ok: errors.length === 0, rows: normalized, errors, warnings };
}

/** `importId` stabil untuk idempotensi (spec 6.3). */
function buildImportId({ rows, warehouseId, schemaVersion = 1 }) {
  const canonical = JSON.stringify({
    schemaVersion,
    warehouseId,
    rows: rows.map((row) => ({
      code: row.code,
      name: row.name,
      type: row.type,
      uom: row.uom,
      barcodes: [...row.barcodes].sort(),
      minStock: row.minStock,
      active: row.active,
      note: row.note,
    })),
  });
  return crypto.createHash('sha256').update(canonical).digest('hex');
}

function sameProduct(existing, row) {
  const existingBarcodes = [...(existing.barcodes || [])].sort();
  const rowBarcodes = [...row.barcodes].sort();
  const existingWarehouses = Array.isArray(existing.warehouseIds)
    ? existing.warehouseIds
    : [];
  return (
    existing.name === row.name &&
    existing.type === row.type &&
    existing.uom === row.uom &&
    (existing.minStock || 0) === row.minStock &&
    existing.active === row.active &&
    (existing.note || '') === row.note &&
    existingWarehouses.includes(row.warehouseId) &&
    JSON.stringify(existingBarcodes) === JSON.stringify(rowBarcodes)
  );
}

/**
 * Menentukan operasi tulis dari data server yang sudah dibaca.
 *
 * @param {object} input
 * @param {Array<object>} input.rows baris ternormalisasi
 * @param {Map<string, object>} input.existingByCode map kode -> dokumen produk
 * @param {object} input.barcodeOwners map barcode -> {productId, productCode}
 */
function planImport({ rows, existingByCode, barcodeOwners }) {
  const errors = [];
  const creates = [];
  const updates = [];
  const unchanged = [];
  const barcodesToDelete = new Set();

  for (const row of rows) {
    const existing = existingByCode.get(row.code);

    for (const barcode of row.barcodes) {
      const owner = barcodeOwners[barcode];
      if (owner && owner.productId !== (existing ? existing.id : null)) {
        pushError(
          errors,
          row.line,
          'barcodes',
          'E-BARCODE-EXISTS',
          `Barcode ${barcode} sudah dimiliki ${owner.productCode}.`,
        );
      }
    }

    if (!existing) {
      creates.push(row);
      continue;
    }

    const oldBarcodes = Array.isArray(existing.barcodes) ? existing.barcodes : [];
    for (const oldBarcode of oldBarcodes) {
      if (!row.barcodes.includes(oldBarcode)) {
        barcodesToDelete.add(oldBarcode);
      }
    }

    if (sameProduct(existing, row)) {
      unchanged.push(row.code);
    } else {
      updates.push({ id: existing.id, row });
    }
  }

  const barcodeCount = rows.reduce((total, row) => total + row.barcodes.length, 0);
  const docCount = rows.length + barcodeCount;
  if (docCount > MAX_TRANSACTION_DOCS) {
    pushError(
      errors,
      0,
      '-',
      'E-IMPORT-BATCH',
      `Batch terlalu besar (${docCount} dokumen); pecah menjadi beberapa kiriman.`,
    );
  }

  return {
    ok: errors.length === 0,
    errors,
    creates,
    updates,
    unchanged,
    barcodesToDelete: [...barcodesToDelete],
  };
}

module.exports = {
  PRODUCT_TYPES,
  UOMS,
  MAX_ROWS,
  MAX_TRANSACTION_DOCS,
  normalizeRow,
  validateImportRows,
  buildImportId,
  planImport,
};
