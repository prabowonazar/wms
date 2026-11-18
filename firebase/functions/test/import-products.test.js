'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');

const {
  validateImportRows,
  buildImportId,
  planImport,
  countBillableImports,
  MAX_ROWS,
} = require('../lib/import-products');

function row(overrides = {}) {
  return {
    code: 'BRG-001',
    name: 'Sarung Tangan Nitril',
    type: 'consumable',
    uom: 'box',
    barcodes: ['8991000000017'],
    minStock: 5,
    active: true,
    note: 'Ukuran M',
    ...overrides,
  };
}

function codesOf(errors) {
  return errors.map((error) => error.code);
}

test('100 produk dari template lolos validasi', () => {
  const rows = Array.from({ length: MAX_ROWS }, (_, index) =>
    row({
      code: `BRG-${String(index).padStart(3, '0')}`,
      barcodes: [`899100000${String(index).padStart(4, '0')}`],
    }),
  );

  const result = validateImportRows(rows, 'JKT-01');

  assert.equal(result.ok, true);
  assert.equal(result.rows.length, MAX_ROWS);
  assert.equal(result.errors.length, 0);
});

test('normalisasi: huruf besar, spasi, dan barcode berulang', () => {
  const result = validateImportRows(
    [
      row({
        code: ' brg-001 ',
        type: 'Consumable',
        uom: 'BOX',
        barcodes: [' 8991000000017 ', '8991000000017'],
        note: '  ',
      }),
    ],
    'jkt-01',
  );

  assert.equal(result.ok, true);
  assert.equal(result.rows[0].code, 'BRG-001');
  assert.equal(result.rows[0].type, 'consumable');
  assert.equal(result.rows[0].uom, 'box');
  assert.deepEqual(result.rows[0].barcodes, ['8991000000017']);
  assert.equal(result.rows[0].warehouseId, 'JKT-01');
  assert.equal(result.rows[0].minStock, 5);
  assert.deepEqual(codesOf(result.warnings), ['W-BARCODE-SELF']);
});

test('kode ganda dan barcode ganda dalam satu file ditolak', () => {
  const result = validateImportRows(
    [
      row(),
      row({ code: 'BRG-001', barcodes: ['8991000000024'] }),
      row({ code: 'BRG-002', barcodes: ['8991000000017'] }),
    ],
    'JKT-01',
  );

  assert.equal(result.ok, false);
  assert.ok(codesOf(result.errors).includes('E-CODE-DUPLICATE'));
  assert.ok(codesOf(result.errors).includes('E-BARCODE-DUPLICATE'));
});

test('format salah dikumpulkan semuanya, bukan berhenti di yang pertama', () => {
  const result = validateImportRows(
    [
      row({
        code: 'X',
        name: '=A',
        type: 'unknown',
        uom: 'drum',
        barcodes: ['AB'],
        minStock: 1.5,
        note: 'x'.repeat(201),
      }),
    ],
    'JKT-01',
  );

  const codes = codesOf(result.errors);
  for (const expected of [
    'E-CODE-FORMAT',
    'E-NAME-LENGTH',
    'E-CSV-INJECTION',
    'E-TYPE-INVALID',
    'E-UOM-INVALID',
    'E-BARCODE-FORMAT',
    'E-MINSTOCK-NUMBER',
    'E-NOTE-LENGTH',
  ]) {
    assert.ok(codes.includes(expected), `harus ada ${expected}`);
  }
});

test('baris untuk gudang lain ditolak', () => {
  const result = validateImportRows([row({ warehouseId: 'JKT-02' })], 'JKT-01');

  assert.equal(result.ok, false);
  assert.ok(codesOf(result.errors).includes('E-WAREHOUSE-INVALID'));
});

test('lebih dari batas batch ditolak dengan pesan jelas', () => {
  const rows = Array.from({ length: MAX_ROWS + 1 }, (_, index) =>
    row({
      code: `BRG-${String(index).padStart(3, '0')}`,
      barcodes: [`8991000${String(index).padStart(5, '0')}`],
    }),
  );

  const result = validateImportRows(rows, 'JKT-01');

  assert.equal(result.ok, false);
  assert.ok(codesOf(result.errors).includes('E-IMPORT-BATCH'));
});

test('importId stabil dan berbeda antar gudang', () => {
  const valid = validateImportRows([row()], 'JKT-01');
  const first = buildImportId({
    rows: valid.rows,
    warehouseId: 'JKT-01',
  });
  const second = buildImportId({
    rows: valid.rows,
    warehouseId: 'JKT-01',
  });
  const otherWarehouse = buildImportId({
    rows: valid.rows,
    warehouseId: 'JKT-02',
  });
  const otherFile = buildImportId({
    rows: valid.rows,
    warehouseId: 'JKT-01',
    fileId: 'file-b',
  });

  assert.equal(first, second);
  assert.notEqual(first, otherWarehouse);
  assert.notEqual(first, otherFile);
  assert.match(first, /^[a-f0-9]{64}$/);
});

test('satu file 50 batch hanya memakai satu kuota impor per jam', () => {
  const entries = [];
  for (let batch = 0; batch < 50; batch += 1) {
    entries.push({ action: 'product.import', batchIndex: batch });
  }
  // Dokumen lama tanpa batchIndex tetap dihitung satu file.
  entries.push({ action: 'product.import' });
  // Audit log aksi lain tidak memakai kuota impor.
  entries.push({ action: 'user.update' });
  entries.push(null);

  assert.equal(countBillableImports(entries), 2);
  assert.equal(countBillableImports([]), 0);
});

test('planImport: create, update, unchanged, dan barcode dilepas', () => {
  const existingByCode = new Map([
    [
      'BRG-002',
      {
        id: 'p2',
        name: 'Produk Lama',
        type: 'consumable',
        uom: 'box',
        barcodes: ['8991000000024', '8991000000031'],
        minStock: 0,
        active: true,
        note: '',
        warehouseIds: ['JKT-01'],
      },
    ],
    [
      'BRG-003',
      {
        id: 'p3',
        name: 'Produk Sama',
        type: 'tool',
        uom: 'unit',
        barcodes: ['8991000000048'],
        minStock: 2,
        active: true,
        note: 'ok',
        warehouseIds: ['JKT-01'],
      },
    ],
  ]);

  const plan = planImport({
    rows: [
      { code: 'BRG-001', name: 'Baru', type: 'tool', uom: 'unit', barcodes: ['8991000000017'], minStock: 0, active: true, note: '', warehouseId: 'JKT-01', line: 1 },
      { code: 'BRG-002', name: 'Produk Baru', type: 'consumable', uom: 'box', barcodes: ['8991000000024'], minStock: 0, active: true, note: '', warehouseId: 'JKT-01', line: 2 },
      { code: 'BRG-003', name: 'Produk Sama', type: 'tool', uom: 'unit', barcodes: ['8991000000048'], minStock: 2, active: true, note: 'ok', warehouseId: 'JKT-01', line: 3 },
    ],
    existingByCode,
    barcodeOwners: {
      '8991000000017': { productId: 'p2', productCode: 'BRG-002' },
    },
  });

  assert.equal(plan.ok, false);
  assert.equal(plan.errors[0].code, 'E-BARCODE-EXISTS');

  const withoutConflict = planImport({
    rows: [
      { code: 'BRG-001', name: 'Baru', type: 'tool', uom: 'unit', barcodes: ['8991000000017'], minStock: 0, active: true, note: '', warehouseId: 'JKT-01', line: 1 },
      { code: 'BRG-002', name: 'Produk Baru', type: 'consumable', uom: 'box', barcodes: ['8991000000024'], minStock: 0, active: true, note: '', warehouseId: 'JKT-01', line: 2 },
      { code: 'BRG-003', name: 'Produk Sama', type: 'tool', uom: 'unit', barcodes: ['8991000000048'], minStock: 2, active: true, note: 'ok', warehouseId: 'JKT-01', line: 3 },
    ],
    existingByCode,
    barcodeOwners: {
      '8991000000024': { productId: 'p2', productCode: 'BRG-002' },
      '8991000000048': { productId: 'p3', productCode: 'BRG-003' },
    },
  });

  assert.equal(withoutConflict.ok, true);
  assert.deepEqual(withoutConflict.creates.map((item) => item.code), ['BRG-001']);
  assert.deepEqual(withoutConflict.updates.map((item) => item.id), ['p2']);
  assert.deepEqual(withoutConflict.unchanged, ['BRG-003']);
  assert.deepEqual(withoutConflict.barcodesToDelete, ['8991000000031']);
});
