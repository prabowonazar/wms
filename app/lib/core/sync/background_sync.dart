import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_sqlcipher/sqflite.dart';
import 'package:workmanager/workmanager.dart';

import '../../bootstrap/bootstrap.dart';
import '../cycle_count/cycle_count_repository.dart';
import '../cycle_count/cycle_count_remote.dart';
import '../cycle_count/cycle_count_sync.dart';
import '../db/app_database.dart';
import '../observability/telemetry.dart';
import '../security/db_key_store.dart';
import '../storage/profile_cache.dart';
import '../transactions/outbox_sync.dart';
import '../transactions/transaction_remote.dart';
import '../transactions/transaction_repository.dart';

/// Nama task WorkManager (unik per aplikasi).
const String backgroundFlushTask = 'vs2OutboxFlush';

/// Dipanggil oleh WorkManager di isolate terpisah. Harus bertanda
/// `vm:entry-point` agar tidak di-tree-shake saat build release.
@pragma('vm:entry-point')
void callbackDispatcher() {
  Workmanager().executeTask((task, inputData) async {
    if (task != backgroundFlushTask) {
      return true;
    }
    try {
      WidgetsFlutterBinding.ensureInitialized();
      await _flushInBackground();
      return true;
    } on Object {
      // WorkManager akan menjadwalkan ulang sesuai kebijakan sistem.
      return false;
    }
  });
}

Future<void> _flushInBackground() async {
  if (Firebase.apps.isEmpty) {
    await Firebase.initializeApp(options: firebaseOptions());
  }
  final user = FirebaseAuth.instance.currentUser;
  if (user == null) {
    return; // Belum login: tidak ada antrean yang bisa dikirim.
  }

  final key = await SecureDatabaseKeyStore().loadOrCreateKey();
  final database = await AppDatabase.open(
    path: p.join(await getDatabasesPath(), AppDatabase.fileName),
    password: key,
  );
  try {
    final profile = await ProfileCache(database).read(user.uid);
    if (profile == null || profile.warehouseId.isEmpty) {
      return;
    }

    final transactions = TransactionRepository(
      database: database,
      warehouseId: profile.warehouseId,
    );
    final outbox = OutboxSyncService(
      repository: transactions,
      remote: FirestoreTransactionRemote(FirebaseFirestore.instance),
      telemetry: const NoopTelemetry(),
    );
    await outbox.flush();

    final cycleCounts = CycleCountRepository(
      database: database,
      warehouseId: profile.warehouseId,
    );
    final cycleSync = CycleCountSyncService(
      repository: cycleCounts,
      remote: FirestoreCycleCountRemote(FirebaseFirestore.instance),
    );
    await cycleSync.flushPending();
  } finally {
    await database.close();
  }
}

/// Inisialisasi WorkManager saat aplikasi dibuka. Idempoten.
class BackgroundSync {
  const BackgroundSync._();

  static bool _initialized = false;

  static Future<void> initialize() async {
    if (_initialized) {
      return;
    }
    await Workmanager().initialize(callbackDispatcher);
    await Workmanager().cancelByUniqueName(backgroundFlushTask);
    await Workmanager().registerPeriodicTask(
      backgroundFlushTask,
      backgroundFlushTask,
      frequency: const Duration(minutes: 15),
      initialDelay: const Duration(minutes: 1),
      constraints: Constraints(networkType: NetworkType.connected),
    );
    _initialized = true;
  }
}
