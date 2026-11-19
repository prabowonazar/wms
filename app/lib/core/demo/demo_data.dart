import 'package:sqflite_common/sqlite_api.dart';

import '../auth/auth_models.dart';
import '../transactions/stock_transaction.dart' show periodKeyFor;

/// Profil untuk MODE DEMO (`--dart-define=DEMO_MODE=true`).
///
/// Bukan akun Firebase dan tidak bisa masuk produksi; dipakai hanya untuk
/// memeriksa UI di device sebelum project dev disiapkan.
const UserProfile demoProfile = UserProfile(
  uid: 'demo-local',
  name: 'Demo Gudang',
  email: 'demo@local',
  role: UserRole.admin,
  warehouseIds: <String>['JKT-01'],
  active: true,
);

/// Isi data contoh agar semua layar punya sesuatu untuk ditampilkan.
/// Aman dijalankan berulang: ID dan kode bersifat tetap.
Future<void> seedDemoData(Database database) async {
  final now = DateTime.now();
  final millis = now.millisecondsSinceEpoch;

  // Master dianggap segar supaya ScanScreen tidak memicu sync Firestore.
  await database.insert(
    'meta',
    <String, Object?>{
      'key': 'last_master_sync_at',
      'value': '$millis',
      'updated_at': millis,
    },
    conflictAlgorithm: ConflictAlgorithm.replace,
  );

  final products = <Map<String, Object?>>[
    <String, Object?>{
      'product_id': 'demo-p1',
      'code': 'BRG-001',
      'name': 'Sarung Tangan Nitril',
      'type': 'consumable',
      'uom': 'box',
      'min_stock': 5,
      'active': 1,
      'updated_at': millis,
      'synced_at': millis,
      'barcode': '899100000001',
    },
    <String, Object?>{
      'product_id': 'demo-p2',
      'code': 'BRG-002',
      'name': 'Masker Medis 3 Ply',
      'type': 'consumable',
      'uom': 'pack',
      'min_stock': 10,
      'active': 1,
      'updated_at': millis,
      'synced_at': millis,
      'barcode': '899100000002',
    },
    <String, Object?>{
      'product_id': 'demo-p3',
      'code': 'BRG-003',
      'name': 'Buku Tulis A5',
      'type': 'stationery',
      'uom': 'pcs',
      'min_stock': 0,
      'active': 1,
      'updated_at': millis,
      'synced_at': millis,
      'barcode': '899100000003',
    },
  ];

  for (final product in products) {
    await database.insert(
      'products',
      <String, Object?>{
        'product_id': product['product_id'],
        'code': product['code'],
        'name': product['name'],
        'type': product['type'],
        'uom': product['uom'],
        'min_stock': product['min_stock'],
        'active': product['active'],
        'updated_at': product['updated_at'],
        'synced_at': product['synced_at'],
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    await database.insert(
      'product_barcodes',
      <String, Object?>{
        'barcode': product['barcode'],
        'product_id': product['product_id'],
        'format': 'EAN13',
        'updated_at': millis,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  final transactions = <Map<String, Object?>>[
    <String, Object?>{
      'id': 'demo-tx-1',
      'product': products[0],
      'type': 'incoming',
      'qty': 20,
      'signed': 20,
    },
    <String, Object?>{
      'id': 'demo-tx-2',
      'product': products[0],
      'type': 'outgoing',
      'qty': 4,
      'signed': -4,
    },
    <String, Object?>{
      'id': 'demo-tx-3',
      'product': products[1],
      'type': 'incoming',
      'qty': 8,
      'signed': 8,
    },
  ];

  for (final item in transactions) {
    final product = item['product']! as Map<String, Object?>;
    await database.insert(
      'transactions',
      <String, Object?>{
        'transaction_id': item['id'],
        'schema_version': 1,
        'warehouse_id': 'JKT-01',
        'product_id': product['product_id'],
        'product_code': product['code'],
        'product_name': product['name'],
        'product_type': product['type'],
        'uom': product['uom'],
        'type': item['type'],
        'qty': item['qty'],
        'signed_qty': item['signed'],
        'period_key': periodKeyFor(now),
        'user_id': demoProfile.uid,
        'user_name': demoProfile.name,
        'device_id': 'demo-device',
        'occurred_at': millis,
        'created_at_client': millis,
        'created_at_local': millis,
        'source': 'scan',
        'note': 'Data contoh mode demo',
        'sync_status': 'synced',
        'synced_at': millis,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }
}
