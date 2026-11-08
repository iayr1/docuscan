import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:gal/gal.dart';
import 'package:path/path.dart' as p;
import 'package:printing/printing.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/errors/app_exception.dart';
import '../../core/image/image_service.dart';
import '../../core/services/pdf_service.dart';
import '../../core/services/pdf_tools_service.dart';
import '../../core/storage/file_store.dart';
import '../../core/utils/formatters.dart';
import '../models/models.dart';
import 'asset_repository.dart';
import 'document_repository.dart';
import 'vault_repository.dart';

/// Builds export files from library documents and hands them to the OS
/// (share sheet, Storage Access Framework / Files app, gallery, printer).
class ExportRepository {
  ExportRepository(this._docs, this._assets, this._vault, this._files,
      {this.pdf = const PdfService(), this.tools = const PdfToolsService(), this.images = const ImageService()});

  final DocumentRepository _docs;
  final AssetRepository _assets;
  final VaultRepository _vault;
  final FileStore _files;
  final PdfService pdf;
  final PdfToolsService tools;
  final ImageService images;

  /// Renders a document to PDF bytes, including annotations, the OCR text
  /// layer and optional password protection.
  Future<Uint8List> buildPdfBytes(String docId, PdfExportOptions options, {List<String>? pageIds}) async {
    final doc = await _docs.getDocument(docId);
    if (doc == null) throw const AppException('Document not found.');
    var pages = await _docs.getPages(docId);
    if (pageIds != null) pages = pages.where((pg) => pageIds.contains(pg.id)).toList();
    if (pages.isEmpty) throw const AppException('No pages to export.');

    final paths = doc.inVault ? await _vault.decryptPagesToTemp(docId) : null;
    final annotations = options.includeAnnotations ? await _assets.annotationsForDocument(docId) : const <String, List<Annotation>>{};
    final ocr = options.searchable ? await _assets.ocrForDocument(docId) : const <String, OcrResult>{};
    final inputs = <PdfPageInput>[];
    for (final page in pages) {
      final ocrRow = ocr[page.id];
      inputs.add(PdfPageInput(
        imagePath: paths != null ? paths[page.index] : _files.abs(page.imagePath),
        width: page.width,
        height: page.height,
        annotations: annotations[page.id] ?? const [],
        // Edited OCR text no longer matches its boxes; skip the layer then.
        ocrLines: (ocrRow == null || ocrRow.edited) ? const [] : ocrRow.lines,
        resolveImage: _files.abs,
      ));
    }
    var bytes = await pdf.buildFromPages(inputs, options.copyWith(title: options.title ?? doc.title));
    if (options.password != null && options.password!.isNotEmpty) {
      bytes = await tools.protect(bytes, options.password!);
    }
    return bytes;
  }

  /// Writes a PDF into Exports/ and returns the file.
  Future<File> exportPdfFile(String docId, PdfExportOptions options, {List<String>? pageIds}) async {
    final doc = await _docs.getDocument(docId);
    final bytes = await buildPdfBytes(docId, options, pageIds: pageIds);
    final file = await _files.writeAtomic(await _uniqueExportPath('${sanitizeFileName(doc?.title ?? 'document')}.pdf'), bytes);
    await _docs.logExport(documentId: docId, title: doc?.title ?? 'Document', format: 'PDF', target: 'file', path: _files.rel(file.path));
    return file;
  }

  /// Copies page images (with annotations flattened when [flatten]) as JPG/PNG.
  Future<List<File>> exportImages(String docId, {bool png = false, List<String>? pageIds, bool flatten = true}) async {
    final doc = await _docs.getDocument(docId);
    if (doc == null) throw const AppException('Document not found.');
    final annotations = await _assets.annotationsForDocument(docId);
    final hasAnnotations = annotations.values.any((l) => l.isNotEmpty);
    final out = <File>[];
    final base = sanitizeFileName(doc.title);
    if (flatten && hasAnnotations) {
      // Render through the PDF pipeline so annotations are included, then rasterise.
      final tmp = await _files.newTempFile('pdf');
      await tmp.writeAsBytes(await buildPdfBytes(docId, const PdfExportOptions(pageSize: 'Fit', searchable: false), pageIds: pageIds));
      await for (final r in tools.renderPages(tmp.path, dpi: 200)) {
        final bytes = await images.encodeBgra(r.bgra, r.width, r.height, png: png);
        out.add(await _files.writeAtomic(await _uniqueExportPath('${base}_${r.index + 1}.${png ? 'png' : 'jpg'}'), bytes));
      }
      await tmp.delete();
    } else {
      var pages = await _docs.getPages(docId);
      if (pageIds != null) pages = pages.where((pg) => pageIds.contains(pg.id)).toList();
      final plain = doc.inVault ? await _vault.decryptPagesToTemp(docId) : null;
      for (final page in pages) {
        final src = plain != null ? plain[page.index] : _files.abs(page.imagePath);
        final target = await _uniqueExportPath('${base}_${page.index + 1}.${png ? 'png' : 'jpg'}');
        if (png) {
          final pngBytes = await images.toPng(await File(src).readAsBytes());
          out.add(await _files.writeAtomic(target, pngBytes));
        } else {
          out.add(await _files.copyInto(src, _files.rel(target)));
        }
      }
    }
    await _docs.logExport(documentId: docId, title: doc.title, format: png ? 'PNG' : 'JPG', target: 'file');
    return out;
  }

  Future<String> _uniqueExportPath(String name) async {
    final dir = _files.exports;
    await dir.create(recursive: true);
    final ext = p.extension(name);
    final stem = p.basenameWithoutExtension(name);
    var candidate = p.join(dir.path, name);
    var i = 2;
    while (await File(candidate).exists()) {
      candidate = p.join(dir.path, '$stem ($i)$ext');
      i++;
    }
    return candidate;
  }

  // ------------------------------------------------------- OS integrations

  /// Native share sheet (WhatsApp, Bluetooth, email, Drive… whatever is installed).
  Future<ShareResultStatus> share(List<String> paths, {String? text, String? subject}) async {
    final res = await SharePlus.instance.share(ShareParams(
      files: [for (final f in paths) XFile(f, mimeType: _mime(f))],
      text: text,
      subject: subject,
    ));
    return res.status;
  }

  Future<ShareResultStatus> shareText(String text, {String? subject}) async =>
      (await SharePlus.instance.share(ShareParams(text: text, subject: subject))).status;

  /// Opens the system "Save as" UI: Storage Access Framework on Android,
  /// the Files document picker on iOS. Returns false if the user cancelled.
  Future<bool> saveToDevice(Uint8List bytes, String fileName) async {
    final uri = await FilePicker.saveFile(fileName: fileName, bytes: bytes, mimeType: _mime(fileName), dialogTitle: 'Save $fileName');
    if (uri != null) {
      await _docs.logExport(title: fileName, format: p.extension(fileName).replaceAll('.', '').toUpperCase(), target: 'device');
    }
    return uri != null;
  }

  Future<void> saveImagesToGallery(List<String> paths) async {
    if (!await Gal.hasAccess(toAlbum: true)) {
      final granted = await Gal.requestAccess(toAlbum: true);
      if (!granted) throw const PermissionDeniedException('Photos');
    }
    for (final path in paths) {
      await Gal.putImage(path, album: 'DocuScan');
    }
    await _docs.logExport(title: '${paths.length} image(s)', format: 'JPG', target: 'gallery');
  }

  /// System print dialog (copies, page range and printer are chosen there).
  Future<bool> printPdf(Uint8List bytes, String name) =>
      Printing.layoutPdf(onLayout: (_) async => bytes, name: name, usePrinterSettings: true);

  static String _mime(String path) => switch (p.extension(path).toLowerCase()) {
        '.pdf' => 'application/pdf',
        '.jpg' || '.jpeg' => 'image/jpeg',
        '.png' => 'image/png',
        '.txt' => 'text/plain',
        '.csv' => 'text/csv',
        '.docx' => 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
        '.xlsx' => 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
        '.pptx' => 'application/vnd.openxmlformats-officedocument.presentationml.presentation',
        _ => 'application/octet-stream',
      };
}
