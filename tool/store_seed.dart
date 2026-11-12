// Realistic sample documents for Play Store screenshots.
//
// Usage: build and install with this entry point once, then reinstall the
// normal app with `adb install -r` (data is kept):
//   flutter build apk --debug -t tool/store_seed.dart
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import 'package:docu_scan/core/image/image_service.dart';
import 'package:docu_scan/core/services/ocr_service.dart';
import 'package:docu_scan/core/storage/file_store.dart';
import 'package:docu_scan/data/database/app_database.dart';
import 'package:docu_scan/data/repositories/asset_repository.dart';
import 'package:docu_scan/data/repositories/conversion_repository.dart';
import 'package:docu_scan/data/repositories/document_repository.dart';
import 'package:docu_scan/data/repositories/folder_repository.dart';
import 'package:docu_scan/main.dart' as app;

const _green = PdfColor.fromInt(0xFF1E7054);
const _ink = PdfColor.fromInt(0xFF1A2420);
const _grey = PdfColor.fromInt(0xFF6B7470);
const _line = PdfColor.fromInt(0xFFE3E7E4);

pw.Widget _header(String brand, String title, String sub) => pw.Row(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
      children: [
        pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
          pw.Text(brand, style: pw.TextStyle(fontSize: 20, fontWeight: pw.FontWeight.bold, color: _green)),
          pw.SizedBox(height: 4),
          pw.Text('12 MG Road, Bengaluru 560001', style: const pw.TextStyle(fontSize: 9, color: _grey)),
        ]),
        pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.end, children: [
          pw.Text(title, style: pw.TextStyle(fontSize: 22, fontWeight: pw.FontWeight.bold, color: _ink)),
          pw.Text(sub, style: const pw.TextStyle(fontSize: 10, color: _grey)),
        ]),
      ],
    );

pw.Widget _para(String t) => pw.Padding(
      padding: const pw.EdgeInsets.only(bottom: 8),
      child: pw.Text(t, style: const pw.TextStyle(fontSize: 10.5, lineSpacing: 3, color: _ink)),
    );

Future<List<int>> invoice() async {
  final d = pw.Document();
  final rows = [
    ['Website redesign', '1', '45,000'],
    ['Mobile app UI kit', '1', '28,000'],
    ['Brand guidelines', '1', '12,500'],
    ['Hosting (12 months)', '1', '6,000'],
  ];
  d.addPage(pw.Page(
    pageFormat: PdfPageFormat.a4,
    margin: const pw.EdgeInsets.all(40),
    build: (_) => pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
      _header('Northwind Studio', 'INVOICE', '#INV-2026-0418'),
      pw.SizedBox(height: 30),
      pw.Row(mainAxisAlignment: pw.MainAxisAlignment.spaceBetween, children: [
        pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
          pw.Text('BILL TO', style: const pw.TextStyle(fontSize: 9, color: _grey)),
          pw.Text('Riverside Traders Pvt Ltd', style: pw.TextStyle(fontWeight: pw.FontWeight.bold)),
          pw.Text('Pune, Maharashtra', style: const pw.TextStyle(fontSize: 10)),
        ]),
        pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.end, children: [
          pw.Text('Issued: 04 Nov 2026', style: const pw.TextStyle(fontSize: 10)),
          pw.Text('Due: 18 Nov 2026', style: const pw.TextStyle(fontSize: 10)),
        ]),
      ]),
      pw.SizedBox(height: 24),
      pw.TableHelper.fromTextArray(
        headers: ['Description', 'Qty', 'Amount (INR)'],
        data: rows,
        headerStyle: pw.TextStyle(color: PdfColors.white, fontWeight: pw.FontWeight.bold, fontSize: 10),
        headerDecoration: const pw.BoxDecoration(color: _green),
        cellStyle: const pw.TextStyle(fontSize: 10),
        cellAlignments: {1: pw.Alignment.center, 2: pw.Alignment.centerRight},
        rowDecoration: const pw.BoxDecoration(border: pw.Border(bottom: pw.BorderSide(color: _line))),
        cellPadding: const pw.EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      ),
      pw.SizedBox(height: 16),
      pw.Align(
        alignment: pw.Alignment.centerRight,
        child: pw.Container(
          padding: const pw.EdgeInsets.all(12),
          color: const PdfColor.fromInt(0xFFEAF4EF),
          child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.end, children: [
            pw.Text('Subtotal  91,500', style: const pw.TextStyle(fontSize: 10)),
            pw.Text('GST 18%  16,470', style: const pw.TextStyle(fontSize: 10)),
            pw.SizedBox(height: 4),
            pw.Text('Total  INR 1,07,970', style: pw.TextStyle(fontSize: 14, fontWeight: pw.FontWeight.bold, color: _green)),
          ]),
        ),
      ),
      pw.Spacer(),
      pw.Text('Thank you for your business. Payment via bank transfer within 14 days.', style: const pw.TextStyle(fontSize: 9, color: _grey)),
    ]),
  ));
  return d.save();
}

Future<List<int>> agreement() async {
  final d = pw.Document();
  for (var page = 1; page <= 3; page++) {
    d.addPage(pw.Page(
      pageFormat: PdfPageFormat.a4,
      margin: const pw.EdgeInsets.all(48),
      build: (_) => pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
        if (page == 1) ...[
          pw.Center(child: pw.Text('RESIDENTIAL RENTAL AGREEMENT', style: pw.TextStyle(fontSize: 18, fontWeight: pw.FontWeight.bold))),
          pw.SizedBox(height: 6),
          pw.Center(child: pw.Text('Flat 4B, Lakeview Residency, Bengaluru', style: const pw.TextStyle(fontSize: 10, color: _grey))),
          pw.SizedBox(height: 24),
        ],
        pw.Text('Clause ${page * 3 - 2}. Term of tenancy', style: pw.TextStyle(fontWeight: pw.FontWeight.bold)),
        pw.SizedBox(height: 6),
        _para('This agreement is made between the Owner and the Tenant for a period of eleven (11) months commencing on the first day of December 2026. '
            'The tenancy may be renewed by mutual written consent of both parties on revised terms.'),
        pw.Text('Clause ${page * 3 - 1}. Rent and deposit', style: pw.TextStyle(fontWeight: pw.FontWeight.bold)),
        pw.SizedBox(height: 6),
        _para('The Tenant shall pay a monthly rent of INR 32,000 on or before the fifth day of each month. A refundable security deposit of INR 1,00,000 '
            'has been received by the Owner and will be returned at the end of the tenancy after deducting any dues.'),
        pw.Text('Clause ${page * 3}. Maintenance', style: pw.TextStyle(fontWeight: pw.FontWeight.bold)),
        pw.SizedBox(height: 6),
        _para('Routine maintenance and minor repairs shall be borne by the Tenant. Structural repairs, society charges and property taxes '
            'remain the responsibility of the Owner. The Tenant shall keep the premises clean and in good condition.'),
        _para('Both parties agree to the terms set out above and have signed this agreement in the presence of witnesses.'),
        pw.Spacer(),
        if (page == 3)
          pw.Row(mainAxisAlignment: pw.MainAxisAlignment.spaceBetween, children: [
            pw.Text('_____________________\nOwner', style: const pw.TextStyle(fontSize: 10)),
            pw.Text('_____________________\nTenant', style: const pw.TextStyle(fontSize: 10)),
          ]),
        pw.Align(alignment: pw.Alignment.centerRight, child: pw.Text('Page $page of 3', style: const pw.TextStyle(fontSize: 9, color: _grey))),
      ]),
    ));
  }
  return d.save();
}

Future<List<int>> receipt(String shop, List<List<String>> items, String total) async {
  final d = pw.Document();
  d.addPage(pw.Page(
    pageFormat: const PdfPageFormat(80 * PdfPageFormat.mm, 150 * PdfPageFormat.mm, marginAll: 6 * PdfPageFormat.mm),
    build: (_) => pw.Column(children: [
      pw.Text(shop, style: pw.TextStyle(fontSize: 14, fontWeight: pw.FontWeight.bold)),
      pw.Text('GSTIN 29ABCDE1234F1Z5', style: const pw.TextStyle(fontSize: 7)),
      pw.Text('09 Nov 2026  18:42', style: const pw.TextStyle(fontSize: 7)),
      pw.Divider(),
      for (final it in items)
        pw.Row(mainAxisAlignment: pw.MainAxisAlignment.spaceBetween, children: [
          pw.Text(it[0], style: const pw.TextStyle(fontSize: 8)),
          pw.Text(it[1], style: const pw.TextStyle(fontSize: 8)),
        ]),
      pw.Divider(),
      pw.Row(mainAxisAlignment: pw.MainAxisAlignment.spaceBetween, children: [
        pw.Text('TOTAL', style: pw.TextStyle(fontSize: 10, fontWeight: pw.FontWeight.bold)),
        pw.Text(total, style: pw.TextStyle(fontSize: 10, fontWeight: pw.FontWeight.bold)),
      ]),
      pw.SizedBox(height: 10),
      pw.Text('Thank you! Visit again', style: const pw.TextStyle(fontSize: 8)),
    ]),
  ));
  return d.save();
}

Future<List<int>> notes() async {
  final d = pw.Document();
  d.addPage(pw.Page(
    pageFormat: PdfPageFormat.a4,
    margin: const pw.EdgeInsets.all(48),
    build: (_) => pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
      pw.Text('Product sync - meeting notes', style: pw.TextStyle(fontSize: 20, fontWeight: pw.FontWeight.bold, color: _green)),
      pw.Text('Thursday, 06 Nov 2026 · 10:00', style: const pw.TextStyle(fontSize: 10, color: _grey)),
      pw.SizedBox(height: 18),
      pw.Text('Agenda', style: pw.TextStyle(fontSize: 13, fontWeight: pw.FontWeight.bold)),
      for (final a in ['Q4 launch timeline', 'Offline OCR accuracy', 'Onboarding flow review', 'Play Store listing'])
        pw.Bullet(text: a, style: const pw.TextStyle(fontSize: 11)),
      pw.SizedBox(height: 12),
      pw.Text('Decisions', style: pw.TextStyle(fontSize: 13, fontWeight: pw.FontWeight.bold)),
      _para('Ship the redesigned scanner in the next release. Keep every feature fully offline. Add Hindi and Marathi OCR to the language picker.'),
      pw.Text('Action items', style: pw.TextStyle(fontSize: 13, fontWeight: pw.FontWeight.bold)),
      for (final a in ['Priya — finalise store screenshots', 'Arjun — test PDF tools on low-end devices', 'Meera — write release notes'])
        pw.Bullet(text: a, style: const pw.TextStyle(fontSize: 11)),
    ]),
  ));
  return d.save();
}

Future<List<int>> certificate() async {
  final d = pw.Document();
  d.addPage(pw.Page(
    pageFormat: PdfPageFormat.a4.landscape,
    margin: const pw.EdgeInsets.all(28),
    build: (_) => pw.Container(
      decoration: pw.BoxDecoration(border: pw.Border.all(color: _green, width: 6)),
      padding: const pw.EdgeInsets.all(36),
      child: pw.Column(mainAxisAlignment: pw.MainAxisAlignment.center, children: [
        pw.Text('CERTIFICATE OF COMPLETION', style: pw.TextStyle(fontSize: 28, fontWeight: pw.FontWeight.bold, color: _green, letterSpacing: 2)),
        pw.SizedBox(height: 18),
        pw.Text('This is to certify that', style: const pw.TextStyle(fontSize: 13, color: _grey)),
        pw.SizedBox(height: 10),
        pw.Text('Ananya Sharma', style: pw.TextStyle(fontSize: 34, fontWeight: pw.FontWeight.bold)),
        pw.SizedBox(height: 10),
        pw.Text('has successfully completed the Advanced Data Analytics programme', style: const pw.TextStyle(fontSize: 13)),
        pw.SizedBox(height: 30),
        pw.Text('Awarded on 30 October 2026', style: const pw.TextStyle(fontSize: 11, color: _grey)),
      ]),
    ),
  ));
  return d.save();
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await seedStoreContent();
  await app.main();
}

/// Adds sample folders and documents once (skipped if documents exist).
Future<void> seedStoreContent() async {
  final supportDir = await getApplicationSupportDirectory();
  final db = await AppDatabase.open(p.join(supportDir.path, 'docscanner.db'));
  final files = await FileStore.open();
  final docs = DocumentRepository(db, files, images: const ImageService());
  if ((await docs.stats()).documents > 0) {
    await db.close();
    return;
  }
  final folders = FolderRepository(db);
  final conv = ConversionRepository(docs, AssetRepository(db, files), files, OcrService());

  Future<String> folder(String name, int color) async => (await folders.findByName(name) ?? await folders.create(name, color: color)).id;
  final work = await folder('Work', 0xFF3466C9);
  final finance = await folder('Finance', 0xFF1E7054);
  final personal = await folder('Personal', 0xFFC03A6B);
  final receipts = await folder('Receipts', 0xFFB4532A);

  final tmp = await Directory.systemTemp.createTemp('seed');
  Future<String> save(String name, List<int> bytes) async {
    final f = File(p.join(tmp.path, name));
    await f.writeAsBytes(bytes, flush: true);
    return f.path;
  }

  final seeded = [
    await conv.importPdf(await save('cert.pdf', await certificate()), title: 'Course Certificate', folderId: personal),
    await conv.importPdf(await save('r2.pdf', await receipt('FRESH MART', [['Milk 1L', '68'], ['Bread', '45'], ['Apples 1kg', '180'], ['Coffee', '420']], 'INR 713')), title: 'Grocery receipt', folderId: receipts),
    await conv.importPdf(await save('r1.pdf', await receipt('CAFE BLOOM', [['Cappuccino', '220'], ['Croissant', '160'], ['Water', '40']], 'INR 420')), title: 'Cafe receipt', folderId: receipts),
    await conv.importPdf(await save('notes.pdf', await notes()), title: 'Meeting notes', folderId: work),
    await conv.importPdf(await save('agreement.pdf', await agreement()), title: 'Rental Agreement', folderId: personal),
    await conv.importPdf(await save('invoice.pdf', await invoice()), title: 'Invoice INV-0418', folderId: finance),
  ];
  for (final d in seeded) {
    if (d.title.startsWith('Invoice') || d.title.startsWith('Rental')) await docs.setFavorite(d.id, true);
  }
  await db.close();
}
