import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:warehouse_mobile/core/auth/auth_models.dart';
import 'package:warehouse_mobile/core/db/schema_bootstrap.dart';
import 'package:warehouse_mobile/core/storage/profile_cache.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
  });

  late Database db;
  late ProfileCache cache;

  setUp(() async {
    db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    final script = File('sqlite_schema.sql').readAsStringSync();
    await SchemaBootstrap.apply(db, script);
    cache = ProfileCache(db);
  });

  tearDown(() async {
    await db.close();
  });

  const profile = UserProfile(
    uid: 'op1',
    name: 'Operator Satu',
    email: 'op1@contoh.co.id',
    role: UserRole.operator,
    warehouseIds: ['wh1'],
    active: true,
  );

  test('menyimpan lalu membaca profil', () async {
    await cache.save(profile, fetchedAt: 1000);

    final result = await cache.read('op1');
    expect(result, isNotNull);
    expect(result!.uid, 'op1');
    expect(result.name, 'Operator Satu');
    expect(result.email, 'op1@contoh.co.id');
    expect(result.role, UserRole.operator);
    expect(result.warehouseIds, ['wh1']);
    expect(result.warehouseId, 'wh1');
    expect(result.active, isTrue);
  });

  test('menyimpan ulang mengganti baris, bukan menduplikasi', () async {
    await cache.save(profile, fetchedAt: 1000);
    await cache
        .save(profile.copyWith(name: 'Nama Baru'), fetchedAt: 2000);

    final result = await cache.read('op1');
    expect(result!.name, 'Nama Baru');

    final rows = await db.query('user_profile');
    expect(rows, hasLength(1));
    expect(rows.single['fetched_at'], 2000);
  });

  test('profil nonaktif tersimpan sebagai 0', () async {
    const inactive = UserProfile(
      uid: 'op2',
      name: 'Operator Dua',
      email: 'op2@contoh.co.id',
      role: UserRole.operator,
      warehouseIds: [],
      active: false,
    );
    await cache.save(inactive, fetchedAt: 1000);

    final result = await cache.read('op2');
    expect(result!.active, isFalse);
    expect(result.warehouseIds, isEmpty);
  });

  test('profil yang tidak ada mengembalikan null', () async {
    expect(await cache.read('unknown'), isNull);
  });

  test('clear menghapus semua profil', () async {
    await cache.save(profile, fetchedAt: 1000);
    await cache.clear();
    expect(await cache.read('op1'), isNull);
  });
}
