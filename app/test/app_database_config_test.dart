import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('semua PRAGMA di onConfigure memakai rawQuery, bukan execute', () {
    // Regression guard: di Android sqflite_sqlcipher menolak execute() untuk
    // statement PRAGMA ("Queries can be performed using SQLiteDatabase query
    // or rawQuery methods only"). FFI test tidak menangkap perbedaan ini.
    final source = File('lib/core/db/app_database.dart').readAsStringSync();

    for (final pragma in <String>[
      'PRAGMA foreign_keys = ON',
      'PRAGMA journal_mode = WAL',
      'PRAGMA busy_timeout = 5000',
    ]) {
      expect(source, contains("await db.rawQuery('$pragma')"), reason: pragma);
      expect(source, isNot(contains("await db.execute('$pragma')")), reason: pragma);
    }
  });
}
