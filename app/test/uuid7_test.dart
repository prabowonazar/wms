import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:warehouse_mobile/core/sync/uuid7.dart';

void main() {
  test('uuid7 memiliki format, versi 7, dan varian RFC', () {
    final value = uuid7(now: DateTime.utc(2026, 11, 18, 9, 30));

    expect(isUuid7(value), isTrue, reason: value);
    expect(value.length, 36);
    expect(value[14], '7');
    expect('89ab'.contains(value[19]), isTrue, reason: value);
  });

  test('48 bit awal mengikuti waktu pembuatan sehingga terurut', () {
    final early = uuid7(
      now: DateTime.utc(2026, 11, 18, 9, 30),
      random: Random(1),
    );
    final late = uuid7(
      now: DateTime.utc(2026, 11, 18, 9, 31),
      random: Random(1),
    );

    expect(early.substring(0, 13).compareTo(late.substring(0, 13)) < 0, isTrue);
  });

  test('dua ID pada milidetik yang sama tetap berbeda', () {
    final now = DateTime.utc(2026, 11, 18, 9, 30);
    final first = uuid7(now: now, random: Random(7));
    final second = uuid7(now: now, random: Random(8));

    expect(first, isNot(second));
  });

  test('generator deterministik bila waktu dan random disuntik', () {
    final now = DateTime.utc(2026, 11, 18, 9, 30);

    expect(
      uuid7(now: now, random: Random(42)),
      uuid7(now: now, random: Random(42)),
    );
  });

  test('isUuid7 menolak UUID versi lain dan string acak', () {
    expect(isUuid7('00000000-0000-4000-8000-000000000000'), isFalse);
    expect(isUuid7('bukan-uuid'), isFalse);
    expect(isUuid7(''), isFalse);
  });
}
