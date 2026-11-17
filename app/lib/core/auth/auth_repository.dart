import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

import '../observability/telemetry.dart';
import '../storage/profile_cache.dart';
import 'auth_models.dart';
import 'google_sign_in_adapter.dart';

/// Login Google + resolusi profil + role gate.
///
/// Alur (FR-AUTH-01..05):
/// 1. Google Sign-In -> ID token -> `signInWithCredential`.
/// 2. Baca `users/{uid}`; bila offline, pakai cache SQLite terakhir.
/// 3. Tolak bila dokumen tidak ada, `active=false`, role tidak dikenal, atau
///    belum punya gudang.
class AuthRepository {
  AuthRepository({
    required FirebaseAuth auth,
    required FirebaseFirestore firestore,
    required GoogleSignInAdapter googleSignIn,
    required ProfileCache profileCache,
    required Telemetry telemetry,
  })  : _auth = auth,
        _firestore = firestore,
        _googleSignIn = googleSignIn,
        _cache = profileCache,
        _telemetry = telemetry {
    _subscription = _auth.authStateChanges().listen(
      _handleUser,
      onError: (Object error, StackTrace stackTrace) {
        _emitError(error, stackTrace);
      },
    );
  }

  static const Duration _profileTimeout = Duration(seconds: 8);

  final FirebaseAuth _auth;
  final FirebaseFirestore _firestore;
  final GoogleSignInAdapter _googleSignIn;
  final ProfileCache _cache;
  final Telemetry _telemetry;

  final StreamController<AuthState> _controller =
      StreamController<AuthState>.broadcast();
  StreamSubscription<User?>? _subscription;
  AuthState _currentState = const AuthChecking();
  int _generation = 0;

  Stream<AuthState> get stateChanges => _controller.stream;

  /// State terakhir, dipakai sebagai `initialData` agar tidak ada layar kosong
  /// saat widget baru berlangganan.
  AuthState get currentState => _currentState;

  Future<void> signInWithGoogle() async {
    try {
      final token = await _googleSignIn.idToken();
      if (token == null) {
        throw const AuthException(
          'id_token_missing',
          'Google tidak mengembalikan ID token. '
          'Pastikan GOOGLE_SERVER_CLIENT_ID (OAuth web) sudah benar.',
        );
      }

      final credential = GoogleAuthProvider.credential(idToken: token);
      final result = await _auth.signInWithCredential(credential);
      final user = result.user;
      if (user == null) {
        throw const AuthException(
          'sign_in_failed',
          'Login gagal: sesi Firebase tidak terbentuk.',
        );
      }

      await _telemetry.setUser(user.uid);
      await _telemetry.logEvent(TelemetryEvents.loginSuccess);
    } on SignInCancelled {
      await _telemetry.logEvent(TelemetryEvents.loginCancelled);
      rethrow;
    } on AuthException {
      rethrow;
    } on FirebaseAuthException catch (error) {
      await _telemetry.logEvent(
        TelemetryEvents.loginFailed,
        parameters: {'code': error.code},
      );
      throw AuthException(error.code, _messageFor(error));
    } catch (_) {
      await _telemetry.logEvent(TelemetryEvents.loginFailed);
      throw AuthException(
        'sign_in_failed',
        'Login gagal. Periksa jaringan lalu coba lagi.',
      );
    }
  }

  Future<void> signOut() async {
    await _googleSignIn.signOut();
    await _auth.signOut();
    await _cache.clear();
    await _telemetry.setUser(null);
  }

  /// Memuat ulang profil untuk pengguna yang sedang login (tombol "Coba lagi"
  /// pada SCR-02).
  Future<void> refresh() async {
    await _handleUser(_auth.currentUser);
  }

  Future<void> dispose() async {
    await _subscription?.cancel();
    await _controller.close();
  }

  Future<void> _handleUser(User? user) async {
    final generation = ++_generation;
    try {
      final state = await _resolve(user);
      if (generation == _generation) {
        _emit(state);
      }
    } catch (error, stackTrace) {
      if (generation != _generation) {
        return;
      }
      await _telemetry.recordError(
        error,
        stackTrace,
        reason: 'auth_resolve_failed',
      );
      _emit(const AuthDenied(reason: DenialReason.profileUnavailable));
    }
  }

  Future<AuthState> _resolve(User? user) async {
    if (user == null) {
      return const AuthSignedOut();
    }

    UserProfile? profile;
    try {
      profile = await _fetchProfile(user.uid);
    } on FormatException catch (error) {
      return AuthDenied(
        reason: DenialReason.unknownRole,
        email: user.email ?? '',
        detail: error.message,
      );
    } on Exception {
      // Offline / Firestore error: pakai cache terakhir bila ada.
      profile = await _cache.read(user.uid);
      if (profile == null) {
        return AuthDenied(
          reason: DenialReason.profileUnavailable,
          email: user.email ?? '',
        );
      }
    }

    if (profile == null) {
      return AuthDenied(
        reason: DenialReason.profileMissing,
        email: user.email ?? '',
      );
    }

    final normalized = profile.copyWith(
      name: profile.name.isEmpty ? (user.displayName ?? '') : null,
      email: profile.email.isEmpty ? (user.email ?? '') : null,
    );

    if (!normalized.active) {
      await _cache.save(
        normalized,
        fetchedAt: DateTime.now().millisecondsSinceEpoch,
      );
      return AuthDenied(
        reason: DenialReason.inactive,
        email: normalized.email,
      );
    }

    if (normalized.warehouseIds.isEmpty) {
      return AuthDenied(
        reason: DenialReason.warehouseMissing,
        email: normalized.email,
      );
    }

    await _cache.save(
      normalized,
      fetchedAt: DateTime.now().millisecondsSinceEpoch,
    );
    await _telemetry.setUser(normalized.uid);
    return AuthReady(normalized);
  }

  Future<UserProfile?> _fetchProfile(String uid) async {
    final snapshot = await _firestore
        .collection('users')
        .doc(uid)
        .get()
        .timeout(_profileTimeout);
    if (!snapshot.exists) {
      return null;
    }
    final data = snapshot.data();
    if (data == null) {
      return null;
    }
    return UserProfile.fromFirestore(uid, data);
  }

  void _emit(AuthState state) {
    _currentState = state;
    if (!_controller.isClosed) {
      _controller.add(state);
    }
  }

  void _emitError(Object error, StackTrace stackTrace) {
    if (!_controller.isClosed) {
      _controller.addError(error, stackTrace);
    }
  }

  static String _messageFor(FirebaseAuthException error) {
    switch (error.code) {
      case 'network-request-failed':
        return 'Tidak ada koneksi. Periksa jaringan lalu coba lagi.';
      case 'user-disabled':
        return 'Akun ini dinonaktifkan di Firebase Auth.';
      case 'operation-not-allowed':
        return 'Metode login Google belum diaktifkan di Firebase.';
      case 'account-exists-with-different-credential':
        return 'Email ini sudah terdaftar dengan metode login lain.';
      default:
        return 'Login gagal (${error.code}). Coba lagi atau hubungi Admin.';
    }
  }
}
