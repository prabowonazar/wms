/// Aturan percobaan ulang pengiriman outbox (FR-SYN-02).
///
/// Satu "siklus" berhenti setelah [maxSyncAttempts] percobaan. Setelah itu
/// baris tetap `failed` dengan alasan tersimpan, tidak diambil otomatis lagi,
/// dan hanya bisa dicoba ulang lewat aksi manual di layar Sinkronisasi.
library;

/// Batas percobaan otomatis sebelum baris dianggap perlu tindakan.
const int maxSyncAttempts = 5;

/// Jeda dasar sebelum percobaan berikutnya (backoff eksponensial).
const Duration syncRetryBaseDelay = Duration(seconds: 30);

/// Jeda maksimum agar backoff tidak menunda berhari-hari.
const Duration syncRetryMaxDelay = Duration(minutes: 8);

/// Jeda untuk percobaan ke-[attempt] (1 = setelah kegagalan pertama).
///
/// 30 s, 60 s, 120 s, 240 s, lalu ditahan di 8 menit. Bila [attempt] sudah
/// mencapai [maxAttempts], hasilnya `null`: tidak ada percobaan otomatis.
Duration? retryDelayFor(
  int attempt, {
  Duration base = syncRetryBaseDelay,
  int maxAttempts = maxSyncAttempts,
}) {
  if (attempt <= 0 || attempt >= maxAttempts) {
    return null;
  }
  final seconds = base.inSeconds * (1 << (attempt - 1));
  if (seconds <= 0) {
    return Duration.zero;
  }
  final capped = seconds.clamp(
    base.inSeconds,
    syncRetryMaxDelay.inSeconds,
  );
  return Duration(seconds: capped);
}

/// Pesan kegagalan yang bisa dibaca operator.
///
/// Exception Firestore membawa kode pada teksnya; memeriksa teks membuat
/// lapisan ini tidak bergantung pada paket `cloud_firestore` dan tetap bisa
/// diuji tanpa Firebase.
String describeSyncError(Object error) {
  final raw = error.toString();
  final lower = raw.toLowerCase();
  if (lower.contains('unavailable') ||
      lower.contains('network-request-failed') ||
      lower.contains('socketexception') ||
      lower.contains('failed host lookup') ||
      lower.contains('tidak ada jaringan')) {
    return 'Tidak ada koneksi. Data tetap aman di perangkat.';
  }
  if (lower.contains('permission-denied')) {
    return 'Server menolak transaksi ini (izin). Hubungi Admin.';
  }
  if (lower.contains('deadline-exceeded')) {
    return 'Koneksi terlalu lambat. Coba lagi saat sinyal membaik.';
  }
  if (lower.contains('resource-exhausted')) {
    return 'Server sedang sibuk. Coba lagi beberapa saat.';
  }
  if (lower.contains('failed-precondition')) {
    return 'Server belum siap menerima data. Coba lagi nanti.';
  }
  return 'Gagal mengirim. Coba lagi saat jaringan tersedia.';
}
