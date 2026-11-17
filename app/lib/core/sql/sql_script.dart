/// Pemecah skrip SQL menjadi pernyataan tunggal.
///
/// `sqflite` hanya bisa mengeksekusi satu pernyataan per `execute`, sedangkan
/// skema kita satu file SQL (`app/sqlite_schema.sql`) berisi tabel, view, dan
/// trigger `BEGIN ... END` yang punya titik koma di dalamnya.
///
/// Aturan pemecahan:
/// - `;` hanya memotong bila tidak berada di dalam string, komentar, atau blok
///   `BEGIN/CASE ... END`.
/// - Komentar `--` dan `/* */` dibuang (diganti satu spasi agar kata tidak
///   menempel).
/// - `BEGIN`/`CASE` menambah kedalaman, `END` menguranginya. Dengan begitu
///   `CASE ... END` di dalam trigger tidak memotong trigger lebih awal.
///
/// Batasan yang disengaja: skrip ini bukan parser SQL. Fitur seperti
/// `BEGIN TRANSACTION` di dalam file skema tidak didukung (memang tidak dipakai).
class SqlScript {
  const SqlScript._();

  static const String _beginKeyword = 'BEGIN';
  static const String _caseKeyword = 'CASE';
  static const String _endKeyword = 'END';
  static const String _pragmaKeyword = 'PRAGMA';

  /// Memecah [script] menjadi daftar pernyataan tanpa titik koma di ujung.
  static List<String> split(String script) {
    final statements = <String>[];
    final buffer = StringBuffer();

    var depth = 0;
    var i = 0;
    var inSingleQuote = false;
    var inDoubleQuote = false;
    var inLineComment = false;
    var inBlockComment = false;

    while (i < script.length) {
      final ch = script[i];
      final next = i + 1 < script.length ? script[i + 1] : '';

      if (inLineComment) {
        if (ch == '\n') {
          inLineComment = false;
          buffer.write(' ');
        }
        i++;
        continue;
      }

      if (inBlockComment) {
        if (ch == '*' && next == '/') {
          inBlockComment = false;
          buffer.write(' ');
          i += 2;
          continue;
        }
        i++;
        continue;
      }

      if (inSingleQuote) {
        buffer.write(ch);
        if (ch == "'") {
          if (next == "'") {
            buffer.write(next);
            i += 2;
            continue;
          }
          inSingleQuote = false;
        }
        i++;
        continue;
      }

      if (inDoubleQuote) {
        buffer.write(ch);
        if (ch == '"') {
          inDoubleQuote = false;
        }
        i++;
        continue;
      }

      if (ch == '-' && next == '-') {
        inLineComment = true;
        i += 2;
        continue;
      }
      if (ch == '/' && next == '*') {
        inBlockComment = true;
        i += 2;
        continue;
      }
      if (ch == "'") {
        inSingleQuote = true;
        buffer.write(ch);
        i++;
        continue;
      }
      if (ch == '"') {
        inDoubleQuote = true;
        buffer.write(ch);
        i++;
        continue;
      }

      if (_isWordChar(ch.codeUnitAt(0))) {
        var j = i;
        while (j < script.length && _isWordChar(script.codeUnitAt(j))) {
          j++;
        }
        final word = script.substring(i, j);
        final upper = word.toUpperCase();
        if (upper == _beginKeyword || upper == _caseKeyword) {
          depth++;
        } else if (upper == _endKeyword && depth > 0) {
          depth--;
        }
        buffer.write(word);
        i = j;
        continue;
      }

      if (ch == ';' && depth == 0) {
        final statement = buffer.toString().trim();
        if (statement.isNotEmpty) {
          statements.add(statement);
        }
        buffer.clear();
        i++;
        continue;
      }

      buffer.write(ch);
      i++;
    }

    final tail = buffer.toString().trim();
    if (tail.isNotEmpty) {
      statements.add(tail);
    }
    return statements;
  }

  /// Pernyataan yang boleh dieksekusi untuk membangun skema.
  ///
  /// `PRAGMA` dikeluarkan karena diatur di `onConfigure` (di luar transaksi):
  /// `journal_mode` tidak bisa diubah di dalam transaksi yang dipakai `sqflite`
  /// saat membuat database.
  static List<String> schemaStatements(String script) {
    final result = <String>[];
    for (final statement in split(script)) {
      if (leadingKeyword(statement).toUpperCase() != _pragmaKeyword) {
        result.add(statement);
      }
    }
    return result;
  }

  /// Kata pertama pada [statement], melewati spasi di awal.
  static String leadingKeyword(String statement) {
    var i = 0;
    while (i < statement.length && _isWhitespace(statement.codeUnitAt(i))) {
      i++;
    }
    var j = i;
    while (j < statement.length && _isWordChar(statement.codeUnitAt(j))) {
      j++;
    }
    return statement.substring(i, j);
  }

  static bool _isWordChar(int codeUnit) {
    final isDigit = codeUnit >= 0x30 && codeUnit <= 0x39;
    final isUpper = codeUnit >= 0x41 && codeUnit <= 0x5A;
    final isLower = codeUnit >= 0x61 && codeUnit <= 0x7A;
    return isDigit || isUpper || isLower || codeUnit == 0x5F;
  }

  static bool _isWhitespace(int codeUnit) =>
      codeUnit == 0x20 ||
      codeUnit == 0x09 ||
      codeUnit == 0x0A ||
      codeUnit == 0x0D;
}
