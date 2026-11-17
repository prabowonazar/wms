import 'package:sqflite_common/sqlite_api.dart';

import '../sql/sql_script.dart';

/// Membangun skema dari satu file SQL kanonik (`sqlite_schema.sql`).
///
/// File yang sama dipakai aplikasi (asset) dan test (baca langsung dari paket),
/// sehingga tidak ada dua versi skema yang bisa berbeda.
class SchemaBootstrap {
  const SchemaBootstrap._();

  static const String assetPath = 'sqlite_schema.sql';
  static const int version = 1;

  /// Menjalankan seluruh pernyataan skema pada [db].
  ///
  /// `PRAGMA` sudah dibuang oleh [SqlScript.schemaStatements] karena diatur di
  /// `onConfigure` (di luar transaksi). Seluruh pernyataan memakai
  /// `IF NOT EXISTS`/`DROP ... IF EXISTS`, sehingga aman dijalankan ulang.
  static Future<void> apply(DatabaseExecutor db, String script) async {
    final statements = SqlScript.schemaStatements(script);
    if (statements.isEmpty) {
      throw StateError('Skema SQL kosong atau gagal dipecah: $assetPath');
    }
    for (final statement in statements) {
      await db.execute(statement);
    }
  }
}
