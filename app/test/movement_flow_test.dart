import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:warehouse_mobile/core/auth/auth_models.dart';
import 'package:warehouse_mobile/core/master/master_remote.dart';
import 'package:warehouse_mobile/core/master/master_sync.dart';
import 'package:warehouse_mobile/core/master/product.dart';
import 'package:warehouse_mobile/core/master/product_repository.dart';
import 'package:warehouse_mobile/core/transactions/outbox_sync.dart';
import 'package:warehouse_mobile/core/transactions/transaction_repository.dart';
import 'package:warehouse_mobile/features/scan/scan_screen.dart';

import 'support/fake_transaction_remote.dart';
import 'support/test_database.dart';

class EmptyRemote implements MasterRemote {
  @override
  Future<MasterPage> fetchProducts({
    required String warehouseId,
    DateTime? updatedAfter,
    int limit = 500,
  }) async {
    return const MasterPage(
      products: <Product>[],
      newestUpdatedAt: null,
      hasMore: false,
    );
  }
}

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
  await database.insert('product_barcodes', {
    'barcode': '899123',
    'product_id': 'p1',
    'format': 'CODE128',
    'updated_at': DateTime.utc(2026, 11, 18).millisecondsSinceEpoch,
  });
}

Future<void> markMasterFresh(Database database) async {
  final now = DateTime.now();
  await database.insert(
    'meta',
    {
      'key': MasterSyncService.lastSyncKey,
      'value': '${now.toUtc().millisecondsSinceEpoch}',
      'updated_at': now.millisecondsSinceEpoch,
    },
    conflictAlgorithm: ConflictAlgorithm.replace,
  );
}

void main() {
  late Database database;
  late TransactionRepository transactions;
  late FakeTransactionRemote remote;
  late RecordingTelemetry telemetry;
  late OutboxSyncService outbox;

  setUp(() async {
    database = await openTestDatabase();
    await seedProduct(database);
    transactions = TransactionRepository(
      database: database,
      warehouseId: 'JKT-01',
    );
    remote = FakeTransactionRemote();
    telemetry = RecordingTelemetry();
    outbox = OutboxSyncService(
      repository: transactions,
      remote: remote,
      telemetry: telemetry,
    );
  });

  tearDown(() async {
    await database.close();
  });

  Widget harness(UserProfile profile) {
    return MaterialApp(
      home: ScanScreen(
        database: database,
        products: ProductRepository(
          database: database,
          warehouseId: 'JKT-01',
        ),
        sync: MasterSyncService(
          database: database,
          remote: EmptyRemote(),
          warehouseId: 'JKT-01',
          telemetry: telemetry,
        ),
        transactions: transactions,
        outbox: outbox,
        telemetry: telemetry,
        profile: profile,
        onSignOut: () async {},
        scannerBuilder: (context, onCode) => Center(
          child: ElevatedButton(
            onPressed: () => onCode('899123'),
            child: const Text('emit'),
          ),
        ),
      ),
    );
  }

  Future<void> openProductSheet(WidgetTester tester, UserProfile profile) async {
    await markMasterFresh(database);
    await tester.pumpWidget(harness(profile));
    await tester.pumpAndSettle();
    await tester.tap(find.text('emit'));
    await tester.pumpAndSettle();
  }

  Future<void> tapSave(WidgetTester tester) async {
    await tester.ensureVisible(find.text('SIMPAN'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('SIMPAN'));
    await tester.pumpAndSettle();
  }

  testWidgets('keluar mengurangi saldo dan menyimpan tepat satu baris', (
    tester,
  ) async {
    await insertLedgerRow(
      database,
      id: 'in-1',
      productId: 'p1',
      signedQty: 5,
      syncStatus: 'synced',
    );
    await openProductSheet(tester, operatorProfile);

    expect(find.text('5 box'), findsOneWidget);

    await tester.tap(find.byKey(const Key('product-outgoing')));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Tambah'));
    await tester.pumpAndSettle();
    await tapSave(tester);

    expect(find.text('Transaksi keluar tersimpan.'), findsOneWidget);
    expect(find.text('3 box'), findsOneWidget);

    final rows = await database.query(
      'transactions',
      where: "type = 'outgoing'",
    );
    expect(rows, hasLength(1));
    expect(rows.single['qty'], 2);
    expect(rows.single['signed_qty'], -2);
    expect(telemetry.events, contains('transaction_saved'));
  });

  testWidgets('stok tidak cukup menampilkan SCR-08 tanpa menulis baris', (
    tester,
  ) async {
    await openProductSheet(tester, operatorProfile);

    await tester.tap(find.byKey(const Key('product-outgoing')));
    await tester.pumpAndSettle();
    await tapSave(tester);

    expect(find.text('Stok tidak cukup'), findsOneWidget);
    expect(find.text('Ubah qty'), findsOneWidget);
    expect(find.text('Override'), findsNothing);

    await tester.tap(find.text('Ubah qty'));
    await tester.pumpAndSettle();

    expect(await database.query('transactions'), isEmpty);
  });

  testWidgets('supervisor bisa override stok negatif dengan alasan', (
    tester,
  ) async {
    await openProductSheet(tester, supervisor);

    await tester.tap(find.byKey(const Key('product-outgoing')));
    await tester.pumpAndSettle();
    await tapSave(tester);

    expect(find.text('Stok tidak cukup'), findsOneWidget);
    final reasonField = find.descendant(
      of: find.byType(AlertDialog),
      matching: find.byType(TextField),
    );
    expect(reasonField, findsOneWidget);

    await tester.enterText(reasonField, 'barang keluar belum dicatat');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Override'));
    await tester.pumpAndSettle();

    expect(find.text('-1 box'), findsOneWidget);

    final row = (await database.query('transactions')).single;
    expect(row['approval_status'], 'pending');
    expect(row['approval_reason'], 'barang keluar belum dicatat');
  });

  testWidgets('alasan override kurang dari 10 karakter tidak bisa dikirim', (
    tester,
  ) async {
    await openProductSheet(tester, supervisor);

    await tester.tap(find.byKey(const Key('product-outgoing')));
    await tester.pumpAndSettle();
    await tapSave(tester);

    final reasonField = find.descendant(
      of: find.byType(AlertDialog),
      matching: find.byType(TextField),
    );
    await tester.enterText(reasonField, 'kurang');
    await tester.pumpAndSettle();

    final button = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Override'),
    );
    expect(button.onPressed, isNull);
    expect(await database.query('transactions'), isEmpty);
  });

  testWidgets('qty 0 membuat tombol simpan nonaktif', (tester) async {
    await openProductSheet(tester, operatorProfile);

    await tester.tap(find.byKey(const Key('product-outgoing')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, '0');
    await tester.pumpAndSettle();

    final button = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'SIMPAN'),
    );
    expect(button.onPressed, isNull);
    expect(await database.query('transactions'), isEmpty);
  });
}
