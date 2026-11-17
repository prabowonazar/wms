import 'package:flutter/material.dart';

/// Ditampilkan bila bootstrap (Firebase/DB) gagal total.
///
/// Jangan menampilkan stack trace ke operator; detail sudah dikirim ke
/// Crashlytics dengan alasan `bootstrap_failed`.
class BootstrapFailureScreen extends StatelessWidget {
  const BootstrapFailureScreen({super.key, required this.error});

  final Object error;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.error_outline,
                  size: 56,
                  color: theme.colorScheme.error,
                ),
                const SizedBox(height: 16),
                Text(
                  'Aplikasi gagal dimulai',
                  style: theme.textTheme.headlineSmall,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 8),
                Text(
                  'Jangan hapus aplikasi: data transaksi yang belum terkirim '
                  'bisa hilang. Catat kode di bawah lalu hubungi Admin.',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium,
                ),
                const SizedBox(height: 16),
                SelectableText(
                  error.runtimeType.toString(),
                  style: theme.textTheme.labelLarge,
                ),
                const SizedBox(height: 24),
                Text(
                  'Tutup paksa lalu buka kembali aplikasi. Bila tetap gagal, '
                  'kirim laporan ke tim teknis.',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
