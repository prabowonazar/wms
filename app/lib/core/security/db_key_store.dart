import 'dart:convert';
import 'dart:math';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Penyimpanan kunci enkripsi database (SQLCipher).
///
/// Kunci dibuat sekali per instalasi, disimpan di Android Keystore lewat
/// `flutter_secure_storage`, dan tidak pernah ditulis ke log atau file biasa.
/// Kunci TIDAK boleh dirotasi diam-diam: bila kunci berubah, database lama
/// tidak bisa dibuka dan data outbox hilang.
abstract class DatabaseKeyStore {
  Future<String> loadOrCreateKey();
}

class DatabaseKeyException implements Exception {
  const DatabaseKeyException(this.message);

  final String message;

  @override
  String toString() => 'DatabaseKeyException: $message';
}

class SecureDatabaseKeyStore implements DatabaseKeyStore {
  SecureDatabaseKeyStore({FlutterSecureStorage? storage})
      : _storage = storage ??
            const FlutterSecureStorage(
              aOptions: AndroidOptions(encryptedSharedPreferences: true),
            );

  static const String _storageKey = 'warehouse_db_key_v1';
  static const int _keyLengthBytes = 32;

  final FlutterSecureStorage _storage;
  String? _cachedKey;

  @override
  Future<String> loadOrCreateKey() async {
    final cached = _cachedKey;
    if (cached != null) {
      return cached;
    }

    final existing = await _storage.read(key: _storageKey);
    if (existing != null && existing.isNotEmpty) {
      _assertValid(existing);
      _cachedKey = existing;
      return existing;
    }

    final created = _generateKey();
    await _storage.write(key: _storageKey, value: created);
    _cachedKey = created;
    return created;
  }

  /// Menghapus kunci. Hanya untuk test/uninstall; database lama menjadi
  /// tidak terbaca, jadi jangan dipanggil dari alur aplikasi.
  Future<void> deleteKey() async {
    _cachedKey = null;
    await _storage.delete(key: _storageKey);
  }

  void _assertValid(String key) {
    final List<int> bytes;
    try {
      bytes = base64Url.decode(key);
    } on FormatException {
      throw const DatabaseKeyException(
        'Kunci database di penyimpanan aman rusak. '
        'Jangan hapus aplikasi; hubungi admin untuk pemulihan.',
      );
    }
    if (bytes.length != _keyLengthBytes) {
      throw const DatabaseKeyException(
        'Panjang kunci database tidak sesuai (harus 32 byte).',
      );
    }
  }

  String _generateKey() {
    final random = Random.secure();
    final bytes = List<int>.generate(_keyLengthBytes, (_) => random.nextInt(256));
    return base64UrlEncode(bytes);
  }
}
