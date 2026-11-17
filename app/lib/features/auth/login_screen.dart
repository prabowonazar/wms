import 'package:flutter/material.dart';

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
  });

  final AuthRepository auth;
  final Telemetry telemetry;

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  bool _busy = false;
  String? _error;

  Future<void> _signIn() async {
    setState(() {
      _busy = true;
      _error = null;
    });

    try {
      await widget.auth.signInWithGoogle();
      // AuthGate akan berpindah layar lewat stream authStateChanges.
    } on SignInCancelled {
      // Pengguna menutup dialog Google: bukan error.
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
          () => _error = 'Login gagal. Periksa jaringan lalu coba lagi.',
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
                  FilledButton.icon(
                    onPressed: _busy ? null : _signIn,
                    icon: _busy
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.login),
                    label: Text(
                      _busy ? 'Menghubungkan...' : 'Masuk dengan Google',
                    ),
                    style: FilledButton.styleFrom(
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
                        ],
                      ),
                    ),
                  ],
                  const SizedBox(height: 24),
                  Text(
                    'Gunakan akun Google yang sudah didaftarkan Admin. '
                    'Belum punya akses? Hubungi Admin gudang.',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodySmall,
                  ),
                  const SizedBox(height: 32),
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
