import 'dart:async';
import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/material.dart';

import 'app.dart';
import 'bootstrap/bootstrap.dart';
import 'core/config/app_config.dart';
import 'core/demo/demo_data.dart';
import 'core/observability/telemetry.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  const telemetry = FirebaseTelemetry();

  FlutterError.onError = (details) {
    FlutterError.presentError(details);
    unawaited(
      telemetry.recordError(
        details.exception,
        details.stack,
        reason: 'flutter_error',
        fatal: true,
      ),
    );
  };

  PlatformDispatcher.instance.onError = (error, stackTrace) {
    unawaited(
      telemetry.recordError(
        error,
        stackTrace,
        reason: 'platform_error',
        fatal: true,
      ),
    );
    return true;
  };

  if (!AppConfig.isConfigured) {
    runApp(ConfigMissingApp(missingKeys: AppConfig.missingKeys()));
    return;
  }

  try {
    final services = await bootstrap(telemetry: telemetry);
    if (!AppConfig.demoMode) {
      try {
        await services.auth.initializeGoogleSignIn();
      } catch (error, stackTrace) {
        await telemetry.recordError(
          error,
          stackTrace,
          reason: 'google_sign_in_init_failed',
        );
      }
    }

    if (AppConfig.demoMode) {
      await seedDemoData(services.database);
      runApp(
        WarehouseApp(services: services, demoProfile: demoProfile),
      );
      return;
    }
    runApp(WarehouseApp(services: services));
  } catch (error, stackTrace) {
    await telemetry.recordError(
      error,
      stackTrace,
      reason: 'bootstrap_failed',
      fatal: true,
    );
    runApp(BootstrapFailureApp(error: error));
  }
}
