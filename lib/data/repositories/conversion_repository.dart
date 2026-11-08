import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:pdf/widgets.dart' as pw;

import '../../core/errors/app_exception.dart';
import '../../core/image/image_service.dart';
import '../../core/services/ocr_service.dart';
import '../../core/services/office_converter.dart';
import '../../core/services/pdf_service.dart';
import '../../core/services/pdf_tools_service.dart';
import '../../core/storage/file_store.dart';
import '../../core/storage/settings_store.dart';
import '../../core/utils/formatters.dart';
import '../models/models.dart';
import 'asset_repository.dart';
import 'document_repository.dart';

typedef StepProgress = void Function(String message, double? fraction);

/// File conversions and imports. Everything runs locally; scanned PDFs
/// without a text layer fall back to on-device OCR.
class ConversionRepository {
  ConversionRepository(this._docs, this._assets, this._files, this._ocr,
      {this.tools = const PdfToolsService(), this.pdf = const PdfService(), this.images = const ImageService()});

  final DocumentRepository _docs;
  final AssetRepository _assets;
  final FileStore _files;
  final OcrService? _ocr;
  final PdfToolsService tools;
  final PdfService pdf;
  final ImageService images;

  /// Writes bytes to Exports/ with a unique name.
  Future<File> saveOutput(Uint8List bytes, String fileName) async {
    final dir = _files.exports;
    await dir.create(recursive: true);
    final ext = p.extension(fileName);
    final stem = sanitizeFileName(p.basenameWithoutExtension(fileName));
    var path = p.join(dir.path, '$stem$ext');
    var i = 2;
    while (await File(path).exists()) {
      path = p.join(dir.path, '$stem ($i)$ext');
      i++;
    }
    final f = await _files.writeAtomic(path, bytes);
    await _docs.logExport(title: p.basename(path), format: ext.replaceAll('.', '').toUpperCase(), target: 'file', path: _files.rel(path));
    return f;
  }

  // ------------------------------------------------------------- imports

  /// Imports a PDF into the library: pages are rasterised (so they can be
  /// edited, annotated and enhanced) and any existing text layer is kept as
  /// searchable text.
  Future<Document> importPdf(String path, {String? password, String? title, String? folderId, StepProgress? onProgress}) async {
    final tmp = await _files.newTempDir();
    try {
      final drafts = <PageDraft>[];
      await for (final page in tools.renderPages(path, password: password, dpi: 200)) {
        onProgress?.call('Rendering page ${page.index + 1}', null);
        final jpg = await images.encodeBgra(page.bgra, page.width, page.height, quality: 90);
        final f = File(p.join(tmp.path, 'p${page.index}.jpg'));
        await f.writeAsBytes(jpg, flush: true);
        drafts.add(PageDraft(f.path, preProcessed: true));
      }
      if (drafts.isEmpty) throw const AppException('The PDF has no pages.');
      final doc = await _docs.createDocument(
        title: title ?? p.basenameWithoutExtension(path),
        pages: drafts,
        folderId: folderId,
        source: 'import_pdf',
        onProgress: (d, t) => onProgress?.call('Saving page $d of $t', d / t),
      );
      try {
        final texts = await tools.extractText(path, password: password);
        final pages = await _docs.getPages(doc.id);
        for (var i = 0; i < pages.length && i < texts.length; i++) {
          if (texts[i].trim().isEmpty) continue;
          await _assets.saveOcr(pageId: pages[i].id, documentId: doc.id, script: 'pdf', text: texts[i].trim(), edited: true);
        }
      } catch (_) {
        // Text extraction is best-effort; the visual import already succeeded.
      }
      return doc;
    } finally {
      await tmp.delete(recursive: true);
    }
  }

  // ------------------------------------------------------- PDF → others

  /// Text per page; pages without a text layer are OCR'd when [ocrFallback].
  Future<List<String>> pdfTextPerPage(String path, {String? password, bool ocrFallback = true, OcrLanguage language = OcrLanguage.latin, StepProgress? onProgress}) async {
    final texts = await tools.extractText(path, password: password);
    final missing = [for (var i = 0; i < texts.length; i++) if (texts[i].trim().isEmpty) i];
    if (missing.isEmpty || !ocrFallback || _ocr == null) return texts;
    final tmp = await _files.newTempDir();
    try {
      await for (final page in tools.renderPages(path, password: password, dpi: 220, pages: missing)) {
        onProgress?.call('Recognising text on page ${page.index + 1}', (missing.indexOf(page.index) + 1) / missing.length);
        final jpg = await images.encodeBgra(page.bgra, page.width, page.height, quality: 92);
        final f = File(p.join(tmp.path, 'ocr${page.index}.jpg'))..writeAsBytesSync(jpg);
        final out = await _ocr.recognizeFile(f.path, language: language, width: page.width, height: page.height);
        texts[page.index] = out.text;
      }
    } finally {
      await tmp.delete(recursive: true);
    }
    return texts;
  }

  Future<File> pdfToTxt(String path, {String? password, OcrLanguage language = OcrLanguage.latin, StepProgress? onProgress}) async {
    final texts = await pdfTextPerPage(path, password: password, language: language, onProgress: onProgress);
    final buffer = StringBuffer();
    for (var i = 0; i < texts.length; i++) {
      if (texts.length > 1) buffer.writeln('--- Page ${i + 1} ---');
      buffer.writeln(texts[i].trim());
      buffer.writeln();
    }
    return saveOutput(Uint8List.fromList(utf8.encode(buffer.toString())), '${p.basenameWithoutExtension(path)}.txt');
  }

  static List<String> _paragraphs(String text) => text
      .replaceAll('\r\n', '\n')
      .split(RegExp(r'\n\s*\n'))
      .map((e) => e.trim())
      .where((e) => e.isNotEmpty)
      .toList();

  /// [includePageImages] embeds each rendered page above its text, so the
  /// visual content is preserved even where text is not.
  Future<File> pdfToDocx(String path, {String? password, bool includePageImages = false, OcrLanguage language = OcrLanguage.latin, StepProgress? onProgress}) async {
    final texts = await pdfTextPerPage(path, password: password, language: language, onProgress: onProgress);
    final pages = <DocxPage>[];
    if (includePageImages) {
      await for (final r in tools.renderPages(path, password: password, dpi: 130)) {
        onProgress?.call('Rendering page ${r.index + 1}', null);
        final jpg = await images.encodeBgra(r.bgra, r.width, r.height, quality: 80);
        pages.add(DocxPage(paragraphs: _paragraphs(texts[r.index]), image: jpg, imageWidth: r.width, imageHeight: r.height));
      }
    } else {
      pages.addAll(texts.map((t) => DocxPage(paragraphs: _paragraphs(t))));
    }
    final title = p.basenameWithoutExtension(path);
    final bytes = await Isolate.run(() => OfficeConverter.buildDocx(pages, title: title));
    return saveOutput(bytes, '$title.docx');
  }

  /// One sheet per page; columns are split on tabs or runs of 2+ spaces.
  Future<File> pdfToXlsx(String path, {String? password, OcrLanguage language = OcrLanguage.latin, StepProgress? onProgress}) async {
    final texts = await pdfTextPerPage(path, password: password, language: language, onProgress: onProgress);
    final sheets = [
      for (var i = 0; i < texts.length; i++)
        SheetData('Page ${i + 1}', [
          for (final line in texts[i].split('\n'))
            if (line.trim().isNotEmpty) line.trim().split(RegExp(r'\t| {2,}')).map((c) => c.trim()).toList(),
        ]),
    ];
    final title = p.basenameWithoutExtension(path);
    final bytes = await Isolate.run(() => OfficeConverter.buildXlsx(sheets));
    return saveOutput(bytes, '$title.xlsx');
  }

  Future<File> pdfToPptx(String path, {String? password, StepProgress? onProgress}) async {
    final slides = <PptxSlideImage>[];
    await for (final r in tools.renderPages(path, password: password, dpi: 150)) {
      onProgress?.call('Rendering page ${r.index + 1}', null);
      slides.add(PptxSlideImage(await images.encodeBgra(r.bgra, r.width, r.height, quality: 85), r.width, r.height));
    }
    final title = p.basenameWithoutExtension(path);
    final bytes = await Isolate.run(() => OfficeConverter.buildPptx(slides, title: title));
    return saveOutput(bytes, '$title.pptx');
  }

  Future<List<File>> pdfToImages(String path, {String? password, bool png = false, double dpi = 150, List<int>? pages, StepProgress? onProgress}) async {
    final out = <File>[];
    final stem = p.basenameWithoutExtension(path);
    await for (final r in tools.renderPages(path, password: password, dpi: dpi, pages: pages)) {
      onProgress?.call('Rendering page ${r.index + 1}', null);
      final bytes = await images.encodeBgra(r.bgra, r.width, r.height, png: png, quality: 90);
      out.add(await saveOutput(bytes, '${stem}_${r.index + 1}.${png ? 'png' : 'jpg'}'));
    }
    return out;
  }

  // ------------------------------------------------------- others → PDF

  Future<File> officeToPdf(String path) async {
    final ext = p.extension(path).toLowerCase();
    final bytes = await File(path).readAsBytes();
    final fonts = await PdfFonts.load();
    final regular = fonts.regular, deva = fonts.devanagari;
    final out = await Isolate.run(() async {
      pw.ThemeData? theme;
      if (regular != null) {
        final base = pw.Font.ttf(ByteData.sublistView(regular));
        theme = pw.ThemeData.withFont(base: base, bold: base, italic: base, boldItalic: base, fontFallback: [
          if (deva != null) pw.Font.ttf(ByteData.sublistView(deva)),
        ]);
      }
      return switch (ext) {
        '.docx' => OfficeConverter.docxToPdf(bytes, theme: theme),
        '.xlsx' => OfficeConverter.xlsxToPdf(bytes, theme: theme),
        '.pptx' => OfficeConverter.pptxToPdf(bytes, theme: theme),
        _ => throw UnsupportedConversionException(
            'Only .docx, .xlsx and .pptx are supported. Legacy .doc/.xls/.ppt binary formats cannot be converted offline.'),
      };
    });
    return saveOutput(out, '${p.basenameWithoutExtension(path)}.pdf');
  }

  Future<File> txtToPdf(String path) async {
    final raw = await File(path).readAsBytes();
    String text;
    try {
      text = utf8.decode(raw);
    } on FormatException {
      text = String.fromCharCodes(raw); // Latin-1 fallback
    }
    final bytes = await pdf.buildFromText(text, title: p.basenameWithoutExtension(path));
    return saveOutput(bytes, '${p.basenameWithoutExtension(path)}.pdf');
  }

  Future<File> imagesToPdf(List<String> paths, PdfExportOptions options, {String name = 'Images'}) async {
    final bytes = await pdf.buildFromPages(pagesFromImageFiles(paths), options);
    final out = options.password == null || options.password!.isEmpty ? bytes : await tools.protect(bytes, options.password!);
    return saveOutput(out, '$name.pdf');
  }
}
