# Dokumentasi Produk — Warehouse Mobile App

Versi dokumen: **2.0** · Tanggal: 16 November 2026 · Status: **Draft untuk review**

## Daftar dokumen

| File | Isi | Dipakai oleh |
|---|---|---|
| [`PRD-v2.md`](./PRD-v2.md) | Tujuan, metrik, RBAC, scope, requirement ber-ID (`FR/NFR/BR`), arsitektur, risiko, roadmap | Produk, Ops, semua tim |
| [`firestore-schema.md`](./firestore-schema.md) | Skema Firestore, index, security rules, pola tulis, kapasitas, versioning | Engineering, Security |
| [`use-case-matrix.md`](./use-case-matrix.md) | 27 use case lengkap, diagram, matriks UC×FR, traceability, skenario uji | QA, Engineering, Produk |
| [`ux-flow-spec.md`](./ux-flow-spec.md) | 3 alur kritis, 22 layar, state matrix, copy deck, usability test | Desainer, Produk, QA |
| [`spike-backlog.md`](./spike-backlog.md) | 6 spike teknis (SPK-00..06), kriteria lulus biner, rencana 7 hari, Go/No-Go | Engineering, QA, Produk |
| [`vertical-slice-backlog.md`](./vertical-slice-backlog.md) | 7 slice (VS-0..VS-6), 47 tiket, gate & metrik, traceability FR/UC → slice, rencana pilot | Engineering, QA, Produk |
| [`runbook-vs0.md`](./runbook-vs0.md) | Cara menjalankan VS-0: toolchain, Android, Firebase, `--dart-define`, emulator, bukti AC, risiko | Engineering, QA |
| [`product-import-spec.md`](./product-import-spec.md) | Template & aturan validasi import produk, semantik all-or-nothing, acceptance criteria | Admin, Ops, QA |

### Artefak siap-deploy

| File | Isi |
|---|---|
| [`firebase/firestore.rules`](../firebase/firestore.rules) | Security Rules final (RBAC, create-only ledger, Function-only writes) |
| [`firebase/firestore.indexes.json`](../firebase/firestore.indexes.json) | 15 composite index (collection + collection group) |
| [`firebase/firebase.json`](../firebase/firebase.json) | Konfigurasi Firestore + Functions (nodejs20) + port emulator Auth/Firestore/Functions |
| [`app/sqlite_schema.sql`](../app/sqlite_schema.sql) | Skema SQLite device: cache, outbox, ledger, cycle-count, view saldo, trigger immutability |

### Template & alat operasional

| File | Isi |
|---|---|
| [`templates/product-import-template.csv`](../templates/product-import-template.csv) | Template import produk (11 kolom, 3 baris contoh) |
| [`templates/product-import-invalid-sample.csv`](../templates/product-import-invalid-sample.csv) | Contoh file salah untuk QA (15 baris, 13 error) |
| [`templates/product-import-errors-example.csv`](../templates/product-import-errors-example.csv) | Contoh laporan error yang dihasilkan |
| [`tools/validate-products.ps1`](../tools/validate-products.ps1) | Validator CSV lokal; exit code 1 jika ada error |
| [`apps-script/Code.gs`](../apps-script/Code.gs) | Menu **Produk** di Google Sheets: validasi, laporan, export CSV, self-test |
| [`apps-script/appsscript.json`](../apps-script/appsscript.json) | Manifest Apps Script (V8, `Asia/Jakarta`, scope minimal) |
| [`apps-script/README.md`](../apps-script/README.md) | Cara pasang, alur kerja operator, troubleshooting |
| [`tools/test-apps-script.js`](../tools/test-apps-script.js) | Uji logika `Code.gs` tanpa Google (`cscript //nologo tools\test-apps-script.js`) |
| [`tools/export-tickets.ps1`](../tools/export-tickets.ps1) | Regenerasi CSV tiket dari `vertical-slice-backlog.md` |
| [`tools/verify-vs0.ps1`](../tools/verify-vs0.ps1) | Verifikasi statis VS-0 (file, JSON, skema, rules, tiket, kredensial); `-RunTests` bila toolchain ada |
| [`tools/verify-schema-sqlite.ps1`](../tools/verify-schema-sqlite.ps1) | Menjalankan `sqlite_schema.sql` di SQLite nyata (Windows) dan menguji view/trigger/CHECK |
| [`backlog/vertical-slice-tickets.csv`](../backlog/vertical-slice-tickets.csv) | 47 tiket siap impor Jira/Trello (turunan, bukan sumber kebenaran) |
| [`backlog/README.md`](../backlog/README.md) | Pemetaan kolom → Jira/Trello, cara regenerate |

### Menjalankan validasi

```bash
# dari folder firebase/
firebase deploy --only firestore:rules,firestore:indexes   # butuh project aktif
firebase firestore:indexes                                 # cek index yang belum dibuat

# SQLite (opsional, cek sintaks)
sqlite3 :memory: ".read ../app/sqlite_schema.sql"
```

```powershell
# verifikasi statis VS-0 (tanpa Flutter/Node)
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\verify-vs0.ps1

# skema dijalankan di SQLite nyata 3.43 (Windows, tanpa toolchain)
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\verify-schema-sqlite.ps1

# rules test (butuh Java 17 + Node 20)
Set-Location firebase\test; npm install; Set-Location ..
firebase emulators:exec --only firestore --project demo-warehouse "node --test test/"
```

> `firestore.indexes.json` dan `firebase.json` sudah divalidasi sebagai JSON yang sah.
> Verifikasi statis dan eksekusi skema **bukan** bukti acceptance criteria; jalankan CI
> dan demo device sesuai `runbook-vs0.md`.

## Urutan membaca

1. **PRD-v2** §1–§6 — pahami masalah, keputusan, metrik, dan aturan bisnis.
2. **use-case-matrix** §2–§3 — pahami perilaku sistem yang diharapkan.
3. **ux-flow-spec** §2–§8 — pahami alur layar dan semua kondisi gagal.
4. **spike-backlog** §5–§6 — pahami apa yang harus dibuktikan sebelum coding.
5. **vertical-slice-backlog** §3–§6 — pahami urutan slice, gate, dan tiket yang dieksekusi.
6. **runbook-vs0** §2–§8 — jalankan dan buktikan VS-0 sebelum menulis kode slice berikutnya.
7. **firestore-schema** §1–§5 — pahami model data dan konsekuensi teknis.
8. **PRD-v2** §11–§14 — risiko, QA, dan pertanyaan terbuka.

> Urutan eksekusi: workshop keputusan → UX low-fi + technical spike (paralel) → usability test → Go/No-Go → hi-fi → vertical slice.

## Yang berubah dari v1

| Isu v1 | Resolusi v2 |
|---|---|
| Realtime DB + SQLite + Functions saling bertabrakan | SQLite = outbox/cache, Firestore = source of truth |
| Sheets dijadikan database | Sheets = laporan append-only |
| Stock card counter yang di-mutasi | Ledger immutable + snapshot periode |
| Relasi ERD salah, `warehouse` & `role` hilang | Skema diperbaiki, RBAC ditambahkan |
| Cron server membaca SQLite | Sync dari device (WorkManager) |
| Formula cycle-count ambigu | Adjustment transaction (BR-02) |
| Metrik tidak mengukur akurasi | Stock accuracy & sync lag jadi metrik utama |
| Android 6+ vs 7+ | Android 8.0 (API 26), perlu konfirmasi device |
| `bool synced` | State machine `syncStatus` + retry + error |
| Catatan "tier Premium" | Dihapus |

## Keputusan yang masih menunggu stakeholder

Lihat `PRD-v2.md` §14 (Q1–Q8). Yang paling menghambat desain:

- **Q1** — versi Android & ketersediaan Google Play Services pada device gudang.
- **Q4** — cycle-count MVP: full count atau sampling.
- **Q7** — apakah device dipakai bergantian antar operator.

## Aturan pemeliharaan dokumen

- Requirement baru **wajib** punya ID `FR-*`/`NFR-*`/`BR-*` dan dipetakan ke minimal satu use case.
- Perubahan perilaku **wajib** memperbarui `use-case-matrix.md` §4 dan §5.
- Perubahan skema **wajib** memperbarui `firestore-schema.md` dan menaikkan `schemaVersion` jika breaking.
- Istilah "real-time" hanya dipakai untuk data **lokal**; untuk cloud gunakan "sync lag" dengan angka.
