'use strict';

const { onCall, HttpsError } = require('firebase-functions/v2/https');
const { onDocumentCreated } = require('firebase-functions/v2/firestore');
const { onSchedule } = require('firebase-functions/v2/scheduler');
const { defineSecret } = require('firebase-functions/params');
const { initializeApp } = require('firebase-admin/app');
const { getFirestore, FieldValue, FieldPath } = require('firebase-admin/firestore');

const { buildHealthPayload } = require('./lib/health');
const { decideApply, shouldFlagConflict } = require('./lib/apply-balance');
const {
  validateImportRows,
  buildImportId,
  planImport,
  countBillableImports,
} = require('./lib/import-products');
const {
  isAdmin,
  validateUserUpdate,
  validateRetryRequest,
} = require('./lib/admin');
const { decideApproval } = require('./lib/cycle-count');
const { computeMetrics } = require('./lib/metrics');
const {
  previousPeriodKey,
  buildStockCards,
  buildPeriodSnapshot,
} = require('./lib/period-close');
const {
  HEADER,
  buildExportRows,
  planExport,
  rowsChecksum,
  reconcile,
} = require('./lib/sheet-export');
const sheets = require('./lib/sheets-client');

const sheetsCredentials = defineSecret('SHEETS_SERVICE_ACCOUNT');
const sheetsSpreadsheetId = defineSecret('SHEETS_SPREADSHEET_ID');

initializeApp();

const REGION = 'asia-southeast2';
const db = getFirestore();

const IMPORT_LOCK_TTL_MS = 5 * 60 * 1000;
const MAX_IMPORTS_PER_HOUR = 5;

class ImportConflictError extends Error {
  constructor(errors) {
    super('Barcode sudah dimiliki produk lain.');
    this.details = errors;
  }
}

/**
 * Endpoint diagnostik: memastikan Functions v2 bisa dipanggil dengan token
 * pengguna. Tidak menyentuh Firestore, jadi aman dipanggil kapan saja.
 */
exports.health = onCall({ region: REGION }, (request) => {
  if (!request.auth) {
    throw new HttpsError('unauthenticated', 'Butuh login.');
  }
  return buildHealthPayload({
    uid: request.auth.uid,
    now: new Date(),
  });
});

/**
 * Import master produk (VS1-06, FR-MST-04/05, BR-13).
 *
 * Kontrak input:
 *   { warehouseId: 'JKT-01',
 *     fileId?: '<sha256 isi file>',   // opsional, untuk kuota 5 file/jam
 *     batchIndex?: 0,                 // 0-based, hanya 0 dihitung kuota
 *     rows: [{ code, name, type, uom,
 *       barcodes: ['...'], minStock, active, note }] }
 *
 * All-or-nothing: seluruh baris divalidasi, lalu ditulis dalam satu
 * transaksi Firestore. Idempotensi memakai `importId` (SHA-256 fileId + isi
 * batch + gudang) sebagai ID audit log, sehingga kiriman ulang tidak menulis
 * apa pun.
 */
exports.importProducts = onCall(
  { region: REGION, timeoutSeconds: 120 },
  async (request) => {
    const uid = request.auth && request.auth.uid;
    if (!uid) {
      throw new HttpsError('unauthenticated', 'Butuh login.');
    }

    const data = request.data || {};
    const warehouseId =
      typeof data.warehouseId === 'string'
        ? data.warehouseId.trim().toUpperCase()
        : '';
    if (warehouseId === '') {
      throw new HttpsError('invalid-argument', 'warehouseId wajib diisi.');
    }

    const userSnapshot = await db.doc(`users/${uid}`).get();
    const user = userSnapshot.data();
    if (
      !userSnapshot.exists ||
      !user ||
      user.role !== 'admin' ||
      user.active !== true
    ) {
      throw new HttpsError(
        'permission-denied',
        'Hanya admin aktif yang boleh mengimpor produk.',
      );
    }

    const validation = validateImportRows(data.rows, warehouseId);
    if (!validation.ok) {
      throw new HttpsError('invalid-argument', 'Validasi impor gagal.', {
        errors: validation.errors,
        warnings: validation.warnings,
      });
    }

    const fileId =
      typeof data.fileId === 'string' ? data.fileId.trim() : '';
    const batchIndex = Number.isInteger(data.batchIndex)
      ? data.batchIndex
      : 0;
    if (batchIndex < 0) {
      throw new HttpsError(
        'invalid-argument',
        'batchIndex harus bilangan bulat >= 0.',
      );
    }

    const importId = buildImportId({
      rows: validation.rows,
      warehouseId,
      fileId,
    });
    const auditRef = db.doc(`auditLogs/${importId}`);
    if ((await auditRef.get()).exists) {
      return {
        status: 'skipped',
        importId,
        created: 0,
        updated: 0,
        unchanged: 0,
      };
    }

    // Duplikat diperiksa sebelum batas per jam supaya retry batch yang sama
    // tidak menghabiskan kuota.
    await enforceHourlyLimit(uid);

    await acquireImportLock({ warehouseId, importId, uid });
    try {
      const result = await applyImport({
        rows: validation.rows,
        warehouseId,
        importId,
        fileId,
        batchIndex,
        uid,
        auditRef,
      });
      return { status: 'applied', importId, ...result };
    } catch (error) {
      if (error instanceof ImportConflictError) {
        throw new HttpsError(
          'failed-precondition',
          'Barcode sudah dimiliki produk lain.',
          { errors: error.details },
        );
      }
      throw error;
    } finally {
      await releaseImportLock(warehouseId, importId);
    }
  },
);

/**
 * VS2-04: terapkan transaksi ke saldo gudang (BR-01/03/04).
 *
 * Trigger create, bukan callable: client tidak pernah menulis saldo, dan
 * pengiriman ulang dokumen yang sama tidak memicu efek kedua karena rules
 * create-only + replay guard `lastTransactionId`.
 */
async function applyTransactionToBalance(snapshot) {
  const data = snapshot.data();
    if (!data || data.serverStatus) {
      // Sudah diproses (mis. retry trigger setelah commit sukses).
      return;
    }

    const warehouseId = data.warehouseId;
    const productId = data.productId;
    if (typeof warehouseId !== 'string' || typeof productId !== 'string') {
      return;
    }

    const userSnapshot = await db.doc(`users/${data.userId}`).get();
    const actorRole = userSnapshot.exists
      ? userSnapshot.get('role')
      : null;

    const balanceRef = db.doc(
      `warehouses/${warehouseId}/balances/${productId}`,
    );
    const auditRef = db.collection('auditLogs').doc();

    await db.runTransaction(async (txn) => {
      const balanceSnapshot = await txn.get(balanceRef);
      const balance = balanceSnapshot.exists ? balanceSnapshot.data() : null;

      // BR-06: reversal tidak pernah mengubah transaksi asli. Konteksnya
      // dibaca di dalam transaksi yang sama dengan penulisan saldo, sehingga
      // dua reversal bersamaan tidak bisa lolos keduanya.
      let reversalContext = null;
      if (data.type === 'reversal' &&
          typeof data.refTransactionId === 'string') {
        const originalRef = db.doc(`transactions/${data.refTransactionId}`);
        const [originalSnap, previousSnap] = await Promise.all([
          txn.get(originalRef),
          txn.get(
            db.collection('transactions')
              .where('refTransactionId', '==', data.refTransactionId)
              .where('type', '==', 'reversal')
              .where('serverStatus', '==', 'applied')
              .limit(1),
          ),
        ]);
        reversalContext = {
          originalStatus: originalSnap.exists
            ? originalSnap.get('serverStatus')
            : null,
          alreadyReversed: !previousSnap.empty,
          originalSignedQty: originalSnap.exists
            ? originalSnap.get('signedQty')
            : null,
        };
      }

      const decision = decideApply({
        transaction: data,
        balance,
        actorRole,
        transactionId: snapshot.id,
        reversal: reversalContext,
      });
      if (decision.action === 'skip') {
        return;
      }

      const now = FieldValue.serverTimestamp();

      if (decision.action === 'reject') {
        txn.set(
          snapshot.ref,
          {
            serverStatus: 'rejected',
            rejectedReason: decision.reason,
            processedAt: now,
          },
          { merge: true },
        );
        txn.set(auditRef, {
          action: 'transaction.rejected',
          actorUid: 'system',
          entity: 'transactions',
          entityId: snapshot.id,
          reason: decision.reason,
          before: { endingQty: balance ? balance.endingQty ?? 0 : 0 },
          after: { serverStatus: 'rejected' },
          at: now,
        });
        return;
      }

      txn.set(
        balanceRef,
        {
          schemaVersion: 1,
          warehouseId,
          productId,
          endingQty: decision.endingQty,
          lastTransactionId: snapshot.id,
          updatedAt: now,
        },
        { merge: true },
      );

      const updates = {
        serverStatus: 'applied',
        createdAtServer: now,
        processedAt: now,
      };
      if (decision.override) {
        updates.approval = {
          status: 'approved',
          approvedBy: data.userId,
          approvedAt: now,
          reason: decision.reason,
        };
      }
      txn.update(snapshot.ref, updates);

      if (shouldFlagConflict(data, decision)) {
        const conflictRef = db.collection('stockConflicts').doc();
        txn.set(conflictRef, {
          schemaVersion: 1,
          warehouseId,
          productId,
          productCode: data.productCode || '',
          productName: data.productName || '',
          transactionId: snapshot.id,
          deviceEndingQty: data.deviceEndingQty,
          serverEndingQty: decision.endingQty,
          delta: data.deviceEndingQty - decision.endingQty,
          status: 'open',
          detectedAt: now,
        });
        txn.set(db.collection('auditLogs').doc(), {
          action: 'stock_conflict.detected',
          actorUid: 'system',
          entity: 'stockConflicts',
          entityId: conflictRef.id,
          reason: 'device_ending_qty_mismatch',
          before: { serverEndingQty: balance ? balance.endingQty ?? 0 : 0 },
          after: {
            deviceEndingQty: data.deviceEndingQty,
            serverEndingQty: decision.endingQty,
          },
          at: now,
        });
      }

      txn.set(auditRef, {
        action: 'transaction.applied',
        actorUid: data.userId,
        entity: 'transactions',
        entityId: snapshot.id,
        reason: decision.override
          ? `Override stok negatif: ${decision.reason}`
          : 'Transaksi diterapkan ke saldo',
        before: { endingQty: balance ? balance.endingQty ?? 0 : 0 },
        after: { endingQty: decision.endingQty },
        at: now,
      });
    });
}

exports.applyBalance = onDocumentCreated(
  { document: 'transactions/{transactionId}', region: REGION },
  async (event) => {
    const snapshot = event.data;
    if (!snapshot) {
      return;
    }
    await applyTransactionToBalance(snapshot);
  },
);

async function enforceHourlyLimit(uid) {
  const since = new Date(Date.now() - 60 * 60 * 1000);
  const recent = await db
    .collection('auditLogs')
    .where('actorUid', '==', uid)
    .where('at', '>=', since)
    // Arah DESC agar cocok dengan composite index auditLogs(actorUid, at DESC)
    // yang sudah ada di firestore.indexes.json.
    .orderBy('at', 'descending')
    .get();
  // Satu file 5.000 baris dikirim sebagai 50 batch; hanya batch pertama
  // (batchIndex 0) yang dihitung agar batas "5 file per jam" tetap berlaku.
  const files = countBillableImports(recent.docs.map((doc) => doc.data()));
  if (files >= MAX_IMPORTS_PER_HOUR) {
    throw new HttpsError(
      'resource-exhausted',
      `Batas ${MAX_IMPORTS_PER_HOUR} impor file per jam tercapai. Coba lagi nanti.`,
    );
  }
}

async function acquireImportLock({ warehouseId, importId, uid }) {
  const ref = db.doc(`importLocks/${warehouseId}`);
  await db.runTransaction(async (txn) => {
    const snapshot = await txn.get(ref);
    if (snapshot.exists) {
      const data = snapshot.data();
      const expiresAt = toMillis(data.expiresAt);
      if (expiresAt > Date.now() && data.owner !== importId) {
        throw new HttpsError(
          'aborted',
          'Impor lain sedang berjalan untuk gudang ini (E-IMPORT-LOCKED).',
        );
      }
    }
    txn.set(ref, {
      owner: importId,
      actorUid: uid,
      expiresAt: new Date(Date.now() + IMPORT_LOCK_TTL_MS),
      updatedAt: FieldValue.serverTimestamp(),
    });
  });
}

async function releaseImportLock(warehouseId, importId) {
  const ref = db.doc(`importLocks/${warehouseId}`);
  await db.runTransaction(async (txn) => {
    const snapshot = await txn.get(ref);
    if (!snapshot.exists) {
      return;
    }
    if (snapshot.data().owner === importId) {
      txn.delete(ref);
    }
  });
}

async function applyImport({
  rows,
  warehouseId,
  importId,
  fileId,
  batchIndex,
  uid,
  auditRef,
}) {
  const now = FieldValue.serverTimestamp();

  return db.runTransaction(async (txn) => {
    const existingByCode = new Map();
    for (const row of rows) {
      const snapshot = await txn.get(
        db.collection('products').where('code', '==', row.code).limit(1),
      );
      if (!snapshot.empty) {
        const doc = snapshot.docs[0];
        existingByCode.set(row.code, { id: doc.id, ...doc.data() });
      }
    }

    const allBarcodes = [...new Set(rows.flatMap((row) => row.barcodes))];
    const barcodeOwners = {};
    if (allBarcodes.length > 0) {
      const refs = allBarcodes.map((barcode) => db.doc(`barcodes/${barcode}`));
      const snapshots = await txn.getAll(...refs);
      snapshots.forEach((snapshot, index) => {
        if (snapshot.exists) {
          const data = snapshot.data();
          barcodeOwners[allBarcodes[index]] = {
            productId: data.productId,
            productCode: data.productCode,
          };
        }
      });
    }

    const plan = planImport({ rows, existingByCode, barcodeOwners });
    if (!plan.ok) {
      throw new ImportConflictError(plan.errors);
    }

    const newIds = new Map();
    for (const row of plan.creates) {
      const ref = db.collection('products').doc();
      newIds.set(row.code, ref.id);
      txn.set(ref, {
        ...productFields(row, { warehouseIds: [warehouseId], uid, now }),
        createdAt: now,
      });
    }

    for (const update of plan.updates) {
      const existing = existingByCode.get(update.row.code);
      const warehouseIds = Array.from(
        new Set([...(existing.warehouseIds || []), warehouseId]),
      );
      txn.set(
        db.doc(`products/${update.id}`),
        productFields(update.row, { warehouseIds, uid, now }),
        // merge agar createdAt dan field lain yang tidak dikelola import tetap.
        { merge: true },
      );
    }

    const updatedRows = [...plan.creates, ...plan.updates.map((item) => item.row)];
    for (const row of updatedRows) {
      const productId = existingByCode.has(row.code)
        ? existingByCode.get(row.code).id
        : newIds.get(row.code);
      for (const barcode of row.barcodes) {
        const isNew = !barcodeOwners[barcode];
        txn.set(
          db.doc(`barcodes/${barcode}`),
          {
            productId,
            productCode: row.code,
            format: 'UNKNOWN',
            ...(isNew ? { createdAt: now } : {}),
          },
          { merge: true },
        );
      }
    }

    for (const barcode of plan.barcodesToDelete) {
      txn.delete(db.doc(`barcodes/${barcode}`));
    }

    txn.set(auditRef, {
      action: 'product.import',
      actorUid: uid,
      entity: 'products',
      entityId: warehouseId,
      fileId,
      batchIndex,
      reason: `Impor ${rows.length} baris untuk ${warehouseId}` +
        (fileId ? ` (file ${fileId.slice(0, 8)}, batch ${batchIndex})` : ''),
      before: null,
      after: {
        created: plan.creates.length,
        updated: plan.updates.length,
        unchanged: plan.unchanged.length,
        deletedBarcodes: plan.barcodesToDelete.length,
      },
      at: now,
    });

    return {
      created: plan.creates.length,
      updated: plan.updates.length,
      unchanged: plan.unchanged.length,
      deletedBarcodes: plan.barcodesToDelete.length,
    };
  });
}

function productFields(row, { warehouseIds, uid, now }) {
  return {
    code: row.code,
    name: row.name,
    type: row.type,
    uom: row.uom,
    minStock: row.minStock,
    note: row.note,
    barcodes: row.barcodes,
    active: row.active,
    warehouseIds,
    updatedAt: now,
    updatedBy: uid,
    schemaVersion: 1,
  };
}

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

// ---------------------------------------------------------------------------
// VS-4: closing, ekspor Sheet, dan rekonsiliasi
// ---------------------------------------------------------------------------

async function fetchAppliedTransactions(periodKey) {
  const rows = [];
  let last = null;
  const pageSize = 500;
  for (;;) {
    let query = db
      .collection('transactions')
      .where('periodKey', '==', periodKey)
      .where('serverStatus', '==', 'applied')
      .orderBy(FieldPath.documentId)
      .limit(pageSize);
    if (last) {
      query = query.startAfter(last);
    }
    const snapshot = await query.get();
    if (snapshot.empty) {
      break;
    }
    for (const doc of snapshot.docs) {
      rows.push({ transactionId: doc.id, ...doc.data() });
    }
    if (snapshot.size < pageSize) {
      break;
    }
    last = snapshot.docs[snapshot.size - 1];
  }
  return rows;
}

async function commitChunks(writes) {
  for (let i = 0; i < writes.length; i += 400) {
    const batch = db.batch();
    for (const { ref, data, merge } of writes.slice(i, i + 400)) {
      if (merge) {
        batch.set(ref, data, { merge: true });
      } else {
        batch.set(ref, data);
      }
    }
    await batch.commit();
  }
}

function wait(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

/** 00:05 WIB: kunci periode D-1 dan simpan stock card per produk. */
exports.closeDailyPeriod = onSchedule(
  { schedule: '5 0 * * *', timeZone: 'Asia/Jakarta', region: REGION },
  async () => {
    const periodKey = previousPeriodKey();
    const warehouses = await db.collection('warehouses').get();
    const productSnapshot = await db.collection('products').get();
    const products = productSnapshot.docs.map((doc) => ({
      productId: doc.id,
      productCode: doc.data().code || '',
      productName: doc.data().name || '',
      uom: doc.data().uom || '',
      warehouseId: (doc.data().warehouseIds || [])[0] || '',
    }));

    for (const warehouse of warehouses.docs) {
      const periodRef = db
        .collection('warehouses')
        .doc(warehouse.id)
        .collection('periods')
        .doc(periodKey);
      const existing = await periodRef.get();
      if (existing.exists && existing.get('status') === 'closed') {
        continue; // Idempoten: job dijalankan ulang tidak mengubah snapshot.
      }

      const transactions = (await fetchAppliedTransactions(periodKey)).filter(
        (txn) => txn.warehouseId === warehouse.id,
      );
      const balanceSnapshot = await db
        .collection('warehouses')
        .doc(warehouse.id)
        .collection('balances')
        .get();
      const balances = balanceSnapshot.docs.map((doc) => ({
        productId: doc.id,
        warehouseId: warehouse.id,
        endingQty: doc.data().endingQty || 0,
      }));

      let cards = buildStockCards({
        transactions,
        products,
        balances,
        periodKey,
      });
      // Produk tanpa mutasi tetap masuk laporan, dengan opening = saldo.
      const covered = new Set(cards.map((card) => card.productId));
      for (const balance of balances) {
        if (covered.has(balance.productId)) {
          continue;
        }
        const product = products.find(
          (item) => item.productId === balance.productId,
        );
        cards.push({
          warehouseId: warehouse.id,
          periodKey,
          productId: balance.productId,
          productCode: product ? product.productCode : '',
          productName: product ? product.productName : '',
          uom: product ? product.uom : '',
          openingQty: balance.endingQty,
          incomingQty: 0,
          outgoingQty: 0,
          adjustmentQty: 0,
          endingQty: balance.endingQty,
          transactionCount: 0,
        });
      }
      cards.sort((a, b) => a.productCode.localeCompare(b.productCode));

      const snapshot = buildPeriodSnapshot(cards, periodKey);
      const writes = [
        { ref: periodRef, data: snapshot, merge: true },
      ];
      for (const card of cards) {
        writes.push({
          ref: periodRef.collection('stockCards').doc(card.productId),
          data: { ...card, computedAt: FieldValue.serverTimestamp() },
          merge: true,
        });
      }
      writes.push({
        ref: db.collection('auditLogs').doc(),
        data: {
          action: 'period.closed',
          actorUid: 'system',
          entityType: 'periods',
          entityId: periodKey,
          reason: 'closing harian 00:05 WIB',
          before: { status: existing.exists ? existing.get('status') : null },
          after: { status: 'closed', productCount: cards.length },
          at: FieldValue.serverTimestamp(),
        },
      });
      await commitChunks(writes);
    }
  },
);

function sheetsConfig() {
  let credentials;
  let spreadsheetId;
  try {
    credentials = sheetsCredentials.value();
    spreadsheetId = sheetsSpreadsheetId.value();
  } catch (error) {
    return null;
  }
  if (!credentials || !spreadsheetId) {
    return null;
  }
  try {
    return { credentials: JSON.parse(credentials), spreadsheetId };
  } catch (error) {
    return null;
  }
}

async function appendWithRetry(token, config, range, values) {
  let lastError;
  for (let attempt = 1; attempt <= 3; attempt++) {
    try {
      return await sheets.appendRange(
        token,
        config.spreadsheetId,
        range,
        values,
      );
    } catch (error) {
      lastError = error;
      if (attempt < 3) {
        await wait(attempt === 1 ? 5000 : 15000);
      }
    }
  }
  throw lastError;
}

/** 02:00 WIB: ekspor transaksi D-1 ke Sheet, idempoten per transactionId. */
exports.exportDailySheet = onSchedule(
  {
    schedule: '0 2 * * *',
    timeZone: 'Asia/Jakarta',
    region: REGION,
    secrets: [sheetsCredentials, sheetsSpreadsheetId],
    timeoutSeconds: 300,
  },
  async () => {
    const config = sheetsConfig();
    if (!config) {
      console.warn('Sheet export dilewati: kredensial belum dikonfigurasi.');
      return;
    }

    const periodKey = previousPeriodKey();
    const exportRef = db.collection('sheetExports').doc(`${periodKey}_1`);
    const previous = await exportRef.get();
    if (previous.exists && previous.get('status') === 'success') {
      return;
    }

    const startedAt = FieldValue.serverTimestamp();
    await exportRef.set(
      {
        periodKey,
        spreadsheetId: config.spreadsheetId,
        tabName: periodKey.slice(0, 7),
        status: 'running',
        attempts: 1,
        startedAt,
        rowCount: 0,
        checksum: '',
      },
      { merge: true },
    );

    try {
      const rows = buildExportRows(
        await fetchAppliedTransactions(periodKey),
        periodKey,
      );
      const token = await sheets.fetchAccessToken(config.credentials);
      const tab = periodKey.slice(0, 7);
      const existing = await sheets.readRange(
        token,
        config.spreadsheetId,
        `${tab}!A:A`,
      );
      const existingIds = existing
        .map((row) => (row && row.length ? String(row[0]) : ''))
        .filter((id) => id && id !== HEADER[0]);
      const plan = planExport(rows, existingIds);

      if (plan.toAppend.length > 0) {
        const values = existingIds.length === 0
          ? [HEADER, ...plan.toAppend]
          : plan.toAppend;
        await appendWithRetry(token, config, `${tab}!A1`, values);
      }

      await exportRef.set(
        {
          status: 'success',
          rowCount: rows.length,
          appendedRows: plan.toAppend.length,
          duplicateRows: plan.duplicates,
          checksum: rowsChecksum(rows),
          finishedAt: FieldValue.serverTimestamp(),
          error: null,
        },
        { merge: true },
      );
    } catch (error) {
      await exportRef.set(
        {
          status: 'failed',
          error: String(error && error.message ? error.message : error),
          finishedAt: FieldValue.serverTimestamp(),
        },
        { merge: true },
      );
      console.error('exportDailySheet gagal', error);
    }
  },
);

/** 02:30 WIB: bandingkan isi Sheet dengan Firestore (FR-SYN-07). */
exports.reconcileSheet = onSchedule(
  {
    schedule: '30 2 * * *',
    timeZone: 'Asia/Jakarta',
    region: REGION,
    secrets: [sheetsCredentials, sheetsSpreadsheetId],
    timeoutSeconds: 300,
  },
  async () => {
    const config = sheetsConfig();
    if (!config) {
      return;
    }
    const periodKey = previousPeriodKey();
    const exportRef = db.collection('sheetExports').doc(`${periodKey}_1`);
    const exportDoc = await exportRef.get();
    if (!exportDoc.exists) {
      return;
    }

    try {
      const expectedRows = buildExportRows(
        await fetchAppliedTransactions(periodKey),
        periodKey,
      );
      const token = await sheets.fetchAccessToken(config.credentials);
      const sheetRows = await sheets.readRange(
        token,
        config.spreadsheetId,
        `${periodKey.slice(0, 7)}!A:J`,
      );
      const result = reconcile({ expectedRows, sheetRows });

      await exportRef.set(
        {
          reconciliation: {
            status: result.status,
            rowCount: result.rowCount,
            expectedRowCount: result.expectedRowCount,
            duplicates: result.duplicates,
            missingCount: result.missing.length,
            extraCount: result.extra.length,
            checksumMatch: result.checksumMatch,
            checkedAt: FieldValue.serverTimestamp(),
          },
          status: result.status === 'verified' ? 'success' : result.status,
        },
        { merge: true },
      );
      await db.collection('auditLogs').add({
        action: 'export.reconciled',
        actorUid: 'system',
        entityType: 'sheetExports',
        entityId: exportRef.id,
        reason: result.status,
        after: {
          rowCount: result.rowCount,
          duplicates: result.duplicates,
          checksumMatch: result.checksumMatch,
        },
        at: FieldValue.serverTimestamp(),
      });
    } catch (error) {
      console.error('reconcileSheet gagal', error);
    }
  },
);

// ---------------------------------------------------------------------------
// VS-4: administrasi (FR-ADM-01/02/03)
// ---------------------------------------------------------------------------

async function requestRole(request) {
  if (!request.auth || !request.auth.uid) {
    throw new HttpsError('unauthenticated', 'Login diperlukan.');
  }
  const snapshot = await db.doc(`users/${request.auth.uid}`).get();
  return snapshot.exists ? snapshot.get('role') : null;
}

/** Admin mengubah role/status user; semua perubahan tercatat di audit log. */
exports.adminUpdateUser = onCall({ region: REGION }, async (request) => {
  const role = await requestRole(request);
  if (!isAdmin(role)) {
    throw new HttpsError('permission-denied', 'Hanya Admin yang boleh mengubah user.');
  }
  const result = validateUserUpdate(request.data || {});
  if (!result.ok) {
    throw new HttpsError('invalid-argument', result.error);
  }
  const uid = request.data.uid;
  if (typeof uid !== 'string' || uid.trim() === '') {
    throw new HttpsError('invalid-argument', 'missing_uid');
  }
  const ref = db.doc(`users/${uid.trim()}`);
  const before = await ref.get();
  if (!before.exists) {
    throw new HttpsError('not-found', 'user_not_found');
  }
  const changes = { ...result.changes };
  delete changes.reason;
  await ref.update({ ...changes, updatedAt: FieldValue.serverTimestamp() });
  await db.collection('auditLogs').add({
    action: 'user.role.update',
    actorUid: request.auth.uid,
    actorRole: role,
    entityType: 'users',
    entityId: uid.trim(),
    reason: result.changes.reason,
    before: Object.fromEntries(
      Object.keys(changes).map((key) => [key, before.get(key) ?? null]),
    ),
    after: changes,
    at: FieldValue.serverTimestamp(),
  });
  return { ok: true, uid: uid.trim(), changes };
});

/** Daftar transaksi yang ditolak server untuk ditindaklanjuti Admin. */
exports.adminListFailed = onCall({ region: REGION }, async (request) => {
  const role = await requestRole(request);
  if (!isAdmin(role) && role !== 'supervisor') {
    throw new HttpsError('permission-denied', 'Tidak ada izin monitoring.');
  }
  const snapshot = await db
    .collection('transactions')
    .where('serverStatus', '==', 'rejected')
    .limit(50)
    .get();
  return {
    items: snapshot.docs.map((doc) => ({
      transactionId: doc.id,
      warehouseId: doc.get('warehouseId'),
      productCode: doc.get('productCode'),
      productName: doc.get('productName'),
      type: doc.get('type'),
      qty: doc.get('qty'),
      userId: doc.get('userId'),
      rejectedReason: doc.get('rejectedReason'),
      periodKey: doc.get('periodKey'),
    })),
  };
});

/**
 * Retry paksa transaksi yang ditolak. Karena trigger applyBalance hanya jalan
 * saat create, status server dihapus dulu oleh Admin SDK lalu logika yang sama
 * dipanggil ulang. Idempoten lewat replay guard `lastTransactionId`.
 */
exports.adminForceRetry = onCall({ region: REGION }, async (request) => {
  const role = await requestRole(request);
  if (!isAdmin(role)) {
    throw new HttpsError('permission-denied', 'Hanya Admin yang boleh retry paksa.');
  }
  const result = validateRetryRequest(request.data || {});
  if (!result.ok) {
    throw new HttpsError('invalid-argument', result.error);
  }
  const ref = db.collection('transactions').doc(result.transactionId);
  const current = await ref.get();
  if (!current.exists || current.get('serverStatus') !== 'rejected') {
    throw new HttpsError('failed-precondition', 'transaction_not_rejected');
  }
  await ref.update({
    serverStatus: FieldValue.delete(),
    rejectedReason: FieldValue.delete(),
    processedAt: FieldValue.delete(),
  });
  await applyTransactionToBalance(await ref.get());
  await db.collection('auditLogs').add({
    action: 'transaction.force_retry',
    actorUid: request.auth.uid,
    actorRole: role,
    entityType: 'transactions',
    entityId: result.transactionId,
    reason: result.reason,
    at: FieldValue.serverTimestamp(),
  });
  return { ok: true, transactionId: result.transactionId };
});

// ---------------------------------------------------------------------------
// VS-5: cycle-count -> adjustment -> approval
// ---------------------------------------------------------------------------

async function cycleReviewerRole(request) {
  const role = await requestRole(request);
  if (!isAdmin(role) && role !== 'supervisor') {
    throw new HttpsError('permission-denied', 'Hanya Supervisor/Admin yang boleh meninjau.');
  }
  return role;
}

async function writeAdjustment(session, adjustment, reviewerUid) {
  // ID deterministik: retry/approve 2x tidak pernah membuat adjustment ganda.
  const id = `${session.id}_${adjustment.productId}`;
  const ref = db.collection('transactions').doc(id);
  const now = new Date();
  const payload = {
    schemaVersion: 1,
    warehouseId: session.warehouseId,
    productId: adjustment.productId,
    productCode: adjustment.productCode,
    productName: adjustment.productName,
    productType: 'general',
    uom: adjustment.uom,
    type: 'adjustment',
    qty: adjustment.qty,
    signedQty: adjustment.signedQty,
    periodKey: adjustment.periodKey,
    userId: reviewerUid,
    userName: reviewerUid,
    deviceId: 'server',
    occurredAt: now,
    createdAtClient: now,
    source: 'cycle_count',
    cycleCountId: session.id,
    note: adjustment.note,
  };
  try {
    await ref.create(payload);
  } catch (error) {
    if (error.code !== 6) {
      throw error; // 6 = ALREADY_EXISTS
    }
  }
  await applyTransactionToBalance(await ref.get());
  return id;
}

/** Setujui sesi: satu adjustment per baris variance, idempoten. */
exports.approveCycleCount = onCall({ region: REGION }, async (request) => {
  const role = await cycleReviewerRole(request);
  const sessionId = request.data && request.data.sessionId;
  if (typeof sessionId !== 'string' || sessionId.trim() === '') {
    throw new HttpsError('invalid-argument', 'missing_session_id');
  }
  const ref = db.collection('cycleCounts').doc(sessionId.trim());
  const sessionDoc = await ref.get();
  if (!sessionDoc.exists) {
    throw new HttpsError('not-found', 'session_not_found');
  }
  const session = { id: ref.id, ...sessionDoc.data() };
  const lineSnapshot = await ref.collection('countLines').get();
  const lines = lineSnapshot.docs.map((doc) => ({
    productId: doc.id,
    ...doc.data(),
  }));
  const decision = decideApproval(session, lines);
  if (decision.action === 'noop') {
    return { ok: true, adjustments: 0, alreadyApproved: true };
  }
  if (decision.action !== 'approve' && decision.action !== 'auto_approve') {
    throw new HttpsError('failed-precondition', decision.reason);
  }

  const adjustmentIds = [];
  for (const adjustment of decision.adjustments) {
    adjustmentIds.push(
      await writeAdjustment(session, adjustment, request.auth.uid),
    );
  }
  const now = FieldValue.serverTimestamp();
  await ref.update({
    status: 'approved',
    reviewedBy: request.auth.uid,
    reviewedAt: now,
    adjustmentTxnIds: adjustmentIds,
    varianceLineCount: decision.summary.varianceLineCount,
    totalVarianceQty: decision.summary.totalVarianceQty,
  });
  const lineWrites = db.batch();
  for (const line of lines) {
    const variance = Number.isInteger(line.variance)
      ? line.variance
      : line.countedQty - line.systemQty;
    if (variance === 0) {
      continue;
    }
    lineWrites.update(ref.collection('countLines').doc(line.productId), {
      approvalStatus: 'approved',
      adjustmentTxnId: `${session.id}_${line.productId}`,
    });
  }
  if (lines.some((line) =>
      (Number.isInteger(line.variance)
        ? line.variance
        : line.countedQty - line.systemQty) !== 0)) {
    await lineWrites.commit();
  }
  await db.collection('auditLogs').add({
    action: 'cycleCount.approve',
    actorUid: request.auth.uid,
    actorRole: role,
    entityType: 'cycleCounts',
    entityId: session.id,
    reason: `Disetujui: ${adjustmentIds.length} adjustment`,
    after: { adjustmentTxnIds: adjustmentIds },
    at: now,
  });
  return { ok: true, adjustments: adjustmentIds.length };
});

/** Tolak sesi wajib alasan; sesi bisa dibuka lagi untuk recount. */
exports.rejectCycleCount = onCall({ region: REGION }, async (request) => {
  await cycleReviewerRole(request);
  const sessionId = request.data && request.data.sessionId;
  const reason = request.data && request.data.reason;
  if (typeof sessionId !== 'string' || sessionId.trim() === '') {
    throw new HttpsError('invalid-argument', 'missing_session_id');
  }
  if (typeof reason !== 'string' || reason.trim().length < 10) {
    throw new HttpsError('invalid-argument', 'reason_too_short');
  }
  const ref = db.collection('cycleCounts').doc(sessionId.trim());
  const snapshot = await ref.get();
  if (!snapshot.exists || snapshot.get('status') !== 'submitted') {
    throw new HttpsError('failed-precondition', 'session_not_submitted');
  }
  await ref.update({
    status: 'rejected',
    reviewedBy: request.auth.uid,
    reviewedAt: FieldValue.serverTimestamp(),
    note: reason.trim(),
  });
  await db.collection('auditLogs').add({
    action: 'cycleCount.reject',
    actorUid: request.auth.uid,
    entityType: 'cycleCounts',
    entityId: sessionId.trim(),
    reason: reason.trim(),
    at: FieldValue.serverTimestamp(),
  });
  return { ok: true };
});

/** 03:00 WIB: ringkasan M1-M7 harian + alarm bila ambang dilanggar. */
exports.dailyMetrics = onSchedule(
  { schedule: '0 3 * * *', timeZone: 'Asia/Jakarta', region: REGION },
  async () => {
    const dayAgo = new Date(Date.now() - 24 * 60 * 60 * 1000);
    const weekAgo = new Date(Date.now() - 7 * 24 * 60 * 60 * 1000);
    const [txnSnapshot, cycleSnapshot, auditSnapshot, userSnapshot] =
      await Promise.all([
        db.collection('transactions').where('createdAtServer', '>=', dayAgo).get(),
        db.collection('cycleCounts').where('startedAt', '>=', weekAgo).get(),
        db.collection('auditLogs').where('at', '>=', weekAgo).get(),
        db.collection('users').get(),
      ]);

    const result = computeMetrics({
      transactions: txnSnapshot.docs.map((doc) => ({ ...doc.data() })),
      cycles: cycleSnapshot.docs.map((doc) => ({ ...doc.data() })),
      audits: auditSnapshot.docs.map((doc) => ({ ...doc.data() })),
      userCount: userSnapshot.size,
    });
    const periodKey = previousPeriodKey();
    await db.collection('metrics').doc(periodKey).set({
      ...result.metrics,
      thresholds: result.thresholds,
      alarms: result.alarms,
      computedAt: FieldValue.serverTimestamp(),
      schemaVersion: 1,
    });
    if (result.alarms.length > 0) {
      await db.collection('auditLogs').add({
        action: 'metrics.alarm',
        actorUid: 'system',
        entityType: 'metrics',
        entityId: periodKey,
        reason: result.alarms.join(', '),
        at: FieldValue.serverTimestamp(),
      });
    }
  },
);
