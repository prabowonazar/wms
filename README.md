# Warehouse Mobile App v2

Aplikasi gudang Android **offline-first**: operator mencatat barang masuk/keluar dari
barcode, data tersimpan di SQLite terenkripsi, lalu tersinkron ke Firestore tepat
sekali. Proyek ini dibangun bertahap lewat 7 vertical slice (VS-0..VS-6).

## Status

**VS-0 sampai VS-4: kode selesai dan CI hijau. VS-5 (cycle count & approval):
kode selesai, CI sedang diverifikasi; belum diverifikasi di device.**

Yang sudah ada: login Google + role gate (sesi offline maksimal 7 hari),
database SQLCipher, skema v1, rules Firestore + 41 test rules, Cloud Functions
`health`, `importProducts`, `applyBalance`, closing harian, ekspor/rekonsiliasi
Sheets, admin, dan approval cycle-count, sync master full/delta, layar scan +
pencarian lokal, ledger lokal + outbox idempoten, lembar masuk/keluar, saldo &
stock card, layar sinkronisasi dengan backoff 5× dan penolakan server, konflik
saldo, histori berfilter, reversal + audit, dashboard, cycle count, CI, dan
runbook.

> Mesin ini tidak punya Flutter/Dart/Node/Java, jadi seluruh bukti kompilasi
> datang dari CI GitHub Actions (run #31, commit `abe6ab2`): `flutter analyze`
> bersih, 107 test Flutter, APK debug terbangun, 41 test rules, dan 41 test
> Functions lulus. Yang masih terbuka
> hanya bukti di device: login Google nyata, kamera & debounce, simpan
> transaksi ≤1,5 s, airplane mode → `synced`, override supervisor, konflik dua
> device, SQLCipher, Crashlytics, angka NFR, serta job terjadwal dengan secret
> Sheets. Outbox masih memakai timer foreground, bukan WorkManager - lihat
> `docs/vertical-slice-backlog.md` (VS-2).

## Mulai cepat

1. Baca [`docs/runbook-vs0.md`](docs/runbook-vs0.md) - prasyarat, generate Android,
   Firebase, `--dart-define`, emulator, dan bukti AC.
2. Verifikasi statis tanpa toolchain:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\verify-vs0.ps1
```

3. Buktikan skema SQLite di SQLite nyata (Windows, tanpa Flutter):

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\verify-schema-sqlite.ps1
```

4. Dengan toolchain:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\verify-vs0.ps1 -RunTests
```

## Struktur

```
app/                 Flutter app (lib, test, sqlite_schema.sql, pubspec)
  lib/core/          config, sql, db, security, auth, storage, observability
  lib/core/master/   model produk, sync full/delta, lookup & pencarian lokal
  lib/core/transactions/  ledger lokal, UUIDv7, remote create-only, outbox
  lib/features/      login, denied, home, splash, bootstrap, scan, movement, stock
  test/              test unit, FFI SQLite, widget
firebase/            rules, indexes, firebase.json, functions/, test/
docs/                PRD, skema, UX, spike, backlog slice, runbook
templates/           template & contoh import produk
apps-script/         validator produk di Google Sheets
tools/               validator CSV, generator tiket, verifikasi VS-0
backlog/             CSV tiket (turunan dari docs)
.github/workflows/   CI: analyze/test, APK, Functions, rules emulator
```

## Dokumen

Indeks lengkap: [`docs/README.md`](docs/README.md).

| Dokumen | Isi |
|---|---|
| [`docs/PRD-v2.md`](docs/PRD-v2.md) | Masalah, metrik, RBAC, requirement ber-ID, arsitektur |
| [`docs/vertical-slice-backlog.md`](docs/vertical-slice-backlog.md) | 7 slice, 47 tiket, gate G0-G6, traceability |
| [`docs/firestore-schema.md`](docs/firestore-schema.md) | Model Firestore, index, pola tulis |
| [`docs/product-import-spec.md`](docs/product-import-spec.md) | Aturan impor produk dari sheet + batas batch/kuota |
| [`docs/ux-flow-spec.md`](docs/ux-flow-spec.md) | 22 layar, 3 alur kritis, copy deck |
| [`docs/runbook-vs0.md`](docs/runbook-vs0.md) | Cara menjalankan & membuktikan VS-0 |

## Aturan kontribusi

- **Markdown adalah sumber kebenaran** scope, estimasi, dan acceptance criteria.
  CSV tiket (`backlog/vertical-slice-tickets.csv`) hanya turunan; regenerate dengan
  `tools/export-tickets.ps1`, jangan diedit manual.
- Skema SQLite hanya ada di `app/sqlite_schema.sql`; jangan menyalin SQL ke Dart
  atau dokumen lain.
- Tidak ada kredensial di repo. Firebase dikonfigurasi lewat `--dart-define`;
  file rahasia di-`.gitignore` dan diperiksa `tools/verify-vs0.ps1`.
- Perubahan perilaku wajib memperbarui dokumen di `docs/` pada commit yang sama.
- Jangan menambah `TODO` tanpa tiket backlog.
