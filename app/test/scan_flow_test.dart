import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:warehouse_mobile/core/auth/auth_models.dart';
import 'package:warehouse_mobile/core/master/master_remote.dart';
import 'package:warehouse_mobile/core/master/master_sync.dart';
import 'package:warehouse_mobile/core/master/product.dart';
import 'package:warehouse_mobile/core/master/product_repository.dart';
import 'package:warehouse_mobile/core/observability/telemetry.dart';
import 'package:warehouse_mobile/features/scan/scan_screen.dart';
import 'package:warehouse_mobile/features/scan/search_screen.dart';

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

const UserProfile profile = UserProfile(
  uid: 'op1',
  name: 'Operator Satu',
  email: 'op1@example.com',
  role: UserRole.operator,
  warehouseIds: <String>['JKT-01'],
  active: true,
);

Future<void> seedProduct(
  Database database, {
  String id = 'p1',
  String code = 'BRG-001',
  String name = 'Sarung Tangan Nitril',
  bool active = true,
  List<String> barcodes = const <String>['899123'],
}) async {
  await database.insert('products', {
    'product_id': id,
    'code': code,
    'name': name,
    'type': 'consumable',
    'uom': 'box',
    'min_stock': 0,
    'active': active ? 1 : 0,
    'updated_at': DateTime.utc(2026, 11, 18).millisecondsSinceEpoch,
    'synced_at': DateTime.utc(2026, 11, 18).millisecondsSinceEpoch,
  });
  for (final barcode in barcodes) {
    await database.insert('product_barcodes', {
      'barcode': barcode,
      'product_id': id,
      'format': 'CODE128',
      'updated_at': DateTime.utc(2026, 11, 18).millisecondsSinceEpoch,
    });
  }
}

/// Menandai master baru saja disinkronkan agar `initState` tidak memicu full
/// sync yang (secara desain) mengganti seluruh mirror lokal.
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

  setUp(() async {
    database = await openTestDatabase();
  });

  tearDown(() async {
    await database.close();
  });

  Widget buildScanScreen() {
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
        ),
        telemetry: const NoopTelemetry(),
        profile: profile,
        onSignOut: () async {},
        scannerBuilder: (context, onCode) => Center(
          child: ElevatedButton(
            onPressed: () => onCode(' 899123 '),
            child: const Text('emit'),
          ),
        ),
      ),
    );
  }

  testWidgets('scan barcode dikenal menampilkan produk dan saldo', (
    tester,
  ) async {
    await seedProduct(database);
    await markMasterFresh(database);
    await tester.pumpWidget(buildScanScreen());
    await tester.pumpAndSettle();

    await tester.tap(find.text('emit'));
    await tester.pumpAndSettle();

    expect(find.text('Sarung Tangan Nitril'), findsOneWidget);
    expect(find.text('Saldo saat ini'), findsOneWidget);
    expect(find.text('0 box'), findsOneWidget);
  });

  testWidgets('barcode sama yang terbaca berulang <800 ms hanya dibuka sekali', (
    tester,
  ) async {
    await seedProduct(database);
    await markMasterFresh(database);
    await tester.pumpWidget(
      MaterialApp(
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
          ),
          telemetry: const NoopTelemetry(),
          profile: profile,
          onSignOut: () async {},
          scannerBuilder: (context, onCode) => Center(
            child: ElevatedButton(
              // Dua deteksi dalam satu frame, seperti kamera yang membaca
              // barcode yang sama dua kali sebelum lembar terbuka.
              onPressed: () {
                onCode('899123');
                onCode('899123');
              },
              child: const Text('emit'),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('emit'));
    await tester.pumpAndSettle();

    expect(find.text('Saldo saat ini'), findsOneWidget);
    expect(find.text('Sarung Tangan Nitril'), findsOneWidget);
  });

  testWidgets('barcode asing membuka SCR-06 dan laporan tersimpan lokal', (
    tester,
  ) async {
    await seedProduct(database);
    await markMasterFresh(database);
    await tester.pumpWidget(
      MaterialApp(
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
          ),
          telemetry: const NoopTelemetry(),
          profile: profile,
          onSignOut: () async {},
          scannerBuilder: (context, onCode) => Center(
            child: ElevatedButton(
              onPressed: () => onCode('000111'),
              child: const Text('emit-unknown'),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('emit-unknown'));
    await tester.pumpAndSettle();
    expect(find.text('Barang tidak dikenal'), findsOneWidget);
    expect(find.text('000111'), findsOneWidget);

    await tester.tap(find.text('Lapor admin'));
    await tester.pumpAndSettle();

    final rows = await database.query('error_log');
    expect(rows, hasLength(1));
    expect(rows.single['code'], 'UNKNOWN_BARCODE');
    expect(find.text('Sudah dilaporkan'), findsOneWidget);
  });

  testWidgets('produk nonaktif dijelaskan sebagai produk tidak aktif', (
    tester,
  ) async {
    await seedProduct(database, active: false);
    await markMasterFresh(database);
    await tester.pumpWidget(buildScanScreen());
    await tester.pumpAndSettle();

    await tester.tap(find.text('emit'));
    await tester.pumpAndSettle();

    expect(find.text('Produk tidak aktif'), findsOneWidget);
  });

  testWidgets('banner master muncul bila belum pernah sync', (tester) async {
    await tester.pumpWidget(buildScanScreen());
    await tester.pumpAndSettle();

    expect(find.text('Master produk belum diunduh'), findsOneWidget);
    expect(find.text('Sync sekarang'), findsOneWidget);
  });

  testWidgets('banner master hilang bila sync <24 jam', (tester) async {
    await database.insert('meta', {
      'key': MasterSyncService.lastSyncKey,
      'value': '${DateTime.now().subtract(const Duration(hours: 2)).toUtc().millisecondsSinceEpoch}',
      'updated_at': DateTime.now().millisecondsSinceEpoch,
    });

    await tester.pumpWidget(buildScanScreen());
    await tester.pumpAndSettle();

    expect(find.textContaining('Master produk'), findsNothing);
  });

  testWidgets('pencarian 3 karakter menampilkan hasil lalu membuka lembar', (
    tester,
  ) async {
    await seedProduct(database);
    await tester.pumpWidget(
      MaterialApp(
        home: SearchScreen(database: database, warehouseId: 'JKT-01'),
      ),
    );

    await tester.enterText(find.byType(TextField), 'sar');
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();

    expect(find.text('Sarung Tangan Nitril'), findsOneWidget);

    await tester.tap(find.text('Sarung Tangan Nitril'));
    await tester.pumpAndSettle();

    expect(find.text('Saldo saat ini'), findsOneWidget);
  });

  testWidgets('kode persis yang tidak ada memberi pesan jelas', (tester) async {
    await seedProduct(database);
    await tester.pumpWidget(
      MaterialApp(
        home: SearchScreen(database: database, warehouseId: 'JKT-01'),
      ),
    );

    await tester.enterText(find.byType(TextField), 'BRG-999');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();

    expect(find.textContaining('tidak ditemukan'), findsOneWidget);
  });
}
