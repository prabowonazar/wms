import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:warehouse_mobile/core/observability/telemetry.dart';
import 'package:warehouse_mobile/core/transactions/outbox_sync.dart';
import 'package:warehouse_mobile/core/transactions/transaction_repository.dart';

import 'support/fake_transaction_remote.dart';
import 'support/test_database.dart';

void main() {
  late TransactionRepository repository;
  late FakeTransactionRemote remote;
  late RecordingTelemetry telemetry;
  late OutboxSyncService outbox;
  late Database database;

  setUp(() async {
    database = await openTestDatabase();
    repository = TransactionRepository(
      database: database,
      warehouseId: 'JKT-01',
    );
    remote = FakeTransactionRemote();
    telemetry = RecordingTelemetry();
    outbox = OutboxSyncService(
      repository: repository,
      remote: remote,
      telemetry: telemetry,
      batchSize: 20,
      retryDelay: Duration.zero,
    );
  });

  tearDown(() async {
    await database.close();
  });

  Future<void> seed(int count, {String prefix = 'tx'}) async {
    for (var i = 0; i < count; i++) {
      await insertLedgerRow(
        database,
        id: '${prefix}_$i',
        productId: 'p1',
        signedQty: 1,
      );
    }
  }

  test('outbox kosong tidak mengirim apa pun', () async {
    final result = await outbox.flush();

    expect(result.sent, 0);
    expect(result.remaining, 0);
    expect(remote.createCalls, 0);
    expect(telemetry.events, isEmpty);
  });

  test('semua transaksi pending terkirim dan ditandai synced', () async {
    await seed(3);

    final result = await outbox.flush();

    expect(result.sent, 3);
    expect(result.failed, 0);
    expect(result.remaining, 0);
    expect(remote.stored, hasLength(3));

    final rows = await database.query('transactions');
    expect(rows.every((row) => row['sync_status'] == 'synced'), isTrue);
    expect(rows.every((row) => row['synced_at'] != null), isTrue);
    expect(telemetry.events, contains(TelemetryEvents.outboxSyncCompleted));
  });

  test('replay dokumen yang sama tidak menggandakan data', () async {
    await seed(2);
    await outbox.flush();

    // Semua baris dikirim ulang (mis. status lokal direset saat restore).
    await database.update('transactions', {'sync_status': 'pending'});
    final replay = await outbox.flush();

    expect(replay.sent, 2);
    expect(remote.stored, hasLength(2));
    expect(remote.alreadyExisted, 2);
  });

  test('jaringan mati menandai gagal dan menyisakan antrean', () async {
    await seed(3);
    remote.offline = true;

    final result = await outbox.flush();

    expect(result.sent, 0);
    expect(result.failed, 1);
    expect(result.remaining, 3);
    expect(result.error, contains('tidak ada jaringan'));
    expect(telemetry.events, contains(TelemetryEvents.outboxSyncFailed));
    expect(telemetry.errors, contains('outbox_sync_failed'));

    final failed = await database.query(
      'transactions',
      where: 'sync_status = ?',
      whereArgs: ['failed'],
    );
    expect(failed, hasLength(1));
    expect(failed.single['retry_count'], 1);
  });

  test('kiriman berikutnya melanjutkan antrean setelah jaringan pulih',
      () async {
    await seed(3);
    remote.offline = true;
    await outbox.flush();

    remote.offline = false;
    // Pengiriman berikutnya mengembalikan baris `syncing` yang tertinggal.
    final result = await outbox.flush();

    expect(result.sent, 3);
    expect(result.remaining, 0);
    expect(remote.stored, hasLength(3));
  });

  test('300 transaksi terkirim semua tanpa duplikat', () async {
    await seed(300);
    expect(await repository.pendingCount(), 300);

    final result = await outbox.flush();

    expect(result.sent, 300);
    expect(result.failed, 0);
    expect(result.remaining, 0);
    expect(remote.stored, hasLength(300));
    expect(await repository.pendingCount(), 0);
  });
}
