import 'package:google_sign_in/google_sign_in.dart';

import '../config/app_config.dart';

class SignInCancelled implements Exception {
  const SignInCancelled({this.detail});

  /// Kode GoogleSignInException asli untuk diagnostics (mis. `canceled: ...`).
  final String? detail;

  @override
  String toString() => 'SignInCancelled(${detail ?? 'no detail'})';
}

/// Pembungkus tipis Google Sign-In v7.
///
/// Sengaja kecil dan terisolasi: API v7 berbeda dari v6 (`instance`,
/// `initialize`, `authenticate`, `authentication.idToken`). Bila API berubah
/// lagi, hanya file ini yang perlu diperbaiki.
class GoogleSignInAdapter {
  GoogleSignInAdapter({GoogleSignIn? googleSignIn})
      : _googleSignIn = googleSignIn ?? GoogleSignIn.instance;

  final GoogleSignIn _googleSignIn;
  bool _initialized = false;

  Future<void> _ensureInitialized() async {
    if (_initialized) {
      return;
    }
    const serverClientId = AppConfig.googleServerClientId;
    await _googleSignIn.initialize(
      serverClientId: serverClientId.isEmpty ? null : serverClientId,
    );
    _initialized = true;
  }

  /// Mengembalikan ID token, atau `null` bila token kosong.
  Future<String?> idToken() async {
    await _ensureInitialized();
    if (!_googleSignIn.supportsAuthenticate()) {
      throw StateError(
        'Google Sign-In interaktif tidak didukung di platform ini.',
      );
    }

    try {
      final account = await _googleSignIn.authenticate();
      final token = account.authentication.idToken;
      if (token == null || token.isEmpty) {
        return null;
      }
      return token;
    } on GoogleSignInException catch (error) {
      if (error.code == GoogleSignInExceptionCode.canceled) {
        throw SignInCancelled(
          detail: '${error.code.name}: ${error.toString()}',
        );
      }
      rethrow;
    }
  }

  Future<void> signOut() async {
    if (!_initialized) {
      return;
    }
    await _googleSignIn.signOut();
  }
}
