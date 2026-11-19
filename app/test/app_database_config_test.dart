import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('PRAGMA journal_mode memakai rawQuery, bukan execute', () {
    // Regression guard: di Android sqflite menolak execute() untuk statement
    // yang mengembalikan baris. FFI test tidak menangkap perbedaan ini.
    final source = File('lib/core/db/app_database.dart').readAsStringSync();

    expect(
      source,
      contains("await db.rawQuery('PRAGMA journal_mode = WAL')"),
    );
    expect(
      source,
      isNot(contains("await db.execute('PRAGMA journal_mode = WAL')")),
    );
  });
}
