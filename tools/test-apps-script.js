// Harness uji Code.gs (Apps Script) memakai JScript Windows Script Host.
// Jalankan: cscript //nologo tools\test-apps-script.js
// Tidak memanggil Google API: hanya validateProductRows_, buildCsv_, selfTest_.

var fso = new ActiveXObject("Scripting.FileSystemObject");
var TOOLS_DIR = fso.GetParentFolderName(WScript.ScriptFullName);
var ROOT_DIR = fso.GetParentFolderName(TOOLS_DIR);
var CODE_PATH = fso.BuildPath(fso.BuildPath(ROOT_DIR, "apps-script"), "Code.gs");
var src = fso.OpenTextFile(CODE_PATH, 1).ReadAll();

// ---------- polyfill ES5 minimal yang dipakai Code.gs ----------
if (!Array.prototype.indexOf) {
  Array.prototype.indexOf = function (v, from) {
    var start = from || 0;
    for (var i = start; i < this.length; i++) if (this[i] === v) return i;
    return -1;
  };
}
if (!Array.prototype.map) {
  Array.prototype.map = function (fn) {
    var out = [];
    for (var i = 0; i < this.length; i++) out.push(fn(this[i], i, this));
    return out;
  };
}
if (!Array.prototype.filter) {
  Array.prototype.filter = function (fn) {
    var out = [];
    for (var i = 0; i < this.length; i++) if (fn(this[i], i, this)) out.push(this[i]);
    return out;
  };
}
if (!Array.prototype.forEach) {
  Array.prototype.forEach = function (fn) {
    for (var i = 0; i < this.length; i++) fn(this[i], i, this);
  };
}
if (!String.prototype.trim) {
  String.prototype.trim = function () {
    return this.replace(/^[\s\u00a0]+|[\s\u00a0]+$/g, "");
  };
}
if (!Object.keys) {
  Object.keys = function (o) {
    var out = [];
    for (var k in o) if (Object.prototype.hasOwnProperty.call(o, k)) out.push(k);
    return out;
  };
}

// ---------- muat kode yang diuji ----------
eval(src);

// ---------- util ----------
var failures = 0;
function check(name, ok, detail) {
  if (ok) {
    WScript.Echo("PASS  " + name);
  } else {
    failures++;
    WScript.Echo("FAIL  " + name + (detail ? "  -> " + detail : ""));
  }
}
function repeat(s, n) {
  return new Array(n + 1).join(s);
}
function sig(issues) {
  return issues.map(function (i) { return i.row + "|" + i.code; }).join(", ");
}

// ---------- fixture: 15 baris dari product-import-invalid-sample.csv ----------
var longNote = repeat("x", 259);
var invalidRows = [
  ["", "Tanpa Kode", "consumable", "box", "8991000000105", "", "", 0, "aktif", "JKT-01", ""],
  ["BRG 00010", "Spasi di kode", "consumable", "box", "8991000000112", "", "", 0, "aktif", "JKT-01", ""],
  ["BRG-00010", "Produk A", "consumable", "box", "8991000000129", "", "", 0, "aktif", "JKT-01", ""],
  ["BRG-00010", "Produk A duplikat", "consumable", "box", "8991000000136", "", "", 0, "aktif", "JKT-01", ""],
  ["BRG-00011", "Tanpa Barcode", "consumable", "box", "", "", "", 0, "aktif", "JKT-01", ""],
  ["BRG-00012", "Produk Tipe Salah", "chemical", "box", "8991000000143", "", "", "", "aktif", "JKT-01", ""],
  ["BRG-00013", "Uom Salah", "consumable", "salah", "8991000000150", "", "", 0, "aktif", "JKT-01", ""],
  ["BRG-00014", "Barcode Ganda A", "consumable", "box", "8991000000167", "", "", 0, "aktif", "JKT-01", ""],
  ["BRG-00015", "Barcode Ganda B", "consumable", "box", "8991000000167", "", "", 0, "aktif", "JKT-01", ""],
  ["BRG-00016", "Stok Minus", "consumable", "box", "8991000000174", "", "", -5, "aktif", "JKT-01", ""],
  ["BRG-00017", "Status Salah", "consumable", "box", "8991000000181", "", "", 0, "aktifkan", "JKT-01", ""],
  ["BRG-00018", "Gudang Salah", "consumable", "box", "8991000000198", "", "", 0, "aktif", "JKT-99", ""],
  ["BRG-00019", "=SUM(A1:A9)", "consumable", "box", "8991000000204", "", "", 0, "aktif", "JKT-01", ""],
  ["BRG-00020", "AB", "consumable", "box", "8991000000211", "", "", 0, "aktif", "JKT-01", ""],
  ["BRG-00021", "Nama Panjang", "consumable", "box", "8991000000228", "", "", 0, "aktif", "JKT-01", longNote]
];

var expected = [
  "2|E-CODE-REQUIRED", "3|E-CODE-FORMAT", "5|E-CODE-DUPLICATE", "6|E-BARCODE-REQUIRED",
  "7|E-TYPE-INVALID", "8|E-UOM-INVALID", "10|E-BARCODE-DUPLICATE", "11|E-MINSTOCK-RANGE",
  "12|E-STATUS-INVALID", "13|E-WAREHOUSE-INVALID", "14|E-CSV-INJECTION", "15|E-NAME-LENGTH",
  "16|E-NOTE-LENGTH"
].join(", ");

var got = validateProductRows_(CONFIG.HEADER, invalidRows, [], ["JKT-01"]);
var errorsOnly = got.filter(function (i) { return i.level === "error"; });
check("invalid sample: 13 error", errorsOnly.length === 13, "dapat " + errorsOnly.length);
check("invalid sample: kode+baris persis sama dengan validator PowerShell",
  sig(errorsOnly) === expected,
  "\n  harap: " + expected + "\n  dapat: " + sig(errorsOnly));

// ---------- fixture: 3 baris valid dari template ----------
var validRows = [
  ["BRG-00001", "Sarung Tangan Nitril M", "consumable", "box", "8991000000017", "8991000000024", "", 10, "aktif", "JKT-01", "Ukuran M"],
  ["BRG-00002", "Baut M8 x 40 mm", "spare_part", "pcs", "8991000000031", "", "", 50, "aktif", "JKT-01", ""],
  ["BRG-00003", "Lakban Bening 2 inci", "consumable", "roll", "8991000000048", "", "", 20, "nonaktif", "JKT-01", "Digantikan BRG-00010"]
];
var validIssues = validateProductRows_(CONFIG.HEADER, validRows, [], ["JKT-01"]);
check("template: 0 temuan", validIssues.length === 0, sig(validIssues));

// ---------- normalisasi ----------
var normIssues = validateProductRows_(CONFIG.HEADER, [
  [" brg-00099 ", "  Produk Normalisasi  ", "  CONSUMABLE  ", " BOX ", " 8991000000900 ", "", "", " 7 ", " AKTIF ", " jkt-01 ", " aman "]
], [], ["JKT-01"]);
check("normalisasi: huruf besar/kecil & spasi diterima", normIssues.length === 0, sig(normIssues));

// ---------- baris kosong dilewati ----------
var blankIssues = validateProductRows_(CONFIG.HEADER, [
  ["BRG-00050", "Produk Satu", "consumable", "box", "8991000000500", "", "", 0, "aktif", "JKT-01", ""],
  ["", "", "", "", "", "", "", "", "", "", ""],
  ["", "   ", "", "", "", "", "", "", "", "", ""],
  ["BRG-00051", "Produk Dua", "consumable", "box", "8991000000511", "", "", 0, "aktif", "JKT-01", ""]
], [], ["JKT-01"]);
check("baris kosong tidak menghasilkan error", blankIssues.length === 0, sig(blankIssues));

// ---------- formula di sel ----------
var formulaRows = [
  ["", "", "", "", "", "", "", "", "", "", ""],
  ["", "", "", "", '=CONCAT("899","1000000600")', "", "", "", "", "", ""]
];
var formulaIssues = validateProductRows_(CONFIG.HEADER, [
  ["BRG-00060", "Produk Formula", "consumable", "box", "8991000000600", "", "", 0, "aktif", "JKT-01", ""],
  ["BRG-00061", "Produk Formula 2", "consumable", "box", "8991000000600", "", "", 0, "aktif", "JKT-01", ""]
], formulaRows, ["JKT-01"]);
var hasFormula = formulaIssues.filter(function (i) { return i.code === "E-CSV-INJECTION"; }).length;
check("formula di sel barcode ditolak", hasFormula === 1, sig(formulaIssues));

// ---------- barcode berulang dalam satu produk = warning ----------
var selfIssues = validateProductRows_(CONFIG.HEADER, [
  ["BRG-00070", "Produk Barcode Ganda", "consumable", "box", "8991000000700", "8991000000700", "", 0, "aktif", "JKT-01", ""]
], [], ["JKT-01"]);
check("barcode sama dalam satu produk: 1 warning, 0 error",
  selfIssues.length === 1 && selfIssues[0].code === "W-BARCODE-SELF" && selfIssues[0].level === "warning",
  sig(selfIssues));

// ---------- gudang dinamis ----------
var whIssues = validateProductRows_(CONFIG.HEADER, [
  ["BRG-00080", "Produk Gudang Dua", "consumable", "box", "8991000000800", "", "", 0, "aktif", "JKT-02", ""]
], [], ["JKT-01", "JKT-02"]);
check("gudang tambahan diterima", whIssues.length === 0, sig(whIssues));

// ---------- self-test bawaan ----------
var st = selfTest_();
check("selfTest_() LULUS", st.indexOf("LULUS") === 0, st);

// ---------- CSV export ----------
var csv = buildCsv_([
  ["kode_produk", "nama_produk"],
  ["BRG-1", 'Kabel "NYM" 2x1.5, hitam'],
  ["BRG-2", "Baris\nbaru"]
]);
check("buildCsv_: quote & newline di-escape",
  csv === 'kode_produk,nama_produk\r\nBRG-1,"Kabel ""NYM"" 2x1.5, hitam"\r\nBRG-2,"Baris\nbaru"',
  csv);

WScript.Echo("");
WScript.Echo(failures === 0 ? "SEMUA UJI LULUS" : failures + " UJI GAGAL");
WScript.Quit(failures === 0 ? 0 : 1);
