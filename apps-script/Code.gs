/**
 * Validator Import Produk - Warehouse Mobile App v2
 * -----------------------------------------------------------------------------
 * Dipasang sebagai Apps Script yang terikat (bound) ke Google Spreadsheet.
 *
 * Menu "Produk":
 *   1. Validasi sheet aktif   -> cek aturan, tandai sel, tulis laporan
 *   2. Buat / perbarui template -> siapkan sheet produk + petunjuk + daftar_nilai
 *   3. Unduh CSV              -> validasi dulu, lalu buat file CSV di Drive
 *   4. Jalankan self-test     -> uji cepat bahwa aturan bekerja
 *
 * Aturan lengkap: docs/product-import-spec.md
 * Padanan: tools/validate-products.ps1 (kode error sama)
 */

var CONFIG = {
  SHEET_PRODUK: 'produk',
  SHEET_PETUNJUK: 'petunjuk',
  SHEET_NILAI: 'daftar_nilai',
  SHEET_LAPORAN: 'laporan_validasi',

  HEADER: [
    'kode_produk', 'nama_produk', 'tipe', 'uom',
    'barcode_1', 'barcode_2', 'barcode_3',
    'stok_minimum', 'status', 'kode_gudang', 'keterangan'
  ],

  TYPES: ['consumable', 'spare_part', 'tool', 'packaging', 'other'],
  UOM: ['pcs', 'box', 'pack', 'roll', 'kg', 'g', 'liter', 'ml', 'meter', 'set', 'unit'],
  STATUS: ['aktif', 'nonaktif'],
  DEFAULT_WAREHOUSES: ['JKT-01'],

  MAX_ROWS: 5000,
  MIN_NAME: 3,
  MAX_NAME: 200,
  MAX_NOTE: 200,
  MAX_MIN_STOCK: 1000000,

  CODE_RE: /^[A-Z0-9][A-Z0-9._-]{2,31}$/,
  BARCODE_RE: /^[A-Z0-9._-]{4,48}$/,

  ERROR_FILL: '#FCE8E6'
};

// =============================================================================
// Menu
// =============================================================================

function onOpen() {
  SpreadsheetApp.getUi()
    .createMenu('Produk')
    .addItem('Validasi sheet aktif', 'menuValidate')
    .addItem('Buat / perbarui template', 'menuSetup')
    .addItem('Unduh CSV', 'menuExportCsv')
    .addSeparator()
    .addItem('Jalankan self-test', 'menuSelfTest')
    .addItem('Tentang', 'menuAbout')
    .addToUi();
}

function menuValidate() {
  var ui = SpreadsheetApp.getUi();
  var ss = SpreadsheetApp.getActive();
  var sheet = ss.getActiveSheet();

  if (isUtilitySheet_(sheet.getName())) {
    ui.alert('Buka sheet "' + CONFIG.SHEET_PRODUK + '" lalu jalankan validasi.');
    return;
  }

  try {
    var result = validateSheet_(sheet);
    writeReport_(ss, sheet, result);
    ui.alert('Hasil validasi', summaryText_(result), ui.ButtonSet.OK);
  } catch (e) {
    ui.alert('Validasi gagal dijalankan', String(e && e.message ? e.message : e), ui.ButtonSet.OK);
  }
}

function menuSetup() {
  var ui = SpreadsheetApp.getUi();
  var ss = SpreadsheetApp.getActive();
  var ok = ui.alert(
    'Buat / perbarui template',
    'Header sheet "' + CONFIG.SHEET_PRODUK + '" akan ditulis ulang.\n' +
    'Data mulai baris 2 TIDAK dihapus.\n\nLanjutkan?',
    ui.ButtonSet.YES_NO
  );
  if (ok !== ui.Button.YES) return;

  try {
    setupTemplate_(ss);
    ui.alert('Template siap', 'Sheet produk, petunjuk, dan daftar_nilai sudah disiapkan.', ui.ButtonSet.OK);
  } catch (e) {
    ui.alert('Gagal membuat template', String(e && e.message ? e.message : e), ui.ButtonSet.OK);
  }
}

function menuExportCsv() {
  var ui = SpreadsheetApp.getUi();
  var ss = SpreadsheetApp.getActive();
  var sheet = ss.getSheetByName(CONFIG.SHEET_PRODUK) || ss.getActiveSheet();

  try {
    var result = validateSheet_(sheet);
    writeReport_(ss, sheet, result);

    var errors = result.issues.filter(function (i) { return i.level === 'error'; });
    if (errors.length > 0) {
      ui.alert(
        'Belum bisa diekspor',
        'Masih ada ' + errors.length + ' error. Perbaiki dulu, lalu jalankan validasi lagi.\n\n' +
        'Rincian ada di sheet "' + CONFIG.SHEET_LAPORAN + '".',
        ui.ButtonSet.OK
      );
      return;
    }

    var values = sheet.getDataRange().getValues();
    if (values.length < 2) {
      ui.alert('Tidak ada data produk untuk diekspor.');
      return;
    }

    var csv = buildCsv_(values);
    var name = 'produk-' + Utilities.formatDate(
      new Date(), Session.getScriptTimeZone(), 'yyyyMMdd-HHmm'
    ) + '.csv';

    var file = DriveApp.createFile(name, csv, MimeType.CSV);
    ui.alert(
      'CSV dibuat',
      'File: ' + name + '\nBaris data: ' + (values.length - 1) + '\n\n' + file.getUrl(),
      ui.ButtonSet.OK
    );
  } catch (e) {
    ui.alert('Export gagal', String(e && e.message ? e.message : e), ui.ButtonSet.OK);
  }
}

function menuSelfTest() {
  var msg = selfTest_();
  SpreadsheetApp.getUi().alert('Self-test', msg, SpreadsheetApp.getUi().ButtonSet.OK);
}

function menuAbout() {
  var ui = SpreadsheetApp.getUi();
  ui.alert(
    'Validator Produk v1.0',
    'Memeriksa: kode, nama, tipe, uom, barcode, stok minimum, status, gudang, keterangan, formula.\n\n' +
    'Error = file ditolak. Peringatan = tetap boleh diekspor.\n\n' +
    'Aturan lengkap: docs/product-import-spec.md',
    ui.ButtonSet.OK
  );
}

function isUtilitySheet_(name) {
  return name === CONFIG.SHEET_PETUNJUK ||
    name === CONFIG.SHEET_NILAI ||
    name === CONFIG.SHEET_LAPORAN;
}

// =============================================================================
// Validasi sheet (membaca Spreadsheet)
// =============================================================================

function validateSheet_(sheet) {
  var lastRow = sheet.getLastRow();
  var lastCol = sheet.getLastColumn();

  if (lastRow < 1 || lastCol < 1) {
    return {
      issues: [makeIssue_(1, 'E-EMPTY', 'error', '-', '', 'Sheet kosong atau belum memiliki header.', -1)],
      dataRows: 0,
      header: []
    };
  }

  var width = Math.max(lastCol, CONFIG.HEADER.length);
  var values = sheet.getRange(1, 1, lastRow, width).getValues();
  var formulas = sheet.getRange(1, 1, lastRow, width).getFormulas();

  var header = values[0].map(function (v) { return String(v).trim(); });

  var missing = CONFIG.HEADER.filter(function (h) { return header.indexOf(h) === -1; });
  var extra = header.filter(function (h) { return h !== '' && CONFIG.HEADER.indexOf(h) === -1; });

  var issues = [];
  if (missing.length > 0) {
    issues.push(makeIssue_(1, 'E-HEADER-MISSING', 'error', missing.join('|'), '',
      'Kolom wajib tidak ditemukan: ' + missing.join(', ') + '.', -1));
  }
  if (extra.length > 0) {
    issues.push(makeIssue_(1, 'E-HEADER-UNKNOWN', 'error', extra.join('|'), '',
      'Kolom tidak dikenal: ' + extra.join(', ') + '.', -1));
  }
  if (issues.length > 0) {
    return { issues: issues, dataRows: 0, header: header };
  }

  var rows = values.slice(1);
  var formulaRows = formulas.slice(1);

  if (rows.length === 0) {
    issues.push(makeIssue_(2, 'E-EMPTY', 'error', '-', '',
      'Sheet hanya berisi header, belum ada baris produk.', -1));
  }
  if (rows.length > CONFIG.MAX_ROWS) {
    issues.push(makeIssue_(1, 'E-BATCH-SIZE', 'error', '-', String(rows.length),
      'Maksimum ' + CONFIG.MAX_ROWS + ' baris per file. Pecah menjadi beberapa sheet/file.', -1));
  }

  var rowIssues = validateProductRows_(header, rows, formulaRows, getWarehouses_());

  return {
    issues: issues.concat(rowIssues),
    dataRows: rows.length,
    header: header
  };
}

function getWarehouses_() {
  var ss = SpreadsheetApp.getActive();
  var sh = ss.getSheetByName(CONFIG.SHEET_NILAI);
  if (!sh || sh.getLastRow() < 2) return CONFIG.DEFAULT_WAREHOUSES;

  var values = sh.getRange(2, 4, sh.getLastRow() - 1, 1).getValues();
  var list = values
    .map(function (r) { return String(r[0]).trim().toUpperCase(); })
    .filter(function (v) { return v !== ''; });

  return list.length > 0 ? list : CONFIG.DEFAULT_WAREHOUSES;
}

// =============================================================================
// Inti validasi (fungsi murni: tanpa API Spreadsheet, mudah diuji)
// =============================================================================

function validateProductRows_(header, rows, formulaRows, warehouses) {
  var cfg = CONFIG;
  var issues = [];
  var col = {};
  var c;
  for (c = 0; c < header.length; c++) col[header[c]] = c;

  var allowedTypes = cfg.TYPES;
  var allowedUom = cfg.UOM;
  var allowedStatus = cfg.STATUS;

  var whSet = {};
  var whList = (warehouses && warehouses.length) ? warehouses : cfg.DEFAULT_WAREHOUSES;
  whList.forEach(function (w) { whSet[String(w).trim().toUpperCase()] = true; });

  var seenCodes = {};
  var seenBarcodes = {};

  function cell(row, name) {
    var i = col[name];
    return (i === undefined) ? '' : row[i];
  }
  function txt(v) {
    return (v === null || v === undefined) ? '' : String(v).trim();
  }
  function add(rowNo, code, level, column, value, message, colIndex) {
    issues.push(makeIssue_(rowNo, code, level, column, value, message, colIndex));
  }
  function isInjection(s) {
    return s !== '' && '=+-@'.indexOf(s.charAt(0)) !== -1;
  }

  for (var i = 0; i < rows.length; i++) {
    var row = rows[i] || [];
    var rowNo = i + 2;

    // Lewati baris yang benar-benar kosong
    var hasValue = false;
    for (var k = 0; k < row.length; k++) {
      if (txt(row[k]) !== '') { hasValue = true; break; }
    }
    if (!hasValue) continue;

    // Formula di sel mana pun = risiko injection
    var frow = (formulaRows && formulaRows[i]) ? formulaRows[i] : [];
    for (var f = 0; f < frow.length; f++) {
      var fs = txt(frow[f]);
      if (fs !== '' && fs.charAt(0) === '=') {
        add(rowNo, 'E-CSV-INJECTION', 'error', header[f] || ('kolom_' + (f + 1)), fs,
          'Sel berisi formula. Tempel sebagai nilai (Paste special > Values only).', f);
      }
    }

    // kode_produk
    var codeRaw = txt(cell(row, 'kode_produk'));
    var code = codeRaw.toUpperCase();
    if (code === '') {
      add(rowNo, 'E-CODE-REQUIRED', 'error', 'kode_produk', codeRaw,
        'Kode produk wajib diisi.', col['kode_produk']);
    } else if (!cfg.CODE_RE.test(code)) {
      add(rowNo, 'E-CODE-FORMAT', 'error', 'kode_produk', codeRaw,
        'Kode 3-32 karakter: huruf/angka, titik, garis bawah, strip; diawali huruf/angka.',
        col['kode_produk']);
    } else if (seenCodes[code]) {
      add(rowNo, 'E-CODE-DUPLICATE', 'error', 'kode_produk', code,
        'Kode sudah dipakai di baris ' + seenCodes[code] + '.', col['kode_produk']);
    } else {
      seenCodes[code] = rowNo;
    }

    // nama_produk
    var name = txt(cell(row, 'nama_produk'));
    if (name === '') {
      add(rowNo, 'E-NAME-REQUIRED', 'error', 'nama_produk', name,
        'Nama produk wajib diisi.', col['nama_produk']);
    } else {
      if (name.length < cfg.MIN_NAME) {
        add(rowNo, 'E-NAME-LENGTH', 'error', 'nama_produk', name,
          'Nama minimal ' + cfg.MIN_NAME + ' karakter.', col['nama_produk']);
      }
      if (name.length > cfg.MAX_NAME) {
        add(rowNo, 'E-NAME-LENGTH', 'error', 'nama_produk', name.length + ' karakter',
          'Nama maksimum ' + cfg.MAX_NAME + ' karakter.', col['nama_produk']);
      }
      if (isInjection(name)) {
        add(rowNo, 'E-CSV-INJECTION', 'error', 'nama_produk', name,
          'Nilai diawali =, +, -, atau @ (berisiko formula).', col['nama_produk']);
      }
    }

    // tipe
    var type = txt(cell(row, 'tipe')).toLowerCase();
    if (allowedTypes.indexOf(type) === -1) {
      add(rowNo, 'E-TYPE-INVALID', 'error', 'tipe', type,
        'Tipe harus salah satu: ' + allowedTypes.join(', ') + '.', col['tipe']);
    }

    // uom
    var uom = txt(cell(row, 'uom')).toLowerCase();
    if (allowedUom.indexOf(uom) === -1) {
      add(rowNo, 'E-UOM-INVALID', 'error', 'uom', uom,
        'Satuan harus salah satu: ' + allowedUom.join(', ') + '.', col['uom']);
    }

    // barcode
    var bcCols = ['barcode_1', 'barcode_2', 'barcode_3'];
    var rowBarcodes = [];
    for (var b = 0; b < bcCols.length; b++) {
      var bcName = bcCols[b];
      var bcRaw = txt(cell(row, bcName));
      if (bcRaw === '') continue;

      var bc = bcRaw.toUpperCase();
      if (!cfg.BARCODE_RE.test(bc)) {
        add(rowNo, 'E-BARCODE-FORMAT', 'error', bcName, bcRaw,
          'Barcode 4-48 karakter: huruf/angka, titik, garis bawah, strip.', col[bcName]);
        continue;
      }
      rowBarcodes.push({ value: bc, column: bcName });
    }

    if (rowBarcodes.length === 0) {
      add(rowNo, 'E-BARCODE-REQUIRED', 'error', 'barcode_1', '',
        'Minimal satu barcode wajib diisi (barcode_1).', col['barcode_1']);
    }

    var selfSeen = {};
    var selfWarned = false;
    for (var rb = 0; rb < rowBarcodes.length; rb++) {
      var item = rowBarcodes[rb];
      if (selfSeen[item.value]) {
        if (!selfWarned) {
          add(rowNo, 'W-BARCODE-SELF', 'warning', 'barcode_*', item.value,
            'Barcode yang sama diulang dalam satu produk; hanya satu yang disimpan.', -1);
          selfWarned = true;
        }
        continue;
      }
      selfSeen[item.value] = true;

      if (seenBarcodes[item.value]) {
        add(rowNo, 'E-BARCODE-DUPLICATE', 'error', item.column, item.value,
          'Barcode sudah dipakai di baris ' + seenBarcodes[item.value] + '.', col[item.column]);
      } else {
        seenBarcodes[item.value] = rowNo;
      }
    }

    // stok_minimum
    var minRaw = txt(cell(row, 'stok_minimum'));
    if (minRaw !== '') {
      if (!/^[+-]?\d+$/.test(minRaw)) {
        add(rowNo, 'E-MINSTOCK-NUMBER', 'error', 'stok_minimum', minRaw,
          'Stok minimum harus bilangan bulat.', col['stok_minimum']);
      } else {
        var minVal = parseInt(minRaw, 10);
        if (minVal < 0 || minVal > cfg.MAX_MIN_STOCK) {
          add(rowNo, 'E-MINSTOCK-RANGE', 'error', 'stok_minimum', minRaw,
            'Stok minimum harus antara 0 dan ' + cfg.MAX_MIN_STOCK + '.', col['stok_minimum']);
        }
      }
    }

    // status
    var status = txt(cell(row, 'status')).toLowerCase();
    if (allowedStatus.indexOf(status) === -1) {
      add(rowNo, 'E-STATUS-INVALID', 'error', 'status', status,
        "Status harus 'aktif' atau 'nonaktif'.", col['status']);
    }

    // kode_gudang
    var wh = txt(cell(row, 'kode_gudang')).toUpperCase();
    if (wh === '' || !whSet[wh]) {
      add(rowNo, 'E-WAREHOUSE-INVALID', 'error', 'kode_gudang', wh,
        'Kode gudang tidak dikenal. Pilihan: ' + Object.keys(whSet).join(', ') + '.',
        col['kode_gudang']);
    }

    // keterangan
    var note = txt(cell(row, 'keterangan'));
    if (note.length > cfg.MAX_NOTE) {
      add(rowNo, 'E-NOTE-LENGTH', 'error', 'keterangan', note.length + ' karakter',
        'Keterangan maksimum ' + cfg.MAX_NOTE + ' karakter.', col['keterangan']);
    }
    if (isInjection(note)) {
      add(rowNo, 'E-CSV-INJECTION', 'error', 'keterangan', note,
        'Nilai diawali =, +, -, atau @ (berisiko formula).', col['keterangan']);
    }
  }

  return issues;
}

function makeIssue_(row, code, level, column, value, message, colIndex) {
  return {
    row: row,
    code: code,
    level: level,
    column: column,
    value: (value === null || value === undefined) ? '' : String(value),
    message: message,
    colIndex: (colIndex === undefined) ? -1 : colIndex
  };
}

// =============================================================================
// Laporan & highlight
// =============================================================================

function writeReport_(ss, sheet, result) {
  var sh = ss.getSheetByName(CONFIG.SHEET_LAPORAN);
  if (!sh) sh = ss.insertSheet(CONFIG.SHEET_LAPORAN);
  sh.clear();

  var header = ['baris', 'kode_error', 'tingkat', 'kolom', 'nilai', 'pesan'];
  var out = [header];
  result.issues.forEach(function (it) {
    out.push([it.row, it.code, it.level, it.column, it.value, it.message]);
  });

  sh.getRange(1, 1, out.length, header.length).setValues(out);
  sh.getRange(1, 1, 1, header.length).setFontWeight('bold').setBackground('#EFEFEF');
  sh.setFrozenRows(1);
  sh.setColumnWidth(1, 60);
  sh.setColumnWidth(2, 170);
  sh.setColumnWidth(3, 80);
  sh.setColumnWidth(4, 120);
  sh.setColumnWidth(5, 160);
  sh.setColumnWidth(6, 480);

  highlightIssues_(sheet, result);
}

function highlightIssues_(sheet, result) {
  var n = result.dataRows;
  if (!n || n < 1 || !result.header || result.header.length === 0) return;

  var width = result.header.length;
  var range = sheet.getRange(2, 1, n, width);
  var backgrounds = range.getBackgrounds();

  for (var r = 0; r < backgrounds.length; r++) {
    for (var c = 0; c < backgrounds[r].length; c++) {
      if (String(backgrounds[r][c]).toLowerCase() === CONFIG.ERROR_FILL.toLowerCase()) {
        backgrounds[r][c] = '';
      }
    }
  }

  result.issues.forEach(function (it) {
    var r = it.row - 2;
    var c = it.colIndex;
    if (r >= 0 && r < n && c >= 0 && c < width) {
      backgrounds[r][c] = CONFIG.ERROR_FILL;
    }
  });

  range.setBackgrounds(backgrounds);
}

function summaryText_(result) {
  var errors = result.issues.filter(function (i) { return i.level === 'error'; }).length;
  var warnings = result.issues.filter(function (i) { return i.level === 'warning'; }).length;

  var text = 'Baris data: ' + result.dataRows + '\n' +
    'Error: ' + errors + '\n' +
    'Peringatan: ' + warnings + '\n\n';

  if (errors > 0) {
    text += 'DITOLAK. Perbaiki semua error, lalu validasi ulang.\n' +
      'Rincian: sheet "' + CONFIG.SHEET_LAPORAN + '".';
  } else if (warnings > 0) {
    text += 'LULUS dengan peringatan. Siap diekspor ke CSV.';
  } else {
    text += 'LULUS. Siap diekspor ke CSV.';
  }
  return text;
}

// =============================================================================
// Setup template
// =============================================================================

function setupTemplate_(ss) {
  var cfg = CONFIG;

  var produk = ensureSheet_(ss, cfg.SHEET_PRODUK);
  var petunjuk = ensureSheet_(ss, cfg.SHEET_PETUNJUK);
  var nilai = ensureSheet_(ss, cfg.SHEET_NILAI);

  // daftar_nilai
  nilai.clear();
  nilai.getRange(1, 1, 1, 4).setValues([['tipe', 'uom', 'status', 'kode_gudang']]);
  nilai.getRange(2, 1, cfg.TYPES.length, 1).setValues(cfg.TYPES.map(function (v) { return [v]; }));
  nilai.getRange(2, 2, cfg.UOM.length, 1).setValues(cfg.UOM.map(function (v) { return [v]; }));
  nilai.getRange(2, 3, cfg.STATUS.length, 1).setValues(cfg.STATUS.map(function (v) { return [v]; }));
  nilai.getRange(2, 4, cfg.DEFAULT_WAREHOUSES.length, 1)
    .setValues(cfg.DEFAULT_WAREHOUSES.map(function (v) { return [v]; }));
  nilai.getRange(1, 1, 1, 4).setFontWeight('bold').setBackground('#EFEFEF');

  // produk
  var wasEmpty = produk.getLastRow() === 0;
  produk.getRange(1, 1, 1, cfg.HEADER.length).setValues([cfg.HEADER]);
  produk.getRange(1, 1, 1, cfg.HEADER.length)
    .setFontWeight('bold')
    .setBackground('#EFEFEF')
    .setVerticalAlignment('middle');

  if (wasEmpty) {
    var samples = [
      ['BRG-00001', 'Sarung Tangan Nitril M', 'consumable', 'box',
        '8991000000017', '8991000000024', '', 10, 'aktif', 'JKT-01', 'Ukuran M'],
      ['BRG-00002', 'Baut M8 x 40 mm', 'spare_part', 'pcs',
        '8991000000031', '', '', 50, 'aktif', 'JKT-01', ''],
      ['BRG-00003', 'Lakban Bening 2 inci', 'consumable', 'roll',
        '8991000000048', '', '', 20, 'nonaktif', 'JKT-01', 'Digantikan BRG-00010']
    ];
    produk.getRange(2, 1, samples.length, cfg.HEADER.length).setValues(samples);
  }

  produk.setFrozenRows(1);
  produk.setColumnWidth(1, 120);
  produk.setColumnWidth(2, 260);
  produk.setColumnWidth(3, 110);
  produk.setColumnWidth(4, 80);
  produk.setColumnWidth(5, 150);
  produk.setColumnWidth(6, 150);
  produk.setColumnWidth(7, 150);
  produk.setColumnWidth(8, 110);
  produk.setColumnWidth(9, 100);
  produk.setColumnWidth(10, 110);
  produk.setColumnWidth(11, 240);

  // Barcode & kode sebagai teks agar leading zero tidak hilang (seluruh kolom,
  // termasuk baris yang ditambahkan setelah template dibuat)
  produk.getRange('A2:A').setNumberFormat('@');
  produk.getRange('E2:G').setNumberFormat('@');

  // Dropdown. Nilai tidak sah tetap boleh diketik/ditempel, lalu ditandai oleh validasi
  // (lebih ramah untuk paste massal daripada menolak input).
  applyValidation_(produk, 'C2:C', nilai.getRange(2, 1, cfg.TYPES.length, 1),
    'Pilih tipe: ' + cfg.TYPES.join(', '));
  applyValidation_(produk, 'D2:D', nilai.getRange(2, 2, cfg.UOM.length, 1),
    'Pilih satuan: ' + cfg.UOM.join(', '));
  applyValidation_(produk, 'I2:I', nilai.getRange(2, 3, cfg.STATUS.length, 1),
    'Pilih status: aktif atau nonaktif');
  applyValidation_(produk, 'J2:J', nilai.getRange(2, 4, Math.max(1, nilai.getLastRow() - 1), 1),
    'Pilih kode gudang dari sheet daftar_nilai kolom D');

  var minRule = SpreadsheetApp.newDataValidation()
    .requireNumberBetween(0, cfg.MAX_MIN_STOCK)
    .setAllowInvalid(true)
    .setHelpText('Bilangan bulat 0 - ' + cfg.MAX_MIN_STOCK + '.')
    .build();
  produk.getRange('H2:H').setDataValidation(minRule);

  // petunjuk
  petunjuk.clear();
  var lines = [
    ['CARA MENGISI'],
    [''],
    ['1. Jangan mengubah nama atau urutan kolom.'],
    ['2. Satu baris = satu produk.'],
    ['3. kode_produk: 3-32 karakter, unik. Contoh: BRG-00001'],
    ['4. Minimal satu barcode (barcode_1). Barcode tidak boleh sama antar produk.'],
    ['5. uom = satuan terkecil (pcs, box, roll, kg, ...).'],
    ['6. status: aktif atau nonaktif. Jangan hapus produk; ubah ke nonaktif.'],
    ['7. stok_minimum: bilangan bulat 0-1.000.000 (boleh kosong = 0).'],
    ['8. keterangan maksimal 200 karakter.'],
    ['9. Jangan memakai formula. Tempel sebagai nilai biasa.'],
    [''],
    ['SETELAH SELESAI'],
    ['A. Menu Produk > Validasi sheet aktif.'],
    ['B. Perbaiki sampai Error = 0 (sel merah = bermasalah).'],
    ['C. Menu Produk > Unduh CSV.'],
    [''],
    ['File CSV hasil unduhan itulah yang diunggah ke aplikasi.'],
    [''],
    ['CATATAN'],
    ['- Barcode & kode diformat sebagai teks agar angka nol di depan tidak hilang.'],
    ['- Daftar gudang diambil dari sheet "daftar_nilai" kolom D.'],
    ['- Menambah tipe/uom baru memerlukan perubahan aplikasi.']
  ];
  petunjuk.getRange(1, 1, lines.length, 1).setValues(lines);
  petunjuk.getRange(1, 1).setFontWeight('bold').setFontSize(12);
  petunjuk.setColumnWidth(1, 620);
  petunjuk.getRange(1, 1, lines.length, 1).setWrap(true);
}

function applyValidation_(sheet, a1Range, sourceRange, helpText) {
  var rule = SpreadsheetApp.newDataValidation()
    .requireValueInRange(sourceRange, true)
    .setAllowInvalid(true)
    .setHelpText(helpText || 'Pilih dari daftar.')
    .build();
  sheet.getRange(a1Range).setDataValidation(rule);
}

function ensureSheet_(ss, name) {
  return ss.getSheetByName(name) || ss.insertSheet(name);
}

// =============================================================================
// Export CSV
// =============================================================================

function buildCsv_(values) {
  return values.map(function (row) {
    return row.map(function (cell) {
      var s = (cell === null || cell === undefined) ? '' : String(cell);
      if (/[",\r\n]/.test(s)) {
        s = '"' + s.replace(/"/g, '""') + '"';
      }
      return s;
    }).join(',');
  }).join('\r\n');
}

// =============================================================================
// Self-test
// =============================================================================

function selfTest_() {
  var header = CONFIG.HEADER.slice();
  var longNote = new Array(CONFIG.MAX_NOTE + 2).join('x');

  var rows = [
    ['', 'Tanpa Kode', 'consumable', 'box', '8991000000105', '', '', 0, 'aktif', 'JKT-01', ''],
    ['BRG 1', 'Spasi Kode', 'consumable', 'box', '8991000000112', '', '', 0, 'aktif', 'JKT-01', ''],
    ['BRG-10', 'Produk A', 'consumable', 'box', '8991000000129', '', '', 0, 'aktif', 'JKT-01', ''],
    ['BRG-10', 'Produk Duplikat', 'consumable', 'box', '8991000000136', '', '', 0, 'aktif', 'JKT-01', ''],
    ['BRG-11', 'Tanpa Barcode', 'consumable', 'box', '', '', '', 0, 'aktif', 'JKT-01', ''],
    ['BRG-12', 'Tipe Salah', 'chemical', 'box', '8991000000143', '', '', 0, 'aktif', 'JKT-01', ''],
    ['BRG-13', 'Uom Salah', 'consumable', 'salah', '8991000000150', '', '', 0, 'aktif', 'JKT-01', ''],
    ['BRG-14', 'Barcode A', 'consumable', 'box', '8991000000167', '', '', 0, 'aktif', 'JKT-01', ''],
    ['BRG-15', 'Barcode B', 'consumable', 'box', '8991000000167', '', '', 0, 'aktif', 'JKT-01', ''],
    ['BRG-16', 'Stok Minus', 'consumable', 'box', '8991000000174', '', '', -5, 'aktif', 'JKT-01', ''],
    ['BRG-17', 'Status Salah', 'consumable', 'box', '8991000000181', '', '', 0, 'aktifkan', 'JKT-01', ''],
    ['BRG-18', 'Gudang Salah', 'consumable', 'box', '8991000000198', '', '', 0, 'aktif', 'JKT-99', ''],
    ['BRG-19', '=SUM(A1:A9)', 'consumable', 'box', '8991000000204', '', '', 0, 'aktif', 'JKT-01', ''],
    ['BRG-20', 'AB', 'consumable', 'box', '8991000000211', '', '', 0, 'aktif', 'JKT-01', ''],
    ['BRG-21', 'Nama Panjang', 'consumable', 'box', '8991000000228', '', '', 0, 'aktif', 'JKT-01', longNote]
  ];

  var expected = [
    'E-CODE-REQUIRED', 'E-CODE-FORMAT', 'E-CODE-DUPLICATE',
    'E-BARCODE-REQUIRED', 'E-TYPE-INVALID', 'E-UOM-INVALID',
    'E-BARCODE-DUPLICATE', 'E-MINSTOCK-RANGE', 'E-STATUS-INVALID',
    'E-WAREHOUSE-INVALID', 'E-CSV-INJECTION', 'E-NAME-LENGTH', 'E-NOTE-LENGTH'
  ];

  var issues = validateProductRows_(header, rows, [], ['JKT-01']);
  var found = issues.map(function (i) { return i.code; });
  var missing = expected.filter(function (code) { return found.indexOf(code) === -1; });

  if (missing.length > 0) {
    return 'GAGAL. Kode tidak terdeteksi: ' + missing.join(', ');
  }
  return 'LULUS. ' + issues.length + ' temuan, semua kode yang diharapkan terdeteksi.';
}
