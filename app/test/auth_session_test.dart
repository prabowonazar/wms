import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:warehouse_mobile/core/auth/auth_repository.dart';
import 'package:warehouse_mobile/core/auth/auth_models.dart';
import 'package:warehouse_mobile/core/storage/profile_cache.dart';
import 'package:warehouse_mobile/core/transactions/sync_policy.dart';

import 'support/test_database.dart';

void main() {
  const profile = UserProfile(
    uid: 'op1',
    name: 'Operator Satu',
    email: 'op1@example.com',
    role: UserRole.operator,
    warehouseIds: <String>['JKT-01'],
    active: true,
  );

  test('sesi offline berlaku sampai tepat 7 hari', () {
    final fetchedAt = DateTime.utc(2026, 11, 1).millisecondsSinceEpoch;

    expect(
      AuthRepository.offlineSessionExpired(
        fetchedAt,
        now: DateTime.utc(2026, 11, 8),
      ),
      isFalse,
    );
    expect(
      AuthRepository.offlineSessionExpired(
        fetchedAt,
        now: DateTime.utc(2026, 11, 8, 0, 0, 1),
      ),
      isTrue,
    );
    expect(
      AuthRepository.offlineSessionExpired(
        fetchedAt,
        now: DateTime.utc(2026, 11, 9),
      ),
      isTrue,
    );
  });

  test('cache profil menyimpan waktu ambil terakhir', () async {
    final Database database = await openTestDatabase();
    addTearDown(database.close);
    final cache = ProfileCache(database);

    expect(await cache.lastFetchedAt('op1'), isNull);

    final fetchedAt = DateTime.utc(2026, 11, 18).millisecondsSinceEpoch;
    await cache.save(profile, fetchedAt: fetchedAt);

    expect(await cache.lastFetchedAt('op1'), fetchedAt);
    expect((await cache.read('op1'))?.uid, 'op1');
    expect(AuthRepository.offlineSessionExpired(
      fetchedAt,
      now: DateTime.utc(2026, 11, 25),
    ), isFalse);
  });

  test('retry policy berhenti setelah batas dan memakai backoff', () {
    expect(retryDelayFor(1), const Duration(seconds: 30));
    expect(retryDelayFor(2), const Duration(seconds: 60));
    expect(retryDelayFor(3), const Duration(seconds: 120));
    expect(retryDelayFor(4), const Duration(seconds: 240));
    expect(retryDelayFor(5), isNull);
    expect(describeSyncError(StateError('cloud_firestore/unavailable')),
        contains('Tidak ada koneksi'));
  });
}
