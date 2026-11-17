import 'package:flutter/material.dart';

/// Layar yang muncul bila `--dart-define` Firebase belum lengkap.
///
/// Sengaja tidak memakai Firebase: aplikasi harus tetap bisa menjelaskan
/// masalah konfigurasi, bukan gagal tanpa pesan.
class ConfigMissingScreen extends StatelessWidget {
  const ConfigMissingScreen({super.key, required this.missingKeys});

  final List<String> missingKeys;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 520),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    Icons.settings_applications_outlined,
                    size: 56,
                    color: theme.colorScheme.error,
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'Konfigurasi Firebase belum lengkap',
                    style: theme.textTheme.headlineSmall,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Aplikasi tidak bisa login tanpa nilai berikut. '
                    'Isi lewat --dart-define atau --dart-define-from-file.',
                    style: theme.textTheme.bodyMedium,
                  ),
                  const SizedBox(height: 16),
                  for (final key in missingKeys)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: Text('- $key', style: theme.textTheme.bodyLarge),
                    ),
                  const SizedBox(height: 24),
                  Text(
                    'Contoh:',
                    style: theme.textTheme.titleSmall,
                  ),
                  const SizedBox(height: 8),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: const SelectableText(
                      'flutter run '
                      '--dart-define=FB_PROJECT_ID=warehouse-dev '
                      '--dart-define=FB_API_KEY=... '
                      '--dart-define=FB_APP_ID=... '
                      '--dart-define=FB_MESSAGING_SENDER_ID=... '
                      '--dart-define=GOOGLE_SERVER_CLIENT_ID=...',
                      style: TextStyle(fontFamily: 'monospace', fontSize: 12),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'Detail lengkap: docs/runbook-vs0.md',
                    style: theme.textTheme.bodySmall,
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
