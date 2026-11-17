/// Konfigurasi runtime dari `--dart-define`.
///
/// Tidak ada kredensial di repo (VS0-01). Semua nilai Firebase masuk lewat
/// `--dart-define` atau file `dart_defines/dev.json` yang tidak di-commit.
///
/// Contoh:
///   flutter run \
///     --dart-define=FB_PROJECT_ID=warehouse-dev \
///     --dart-define=FB_API_KEY=... \
///     --dart-define=FB_APP_ID=1:123:android:abc \
///     --dart-define=FB_MESSAGING_SENDER_ID=123 \
///     --dart-define=GOOGLE_SERVER_CLIENT_ID=123-abc.apps.googleusercontent.com
class AppConfig {
  const AppConfig._();

  static const String projectId = String.fromEnvironment('FB_PROJECT_ID');
  static const String apiKey = String.fromEnvironment('FB_API_KEY');
  static const String appId = String.fromEnvironment('FB_APP_ID');
  static const String messagingSenderId =
      String.fromEnvironment('FB_MESSAGING_SENDER_ID');
  static const String storageBucket =
      String.fromEnvironment('FB_STORAGE_BUCKET');

  /// Web OAuth client ID. Wajib di Android agar Google Sign-In
  /// mengembalikan `idToken` (bukan hanya access token).
  static const String googleServerClientId =
      String.fromEnvironment('GOOGLE_SERVER_CLIENT_ID');

  static const String defaultWarehouseId =
      String.fromEnvironment('WAREHOUSE_ID', defaultValue: 'JKT-01');

  static const String appVersion =
      String.fromEnvironment('APP_VERSION', defaultValue: '0.1.0');

  /// `true` bila app harus menunjuk ke Firebase Emulator Suite (VS0-02).
  static const bool useEmulator = bool.fromEnvironment('USE_EMULATOR');

  /// Host emulator dari sudut pandang device.
  /// `10.0.2.2` = loopback host dari Android Emulator; device fisik memakai IP LAN.
  static const String emulatorHost =
      String.fromEnvironment('EMULATOR_HOST', defaultValue: '10.0.2.2');

  static const int authEmulatorPort =
      int.fromEnvironment('AUTH_EMULATOR_PORT', defaultValue: 9099);

  static const int firestoreEmulatorPort =
      int.fromEnvironment('FIRESTORE_EMULATOR_PORT', defaultValue: 8080);

  /// `true` bila semua nilai wajib Firebase sudah diisi.
  ///
  /// `GOOGLE_SERVER_CLIENT_ID` ikut diwajibkan karena tanpa nilai itu Google
  /// Sign-In di Android tidak mengembalikan `idToken`, sehingga login selalu
  /// gagal dengan pesan yang membingungkan.
  static bool get isConfigured =>
      projectId.isNotEmpty &&
      apiKey.isNotEmpty &&
      appId.isNotEmpty &&
      messagingSenderId.isNotEmpty &&
      googleServerClientId.isNotEmpty;

  /// Pesan yang ditampilkan bila konfigurasi belum lengkap.
  static List<String> missingKeys() {
    final missing = <String>[];
    if (projectId.isEmpty) missing.add('FB_PROJECT_ID');
    if (apiKey.isEmpty) missing.add('FB_API_KEY');
    if (appId.isEmpty) missing.add('FB_APP_ID');
    if (messagingSenderId.isEmpty) missing.add('FB_MESSAGING_SENDER_ID');
    if (googleServerClientId.isEmpty) missing.add('GOOGLE_SERVER_CLIENT_ID');
    return missing;
  }
}
