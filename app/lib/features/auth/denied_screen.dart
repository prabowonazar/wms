import 'package:flutter/material.dart';

import '../../core/auth/auth_models.dart';
import '../../core/auth/auth_repository.dart';

/// SCR-02: akun ditolak (FR-AUTH-05).
class DeniedScreen extends StatefulWidget {
  const DeniedScreen({
    super.key,
    required this.auth,
    required this.reason,
    required this.email,
    required this.detail,
  });

  final AuthRepository auth;
  final DenialReason reason;
  final String email;
  final String detail;

  @override
  State<DeniedScreen> createState() => _DeniedScreenState();
}

class _DeniedScreenState extends State<DeniedScreen> {
  bool _busy = false;

  Future<void> _retry() async {
    setState(() => _busy = true);
    try {
      await widget.auth.refresh();
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _signOut() async {
    setState(() => _busy = true);
    try {
      await widget.auth.signOut();
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
      appBar: AppBar(title: const Text('Akun tidak bisa dipakai')),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Icon(
                  Icons.block_outlined,
                  size: 64,
                  color: theme.colorScheme.error,
                ),
                const SizedBox(height: 16),
                Text(
                  'Akses ditolak',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.headlineSmall,
                ),
                const SizedBox(height: 8),
                Text(
                  widget.reason.message,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium,
                ),
                if (widget.email.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  Text(
                    'Akun: ${widget.email}',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodySmall,
                  ),
                ],
                const SizedBox(height: 8),
                Text(
                  'Kode: ${widget.reason.code}',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.labelSmall,
                ),
                if (widget.detail.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text(
                    widget.detail,
                    textAlign: TextAlign.center,
                    style: theme.textTheme.labelSmall,
                  ),
                ],
                const SizedBox(height: 24),
                FilledButton(
                  onPressed: _busy ? null : _retry,
                  style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(48),
                  ),
                  child: Text(_busy ? 'Memeriksa...' : 'Coba lagi'),
                ),
                const SizedBox(height: 8),
                OutlinedButton(
                  onPressed: _busy ? null : _signOut,
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size.fromHeight(48),
                  ),
                  child: const Text('Keluar dan pakai akun lain'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
