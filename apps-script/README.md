# Apps Script — Validator Import Produk

Validator untuk Google Sheets. Menambah menu **Produk** di spreadsheet, memeriksa isi sheet, menandai sel yang bermasalah, dan mengekspor CSV hanya jika sudah bersih.

Aturan lengkap ada di [`../docs/product-import-spec.md`](../docs/product-import-spec.md). Kode error, normalisasi, dan pesan dibuat identik dengan validator PowerShell (`../tools/validate-products.ps1`).

| File | Isi |
|---|---|
| `Code.gs` | Seluruh logika: menu, validasi, laporan, export, self-test |
| `appsscript.json` | Manifest: runtime V8, zona waktu `Asia/Jakarta`, scope minimal |

---

## 1. Pemasangan

### Cara A — tempel manual (tanpa alat tambahan)

1. Buka Google Sheets baru, beri nama misalnya `Master Produk Gudang`.
2. Menu **Extensions → Apps Script**.
3. Hapus isi `Code.gs` yang ada, lalu tempel seluruh isi `apps-script/Code.gs`.
4. Klik ikon **Project Settings** (gear) → centang **Show "appsscript.json" manifest file in editor**.
5. Buka `appsscript.json`, ganti isinya dengan isi `apps-script/appsscript.json`.
6. Simpan (`Ctrl+S`), beri nama project: `Validator Produk`.
7. Kembali ke spreadsheet, muat ulang halaman (F5).
8. Menu **Produk** muncul di kanan menu **Help**.
9. Jalankan **Produk → Buat / perbarui template**. Saat pertama kali, Google meminta otorisasi — pilih akun, **Advanced → Go to Validator Produk (unsafe)**, lalu **Allow**.

### Cara B — `clasp` (butuh Node.js)

```bash
npm install -g @google/clasp
clasp login
clasp create --type sheets --title "Master Produk Gudang" --rootDir .
clasp push
clasp open
```

`clasp create` menulis `appsscript.json` baru; samakan dengan versi di folder ini.

> Folder `apps-script/` sengaja **tidak** memuat `.clasp.json` (berisi `scriptId` unik per project).

---

## 2. Menu

| Menu | Yang terjadi |
|---|---|
| **Validasi sheet aktif** | Membaca header + semua baris, menjalankan seluruh aturan, mewarnai sel bermasalah, menulis sheet `laporan_validasi`. Tidak mengubah data. |
| **Buat / perbarui template** | Menyiapkan sheet `produk` (header + 3 contoh), `petunjuk`, `daftar_nilai`; memasang dropdown tipe/uom/status/gudang; format kode & barcode sebagai teks. Header ditulis ulang, **data mulai baris 2 tidak dihapus**. |
| **Unduh CSV** | Validasi dulu. Jika ada error → berhenti dan membuka laporan. Jika bersih → membuat `produk-YYYYMMDD-HHmm.csv` di Google Drive dan menampilkan tautannya. |
| **Jalankan self-test** | Menguji 13 kode error utama pada data di memori. Tidak menyentuh sheet. Hasil: `LULUS` atau daftar kode yang tidak terdeteksi. |
| **Tentang** | Ringkasan singkat. |

Sheet yang dibuat:

| Sheet | Fungsi |
|---|---|
| `produk` | Data yang diisi operator |
| `petunjuk` | Cara mengisi, 1 kolom lebar |
| `daftar_nilai` | Sumber dropdown: A=tipe, B=uom, C=status, **D=kode_gudang** |
| `laporan_validasi` | Dibuat otomatis saat validasi; 1 baris per temuan |

Menambah gudang: tambahkan kode di kolom D `daftar_nilai`, lalu jalankan **Buat / perbarui template** agar dropdown ikut diperbarui.

---

## 3. Alur kerja operator

1. **Produk → Buat / perbarui template** (sekali di awal).
2. Isi sheet `produk`. Satu baris = satu produk.
3. **Produk → Validasi sheet aktif**.
4. Perbaiki semua baris berwarna merah sampai `Error: 0`.
5. **Produk → Unduh CSV**.
6. Unggah file CSV itu ke aplikasi (menu Import Produk).

Peringatan (`warning`) tidak memblokir export.

---

## 4. Perbedaan dengan validator PowerShell

| Hal | PowerShell | Apps Script |
|---|---|---|
| Sumber | File CSV | Sheet aktif |
| Formula di sel | Tidak terlihat di CSV | Terdeteksi → `E-CSV-INJECTION` |
| `E-FILE-SIZE` | Ya (≤2 MB) | Tidak berlaku (dibatasi 10 juta sel Spreadsheet) |
| `E-BARCODE-EXISTS` | Ya, jika `-ExistingProductsCsv` diberikan | Tidak tersedia (butuh database) |
| `E-IMPORT-LOCKED` | — | Ditangani server saat import |
| Baris kosong | Dilewati | Dilewati |
| Header salah | `E-HEADER-MISSING` / `E-HEADER-UNKNOWN` | Sama |
| Nomor baris | Sama dengan nomor baris file | Sama dengan nomor baris sheet |

Aturan yang **tidak** dapat diperiksa di sisi klien (dicek server): kode produk sudah ada (create vs update), barcode milik produk lain, dan kunci import bersamaan.

---

## 5. Batasan teknis

- **Validasi jalan di browser/Sheets**, bukan di server. Untuk 5.000 baris, proses bisa memakan 20–60 detik; Google akan menampilkan dialog "still running" — pilih **No** dan tunggu.
- `menuValidate` memakai **sheet yang sedang aktif**. Kalau yang aktif `petunjuk` atau `laporan_validasi`, script menolak.
- Validasi membaca `getFormulas()` dua kali (nilai + formula) untuk 11 kolom; biaya baca sebanding jumlah baris.
- Timeout Apps Script 6 menit per eksekusi. Jika sheets >5.000 baris, pecah per batch.
- Dropdown memakai **allow invalid** agar paste massal tidak tertolak; kesalahan tetap dilaporkan validator.

---

## 6. Troubleshooting

| Gejala | Penyebab & solusi |
|---|---|
| Menu **Produk** tidak muncul | Muat ulang spreadsheet. Pastikan `onOpen` ada dan script terikat (bound) ke spreadsheet, bukan standalone. |
| `You do not have permission to call SpreadsheetApp.getUi` | Jalankan fungsi sekali dari editor untuk memicu otorisasi. |
| `Script function not found: onOpen` | `Code.gs` tidak tersimpan / nama fungsi berubah. |
| Error otorisasi Drive saat Unduh CSV | Scope `drive.file` belum disetujui; jalankan ulang dan setujui. |
| Sel merah tertinggal setelah diperbaiki | Jalankan validasi lagi; warna direset setiap validasi. |
| Angka barcode berubah jadi `8,991E+12` | Kolom barcode belum diformat teks. Jalankan **Buat / perbarui template** atau set `Format → Number → Plain text`. |
| Self-test gagal | Laporkan output `FAIL` beserta kode yang hilang; jangan pakai versi itu untuk import. |

---

## 7. Uji yang sudah dijalankan

Logika `validateProductRows_`, `buildCsv_`, dan `selfTest_` dijalankan di luar Google (Windows Script Host, ES5) terhadap data yang sama dengan validator PowerShell:

```powershell
cscript //nologo tools\test-apps-script.js
```

Keluaran: 10 baris `PASS`, diakhiri `SEMUA UJI LULUS`, exit code `0`. Jika ada yang gagal, baris `FAIL` menyebutkan kode error yang tidak terdeteksi.

| Uji | Hasil |
|---|---|
| 15 baris `product-import-invalid-sample.csv` | 13 error, kode & nomor baris **identik** dengan PowerShell |
| 3 baris `product-import-template.csv` | 0 temuan |
| Normalisasi (spasi, huruf besar/kecil) | 0 temuan |
| Baris kosong di tengah data | Dilewati, 0 temuan |
| Formula di sel barcode | `E-CSV-INJECTION` |
| Barcode ganda dalam satu produk | 1 warning, 0 error |
| Gudang tambahan (`JKT-02`) | Diterima |
| Escape CSV (kutip, koma, newline) | Sesuai RFC 4180 |

Panggilan yang menyentuh Google API (Spreadsheet, Drive, UI) **belum** dijalankan otomatis; perlu diuji manual sekali di spreadsheet (lihat §2).
