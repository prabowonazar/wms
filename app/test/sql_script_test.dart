import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:warehouse_mobile/core/sql/sql_script.dart';

void main() {
  group('SqlScript.split', () {
    test('memecah dua pernyataan sederhana', () {
      final statements = SqlScript.split('SELECT 1; SELECT 2;');
      expect(statements, ['SELECT 1', 'SELECT 2']);
    });

    test('titik koma di dalam string tidak memotong', () {
      final statements = SqlScript.split("INSERT INTO t VALUES ('a;b');");
      expect(statements, ["INSERT INTO t VALUES ('a;b')"]);
    });

    test('kutip ganda dan kutip tunggal ganda ditangani', () {
      final statements = SqlScript.split(
        'SELECT "x;y", \'it\'\'s; fine\';',
      );
      expect(statements, ['SELECT "x;y", \'it\'\'s; fine\'']);
    });

    test('komentar baris dan blok dibuang', () {
      final statements = SqlScript.split(
        '-- komentar; dengan titik koma\nSELECT 1; /* blok; */ SELECT 2;',
      );
      expect(statements, ['SELECT 1', 'SELECT 2']);
    });

    test('BEGIN ... END pada trigger tidak dipotong di tengah', () {
      const trigger = '''
CREATE TRIGGER trg BEFORE UPDATE ON t
FOR EACH ROW
BEGIN
  SELECT RAISE(ABORT, 'stop; now');
END;
''';
      final statements = SqlScript.split(trigger);
      expect(statements, hasLength(1));
      expect(statements.single, contains('END'));
    });

    test('CASE ... END di dalam view tetap satu pernyataan', () {
      const view = '''
CREATE VIEW v AS
SELECT SUM(CASE WHEN type = 'in' THEN qty ELSE 0 END) AS incoming
FROM t;
''';
      expect(SqlScript.split(view), hasLength(1));
    });

    test('PRAGMA difilter dari schemaStatements', () {
      final statements = SqlScript.schemaStatements(
        'PRAGMA foreign_keys = ON; CREATE TABLE t (id INTEGER);',
      );
      expect(statements, ['CREATE TABLE t (id INTEGER)']);
    });

    test('leadingKeyword mengabaikan spasi awal', () {
      expect(SqlScript.leadingKeyword('   CREATE TABLE t'), 'CREATE');
      expect(SqlScript.leadingKeyword('PRAGMA x = 1'), 'PRAGMA');
    });
  });

  group('skema kanonik', () {
    late String script;

    setUpAll(() {
      final file = File('sqlite_schema.sql');
      if (!file.existsSync()) {
        fail(
          'sqlite_schema.sql tidak ditemukan. Jalankan test dari folder '
          'app/ (flutter test).',
        );
      }
      script = file.readAsStringSync();
    });

    test('semua pernyataan skema terbaca dan PRAGMA dibuang', () {
      final statements = SqlScript.schemaStatements(script);
      expect(statements.length, greaterThan(30));
      expect(
        statements.where(
          (statement) => SqlScript.leadingKeyword(statement) == 'PRAGMA',
        ),
        isEmpty,
      );
    });

    test('jumlah tabel, view, dan trigger sesuai skema', () {
      final statements = SqlScript.schemaStatements(script);
      int count(String prefix) => statements
          .where((statement) => statement.toUpperCase().startsWith(prefix))
          .length;

      expect(count('CREATE TABLE'), 10);
      expect(count('CREATE VIEW'), 3);
      expect(count('CREATE TRIGGER'), 5);
    });

    test('tidak ada pernyataan kosong', () {
      for (final statement in SqlScript.schemaStatements(script)) {
        expect(statement.trim(), isNotEmpty);
      }
    });
  });
}
