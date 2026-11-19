import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Ditampilkan bila bootstrap (Firebase/DB) gagal total.
///
/// Detail error sengaja bisa dibaca dan disalin teknisi. Pattern error belum
/// tentu cukup: `SqfliteDatabaseException` bisa berarti kunci DB berubah,
/// file rusak, atau statement skema gagal - pesan lengkapnya yang menentukan.
class BootstrapFailureScreen extends StatelessWidget {
  const BootstrapFailureScreen({super.key, required this.error});

  final Object error;

  String get detail => error.toString();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
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
                  'bisa hilang. Salin detail di bawah lalu hubungi Admin.',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium,
                ),
                const SizedBox(height: 16),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.errorContainer,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: SelectableText(
                    detail,
                    key: const Key('bootstrap-error-detail'),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onErrorContainer,
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  onPressed: () async {
                    await Clipboard.setData(ClipboardData(text: detail));
                    if (!context.mounted) {
                      return;
                    }
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('Detail error disalin.'),
                      ),
                    );
                  },
                  icon: const Icon(Icons.copy),
                  label: const Text('Salin detail'),
                ),
                const SizedBox(height: 24),
                Text(
                  'Tutup paksa lalu buka kembali aplikasi. Bila tetap gagal, '
                  'kirim detail ini ke tim teknis.',
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
