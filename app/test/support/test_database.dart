import 'dart:io';

import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:warehouse_mobile/core/db/schema_bootstrap.dart';

/// Database in-memory dengan skema kanonik `app/sqlite_schema.sql`.
///
/// Dipakai bersama oleh test sync master dan repository produk supaya SQL
/// yang diuji benar-benar SQL yang dipakai aplikasi.
Future<Database> openTestDatabase() async {
  sqfliteFfiInit();
  // No-isolate: query selesai lewat microtask, sehingga aman dipakai di
  // widget test yang memakai fake async.
  final database = await databaseFactoryFfiNoIsolate.openDatabase(
    inMemoryDatabasePath,
  );
  final script = File('sqlite_schema.sql').readAsStringSync();
  await SchemaBootstrap.apply(database, script);
  await database.execute('PRAGMA foreign_keys = ON');
  return database;
}

Future<void> insertLedgerRow(
  Database database, {
  required String id,
  required String productId,
  required int signedQty,
  String warehouseId = 'JKT-01',
  String syncStatus = 'pending',
}) async {
  await database.insert('transactions', {
    'transaction_id': id,
    'warehouse_id': warehouseId,
    'product_id': productId,
    'product_code': 'BRG-001',
    'product_name': 'Produk Uji',
    'product_type': 'consumable',
    'uom': 'pcs',
    'type': signedQty >= 0 ? 'incoming' : 'outgoing',
    'qty': signedQty.abs(),
    'signed_qty': signedQty,
    'period_key': '2026-11-18',
    'user_id': 'op1',
    'user_name': 'Operator 1',
    'device_id': 'dev1',
    'occurred_at': 1,
    'created_at_client': 1,
    'created_at_local': 1,
    'sync_status': syncStatus,
  });
}
