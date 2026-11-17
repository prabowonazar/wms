import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:warehouse_mobile/core/db/schema_bootstrap.dart';

Future<Database> openDatabaseWithSchema() async {
  final database = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
  final script = File('sqlite_schema.sql').readAsStringSync();
  await SchemaBootstrap.apply(database, script);
  return database;
}

Future<int> scalarInt(Database db, String sql) async {
  final rows = await db.rawQuery(sql);
  return rows.first.values.first! as int;
}

Future<void> insertTransaction(
  Database db, {
  required String id,
  required String type,
  required int qty,
  required int signedQty,
  String syncStatus = 'pending',
  String periodKey = '2026-11-17',
}) async {
  await db.insert('transactions', {
    'transaction_id': id,
    'warehouse_id': 'wh1',
    'product_id': 'p1',
    'product_code': 'P-001',
    'product_name': 'Produk Uji',
    'product_type': 'general',
    'uom': 'pcs',
    'type': type,
    'qty': qty,
    'signed_qty': signedQty,
    'period_key': periodKey,
    'user_id': 'op1',
    'user_name': 'Operator 1',
    'device_id': 'dev1',
    'occurred_at': 1,
    'created_at_client': 1,
    'created_at_local': 1,
    'sync_status': syncStatus,
  });
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
  });

  test('skema v1 membuat 10 tabel, 3 view, dan 5 trigger', () async {
    final db = await openDatabaseWithSchema();
    addTearDown(db.close);

    expect(
      await scalarInt(
        db,
        'SELECT COUNT(*) FROM sqlite_master '
        "WHERE type = 'table' AND name NOT LIKE 'sqlite_%'",
      ),
      10,
    );
    expect(
      await scalarInt(
        db,
        "SELECT COUNT(*) FROM sqlite_master WHERE type = 'view'",
      ),
      3,
    );
    expect(
      await scalarInt(
        db,
        "SELECT COUNT(*) FROM sqlite_master WHERE type = 'trigger'",
      ),
      5,
    );
  });

  test('skema aman dijalankan ulang (idempoten)', () async {
    final db = await openDatabaseWithSchema();
    addTearDown(db.close);

    final script = File('sqlite_schema.sql').readAsStringSync();
    await SchemaBootstrap.apply(db, script);
    await SchemaBootstrap.apply(db, script);

    expect(
      await scalarInt(
        db,
        "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' "
        "AND name NOT LIKE 'sqlite_%'",
      ),
      10,
    );
  });

  test('v_product_balance menjumlahkan signed_qty dan mengabaikan failed',
      () async {
    final db = await openDatabaseWithSchema();
    addTearDown(db.close);

    await insertTransaction(
      db,
      id: 'tx-in',
      type: 'incoming',
      qty: 5,
      signedQty: 5,
    );
    await insertTransaction(
      db,
      id: 'tx-out',
      type: 'outgoing',
      qty: 3,
      signedQty: -3,
    );
    await insertTransaction(
      db,
      id: 'tx-failed',
      type: 'incoming',
      qty: 100,
      signedQty: 100,
      syncStatus: 'failed',
    );

    final rows = await db.query('v_product_balance');
    expect(rows, hasLength(1));
    expect(rows.single['ending_qty'], 2);
    expect(rows.single['unsynced_qty'], 2);
    expect(rows.single['txn_count'], 2);
  });

  test('v_stock_card menghitung opening dan ending per periode', () async {
    final db = await openDatabaseWithSchema();
    addTearDown(db.close);

    await insertTransaction(
      db,
      id: 'tx-d1',
      type: 'incoming',
      qty: 4,
      signedQty: 4,
      periodKey: '2026-11-16',
    );
    await insertTransaction(
      db,
      id: 'tx-d2',
      type: 'incoming',
      qty: 2,
      signedQty: 2,
      periodKey: '2026-11-17',
    );

    final rows = await db.query(
      'v_stock_card',
      where: 'period_key = ?',
      whereArgs: ['2026-11-17'],
    );
    expect(rows, hasLength(1));
    expect(rows.single['opening_qty'], 4);
    expect(rows.single['incoming_qty'], 2);
    expect(rows.single['ending_qty'], 6);
  });

  test('transaksi pending tidak boleh diubah isinya', () async {
    final db = await openDatabaseWithSchema();
    addTearDown(db.close);

    await insertTransaction(
      db,
      id: 'tx-1',
      type: 'incoming',
      qty: 5,
      signedQty: 5,
    );

    await expectLater(
      db.rawUpdate("UPDATE transactions SET qty = 6 WHERE transaction_id = 'tx-1'"),
      throwsA(
        predicate(
          (Object error) => error.toString().contains('immutable'),
          'error immutability dari trigger SQLite',
        ),
      ),
    );
  });

  test('kolom sync tetap boleh diubah', () async {
    final db = await openDatabaseWithSchema();
    addTearDown(db.close);

    await insertTransaction(
      db,
      id: 'tx-1',
      type: 'incoming',
      qty: 5,
      signedQty: 5,
    );

    await db.rawUpdate(
      "UPDATE transactions SET sync_status = 'synced', synced_at = 123 "
      "WHERE transaction_id = 'tx-1'",
    );

    final rows = await db.query('transactions');
    expect(rows.single['sync_status'], 'synced');
    expect(rows.single['synced_at'], 123);
  });

  test('hanya transaksi failed yang boleh dihapus', () async {
    final db = await openDatabaseWithSchema();
    addTearDown(db.close);

    await insertTransaction(
      db,
      id: 'tx-pending',
      type: 'incoming',
      qty: 1,
      signedQty: 1,
    );
    await expectLater(
      db.delete('transactions', where: 'transaction_id = ?', whereArgs: ['tx-pending']),
      throwsA(
        predicate(
          (Object error) => error.toString().contains('Hanya transaksi gagal'),
          'error delete guard dari trigger SQLite',
        ),
      ),
    );

    await insertTransaction(
      db,
      id: 'tx-failed',
      type: 'incoming',
      qty: 1,
      signedQty: 1,
      syncStatus: 'failed',
    );
    await db.delete('transactions', where: 'transaction_id = ?', whereArgs: ['tx-failed']);
    expect(await scalarInt(db, 'SELECT COUNT(*) FROM transactions'), 1);
  });

  test('variance cycle-count dihitung generated column', () async {
    final db = await openDatabaseWithSchema();
    addTearDown(db.close);

    await db.insert('cycle_counts', {
      'cycle_count_id': 'cc-1',
      'warehouse_id': 'wh1',
      'period_key': '2026-11-17',
      'status': 'open',
      'started_by': 'op1',
      'started_at': 1,
      'created_at_local': 1,
    });
    await db.insert('cycle_count_lines', {
      'cycle_count_id': 'cc-1',
      'product_id': 'p1',
      'product_code': 'P-001',
      'product_name': 'Produk Uji',
      'uom': 'pcs',
      'system_qty': 10,
      'counted_qty': 7,
      'counted_by': 'op1',
      'counted_at': 2,
    });

    final lines = await db.query('cycle_count_lines');
    expect(lines.single['variance'], -3);
  });

  test('baris cycle-count terkunci setelah sesi dikirim', () async {
    final db = await openDatabaseWithSchema();
    addTearDown(db.close);

    await db.insert('cycle_counts', {
      'cycle_count_id': 'cc-1',
      'warehouse_id': 'wh1',
      'period_key': '2026-11-17',
      'status': 'open',
      'started_by': 'op1',
      'started_at': 1,
      'created_at_local': 1,
    });
    await db.insert('cycle_count_lines', {
      'cycle_count_id': 'cc-1',
      'product_id': 'p1',
      'product_code': 'P-001',
      'product_name': 'Produk Uji',
      'uom': 'pcs',
      'system_qty': 10,
      'counted_qty': 7,
      'counted_by': 'op1',
      'counted_at': 2,
    });

    await db.update(
      'cycle_counts',
      {'status': 'submitted'},
      where: 'cycle_count_id = ?',
      whereArgs: ['cc-1'],
    );

    await expectLater(
      db.update(
        'cycle_count_lines',
        {'counted_qty': 8},
        where: 'cycle_count_id = ?',
        whereArgs: ['cc-1'],
      ),
      throwsA(
        predicate(
          (Object error) => error.toString().contains('sudah dikirim'),
          'error lock dari trigger SQLite',
        ),
      ),
    );
  });
}
