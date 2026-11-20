import 'dart:async';

import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/config/app_config.dart';
import '../../core/observability/telemetry.dart';
import '../../core/auth/auth_models.dart';
import '../../core/auth/auth_repository.dart';
import '../../core/auth/google_sign_in_adapter.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({
    super.key,
    required this.auth,
    required this.telemetry,
    this.message,
  });

  final AuthRepository auth;
  final Telemetry telemetry;

  /// Pesan sesi berakhir (offline >7 hari) dari AuthGate.
  final String? message;

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final TextEditingController _email = TextEditingController();
  final TextEditingController _password = TextEditingController();
  bool _obscure = true;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _signInWithEmail() async {
    final email = _email.text.trim();
    final password = _password.text;
    if (email.isEmpty || password.isEmpty) {
      setState(() => _error = 'Isi email dan kata sandi terlebih dahulu.');
      return;
    }
    if (!email.contains('@')) {
      setState(() => _error = 'Format email tidak valid.');
      return;
    }

    setState(() {
      _busy = true;
      _error = null;
    });

    try {
      await widget.auth.signInWithEmailPassword(
        email: email,
        password: password,
      );
      // AuthGate akan berpindah layar lewat stream authStateChanges.
    } on AuthException catch (error) {
      if (mounted) {
        setState(() => _error = error.message);
      }
    } catch (error, stackTrace) {
      await widget.telemetry.recordError(
        error,
        stackTrace,
        reason: 'login_password_unexpected',
      );
      if (mounted) {
        setState(
          () => _error = kDebugMode
              ? 'Login gagal: $error'
              : 'Login gagal. Periksa jaringan lalu coba lagi.',
        );
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _signIn() async {
    setState(() {
      _busy = true;
      _error = null;
    });

    try {
      await widget.auth.signInWithGoogle();
      // AuthGate akan berpindah layar lewat stream authStateChanges.
    } on SignInCancelled catch (error) {
      // Jangan diam: pengguna perlu tahu bahwa akun tidak dikembalikan Google.
      if (mounted) {
        setState(
          () => _error = kDebugMode
              ? 'Google Sign-In dibatalkan / akun tidak dikembalikan. '
                  'Detail: ${error.detail ?? 'tidak ada'}'
              : 'Login Google dibatalkan. Coba lagi.',
        );
      }
    } on AuthException catch (error) {
      if (mounted) {
        setState(() => _error = error.message);
      }
    } catch (error, stackTrace) {
      await widget.telemetry.recordError(
        error,
        stackTrace,
        reason: 'login_unexpected',
      );
      if (mounted) {
        setState(
          () => _error = kDebugMode
              ? 'Login gagal: $error'
              : 'Login gagal. Periksa jaringan lalu coba lagi.',
        );
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Icon(
                    Icons.inventory_2_outlined,
                    size: 72,
                    color: theme.colorScheme.primary,
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'Gudang',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.headlineMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Catat barang masuk dan keluar, tetap bisa dipakai '
                    'saat jaringan bermasalah.',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyMedium,
                  ),
                  const SizedBox(height: 32),
                  if (AppConfig.useEmulator)
                    const Padding(
                      padding: EdgeInsets.only(bottom: 12),
                      child: Chip(
                        avatar: Icon(Icons.science_outlined, size: 18),
                        label: Text(
                          'Mode emulator - ${AppConfig.emulatorHost}',
                        ),
                      ),
                    ),
                  if (widget.message != null) ...[
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: theme.colorScheme.primaryContainer,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Row(
                        children: [
                          const Icon(Icons.lock_clock),
                          const SizedBox(width: 8),
                          Expanded(child: Text(widget.message!)),
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),
                  ],
                  TextField(
                    controller: _email,
                    enabled: !_busy,
                    keyboardType: TextInputType.emailAddress,
                    autocorrect: false,
                    textInputAction: TextInputAction.next,
                    decoration: const InputDecoration(
                      labelText: 'Email',
                      hintText: 'nama@perusahaan.com',
                      prefixIcon: Icon(Icons.alternate_email),
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _password,
                    enabled: !_busy,
                    obscureText: _obscure,
                    textInputAction: TextInputAction.done,
                    onSubmitted: (_) {
                      if (!_busy) {
                        unawaited(_signInWithEmail());
                      }
                    },
                    decoration: InputDecoration(
                      labelText: 'Kata sandi',
                      prefixIcon: const Icon(Icons.lock_outline),
                      border: const OutlineInputBorder(),
                      suffixIcon: IconButton(
                        tooltip: _obscure ? 'Tampilkan' : 'Sembunyikan',
                        icon: Icon(
                          _obscure
                              ? Icons.visibility_outlined
                              : Icons.visibility_off_outlined,
                        ),
                        onPressed: () => setState(() => _obscure = !_obscure),
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  FilledButton.icon(
                    onPressed: _busy ? null : _signInWithEmail,
                    icon: _busy
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.login),
                    label: Text(_busy ? 'Menghubungkan...' : 'Masuk'),
                    style: FilledButton.styleFrom(
                      minimumSize: const Size.fromHeight(52),
                    ),
                  ),
                  const SizedBox(height: 24),
                  Row(
                    children: [
                      const Expanded(child: Divider()),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        child: Text('atau', style: theme.textTheme.labelMedium),
                      ),
                      const Expanded(child: Divider()),
                    ],
                  ),
                  const SizedBox(height: 24),
                  OutlinedButton.icon(
                    onPressed: _busy ? null : _signIn,
                    icon: const Icon(Icons.account_circle_outlined),
                    label: const Text('Masuk dengan Google'),
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size.fromHeight(52),
                    ),
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: 16),
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: theme.colorScheme.errorContainer,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(
                            Icons.error_outline,
                            color: theme.colorScheme.onErrorContainer,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              _error!,
                              style: TextStyle(
                                color: theme.colorScheme.onErrorContainer,
                              ),
                            ),
                          ),
                          IconButton(
                            tooltip: 'Salin pesan error',
                            icon: const Icon(Icons.copy_all_outlined, size: 20),
                            color: theme.colorScheme.onErrorContainer,
                            onPressed: () {
                              Clipboard.setData(
                                ClipboardData(text: _error!),
                              );
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                  content: Text('Pesan error disalin.'),
                                ),
                              );
                            },
                          ),
                        ],
                      ),
                    ),
                  ],
                  const SizedBox(height: 24),
                  Text(
                    'Gunakan email & kata sandi yang didaftarkan Admin, atau '
                    'akun Google yang sudah terdaftar. Belum punya akses? '
                    'Hubungi Admin gudang.',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodySmall,
                  ),
                  const SizedBox(height: 32),
                  if (kDebugMode)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 16),
                      child: Text(
                        'Debug · project: ${AppConfig.projectId} · '
                        'oauth: ${_oauthHint()} · '
                        'demo: ${AppConfig.demoMode}',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.labelSmall,
                      ),
                    ),
                  Text(
                    'Versi ${AppConfig.appVersion}',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.labelSmall,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Awalan Client ID OAuth untuk memastikan nilainya berasal dari project
/// Firebase yang sama (prefix = nomor project, mis. `2232431696-...`).
String _oauthHint() {
  const clientId = AppConfig.googleServerClientId;
  if (clientId.isEmpty) {
    return 'kosong';
  }
  return '${clientId.substring(0, clientId.length <= 12 ? clientId.length : 12)}...';
}
