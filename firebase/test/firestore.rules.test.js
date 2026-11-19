'use strict';

const fs = require('node:fs');
const path = require('node:path');
const { after, before, beforeEach, describe, it } = require('node:test');

const {
  initializeTestEnvironment,
  assertFails,
  assertSucceeds,
} = require('@firebase/rules-unit-testing');

const {
  doc,
  getDoc,
  setDoc,
  updateDoc,
  deleteDoc,
  Timestamp,
} = require('firebase/firestore');

const PROJECT_ID = process.env.GCLOUD_PROJECT || 'demo-warehouse';

let testEnv;

function authedDb(uid) {
  return testEnv.authenticatedContext(uid).firestore();
}

function anonDb() {
  return testEnv.unauthenticatedContext().firestore();
}

function validTransaction(overrides = {}) {
  return {
    schemaVersion: 1,
    warehouseId: 'wh1',
    productId: 'p1',
    productCode: 'P-001',
    productName: 'Produk Uji',
    productType: 'general',
    uom: 'pcs',
    type: 'incoming',
    qty: 5,
    signedQty: 5,
    periodKey: '2026-11-17',
    userId: 'op1',
    userName: 'Operator 1',
    deviceId: 'dev1',
    occurredAt: Timestamp.now(),
    createdAtClient: Timestamp.now(),
    appVersion: '0.1.0',
    source: 'scan',
    ...overrides,
  };
}

function validCycleCount(overrides = {}) {
  return {
    warehouseId: 'wh1',
    periodKey: '2026-11-17',
    status: 'open',
    startedBy: 'op1',
    startedAt: Timestamp.now(),
    ...overrides,
  };
}

function validCountLine(overrides = {}) {
  return {
    productId: 'p1',
    systemQty: 10,
    countedQty: 7,
    variance: -3,
    countedBy: 'op1',
    countedAt: Timestamp.now(),
    ...overrides,
  };
}

async function seed() {
  await testEnv.withSecurityRulesDisabled(async (context) => {
    const db = context.firestore();
    await Promise.all([
      setDoc(doc(db, 'users/op1'), {
        name: 'Operator 1',
        email: 'op1@contoh.co.id',
        role: 'operator',
        warehouseIds: ['wh1'],
        active: true,
      }),
      setDoc(doc(db, 'users/op2'), {
        name: 'Operator 2',
        email: 'op2@contoh.co.id',
        role: 'operator',
        warehouseIds: ['wh1'],
        active: true,
      }),
      setDoc(doc(db, 'users/sv1'), {
        name: 'Supervisor 1',
        email: 'sv1@contoh.co.id',
        role: 'supervisor',
        warehouseIds: ['wh1'],
        active: true,
      }),
      setDoc(doc(db, 'users/adm1'), {
        name: 'Admin 1',
        email: 'adm1@contoh.co.id',
        role: 'admin',
        warehouseIds: ['wh1'],
        active: true,
      }),
      setDoc(doc(db, 'users/inactive1'), {
        name: 'Nonaktif',
        email: 'nonaktif@contoh.co.id',
        role: 'operator',
        warehouseIds: ['wh1'],
        active: false,
      }),
      setDoc(doc(db, 'users/otherwh'), {
        name: 'Operator Gudang Lain',
        email: 'lain@contoh.co.id',
        role: 'operator',
        warehouseIds: ['wh2'],
        active: true,
      }),
      setDoc(doc(db, 'products/p1'), {
        code: 'P-001',
        name: 'Produk Uji',
        type: 'general',
        uom: 'pcs',
        active: true,
      }),
      setDoc(doc(db, 'warehouses/wh1'), {
        code: 'WH1',
        name: 'Gudang 1',
        timezone: 'Asia/Jakarta',
        currentPeriodKey: '2026-11-17',
      }),
      setDoc(doc(db, 'warehouses/wh2'), {
        code: 'WH2',
        name: 'Gudang 2',
        timezone: 'Asia/Jakarta',
        currentPeriodKey: '2026-11-17',
      }),
    ]);
  });
}

before(async () => {
  testEnv = await initializeTestEnvironment({
    projectId: PROJECT_ID,
    firestore: {
      rules: fs.readFileSync(
        path.join(__dirname, '..', 'firestore.rules'),
        'utf8',
      ),
      host: '127.0.0.1',
      port: 8080,
    },
  });
});

after(async () => {
  if (testEnv) {
    await testEnv.cleanup();
  }
});

beforeEach(async () => {
  await testEnv.clearFirestore();
  await seed();
});

describe('default deny & profil', () => {
  it('pengguna tanpa login tidak bisa membaca produk', async () => {
    await assertFails(getDoc(doc(anonDb(), 'products/p1')));
  });

  it('pengguna tanpa login tidak bisa membuat transaksi', async () => {
    await assertFails(
      setDoc(doc(anonDb(), 'transactions/tx-anon'), validTransaction()),
    );
  });

  it('operator aktif bisa membaca produk', async () => {
    await assertSucceeds(getDoc(doc(authedDb('op1'), 'products/p1')));
  });

  it('operator nonaktif tidak bisa membaca produk', async () => {
    await assertFails(getDoc(doc(authedDb('inactive1'), 'products/p1')));
  });

  it('pengguna nonaktif tetap bisa membaca profilnya sendiri', async () => {
    await assertSucceeds(getDoc(doc(authedDb('inactive1'), 'users/inactive1')));
  });

  it('operator tidak bisa membaca profil operator lain', async () => {
    await assertFails(getDoc(doc(authedDb('op1'), 'users/op2')));
  });

  it('supervisor bisa membaca profil operator', async () => {
    await assertSucceeds(getDoc(doc(authedDb('sv1'), 'users/op1')));
  });

  it('hanya admin yang bisa menulis profil', async () => {
    await assertFails(
      setDoc(doc(authedDb('op1'), 'users/op1'), {
        role: 'admin',
        active: true,
        warehouseIds: ['wh1'],
      }),
    );
    await assertSucceeds(
      setDoc(doc(authedDb('adm1'), 'users/newuser'), {
        name: 'Baru',
        email: 'baru@contoh.co.id',
        role: 'operator',
        warehouseIds: ['wh1'],
        active: true,
      }),
    );
  });
});

describe('master produk & saldo', () => {
  it('operator tidak boleh menulis master produk', async () => {
    await assertFails(
      setDoc(doc(authedDb('op1'), 'products/p2'), {
        code: 'P-002',
        name: 'Produk 2',
        type: 'general',
        uom: 'pcs',
        active: true,
      }),
    );
  });

  it('admin boleh menulis master produk', async () => {
    await assertSucceeds(
      setDoc(doc(authedDb('adm1'), 'products/p2'), {
        code: 'P-002',
        name: 'Produk 2',
        type: 'general',
        uom: 'pcs',
        active: true,
      }),
    );
  });

  it('operator bisa membaca saldo tetapi tidak bisa menulisnya', async () => {
    const db = authedDb('op1');
    await assertSucceeds(
      getDoc(doc(db, 'warehouses/wh1/balances/p1')),
    );
    await assertFails(
      setDoc(doc(db, 'warehouses/wh1/balances/p1'), { endingQty: 100 }),
    );
  });

  it('supervisor pun tidak bisa menulis saldo (Function only)', async () => {
    await assertFails(
      setDoc(doc(authedDb('sv1'), 'warehouses/wh1/balances/p1'), {
        endingQty: 100,
      }),
    );
  });

  it('audit log hanya bisa ditulis Function', async () => {
    await assertFails(
      setDoc(doc(authedDb('sv1'), 'auditLogs/log1'), {
        actorId: 'sv1',
        action: 'test',
      }),
    );
  });

  it('admin pun tidak bisa menulis importLocks (Function only)', async () => {
    const db = authedDb('adm1');
    await assertFails(
      setDoc(doc(db, 'importLocks/wh1'), {
        owner: 'abc',
        actorUid: 'adm1',
        expiresAt: Timestamp.fromMillis(Date.now() + 60000),
      }),
    );
    await assertFails(getDoc(doc(db, 'importLocks/wh1')));
  });

  it('operator tidak bisa membaca importLocks', async () => {
    await assertFails(getDoc(doc(authedDb('op1'), 'importLocks/wh1')));
  });
});

describe('transaksi ledger', () => {
  it('operator bisa membuat transaksi valid', async () => {
    await assertSucceeds(
      setDoc(doc(authedDb('op1'), 'transactions/tx-1'), validTransaction()),
    );
  });

  it('operator tidak bisa membuat transaksi atas nama pengguna lain', async () => {
    await assertFails(
      setDoc(
        doc(authedDb('op1'), 'transactions/tx-2'),
        validTransaction({ userId: 'op2' }),
      ),
    );
  });

  it('client tidak boleh mengirim metadata server', async () => {
    await assertFails(
      setDoc(
        doc(authedDb('op1'), 'transactions/tx-3'),
        validTransaction({ serverStatus: 'applied' }),
      ),
    );
  });

  it('qty nol ditolak', async () => {
    await assertFails(
      setDoc(
        doc(authedDb('op1'), 'transactions/tx-4'),
        validTransaction({ qty: 0, signedQty: 0 }),
      ),
    );
  });

  it('tanda outgoing harus negatif', async () => {
    await assertFails(
      setDoc(
        doc(authedDb('op1'), 'transactions/tx-5'),
        validTransaction({ type: 'outgoing', qty: 5, signedQty: 5 }),
      ),
    );
  });

  it('transaksi di gudang lain ditolak', async () => {
    await assertFails(
      setDoc(
        doc(authedDb('otherwh'), 'transactions/tx-6'),
        validTransaction({ userId: 'otherwh' }),
      ),
    );
  });

  it('operator nonaktif tidak bisa membuat transaksi', async () => {
    await assertFails(
      setDoc(
        doc(authedDb('inactive1'), 'transactions/tx-7'),
        validTransaction({ userId: 'inactive1' }),
      ),
    );
  });

  it('transaksi tidak boleh diubah setelah dibuat', async () => {
    const db = authedDb('op1');
    await assertSucceeds(setDoc(doc(db, 'transactions/tx-8'), validTransaction()));
    await assertFails(
      updateDoc(doc(db, 'transactions/tx-8'), { qty: 9, signedQty: 9 }),
    );
  });

  it('transaksi tidak boleh dihapus client', async () => {
    const db = authedDb('op1');
    await assertSucceeds(setDoc(doc(db, 'transactions/tx-9'), validTransaction()));
    await assertFails(deleteDoc(doc(db, 'transactions/tx-9')));
  });

  it('operator hanya melihat transaksinya sendiri', async () => {
    await testEnv.withSecurityRulesDisabled(async (context) => {
      await setDoc(
        doc(context.firestore(), 'transactions/tx-op2'),
        validTransaction({ userId: 'op2', userName: 'Operator 2' }),
      );
    });

    await assertFails(getDoc(doc(authedDb('op1'), 'transactions/tx-op2')));
    await assertSucceeds(getDoc(doc(authedDb('sv1'), 'transactions/tx-op2')));
  });

  it('reversal wajib punya refTransactionId', async () => {
    await assertFails(
      setDoc(
        doc(authedDb('op1'), 'transactions/tx-10'),
        validTransaction({ type: 'reversal', signedQty: 5 }),
      ),
    );
  });

  it('override stok negatif boleh dikirim sebagai approval pending', async () => {
    await assertSucceeds(
      setDoc(
        doc(authedDb('sv1'), 'transactions/tx-11'),
        validTransaction({
          userId: 'sv1',
          approval: {
            status: 'pending',
            reason: 'barang keluar belum tercatat',
          },
        }),
      ),
    );
  });

  it('client tidak boleh mengirim approval yang sudah approved', async () => {
    await assertFails(
      setDoc(
        doc(authedDb('sv1'), 'transactions/tx-12'),
        validTransaction({
          userId: 'sv1',
          approval: {
            status: 'approved',
            reason: 'barang keluar belum tercatat',
          },
        }),
      ),
    );
  });
});

describe('cycle count', () => {
  it('operator bisa memulai sesi di gudangnya', async () => {
    await assertSucceeds(
      setDoc(doc(authedDb('op1'), 'cycleCounts/cc-1'), validCycleCount()),
    );
  });

  it('operator tidak bisa memulai sesi di gudang lain', async () => {
    await assertFails(
      setDoc(
        doc(authedDb('otherwh'), 'cycleCounts/cc-2'),
        validCycleCount({ startedBy: 'otherwh' }),
      ),
    );
  });

  it('sesi baru wajib berstatus open', async () => {
    await assertFails(
      setDoc(
        doc(authedDb('op1'), 'cycleCounts/cc-3'),
        validCycleCount({ status: 'submitted' }),
      ),
    );
  });

  it('operator bisa submit sesi open, tetapi tidak bisa approve', async () => {
    const db = authedDb('op1');
    await assertSucceeds(setDoc(doc(db, 'cycleCounts/cc-4'), validCycleCount()));
    await assertSucceeds(
      updateDoc(doc(db, 'cycleCounts/cc-4'), { status: 'submitted' }),
    );

    await testEnv.withSecurityRulesDisabled(async (context) => {
      await setDoc(
        doc(context.firestore(), 'cycleCounts/cc-5'),
        validCycleCount(),
      );
    });
    await assertFails(
      updateDoc(doc(db, 'cycleCounts/cc-5'), { status: 'approved' }),
    );
  });

  it('operator bisa mengisi count line dengan variance yang benar', async () => {
    await testEnv.withSecurityRulesDisabled(async (context) => {
      await setDoc(
        doc(context.firestore(), 'cycleCounts/cc-line'),
        validCycleCount(),
      );
    });

    await assertSucceeds(
      setDoc(
        doc(authedDb('op1'), 'cycleCounts/cc-line/countLines/p1'),
        validCountLine(),
      ),
    );
  });

  it('variance yang tidak cocok ditolak', async () => {
    await testEnv.withSecurityRulesDisabled(async (context) => {
      await setDoc(
        doc(context.firestore(), 'cycleCounts/cc-var'),
        validCycleCount(),
      );
    });

    await assertFails(
      setDoc(
        doc(authedDb('op1'), 'cycleCounts/cc-var/countLines/p1'),
        validCountLine({ variance: 0 }),
      ),
    );
  });

  it('count line tidak boleh mengisi hasil approval', async () => {
    await testEnv.withSecurityRulesDisabled(async (context) => {
      await setDoc(
        doc(context.firestore(), 'cycleCounts/cc-approval'),
        validCycleCount(),
      );
    });

    await assertFails(
      setDoc(
        doc(authedDb('op1'), 'cycleCounts/cc-approval/countLines/p1'),
        validCountLine({ adjustmentTxnId: 'tx-1' }),
      ),
    );
  });
});

describe('konfigurasi aplikasi', () => {
  it('operator hanya bisa membaca appConfig', async () => {
    await testEnv.withSecurityRulesDisabled(async (context) => {
      await setDoc(doc(context.firestore(), 'appConfig/minVersion'), {
        value: '0.1.0',
      });
    });

    await assertSucceeds(
      getDoc(doc(authedDb('op1'), 'appConfig/minVersion')),
    );
    await assertFails(
      setDoc(doc(authedDb('op1'), 'appConfig/minVersion'), { value: '9.9.9' }),
    );
  });

  it('admin bisa menulis appConfig', async () => {
    await assertSucceeds(
      setDoc(doc(authedDb('adm1'), 'appConfig/minVersion'), {
        value: '0.1.0',
      }),
    );
  });
});
