'use strict';

/**
 * Logika murni tanpa Firebase, supaya bisa diuji `node --test` tanpa emulator
 * dan tanpa dependency eksternal.
 *
 * Fungsi bisnis (applyBalance, approval cycle-count) menyusul di VS-2/VS-5.
 * VS-0 hanya membuktikan pipeline Functions hidup dan CI bisa mengujinya.
 */
function buildHealthPayload({ uid, now }) {
  if (!uid) {
    throw new Error('uid wajib diisi');
  }
  if (!(now instanceof Date) || Number.isNaN(now.getTime())) {
    throw new Error('now harus Date yang valid');
  }
  return {
    ok: true,
    uid,
    serverTime: now.toISOString(),
    schemaVersion: 1,
  };
}

module.exports = { buildHealthPayload };
