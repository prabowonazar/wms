'use strict';

/** Validasi aksi administrasi sensitif (FR-ADM-01/03). */

const ROLES = ['operator', 'supervisor', 'admin'];
const MIN_REASON = 10;

function isAdmin(role) {
  return role === 'admin';
}

/**
 * @returns {{ok: boolean, error?: string, changes?: object}}
 */
function validateUserUpdate({ role, active, reason } = {}) {
  const changes = {};
  if (role !== undefined) {
    if (!ROLES.includes(role)) {
      return { ok: false, error: 'invalid_role' };
    }
    changes.role = role;
  }
  if (active !== undefined) {
    if (typeof active !== 'boolean') {
      return { ok: false, error: 'invalid_active' };
    }
    changes.active = active;
  }
  if (Object.keys(changes).length === 0) {
    return { ok: false, error: 'no_changes' };
  }
  if (typeof reason !== 'string' || reason.trim().length < MIN_REASON) {
    return { ok: false, error: 'reason_too_short' };
  }
  return { ok: true, changes: { ...changes, reason: reason.trim() } };
}

function validateRetryRequest({ transactionId, reason } = {}) {
  if (typeof transactionId !== 'string' || transactionId.trim() === '') {
    return { ok: false, error: 'missing_transaction_id' };
  }
  if (typeof reason !== 'string' || reason.trim().length < MIN_REASON) {
    return { ok: false, error: 'reason_too_short' };
  }
  return { ok: true, transactionId: transactionId.trim(), reason: reason.trim() };
}

module.exports = {
  ROLES,
  MIN_REASON,
  isAdmin,
  validateUserUpdate,
  validateRetryRequest,
};
