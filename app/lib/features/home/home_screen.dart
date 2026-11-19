import 'package:flutter/material.dart';

import '../../bootstrap/app_services.dart';
import '../../core/auth/auth_models.dart';
import '../scan/scan_screen.dart';
import 'home_shell.dart';

/// Beranda setelah login (VS-3): shell dengan navigasi bawah dan chip sync.
///
/// Logika outbox dan status kini ada di [HomeShell] supaya satu instance
/// dipakai bersama layar Scan, Histori, dan Sinkronisasi.
class HomeScreen extends StatelessWidget {
  const HomeScreen({
    super.key,
    required this.services,
    required this.profile,
    this.scannerBuilder,
    this.outboxInterval = const Duration(seconds: 60),
    this.demoMode = false,
  });

  final AppServices services;
  final UserProfile profile;
  final ScannerBuilder? scannerBuilder;
  final Duration outboxInterval;
  final bool demoMode;

  @override
  Widget build(BuildContext context) {
    return HomeShell(
      services: services,
      profile: profile,
      scannerBuilder: scannerBuilder,
      outboxInterval: outboxInterval,
      demoMode: demoMode,
    );
  }
}
