import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:warehouse_mobile/core/master/master_remote.dart';
import 'package:warehouse_mobile/core/master/master_sync.dart';
import 'package:warehouse_mobile/core/master/product.dart';

import 'support/test_database.dart';

/// Remote palsu yang mencatat setiap `updatedAfter` yang dikirim service.
class FakeMasterRemote implements MasterRemote {
  FakeMasterRemote(this.respond);

  final Future<MasterPage> Function(DateTime? updatedAfter) respond;
  final List<DateTime?> calls = <DateTime?>[];

  @override
  Future<MasterPage> fetchProducts({
    required String warehouseId,
    DateTime? updatedAfter,
    int limit = 500,
  }) {
    calls.add(updatedAfter);
    return respond(updatedAfter);
  }
}

MasterPage page(
  List<Product> products, {
  bool hasMore = false,
}) {
  DateTime? newest;
  for (final product in products) {
    if (newest == null || product.updatedAt.isAfter(newest)) {
      newest = product.updatedAt;
    }
  }
  return MasterPage(
    products: products,
    newestUpdatedAt: newest,
    hasMore: hasMore,
  );
}

Product product(
  String id, {
  String? code,
  String name = 'Produk Uji',
  bool active = true,
  DateTime? updatedAt,
  List<String> barcodes = const <String>[],
}) {
  return Product(
    id: id,
    code: code ?? id.toUpperCase(),
    name: name,
    type: 'consumable',
    uom: 'pcs',
    active: active,
    updatedAt: updatedAt ?? DateTime.utc(2026, 11, 18, 1),
    barcodes: barcodes,
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

  MasterSyncService serviceWith(FakeMasterRemote remote) {
    return MasterSyncService(
      database: database,
      remote: remote,
      warehouseId: 'JKT-01',
      clock: () => DateTime.utc(2026, 11, 18, 2),
    );
  }

  test('sync pertama bersifat full: produk + barcode masuk dan kursor tersimpan',
      () async {
    final remote = FakeMasterRemote(
      (_) async => page([
        product(
          'p1',
          code: 'brg-001',
          name: 'Sarung Tangan',
          barcodes: [' 899123 ', '899123'],
        ),
        product('p2', code: 'BRG-002', barcodes: ['BRG2']),
      ]),
    );
    final service = serviceWith(remote);

    final result = await service.syncIfNeeded();

    expect(result.full, isTrue);
    expect(result.productCount, 2);
    expect(remote.calls.single, isNull);

    final rows = await database.query('products', orderBy: 'code');
    expect(rows, hasLength(2));
    expect(rows.first['code'], 'BRG-001');
    expect(rows.first['name'], 'Sarung Tangan');

    final barcodes = await database.query(
      'product_barcodes',
      orderBy: 'barcode',
    );
    expect(
      barcodes.map((row) => row['barcode']),
      orderedEquals(['899123', 'BRG2']),
    );

    expect(
      await service.lastSyncedAt(),
      DateTime.utc(2026, 11, 18, 1),
    );
  });

  test('sync kedua hanya meminta updatedAt setelah kursor terakhir', () async {
    final remote = FakeMasterRemote(
      (updatedAfter) async => updatedAfter == null
          ? page([product('p1', updatedAt: DateTime.utc(2026, 11, 18, 1))])
          : page([
              product(
                'p1',
                name: 'Nama Baru',
                updatedAt: DateTime.utc(2026, 11, 18, 3),
              ),
            ]),
    );
    final service = serviceWith(remote);

    await service.syncIfNeeded();
    await service.syncIfNeeded();

    expect(remote.calls, hasLength(2));
    expect(remote.calls.first, isNull);
    expect(remote.calls.last, DateTime.utc(2026, 11, 18, 1));

    final rows = await database.query('products');
    expect(rows.single['name'], 'Nama Baru');
    expect(await service.lastSyncedAt(), DateTime.utc(2026, 11, 18, 3));
  });

  test('delta memindahkan barcode dan menghapus barcode yang dilepas',
      () async {
    var version = 0;
    final remote = FakeMasterRemote(
      (_) async {
        version++;
        if (version == 1) {
          return page([
            product(
              'p1',
              barcodes: ['AAA', 'BBB'],
              updatedAt: DateTime.utc(2026, 11, 18, 1),
            ),
            product(
              'p2',
              barcodes: <String>[],
              updatedAt: DateTime.utc(2026, 11, 18, 1),
            ),
          ]);
        }
        return page([
          product(
            'p1',
            barcodes: ['AAA'],
            updatedAt: DateTime.utc(2026, 11, 18, 3),
          ),
          product(
            'p2',
            barcodes: ['BBB'],
            updatedAt: DateTime.utc(2026, 11, 18, 3),
          ),
        ]);
      },
    );
    final service = serviceWith(remote);

    await service.syncIfNeeded();
    await service.syncIfNeeded();

    final barcodes = await database.query('product_barcodes', orderBy: 'barcode');
    expect(barcodes, hasLength(2));
    final owner = <String, Object?>{};
    for (final row in barcodes) {
      owner[row['barcode']! as String] = row['product_id'];
    }
    expect(owner['AAA'], 'p1');
    expect(owner['BBB'], 'p2');
  });

  test('beberapa halaman diikuti sampai halaman terakhir', () async {
    final remote = FakeMasterRemote(
      (updatedAfter) async {
        if (updatedAfter == null) {
          return page([
            product('p1', updatedAt: DateTime.utc(2026, 11, 18, 1)),
          ], hasMore: true);
        }
        return page([
          product('p2', updatedAt: DateTime.utc(2026, 11, 18, 2)),
        ]);
      },
    );
    final service = serviceWith(remote);

    final result = await service.syncIfNeeded();

    expect(result.pages, 2);
    expect(result.productCount, 2);
    expect(remote.calls.last, DateTime.utc(2026, 11, 18, 1));
  });

  test('kegagalan di tengah sync tidak memajukan kursor', () async {
    var call = 0;
    final remote = FakeMasterRemote(
      (_) async {
        call++;
        if (call == 1) {
          return page([
            product('p1', updatedAt: DateTime.utc(2026, 11, 18, 1)),
          ], hasMore: true);
        }
        throw StateError('jaringan putus');
      },
    );
    final service = serviceWith(remote);

    await expectLater(service.sync(), throwsStateError);

    expect(await service.lastSyncedAt(), isNull);
    // Halaman pertama tetap tersimpan dan aman: upsert bersifat idempoten.
    expect(await database.query('products'), hasLength(1));
  });

  test('resync gagal di halaman pertama tidak menghapus mirror lama', () async {
    // Isi mirror lebih dulu lewat sync yang sukses.
    final seedRemote = FakeMasterRemote(
      (_) async => page([product('p1', barcodes: ['AAA'])]),
    );
    await serviceWith(seedRemote).syncIfNeeded();
    expect(await database.query('products'), hasLength(1));

    final offline = FakeMasterRemote(
      (_) async => throw StateError('tidak ada jaringan'),
    );
    await expectLater(serviceWith(offline).resyncAll(), throwsStateError);

    // Penghapusan baru terjadi setelah halaman pertama berhasil diambil.
    expect(await database.query('products'), hasLength(1));
    expect(await database.query('product_barcodes'), hasLength(1));
  });

  test('resyncAll mengosongkan produk yang sudah tidak ada di server', () async {
    var version = 0;
    final remote = FakeMasterRemote(
      (_) async {
        version++;
        if (version == 1) {
          return page([
            product('p1', updatedAt: DateTime.utc(2026, 11, 18, 1)),
            product('p2', updatedAt: DateTime.utc(2026, 11, 18, 1)),
          ]);
        }
        return page([product('p2', updatedAt: DateTime.utc(2026, 11, 18, 2))]);
      },
    );
    final service = serviceWith(remote);

    await service.syncIfNeeded();
    await service.resyncAll();

    final rows = await database.query('products');
    expect(rows.single['product_id'], 'p2');
  });

  test('produk nonaktif tetap disimpan agar scan bisa menjelaskan statusnya',
      () async {
    final remote = FakeMasterRemote(
      (_) async => page([product('p1', active: false)]),
    );
    final service = serviceWith(remote);

    await service.syncIfNeeded();

    final rows = await database.query('products');
    expect(rows.single['active'], 0);
  });
}
