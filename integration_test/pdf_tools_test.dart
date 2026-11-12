// On-device check of every PDF Toolkit function.
//
// Run with:  flutter test integration_test/pdf_tools_test.dart -d <device-id>
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;
import 'package:pdf/widgets.dart' as pw;

import 'package:docu_scan/core/errors/app_exception.dart';
import 'package:docu_scan/core/image/image_service.dart';
import 'package:docu_scan/core/services/ocr_service.dart';
import 'package:docu_scan/core/services/pdf_service.dart';
import 'package:docu_scan/core/services/pdf_tools_service.dart';
import 'package:docu_scan/core/storage/file_store.dart';
import 'package:docu_scan/data/database/app_database.dart';
import 'package:docu_scan/data/repositories/asset_repository.dart';
import 'package:docu_scan/data/repositories/conversion_repository.dart';
import 'package:docu_scan/data/repositories/document_repository.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  const tools = PdfToolsService();
  late Directory work;
  late FileStore files;
  late AppDatabase db;
  late DocumentRepository docs;
  late ConversionRepository conv;
  late String samplePdf; // 4 pages: "Page N ..."
  late List<String> sampleImages;

  Future<String> write(String name, List<int> bytes) async {
    final f = File(p.join(work.path, name));
    await f.writeAsBytes(bytes, flush: true);
    return f.path;
  }

  Future<String> allText(String path, {String? password}) async => (await tools.extractText(path, password: password)).join('\n');

  setUpAll(() async {
    work = await Directory.systemTemp.createTemp('pdftools_test');
    files = await FileStore.open();
    db = await AppDatabase.open(p.join(work.path, 'test.db'));
    docs = DocumentRepository(db, files, images: const ImageService());
    conv = ConversionRepository(docs, AssetRepository(db, files), files, OcrService());

    final d = pw.Document();
    for (var i = 1; i <= 4; i++) {
      d.addPage(pw.Page(
        build: (_) => pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
          pw.Text('Page $i', style: pw.TextStyle(fontSize: 32)),
          pw.SizedBox(height: 12),
          pw.Text('Hello DocuScan sample text on page $i'),
          pw.Text('Invoice total: ${i * 100} rupees'),
        ]),
      ));
    }
    samplePdf = await write('sample.pdf', await d.save());

    sampleImages = [];
    for (var i = 0; i < 3; i++) {
      final im = img.Image(width: 900, height: 1200);
      img.fill(im, color: img.ColorRgb8(240, 240 - i * 40, 230));
      img.fillRect(im, x1: 100, y1: 150, x2: 800, y2: 260, color: img.ColorRgb8(20, 90, 60));
      sampleImages.add(await write('img_$i.jpg', img.encodeJpg(im, quality: 90)));
    }
  });

  tearDownAll(() async {
    await db.close();
    try {
      await work.delete(recursive: true);
    } catch (_) {}
  });

  testWidgets('sample PDF is readable', (t) async {
    expect(await tools.pageCount(samplePdf), 4);
    expect(await allText(samplePdf), contains('Page 3'));
  });

  testWidgets('Images to PDF', (t) async {
    final out = await conv.imagesToPdf(sampleImages, const PdfExportOptions(), name: 'it_images');
    expect(await out.exists(), isTrue);
    expect(await tools.pageCount(out.path), 3);
  });

  testWidgets('Images to PDF via library document (app flow)', (t) async {
    final doc = await docs.createDocument(title: 'it_doc', pages: [for (final s in sampleImages) PageDraft(s)]);
    expect(doc.pageCount, 3);
  });

  testWidgets('Merge PDFs', (t) async {
    final bytes = await tools.merge([(samplePdf, null), (samplePdf, null)]);
    final out = await write('merged.pdf', bytes);
    expect(await tools.pageCount(out), 8);
    expect(await allText(out), contains('Page 4'));
  });

  testWidgets('Split PDF (select pages 2 and 4)', (t) async {
    final bytes = await tools.selectPages(samplePdf, [1, 3]);
    final out = await write('split.pdf', bytes);
    expect(await tools.pageCount(out), 2);
    final pages = await tools.extractText(out);
    expect(pages[0], contains('Page 2'));
    expect(pages[1], contains('Page 4'));
  });

  testWidgets('Compress PDF', (t) async {
    final bytes = await tools.rasterCompress(samplePdf, dpi: 120, jpegQuality: 65);
    final out = await write('compressed.pdf', bytes);
    expect(await tools.pageCount(out), 4);
  });

  testWidgets('Protect PDF with password', (t) async {
    final bytes = await tools.protect(await File(samplePdf).readAsBytes(), 'secret123');
    final out = await write('protected.pdf', bytes);
    expect(await tools.needsPassword(out), isTrue);
    expect(await tools.pageCount(out, password: 'secret123'), 4);
  });

  testWidgets('Unlock PDF: correct and wrong password', (t) async {
    final prot = await write('protected2.pdf', await tools.protect(await File(samplePdf).readAsBytes(), 'secret123'));
    final unlocked = await write('unlocked.pdf', await tools.unlock(prot, 'secret123'));
    expect(await tools.needsPassword(unlocked), isFalse);
    expect(await tools.pageCount(unlocked), 4);
    expect(await allText(unlocked), contains('Page 1'));

    Object? error;
    try {
      await tools.unlock(prot, 'wrong');
    } catch (e) {
      error = e;
    }
    expect(error, isNotNull, reason: 'wrong password must fail');
    expect(describeError(error!), isNot(contains('Instance of')), reason: 'error message should be readable: ${describeError(error)}');
  });

  testWidgets('PDF to Text', (t) async {
    final out = await conv.pdfToTxt(samplePdf);
    final txt = await out.readAsString();
    expect(txt, contains('Hello DocuScan'));
    expect(txt, contains('Page 4'));
  });

  Future<void> roundTrip(String kind, Future<File> Function() toOffice, String part) async {
    final office = await toOffice();
    expect(await office.exists(), isTrue, reason: '$kind file written');
    final zip = ZipDecoder().decodeBytes(await office.readAsBytes());
    expect(zip.findFile(part), isNotNull, reason: '$kind contains $part');
    final back = await conv.officeToPdf(office.path);
    expect(await tools.pageCount(back.path), greaterThan(0), reason: '$kind converts back to PDF');
  }

  testWidgets('PDF to Word, and Word to PDF', (t) async {
    await roundTrip('DOCX', () => conv.pdfToDocx(samplePdf), 'word/document.xml');
    final docx = await conv.pdfToDocx(samplePdf);
    final xml = String.fromCharCodes(ZipDecoder().decodeBytes(await docx.readAsBytes()).findFile('word/document.xml')!.content);
    expect(xml, contains('Hello DocuScan'));
  });

  testWidgets('PDF to Excel, and Excel to PDF', (t) async {
    await roundTrip('XLSX', () => conv.pdfToXlsx(samplePdf), 'xl/workbook.xml');
  });

  testWidgets('PDF to PowerPoint, and PowerPoint to PDF', (t) async {
    await roundTrip('PPTX', () => conv.pdfToPptx(samplePdf), 'ppt/presentation.xml');
  });

  testWidgets('Text file to PDF', (t) async {
    final txt = await write('notes.txt', 'Line one\nLine two — unicode ✓\n'.codeUnits.isEmpty ? [] : Uint8List.fromList('Line one\nLine two\n'.codeUnits));
    final out = await conv.txtToPdf(txt);
    expect(await tools.pageCount(out.path), greaterThan(0));
    expect(await allText(out.path), contains('Line two'));
  });

  testWidgets('Import PDF into library', (t) async {
    final doc = await conv.importPdf(samplePdf, title: 'it_import');
    expect(doc.pageCount, 4);
  });

  testWidgets('Legacy .doc is rejected with a clear message', (t) async {
    final legacy = await write('old.doc', [0xD0, 0xCF, 0x11, 0xE0]);
    Object? error;
    try {
      await conv.officeToPdf(legacy);
    } catch (e) {
      error = e;
    }
    expect(error, isA<AppException>());
  });
}
