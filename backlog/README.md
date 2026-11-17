# Backlog — file impor tiket

Folder ini berisi **turunan** dari `docs/vertical-slice-backlog.md`, bukan sumber kebenaran.

| File | Isi |
|---|---|
| `vertical-slice-tickets.csv` | 47 tiket siap impor (Jira, Trello, Linear, Asana) |
| `README.md` | Cara impor, arti kolom, cara regenerate |

**Sumber kebenaran tetap dokumen Markdown.** CSV dibuat ulang dari dokumen setiap kali isinya berubah, sehingga tidak ada dua versi yang berbeda diam-diam.

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\export-tickets.ps1
```

Keluaran yang diharapkan: `Tiket: 47`, `Hari-dev: 65.5` (64 tanpa VS4-07 yang opsional).

---

## 1. Kolom

| Kolom | Arti | Contoh |
|---|---|---|
| `id` | ID tiket, sama dengan dokumen | `VS2-02` |
| `epic` | Nama slice | `Core loop: transaksi offline → sync → saldo` |
| `judul` | Judul siap pakai (ID + ringkasan) | `[VS2-02] Submit idempoten + UUIDv7 + SQLite atomik` |
| `jenis` | `Feature`, `Enabler` (NFR), `Measurement` (metrik) | `Feature` |
| `ref` | Requirement/use case terkait | `FR-SCN-06/07, BR-04` |
| `estimasi_hari` | Hari-dev (8 jam/hari) | `2` |
| `estimasi_jam` | Konversi jam untuk field "Original Estimate" | `16` |
| `milestone` | Gate slice | `G2` |
| `opsional` | `ya` bila boleh dipotong (§10 dokumen) | `tidak` |
| `acceptance_criteria` | Kriteria selesai yang terukur | `Tap 5x → 1 baris; force-stop 20x → 0 baris setengah` |

Catatan:
- `estimasi_hari` adalah **hari-dev ideal**, bukan hari kalender. Durasinya ada di dokumen (§3).
- `jenis` diturunkan otomatis: `ref` mengandung `NFR` → `Enabler`; `ref` diawali `M` (mis. `M1, M7`) → `Measurement`; sisanya `Feature`. Bukan penilaian prioritas.

---

## 2. Impor ke Jira (Cloud)

**Langkah 1 — epik.** Buat CSV kecil berisi 7 baris unik dari kolom `epic`, impor dengan tipe isu **Epic**:

| Epic Name | Ringkasan |
|---|---|
| `Fondasi & walking skeleton` | VS-0, 4 hari |
| `Scan & master data offline` | VS-1, 9 hari |
| `Core loop: transaksi offline → sync → saldo` | VS-2, 10 hari |
| `Kepercayaan: status sync, retry, konflik, histori` | VS-3, 9 hari |
| `Laporan, closing, export Sheets, admin` | VS-4, 9 hari |
| `Cycle count → adjustment → approval` | VS-5, 10 hari |
| `Hardening & kesiapan rollout` | VS-6, 8 hari |

**Langkah 2 — tiket.** Impor `vertical-slice-tickets.csv`, lalu petakan:

| Kolom CSV | Field Jira |
|---|---|
| `judul` | Summary |
| `acceptance_criteria` | Description (tambahkan baris `Ref: <ref>` dan `Gate: <milestone>` di atasnya) |
| `jenis` | Issue Type → `Feature` = Story, `Enabler`/`Measurement` = Task |
| `estimasi_jam` | Original Estimate (Jira menambahkan `h` otomatis; jika tidak, isi `16h`) |
| `epic` | Epic Link |
| `milestone`, `opsional` | Labels |
| `ref` | Label tambahan (opsional) |

Tips:
- Jira Cloud CSV memakai koma; file ini sudah UTF-8 tanpa BOM dan sudah di-escape sesuai RFC 4180.
- Jika Epic Link tidak muncul, impor epik lebih dulu, lalu muat ulang halaman impor.
- Jangan memakai `id` sebagai Issue Key (Jira menolak); biarkan Jira membuat key sendiri.

## 3. Impor ke Trello

Trello menerima CSV dengan kolom `Card`, `List`, `Description`, `Labels`.

| Kolom CSV | Field Trello |
|---|---|
| `judul` | Card |
| `milestone` | List (satu list per gate: G0…G6) — atau `epic` bila ingin list per slice |
| `acceptance_criteria` | Description (tambahkan `Ref:`, `Estimasi:`, `Gate:`) |
| `jenis`, `opsional` | Labels |

---

## 4. Setelah impor

- Perlakukan **Jira/Trello sebagai papan kerja**, dokumen sebagai **baseline scope & gate**.
- Jika ada tiket yang berubah saat eksekusi (scope, estimasi, AC), ubah **dokumen** lalu regenerate CSV — jangan hanya mengubah papan, agar traceability FR → slice tetap benar.
- Saat satu gate lulus, catat tanggal & hasil di dokumen §9 (tabel gate) supaya riwayat tidak hanya hidup di papan.
- Tiket `opsional=ya` (VS4-07) dipotong lebih dulu bila jadwal mepet, sesuai dokumen §10.
