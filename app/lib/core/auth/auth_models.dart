enum UserRole {
  operator('operator'),
  supervisor('supervisor'),
  admin('admin');

  const UserRole(this.wireName);

  /// Nilai yang disimpan di Firestore dan SQLite.
  final String wireName;

  static UserRole? tryParse(Object? value) {
    if (value is! String) {
      return null;
    }
    for (final role in UserRole.values) {
      if (role.wireName == value) {
        return role;
      }
    }
    return null;
  }

  String get label {
    switch (this) {
      case UserRole.operator:
        return 'Operator';
      case UserRole.supervisor:
        return 'Supervisor';
      case UserRole.admin:
        return 'Admin';
    }
  }
}

/// Profil pengguna dari `users/{uid}` (lihat `docs/firestore-schema.md` §2.1).
class UserProfile {
  const UserProfile({
    required this.uid,
    required this.name,
    required this.email,
    required this.role,
    required this.warehouseIds,
    required this.active,
  });

  factory UserProfile.fromFirestore(String uid, Map<String, dynamic> data) {
    final role = UserRole.tryParse(data['role']);
    if (role == null) {
      throw FormatException('Role tidak dikenal: ${data['role']}');
    }
    final rawWarehouses = data['warehouseIds'];
    final warehouses = rawWarehouses is Iterable
        ? rawWarehouses.whereType<String>().toList(growable: false)
        : const <String>[];

    return UserProfile(
      uid: uid,
      name: (data['name'] as String?)?.trim() ?? '',
      email: (data['email'] as String?)?.trim() ?? '',
      role: role,
      warehouseIds: warehouses,
      active: data['active'] == true,
    );
  }

  final String uid;
  final String name;
  final String email;
  final UserRole role;
  final List<String> warehouseIds;
  final bool active;

  /// MVP hanya satu gudang; `warehouseIds` disimpan untuk kompatibilitas.
  String get warehouseId => warehouseIds.isEmpty ? '' : warehouseIds.first;

  String get displayName => name.isNotEmpty ? name : email;

  UserProfile copyWith({String? name, String? email}) {
    return UserProfile(
      uid: uid,
      name: name ?? this.name,
      email: email ?? this.email,
      role: role,
      warehouseIds: warehouseIds,
      active: active,
    );
  }
}

enum DenialReason {
  profileMissing(
    code: 'profile_missing',
    message: 'Akun Anda belum terdaftar di aplikasi gudang. '
        'Hubungi Admin untuk didaftarkan.',
  ),
  inactive(
    code: 'inactive',
    message: 'Akun Anda dinonaktifkan. '
        'Hubungi Admin bila ini tidak disengaja.',
  ),
  warehouseMissing(
    code: 'warehouse_missing',
    message: 'Akun Anda belum punya gudang. Hubungi Admin.',
  ),
  unknownRole(
    code: 'unknown_role',
    message: 'Role akun tidak dikenali. Hubungi Admin.',
  ),
  profileUnavailable(
    code: 'profile_unavailable',
    message: 'Profil tidak dapat dimuat. Periksa jaringan lalu coba lagi.',
  );

  const DenialReason({required this.code, required this.message});

  final String code;
  final String message;
}

class AuthException implements Exception {
  const AuthException(this.code, this.message);

  final String code;
  final String message;

  @override
  String toString() => 'AuthException($code): $message';
}

/// State login yang dipakai UI. `sealed` agar `switch` wajib lengkap.
sealed class AuthState {
  const AuthState();
}

final class AuthChecking extends AuthState {
  const AuthChecking();
}

final class AuthSignedOut extends AuthState {
  const AuthSignedOut();
}

final class AuthDenied extends AuthState {
  const AuthDenied({
    required this.reason,
    this.email = '',
    this.detail = '',
  });

  final DenialReason reason;
  final String email;
  final String detail;
}

final class AuthReady extends AuthState {
  const AuthReady(this.profile);

  final UserProfile profile;
}
