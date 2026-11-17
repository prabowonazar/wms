import 'package:flutter/material.dart';

import 'bootstrap/app_services.dart';
import 'core/auth/auth_models.dart';
import 'features/auth/denied_screen.dart';
import 'features/auth/login_screen.dart';
import 'features/bootstrap/bootstrap_failure_screen.dart';
import 'features/bootstrap/config_missing_screen.dart';
import 'features/home/home_screen.dart';
import 'features/splash/splash_screen.dart';

ThemeData buildAppTheme() {
  final scheme = ColorScheme.fromSeed(seedColor: const Color(0xFF00695C));
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    visualDensity: VisualDensity.standard,
  );
}

class WarehouseApp extends StatelessWidget {
  const WarehouseApp({super.key, required this.services});

  final AppServices services;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Gudang',
      debugShowCheckedModeBanner: false,
      theme: buildAppTheme(),
      home: _AuthGate(services: services),
    );
  }
}

class ConfigMissingApp extends StatelessWidget {
  const ConfigMissingApp({super.key, required this.missingKeys});

  final List<String> missingKeys;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Gudang',
      debugShowCheckedModeBanner: false,
      theme: buildAppTheme(),
      home: ConfigMissingScreen(missingKeys: missingKeys),
    );
  }
}

class BootstrapFailureApp extends StatelessWidget {
  const BootstrapFailureApp({super.key, required this.error});

  final Object error;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Gudang',
      debugShowCheckedModeBanner: false,
      theme: buildAppTheme(),
      home: BootstrapFailureScreen(error: error),
    );
  }
}

class _AuthGate extends StatefulWidget {
  const _AuthGate({required this.services});

  final AppServices services;

  @override
  State<_AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<_AuthGate> {
  late final Stream<AuthState> _states = widget.services.auth.stateChanges;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<AuthState>(
      stream: _states,
      initialData: widget.services.auth.currentState,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return _AuthErrorScreen(
            onRetry: widget.services.auth.refresh,
          );
        }

        final state = snapshot.data ?? const AuthChecking();
        return switch (state) {
          AuthChecking() => const SplashScreen(),
          AuthSignedOut() => LoginScreen(
              auth: widget.services.auth,
              telemetry: widget.services.telemetry,
            ),
          AuthDenied(:final reason, :final email, :final detail) => DeniedScreen(
              auth: widget.services.auth,
              reason: reason,
              email: email,
              detail: detail,
            ),
          AuthReady(:final profile) => HomeScreen(
              services: widget.services,
              profile: profile,
            ),
        };
      },
    );
  }
}

class _AuthErrorScreen extends StatelessWidget {
  const _AuthErrorScreen({required this.onRetry});

  final Future<void> Function() onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.cloud_off_outlined,
                size: 56,
                color: theme.colorScheme.error,
              ),
              const SizedBox(height: 16),
              Text(
                'Gagal memeriksa sesi',
                style: theme.textTheme.titleLarge,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              Text(
                'Periksa jaringan, lalu coba lagi.',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium,
              ),
              const SizedBox(height: 24),
              FilledButton(
                onPressed: onRetry,
                child: const Text('Coba lagi'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
