import 'dart:math';
import 'dart:typed_data';

/// Generator UUID versi 7 (RFC 9562) tanpa paket tambahan.
///
/// 48 bit pertama adalah milidetik Unix, sehingga ID terurut menurut waktu
/// pembuatan. Itu penting untuk outbox: transaksi yang dibuat lebih dulu
/// dikirim lebih dulu, dan document ID Firestore tetap unik.
///
/// [now] dan [random] bisa disuntik di test agar hasilnya deterministik.
String uuid7({DateTime? now, Random? random}) {
  final rng = random ?? Random.secure();
  final millis = (now ?? DateTime.now()).millisecondsSinceEpoch;
  final bytes = Uint8List(16);

  var remaining = millis;
  for (var i = 5; i >= 0; i--) {
    bytes[i] = remaining & 0xff;
    remaining >>= 8;
  }
  for (var i = 6; i < 16; i++) {
    bytes[i] = rng.nextInt(256);
  }

  // Versi 7 di 4 bit atas byte 6; varian RFC 4122 di 2 bit atas byte 8.
  bytes[6] = (bytes[6] & 0x0f) | 0x70;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;

  const hex = '0123456789abcdef';
  final buffer = StringBuffer();
  for (var i = 0; i < 16; i++) {
    if (i == 4 || i == 6 || i == 8 || i == 10) {
      buffer.write('-');
    }
    buffer.write(hex[bytes[i] >> 4]);
    buffer.write(hex[bytes[i] & 0x0f]);
  }
  return buffer.toString();
}

/// Pola UUIDv7 sesuai RFC 9562 (versi 7, varian 8/9/a/b).
final RegExp uuid7Pattern = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
);

bool isUuid7(String value) => uuid7Pattern.hasMatch(value);
