import 'package:flutter/services.dart' show rootBundle;
// `Database` dipakai tanpa prefiks; prefixed import di bawah tidak
// menyediakan nama tanpa prefiks.
import 'package:sqflite_common/sqlite_api.dart';
import 'package:sqflite_sqlcipher/sqflite.dart' as sqlcipher;

import 'schema_bootstrap.dart';

/// Database lokal terenkripsi (SQLCipher AES-256).
///
/// Kenapa SQLCipher, bukan SQLite bawaan Android: skema memakai
/// `GENERATED ALWAYS AS ... STORED` (butuh SQLite >= 3.31) dan
/// `ON CONFLICT ... DO UPDATE`, sedangkan SQLite di Android 8 lebih tua.
/// SQLCipher yang dipakai paket ini membawa SQLite modern.
class AppDatabase {
  const AppDatabase._();

  static const String fileName = 'warehouse.db';

  /// Membuka database, membuat skema v1 bila masih kosong.
  ///
  /// [password] berasal dari [DatabaseKeyStore] dan tidak boleh di-log.
  static Future<Database> open({
    required String path,
    required String password,
  }) async {
    final script = await rootBundle.loadString(SchemaBootstrap.assetPath);

    return sqlcipher.openDatabase(
      path,
      password: password,
      version: SchemaBootstrap.version,
      onConfigure: _configure,
      onCreate: (db, version) async {
        await SchemaBootstrap.apply(db, script);
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        // Sengaja gagal keras: migrasi setengah jalan lebih berbahaya daripada
        // aplikasi berhenti dengan pesan jelas.
        throw StateError(
          'Migrasi database device dari v$oldVersion ke v$newVersion belum '
          'tersedia. Jangan hapus data; pasang versi aplikasi yang sesuai.',
        );
      },
    );
  }

  /// Pengaturan yang tidak boleh berada di dalam transaksi pembuatan skema.
  static Future<void> _configure(Database db) async {
    // Semua PRAGMA lewat rawQuery: sqflite_sqlcipher di Android menolak
    // execute() untuk pernyataan PRAGMA ("Queries can be performed using
    // SQLiteDatabase query or rawQuery methods only"), termasuk WAL dan
    // busy_timeout. Test FFI tidak menangkap perbedaan perilaku ini.
    await db.rawQuery('PRAGMA foreign_keys = ON');
    await db.rawQuery('PRAGMA journal_mode = WAL');
    await db.rawQuery('PRAGMA busy_timeout = 5000');
  }
}
