import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:warehouse_mobile/core/master/product_repository.dart';

import 'support/test_database.dart';

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

void main() {
  late Database database;
  late ProductRepository repository;

  setUp(() async {
    database = await openTestDatabase();
    repository = ProductRepository(database: database, warehouseId: 'JKT-01');
  });

  tearDown(() async {
    await database.close();
  });

  test('lookup barcode menormalkan spasi dan huruf kecil', () async {
    await seedProduct(database);

    final found = await repository.findByBarcode(' 899123 ');

    expect(found, isNotNull);
    expect(found!.code, 'BRG-001');
    expect(found.product.uom, 'box');
  });

  test('barcode asing mengembalikan null tanpa menyentuh jaringan', () async {
    await seedProduct(database);

    expect(await repository.findByBarcode('000000'), isNull);
    expect(await repository.findByBarcode('   '), isNull);
  });

  test('produk nonaktif tetap bisa dijelaskan saat dipindai', () async {
    await seedProduct(database, active: false);

    final found = await repository.findByBarcode('899123');
    expect(found, isNotNull);
    expect(found!.product.active, isFalse);

    // Tidak muncul di hasil pencarian.
    expect(await repository.search('sarung'), isEmpty);
  });

  test('pencarian mencocokkan awalan kode dan potongan nama', () async {
    await seedProduct(database);
    await seedProduct(
      database,
      id: 'p2',
      code: 'BRG-002',
      name: 'Masker Medis',
      barcodes: <String>['899999'],
    );

    final byCode = await repository.search('brg-00');
    expect(byCode.map((view) => view.code), ['BRG-001', 'BRG-002']);

    final byName = await repository.search('masker');
    expect(byName.single.code, 'BRG-002');

    expect(await repository.search('   '), isEmpty);
  });

  test('input manual menerima kode produk maupun barcode', () async {
    await seedProduct(database);

    expect((await repository.findByCodeOrBarcode('brg-001'))!.product.id, 'p1');
    expect((await repository.findByCodeOrBarcode('899123'))!.product.id, 'p1');
    expect(await repository.findByCodeOrBarcode('tidak-ada'), isNull);
  });

  test('saldo berasal dari ledger lokal, bukan field master', () async {
    await seedProduct(database);

    expect((await repository.findByBarcode('899123'))!.balance, 0);

    await insertLedgerRow(database, id: 'tx-1', productId: 'p1', signedQty: 5);
    await insertLedgerRow(database, id: 'tx-2', productId: 'p1', signedQty: -2);

    expect((await repository.findByBarcode('899123'))!.balance, 3);
  });

  test('saldo gudang lain tidak bocor ke gudang ini', () async {
    await seedProduct(database);
    await insertLedgerRow(
      database,
      id: 'tx-lain',
      productId: 'p1',
      signedQty: 9,
      warehouseId: 'JKT-02',
    );

    expect((await repository.findByBarcode('899123'))!.balance, 0);
  });

  test('banner master usang muncul setelah lebih dari 24 jam', () {
    final now = DateTime.utc(2026, 11, 18, 12);

    expect(isMasterStale(null, now: now), isTrue);
    expect(
      isMasterStale(now.subtract(const Duration(hours: 23)), now: now),
      isFalse,
    );
    expect(
      isMasterStale(now.subtract(const Duration(hours: 24)), now: now),
      isFalse,
    );
    expect(
      isMasterStale(
        now.subtract(const Duration(hours: 24, minutes: 1)),
        now: now,
      ),
      isTrue,
    );
  });

  test('produk dengan saldo di bawah minimum dihitung sebagai perlu restock',
      () async {
    await seedProduct(database);
    await database.update(
      'products',
      {'min_stock': 5},
      where: 'product_id = ?',
      whereArgs: ['p1'],
    );
    await insertLedgerRow(
      database,
      id: 'tx-out',
      productId: 'p1',
      signedQty: -3,
    );

    expect(await repository.lowStockCount(), 1);
  });
}
