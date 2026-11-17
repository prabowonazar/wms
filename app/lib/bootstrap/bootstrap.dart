import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_sqlcipher/sqflite.dart';

import '../core/auth/auth_repository.dart';
import '../core/auth/google_sign_in_adapter.dart';
import '../core/config/app_config.dart';
import '../core/db/app_database.dart';
import '../core/observability/telemetry.dart';
import '../core/security/db_key_store.dart';
import '../core/storage/profile_cache.dart';
import 'app_services.dart';

/// Urutan bootstrap yang disengaja:
/// Firebase -> Crashlytics -> kunci DB -> buka DB -> auth.
///
/// Bila DB gagal dibuka, aplikasi berhenti dengan pesan jelas. Membuka DB
/// dengan kunci baru akan menghapus outbox secara diam-diam, dan itu dilarang.
Future<AppServices> bootstrap({Telemetry telemetry = const FirebaseTelemetry()}) async {
  if (Firebase.apps.isEmpty) {
    await Firebase.initializeApp(options: _firebaseOptions());
  }

  if (AppConfig.useEmulator) {
    await FirebaseAuth.instance.useAuthEmulator(
      AppConfig.emulatorHost,
      AppConfig.authEmulatorPort,
    );
    FirebaseFirestore.instance.useFirestoreEmulator(
      AppConfig.emulatorHost,
      AppConfig.firestoreEmulatorPort,
    );
  }

  await FirebaseCrashlytics.instance.setCrashlyticsCollectionEnabled(true);
  await telemetry.logEvent(
    TelemetryEvents.appOpen,
    parameters: {'app_version': AppConfig.appVersion},
  );

  final keyStore = SecureDatabaseKeyStore();
  final key = await keyStore.loadOrCreateKey();
  final databasePath = p.join(await getDatabasesPath(), AppDatabase.fileName);

  late final Database database;
  try {
    database = await AppDatabase.open(path: databasePath, password: key);
    await telemetry.logEvent(TelemetryEvents.dbOpened);
  } catch (error, stackTrace) {
    await telemetry.recordError(
      error,
      stackTrace,
      reason: 'db_open_failed',
      fatal: true,
    );
    rethrow;
  }

  final profileCache = ProfileCache(database);
  final auth = AuthRepository(
    auth: FirebaseAuth.instance,
    firestore: FirebaseFirestore.instance,
    googleSignIn: GoogleSignInAdapter(),
    profileCache: profileCache,
    telemetry: telemetry,
  );

  return AppServices(
    database: database,
    profileCache: profileCache,
    auth: auth,
    telemetry: telemetry,
  );
}

FirebaseOptions _firebaseOptions() {
  return FirebaseOptions(
    apiKey: AppConfig.apiKey,
    appId: AppConfig.appId,
    messagingSenderId: AppConfig.messagingSenderId,
    projectId: AppConfig.projectId,
    storageBucket:
        AppConfig.storageBucket.isEmpty ? null : AppConfig.storageBucket,
  );
}
