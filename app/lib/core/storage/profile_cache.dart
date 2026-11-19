import 'package:sqflite_common/sqlite_api.dart';

import '../auth/auth_models.dart';

/// Cache profil di SQLite agar sesi tetap bisa dipakai saat jaringan mati.
///
/// Sumber kebenaran tetap `users/{uid}` di Firestore; cache hanya salinan
/// terakhir yang berhasil dibaca.
class ProfileCache {
  const ProfileCache(this._db);

  final DatabaseExecutor _db;

  Future<void> save(UserProfile profile, {required int fetchedAt}) async {
    await _db.insert(
      'user_profile',
      {
        'uid': profile.uid,
        'name': profile.name,
        'email': profile.email,
        'role': profile.role.wireName,
        'warehouse_id': profile.warehouseId,
        'active': profile.active ? 1 : 0,
        'fetched_at': fetchedAt,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<UserProfile?> read(String uid) async {
    final rows = await _db.query(
      'user_profile',
      where: 'uid = ?',
      whereArgs: [uid],
      limit: 1,
    );
    if (rows.isEmpty) {
      return null;
    }

    final row = rows.first;
    final role = UserRole.tryParse(row['role']);
    if (role == null) {
      return null;
    }
    final warehouseId = (row['warehouse_id'] as String?) ?? '';

    return UserProfile(
      uid: uid,
      name: (row['name'] as String?) ?? '',
      email: (row['email'] as String?) ?? '',
      role: role,
      warehouseIds: warehouseId.isEmpty ? const [] : [warehouseId],
      active: (row['active'] as int? ?? 0) == 1,
    );
  }

  Future<void> clear() async {
    await _db.delete('user_profile');
  }

  /// Kapan profil terakhir berhasil diambil dari server (epoch ms UTC).
  ///
  /// Dipakai pembatas sesi offline (FR-AUTH-06): `null` bila belum pernah
  /// tersimpan.
  Future<int?> lastFetchedAt(String uid) async {
    final rows = await _db.query(
      'user_profile',
      columns: ['fetched_at'],
      where: 'uid = ?',
      whereArgs: [uid],
      limit: 1,
    );
    if (rows.isEmpty) {
      return null;
    }
    final value = rows.first['fetched_at'];
    return value is int ? value : null;
  }
}
