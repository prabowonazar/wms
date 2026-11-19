import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:warehouse_mobile/core/auth/auth_models.dart';
import 'package:warehouse_mobile/core/master/product.dart';
import 'package:warehouse_mobile/core/sync/uuid7.dart';
import 'package:warehouse_mobile/core/transactions/stock_transaction.dart';
import 'package:warehouse_mobile/core/transactions/stock_conflict.dart';
import 'package:warehouse_mobile/core/transactions/transaction_repository.dart';

import 'support/test_database.dart';

const UserProfile operatorProfile = UserProfile(
  uid: 'op1',
  name: 'Operator Satu',
  email: 'op1@example.com',
  role: UserRole.operator,
  warehouseIds: <String>['JKT-01'],
  active: true,
);

const UserProfile supervisor = UserProfile(
  uid: 'sv1',
  name: 'Supervisor Satu',
  email: 'sv1@example.com',
  role: UserRole.supervisor,
  warehouseIds: <String>['JKT-01'],
  active: true,
);

Future<void> seedProduct(Database database) async {
  await database.insert('products', {
    'product_id': 'p1',
    'code': 'BRG-001',
    'name': 'Sarung Tangan Nitril',
    'type': 'consumable',
    'uom': 'box',
    'min_stock': 0,
    'active': 1,
    'updated_at': DateTime.utc(2026, 11, 18).millisecondsSinceEpoch,
    'synced_at': DateTime.utc(2026, 11, 18).millisecondsSinceEpoch,
  });
}

final ProductView productView = ProductView(
  product: Product(
    id: 'p1',
    code: 'BRG-001',
    name: 'Sarung Tangan Nitril',
    type: 'consumable',
    uom: 'box',
    active: true,
    updatedAt: DateTime.utc(2026, 11, 18),
  ),
  balance: 0,
);

void main() {
  late Database database;
  late TransactionRepository repository;

  setUp(() async {
    database = await openTestDatabase();
    await seedProduct(database);
    repository = TransactionRepository(
      database: database,
      warehouseId: 'JKT-01',
    );
  });

  tearDown(() async {
    await database.close();
  });

  Future<StockTransaction> record({
    TransactionType type = TransactionType.incoming,
    int qty = 1,
    String? id,
    UserProfile profile = operatorProfile,
    String? overrideReason,
    DateTime? now,
  }) {
    return repository.recordMovement(
      transactionId: id ?? uuid7(),
      product: productView,
      type: type,
      qty: qty,
      profile: profile,
      overrideReason: overrideReason,
      now: now ?? DateTime.utc(2026, 11, 18, 2, 15),
    );
  }

  test('transaksi masuk tersimpan dengan tanda positif dan saldo naik', () async {
    final saved = await record(qty: 5);

    expect(saved.signedQty, 5);
    expect(saved.periodKey, '2026-11-18');
    expect(saved.syncStatus, 'pending');
    expect(saved.source, 'scan');

    final balance = await repository.balanceFor('p1');
    expect(balance.endingQty, 5);
    expect(balance.unsyncedQty, 5);
  });

  test('saldo berkurang setelah transaksi keluar', () async {
    await record(qty: 5);
    await record(type: TransactionType.outgoing, qty: 2);

    expect((await repository.balanceFor('p1')).endingQty, 3);
  });

  test('qty 0 ditolak sebelum menyentuh database', () async {
    await expectLater(
      record(qty: 0),
      throwsA(isA<InvalidMovementException>()),
    );
    expect(await database.query('transactions'), isEmpty);
  });

  test('keluar melebihi saldo ditolak tanpa mengubah ledger', () async {
    await record(qty: 2);

    await expectLater(
      record(type: TransactionType.outgoing, qty: 3),
      throwsA(
        isA<InsufficientStockException>()
            .having((e) => e.balance, 'balance', 2)
            .having((e) => e.shortage, 'shortage', 1),
      ),
    );

    expect((await database.query('transactions')).length, 1);
    expect((await repository.balanceFor('p1')).endingQty, 2);
  });

  test('override oleh operator ditolak', () async {
    await expectLater(
      record(
        type: TransactionType.outgoing,
        qty: 3,
        overrideReason: 'stok fisik lebih banyak',
      ),
      throwsA(isA<InvalidMovementException>()),
    );
    expect(await database.query('transactions'), isEmpty);
  });

  test('override supervisor tercatat pending beserta alasannya', () async {
    final saved = await record(
      type: TransactionType.outgoing,
      qty: 3,
      profile: supervisor,
      overrideReason: 'barang keluar belum tercatat',
    );

    expect(saved.approvalStatus, 'pending');
    expect(saved.approvalReason, 'barang keluar belum tercatat');
    expect((await repository.balanceFor('p1')).endingQty, -3);
  });

  test('tap ganda dengan ID sama tetap satu baris', () async {
    final id = uuid7();
    for (var i = 0; i < 5; i++) {
      await record(id: id, qty: 1);
    }

    final rows = await database.query('transactions');
    expect(rows, hasLength(1));
    expect((await repository.balanceFor('p1')).endingQty, 1);
  });

  test('ledger tidak bisa diubah setelah tersimpan', () async {
    await record(qty: 2);

    await expectLater(
      database.update(
        'transactions',
        {'qty': 99},
        where: 'product_id = ?',
        whereArgs: ['p1'],
      ),
      throwsA(anything),
    );
    expect(
      (await database.query('transactions')).single['qty'],
      2,
    );
  });

  test('stock card hari ini cocok dengan ledger', () async {
    await record(qty: 5);
    await record(type: TransactionType.outgoing, qty: 2);

    final card = await repository.stockCardFor('p1', periodKey: '2026-11-18');

    expect(card, isNotNull);
    expect(card!.opening, 0);
    expect(card.incoming, 5);
    expect(card.outgoing, 2);
    expect(card.adjustment, 0);
    expect(card.ending, 3);
    expect(card.isConsistent, isTrue);
  });

  test('transaksi failed tidak dihitung dalam saldo', () async {
    await record(qty: 5);
    await insertLedgerRow(
      database,
      id: 'failed-1',
      productId: 'p1',
      signedQty: -4,
      syncStatus: 'failed',
    );

    expect((await repository.balanceFor('p1')).endingQty, 5);
  });

  test('device id stabil dan berformat UUIDv7', () async {
    final first = await repository.deviceId();
    final second = await TransactionRepository(
      database: database,
      warehouseId: 'JKT-01',
    ).deviceId();

    expect(isUuid7(first), isTrue, reason: first);
    expect(second, first);
  });

  test('outbox mengirim yang paling lama lebih dulu lalu menandai synced',
      () async {
    await record(
      qty: 1,
      id: 'tx-late',
      now: DateTime.utc(2026, 11, 18, 3),
    );
    await record(
      qty: 1,
      id: 'tx-early',
      now: DateTime.utc(2026, 11, 18, 2),
    );

    final pending = await repository.pending();
    expect(pending.map((row) => row.transactionId), ['tx-early', 'tx-late']);

    await repository.markSyncing('tx-early');
    expect((await repository.pending()).first.transactionId, 'tx-early');

    await repository.markSynced('tx-early');
    expect((await repository.pending()).map((row) => row.transactionId),
        ['tx-late']);
    expect(await repository.pendingCount(), 1);
  });

  test('baris syncing yang tertinggal dikembalikan ke pending', () async {
    await record(qty: 1, id: 'tx-stuck');
    await repository.markSyncing('tx-stuck');

    final reset = await repository.resetStuckSyncing();

    expect(reset, 1);
    final rows = await database.query('transactions');
    expect(rows.single['sync_status'], 'pending');
  });

  test('kegagalan jaringan menaikkan retry dan menyimpan alasan', () async {
    await record(qty: 1, id: 'tx-retry', now: DateTime.utc(2026, 11, 18, 2));

    await repository.markFailed(
      'tx-retry',
      'tidak ada jaringan',
      at: DateTime.utc(2026, 11, 18, 3),
    );

    final row = (await database.query('transactions')).single;
    expect(row['sync_status'], 'failed');
    expect(row['retry_count'], 1);
    expect(row['last_error'], 'tidak ada jaringan');
    expect(row['next_retry_at'], isNotNull);
    // Masih dihitung antrean walau sementara gagal.
    expect(await repository.pendingCount(), 1);

    // Sebelum `next_retry_at`, baris tidak diambil lagi.
    final beforeRetry = await repository.pending(
      now: DateTime.utc(2026, 11, 18, 3),
    );
    expect(beforeRetry, isEmpty);

    // Setelah jeda lewat, baris dicoba ulang otomatis.
    final afterRetry = await repository.pending(
      now: DateTime.utc(2026, 11, 18, 3, 2),
    );
    expect(afterRetry.single.transactionId, 'tx-retry');
  });

  test('ringkasan sync memisahkan pending dan failed', () async {
    await record(qty: 1, id: 'tx-a');
    await record(qty: 1, id: 'tx-b');
    await repository.markSyncing('tx-b');
    await repository.markFailed('tx-a', 'Tidak ada koneksi.');

    final summary = await repository.syncSummary();

    expect(summary.pending, 0);
    expect(summary.syncing, 1);
    expect(summary.failed, 1);
    expect(summary.unsynced, 2);
    expect(summary.allClear, isFalse);
    expect(summary.failedItems.single.transactionId, 'tx-a');
    expect(summary.failedItems.single.lastError, 'Tidak ada koneksi.');
    expect(summary.chipLabel, contains('perlu tindakan'));
  });

  test('histori memfilter tanggal, jenis, produk, dan operator', () async {
    await record(
      qty: 4,
      id: 'tx-in',
      now: DateTime.utc(2026, 11, 17, 2),
    );
    await record(
      type: TransactionType.outgoing,
      qty: 1,
      id: 'tx-out',
      now: DateTime.utc(2026, 11, 18, 2),
    );
    await record(
      qty: 2,
      id: 'tx-sv',
      profile: supervisor,
      now: DateTime.utc(2026, 11, 18, 4),
    );

    final all = await repository.history();
    expect(all.map((row) => row.transactionId),
        ['tx-sv', 'tx-out', 'tx-in']);

    final outgoing = await repository.history(type: TransactionType.outgoing);
    expect(outgoing.single.transactionId, 'tx-out');

    final mine = await repository.history(userId: operatorProfile.uid);
    expect(mine.map((row) => row.transactionId), ['tx-out', 'tx-in']);

    final recent = await repository.history(
      from: DateTime.utc(2026, 11, 18),
      to: DateTime.utc(2026, 11, 19),
    );
    expect(recent.map((row) => row.transactionId), ['tx-sv', 'tx-out']);

    final byCode = await repository.history(query: 'BRG-00');
    expect(byCode, hasLength(3));

    final page = await repository.history(limit: 1, offset: 1);
    expect(page.single.transactionId, 'tx-out');
  });

  test('pembatalan membuat reversal dan mengembalikan saldo', () async {
    final original = await record(qty: 5, id: 'tx-original');
    await repository.markSynced('tx-original');

    final reversal = await repository.recordReversal(
      original: original,
      profile: supervisor,
      reason: 'salah input qty oleh operator',
      transactionId: 'tx-reversal',
      now: DateTime.utc(2026, 11, 18, 3),
    );

    expect(reversal.type, TransactionType.reversal);
    expect(reversal.signedQty, -5);
    expect(reversal.refTransactionId, 'tx-original');
    expect(reversal.note, 'salah input qty oleh operator');
    expect(reversal.syncStatus, 'pending');
    expect(await repository.hasReversal('tx-original'), isTrue);
    expect((await repository.balanceFor('p1')).endingQty, 0);
  });

  test('pembatalan ganda dan oleh operator ditolak', () async {
    final original = await record(qty: 5, id: 'tx-original');
    await repository.markSynced('tx-original');
    await repository.recordReversal(
      original: original,
      profile: supervisor,
      reason: 'salah input qty oleh operator',
      transactionId: 'tx-reversal',
    );

    await expectLater(
      repository.recordReversal(
        original: original,
        profile: supervisor,
        reason: 'percobaan kedua yang tidak boleh lolos',
        transactionId: 'tx-reversal-2',
      ),
      throwsA(isA<InvalidMovementException>()),
    );
    await expectLater(
      repository.recordReversal(
        original: original,
        profile: operatorProfile,
        reason: 'operator tidak berhak membatalkan',
      ),
      throwsA(isA<InvalidMovementException>()),
    );
    expect((await database.query('transactions')).length, 2);
  });

  test('pembatalan menolak alasan pendek dan transaksi belum terkirim',
      () async {
    final original = await record(qty: 5, id: 'tx-original');

    await expectLater(
      repository.recordReversal(
        original: original,
        profile: supervisor,
        reason: 'kurang',
      ),
      throwsA(isA<InvalidMovementException>()),
    );
    await expectLater(
      repository.recordReversal(
        original: original,
        profile: supervisor,
        reason: 'alasan yang sebenarnya sudah cukup panjang',
      ),
      throwsA(isA<InvalidMovementException>()),
    );
  });

  test('hanya baris failed yang boleh dihapus dari antrean', () async {
    await record(qty: 1, id: 'tx-failed');
    await repository.markFailed('tx-failed', 'Tidak ada koneksi.');
    await record(qty: 1, id: 'tx-synced');
    await repository.markSynced('tx-synced');

    expect(await repository.discardFailed('tx-synced'), isFalse);
    expect(await repository.discardFailed('tx-failed'), isTrue);
    final rows = await database.query('transactions');
    expect(rows.single['transaction_id'], 'tx-synced');
  });

  test('konflik saldo tersimpan di cache dan bisa ditutup supervisor', () async {
    await repository.replaceOpenConflicts(<StockConflict>[
      StockConflict(
        conflictId: 'conflict-1',
        productId: 'p1',
        deviceEndingQty: 9,
        serverEndingQty: 7,
        detectedAt: DateTime.utc(2026, 11, 19),
      ),
    ]);

    final open = await repository.openConflicts();
    expect(open, hasLength(1));
    expect(open.single.delta, 2);
    expect(open.single.status, 'open');

    await repository.markConflictResolved(
      'conflict-1',
      'accept_server',
      'saldo server sesuai hitungan fisik',
    );
    expect(await repository.openConflicts(), isEmpty);
  });
}
