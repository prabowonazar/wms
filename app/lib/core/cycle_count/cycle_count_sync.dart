import 'cycle_count.dart';
import 'cycle_count_remote.dart';
import 'cycle_count_repository.dart';

/// Mengirim sesi cycle-count lokal ke Firestore.
///
/// Sengaja tetap sederhana: dipanggil setelah submit dan saat layar dibuka.
/// WorkManager tidak dipakai; kegagalan tercatat di `last_error` dan bisa
/// dicoba ulang lewat tombol "Kirim ulang" (sama seperti batasan VS2-03).
class CycleCountSyncService {
  const CycleCountSyncService({
    required CycleCountRepository repository,
    required CycleCountRemote remote,
  })  : _repository = repository,
        _remote = remote;

  final CycleCountRepository _repository;
  final CycleCountRemote _remote;

  Future<void> push(
    CycleCountSession session, {
    bool submit = true,
  }) async {
    try {
      await _remote.createSession(session);
      final lines = await _repository.lines(session.id);
      for (final line in lines) {
        await _remote.saveLine(
          session.id,
          line,
          countedBy: line.countedBy,
        );
      }
      if (submit) {
        await _remote.submitSession(session.id);
      }
      await _repository.markSessionSynced(session.id);
    } on Object catch (error) {
      await _repository.markSessionFailed(session.id, error.toString());
      rethrow;
    }
  }

  /// Kirim ulang sesi yang belum sampai server (termasuk yang gagal).
  Future<int> flushPending() async {
    final sessions = await _repository.pendingSessions();
    var pushed = 0;
    for (final session in sessions) {
      try {
        await push(session, submit: !session.isOpen);
        pushed++;
      } on Object {
        // Lanjutkan sesi berikutnya; kegagalan sudah tercatat di repository.
      }
    }
    return pushed;
  }
}
