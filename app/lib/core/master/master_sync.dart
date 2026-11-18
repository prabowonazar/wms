import 'package:sqflite_common/sqlite_api.dart';

import '../observability/telemetry.dart';
import 'master_remote.dart';
import 'product.dart';

/// Ringkasan satu kali sinkronisasi master.
class MasterSyncResult {
  const MasterSyncResult({
    required this.productCount,
    required this.pages,
    required this.lastSyncedAt,
    required this.duration,
    required this.full,
  });

  final int productCount;
  final int pages;
  final DateTime? lastSyncedAt;
  final Duration duration;
  final bool full;
}

/// Menarik master produk dari server ke SQLite (VS1-01).
///
/// - Sinkronisasi pertama (atau `full`) menghapus mirror lokal lalu menarik
///   semuanya; delta berikutnya hanya `updatedAt > lastSyncAt`.
/// - Setiap halaman ditulis dalam satu transaksi, jadi tidak ada produk
///   setengah jadi bila proses terhenti.
/// - Kursor disimpan di `meta.last_master_sync_at` dan tidak pernah mundur.
class MasterSyncService {
  MasterSyncService({
    required Database database,
    required MasterRemote remote,
    required String warehouseId,
    Telemetry telemetry = const NoopTelemetry(),
    DateTime Function() clock = DateTime.now,
    this.pageSize = 500,
  })  : _database = database,
        _remote = remote,
        _warehouseId = warehouseId,
        _telemetry = telemetry,
        _clock = clock;

  static const String lastSyncKey = 'last_master_sync_at';

  final Database _database;
  final MasterRemote _remote;
  final String _warehouseId;
  final Telemetry _telemetry;
  final DateTime Function() _clock;
  final int pageSize;

  /// `null` berarti device belum pernah menyelesaikan sync master.
  Future<DateTime?> lastSyncedAt() async {
    final rows = await _database.query(
      'meta',
      columns: ['value'],
      where: 'key = ?',
      whereArgs: [lastSyncKey],
      limit: 1,
    );
    if (rows.isEmpty) {
      return null;
    }
    final raw = rows.first['value'];
    final millis = raw is String ? int.tryParse(raw) : null;
    if (millis == null) {
      return null;
    }
    return DateTime.fromMillisecondsSinceEpoch(millis, isUtc: true);
  }

  /// Full sync bila belum pernah sync, delta bila sudah.
  Future<MasterSyncResult> syncIfNeeded() async {
    final last = await lastSyncedAt();
    return sync(full: last == null);
  }

  /// Menghapus mirror lokal lalu menarik ulang seluruh master.
  Future<MasterSyncResult> resyncAll() => sync(full: true);

  Future<MasterSyncResult> sync({bool full = false}) async {
    final stopwatch = Stopwatch()..start();

    if (full) {
      await _database.transaction((txn) async {
        // Urutan eksplisit: barcode lebih dulu agar tidak bergantung pada
        // ON DELETE CASCADE saat tabel produk dikosongkan.
        await txn.delete('product_barcodes');
        await txn.delete('products');
        await txn.delete(
          'meta',
          where: 'key = ?',
          whereArgs: [lastSyncKey],
        );
      });
    }

    var cursor = full ? null : await lastSyncedAt();
    DateTime? newest = cursor;
    var productCount = 0;
    var pages = 0;

    try {
      while (true) {
        final page = await _remote.fetchProducts(
          warehouseId: _warehouseId,
          updatedAfter: cursor,
          limit: pageSize,
        );
        pages++;

        if (page.products.isNotEmpty) {
          await _database.transaction((txn) async {
            for (final product in page.products) {
              await _upsertProduct(txn, product);
            }
          });
          productCount += page.products.length;
        }

        final pageNewest = page.newestUpdatedAt;
        if (pageNewest != null && (newest == null || pageNewest.isAfter(newest))) {
          newest = pageNewest;
        }

        // Berhenti bila halaman terakhir, kosong, atau kursor tidak maju.
        // Tanpa penjaga kursor, data dengan `updatedAt` sama bisa membuat
        // loop tanpa akhir.
        final advanced = pageNewest != null &&
            (cursor == null || pageNewest.isAfter(cursor));
        if (!page.hasMore || page.products.isEmpty || !advanced) {
          break;
        }
        cursor = pageNewest;
      }

      if (newest != null) {
        await _writeCursor(newest);
      }
    } catch (error, stackTrace) {
      stopwatch.stop();
      await _telemetry.logEvent(
        TelemetryEvents.masterSyncFailed,
        parameters: {
          'duration_ms': stopwatch.elapsedMilliseconds,
          'products': productCount,
          'full': full ? 1 : 0,
        },
      );
      await _telemetry.recordError(
        error,
        stackTrace,
        reason: 'master_sync_failed',
      );
      rethrow;
    }

    stopwatch.stop();
    await _telemetry.logEvent(
      TelemetryEvents.masterSyncCompleted,
      parameters: {
        'duration_ms': stopwatch.elapsedMilliseconds,
        'products': productCount,
        'pages': pages,
        'full': full ? 1 : 0,
      },
    );

    return MasterSyncResult(
      productCount: productCount,
      pages: pages,
      lastSyncedAt: newest,
      duration: stopwatch.elapsed,
      full: full,
    );
  }

  Future<void> _writeCursor(DateTime value) async {
    await _database.insert(
      'meta',
      {
        'key': lastSyncKey,
        'value': '${value.toUtc().millisecondsSinceEpoch}',
        'updated_at': _clock().toUtc().millisecondsSinceEpoch,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> _upsertProduct(Transaction txn, Product product) async {
    final updatedAtMillis = product.updatedAt.toUtc().millisecondsSinceEpoch;
    final syncedAtMillis = _clock().toUtc().millisecondsSinceEpoch;
    final code = normalizeCode(product.code);

    await txn.rawInsert(
      'INSERT INTO products ('
      'product_id, code, name, type, uom, min_stock, active, updated_at, '
      'synced_at'
      ') VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?) '
      'ON CONFLICT(product_id) DO UPDATE SET '
      'code = excluded.code, '
      'name = excluded.name, '
      'type = excluded.type, '
      'uom = excluded.uom, '
      'min_stock = excluded.min_stock, '
      'active = excluded.active, '
      'updated_at = excluded.updated_at, '
      'synced_at = excluded.synced_at',
      [
        product.id,
        code,
        product.name,
        product.type,
        product.uom,
        product.minStock,
        product.active ? 1 : 0,
        updatedAtMillis,
        syncedAtMillis,
      ],
    );

    // Barcode dihapus lalu ditulis ulang agar barcode yang sudah tidak
    // dimiliki produk ini hilang dari cache (mis. dipindah ke produk lain).
    await txn.delete(
      'product_barcodes',
      where: 'product_id = ?',
      whereArgs: [product.id],
    );
    for (final barcode in product.barcodes) {
      final normalized = normalizeBarcode(barcode);
      if (normalized.isEmpty) {
        continue;
      }
      await txn.rawInsert(
        'INSERT INTO product_barcodes (barcode, product_id, format, updated_at) '
        'VALUES (?, ?, ?, ?) '
        'ON CONFLICT(barcode) DO UPDATE SET '
        'product_id = excluded.product_id, '
        'updated_at = excluded.updated_at',
        [normalized, product.id, 'UNKNOWN', updatedAtMillis],
      );
    }
  }
}
