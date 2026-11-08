import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';
import 'dart:ui' show Offset;

import 'package:pdfrx/pdfrx.dart' as rx;
import 'package:syncfusion_flutter_pdf/pdf.dart' as sf;

import '../errors/app_exception.dart';
import '../image/image_service.dart';
import '../storage/settings_store.dart';
import 'pdf_service.dart';

class PdfMetadata {
  const PdfMetadata({this.title = '', this.author = '', this.subject = '', this.keywords = '', this.creator = '', this.producer = '', this.pageCount = 0});
  final String title, author, subject, keywords, creator, producer;
  final int pageCount;
}

/// A rendered PDF page as raw BGRA pixels.
class RenderedPage {
  const RenderedPage(this.index, this.bgra, this.width, this.height);
  final int index;
  final Uint8List bgra;
  final int width;
  final int height;
}

/// PDF manipulation on device.
///
/// * Structural edits (merge, split, extract, delete, rotate, reorder,
///   encrypt/decrypt, metadata) use Syncfusion's pure-Dart PDF library and run
///   in background isolates. Page content is copied as vector templates, so
///   text stays selectable.
/// * Rendering and text extraction use PDFium via `pdfrx`.
///
/// Licensing note: `syncfusion_flutter_pdf` is free under the Syncfusion
/// Community License (individuals / companies < US$1M revenue); larger
/// companies need a commercial licence before publishing.
class PdfToolsService {
  const PdfToolsService({this.images = const ImageService(), this.pdf = const PdfService()});
  final ImageService images;
  final PdfService pdf;

  // ------------------------------------------------------------ inspection

  /// True when the file cannot be opened without a password.
  Future<bool> needsPassword(String path) async {
    try {
      final doc = await rx.PdfDocument.openFile(path, passwordProvider: () => null);
      await doc.dispose();
      return false;
    } on rx.PdfPasswordException {
      return true;
    } catch (e) {
      throw CorruptedFileException(path.split(Platform.pathSeparator).last, cause: e);
    }
  }

  Future<rx.PdfDocument> open(String path, {String? password}) async {
    var attempted = false;
    try {
      return await rx.PdfDocument.openFile(
        path,
        passwordProvider: () {
          if (attempted) return null;
          attempted = true;
          return password;
        },
        firstAttemptByEmptyPassword: password == null,
      );
    } on rx.PdfPasswordException {
      throw password == null ? const PasswordRequiredException() : const WrongPasswordException();
    } catch (e) {
      if (e is AppException) rethrow;
      throw CorruptedFileException(path.split(Platform.pathSeparator).last, cause: e);
    }
  }

  Future<int> pageCount(String path, {String? password}) async {
    final doc = await open(path, password: password);
    try {
      return doc.pages.length;
    } finally {
      await doc.dispose();
    }
  }

  Future<PdfMetadata> metadata(String path, {String? password}) {
    return Isolate.run(() {
      final doc = _load(File(path).readAsBytesSync(), password);
      try {
        final info = doc.documentInformation;
        return PdfMetadata(
          title: info.title,
          author: info.author,
          subject: info.subject,
          keywords: info.keywords,
          creator: info.creator,
          producer: info.producer,
          pageCount: doc.pages.count,
        );
      } finally {
        doc.dispose();
      }
    });
  }

  // ------------------------------------------------------------- structure

  Future<Uint8List> setMetadata(String path, PdfMetadata m, {String? password}) => Isolate.run(() {
        final doc = _load(File(path).readAsBytesSync(), password);
        try {
          doc.documentInformation
            ..title = m.title
            ..author = m.author
            ..subject = m.subject
            ..keywords = m.keywords
            ..creator = m.creator.isEmpty ? 'DocuScan' : m.creator;
          return Uint8List.fromList(doc.saveSync());
        } finally {
          doc.dispose();
        }
      });

  /// Merges files in order. Each entry is (path, password).
  Future<Uint8List> merge(List<(String, String?)> inputs) {
    if (inputs.length < 2) throw const AppException('Pick at least two PDFs to merge.');
    final data = [for (final (p, pw) in inputs) (File(p).readAsBytesSync(), pw)];
    return Isolate.run(() {
      final out = sf.PdfDocument();
      try {
        for (final (bytes, pw) in data) {
          final src = _load(bytes, pw);
          try {
            for (var i = 0; i < src.pages.count; i++) {
              _appendPage(out, src.pages[i], 0);
            }
          } finally {
            src.dispose();
          }
        }
        return Uint8List.fromList(out.saveSync());
      } finally {
        out.dispose();
      }
    });
  }

  /// Builds a new PDF from [order] (zero-based page indexes, may repeat).
  /// Used for extract, split, reorder and delete.
  Future<Uint8List> selectPages(String path, List<int> order, {String? password, Map<int, int> rotations = const {}}) {
    final bytes = File(path).readAsBytesSync();
    return Isolate.run(() {
      final src = _load(bytes, password);
      final out = sf.PdfDocument();
      try {
        for (final i in order) {
          if (i < 0 || i >= src.pages.count) throw RangeError.index(i, src.pages, 'page');
          _appendPage(out, src.pages[i], rotations[i] ?? 0);
        }
        _copyInfo(src, out);
        return Uint8List.fromList(out.saveSync());
      } finally {
        src.dispose();
        out.dispose();
      }
    });
  }

  Future<Uint8List> deletePages(String path, List<int> remove, {String? password}) async {
    final count = await pageCount(path, password: password);
    final keep = [for (var i = 0; i < count; i++) if (!remove.contains(i)) i];
    if (keep.isEmpty) throw const AppException('You cannot delete every page.');
    return selectPages(path, keep, password: password);
  }

  /// Rotates pages in place (keeps annotations, links and forms).
  Future<Uint8List> rotatePages(String path, Map<int, int> quarterTurns, {String? password}) {
    final bytes = File(path).readAsBytesSync();
    return Isolate.run(() {
      final doc = _load(bytes, password);
      try {
        for (final e in quarterTurns.entries) {
          final page = doc.pages[e.key];
          final current = sf.PdfPageRotateAngle.values.indexOf(page.rotation);
          page.rotation = sf.PdfPageRotateAngle.values[(current + e.value) % 4];
        }
        return Uint8List.fromList(doc.saveSync());
      } finally {
        doc.dispose();
      }
    });
  }

  /// Splits into consecutive chunks of [pagesPerFile] pages, or at explicit
  /// [splitAfter] indexes (each value = last page index of a part).
  Future<List<Uint8List>> split(String path, {int? pagesPerFile, List<int>? splitAfter, String? password}) async {
    final count = await pageCount(path, password: password);
    final parts = <List<int>>[];
    if (splitAfter != null && splitAfter.isNotEmpty) {
      var start = 0;
      for (final end in [...{...splitAfter}.where((e) => e >= 0 && e < count - 1)]..sort()) {
        parts.add([for (var i = start; i <= end; i++) i]);
        start = end + 1;
      }
      parts.add([for (var i = start; i < count; i++) i]);
    } else {
      final n = (pagesPerFile ?? 1).clamp(1, count);
      for (var s = 0; s < count; s += n) {
        parts.add([for (var i = s; i < s + n && i < count; i++) i]);
      }
    }
    final out = <Uint8List>[];
    for (final p in parts.where((p) => p.isNotEmpty)) {
      out.add(await selectPages(path, p, password: password));
    }
    return out;
  }

  /// AES-256 encryption with a user (open) password.
  Future<Uint8List> protect(Uint8List bytes, String userPassword, {String? ownerPassword, bool allowPrinting = true, bool allowCopy = false}) {
    if (userPassword.isEmpty) throw const AppException('Password cannot be empty.');
    return Isolate.run(() {
      final doc = sf.PdfDocument(inputBytes: bytes);
      try {
        final sec = doc.security
          ..algorithm = sf.PdfEncryptionAlgorithm.aesx256Bit
          ..userPassword = userPassword
          ..ownerPassword = (ownerPassword == null || ownerPassword.isEmpty) ? '$userPassword#owner' : ownerPassword;
        sec.permissions.clear();
        if (allowPrinting) sec.permissions.addAll([sf.PdfPermissionsFlags.print, sf.PdfPermissionsFlags.fullQualityPrint]);
        if (allowCopy) sec.permissions.add(sf.PdfPermissionsFlags.copyContent);
        return Uint8List.fromList(doc.saveSync());
      } finally {
        doc.dispose();
      }
    });
  }

  /// Removes password protection (requires the correct password).
  Future<Uint8List> unlock(String path, String password) {
    final bytes = File(path).readAsBytesSync();
    return Isolate.run(() {
      final src = _load(bytes, password);
      final out = sf.PdfDocument();
      try {
        for (var i = 0; i < src.pages.count; i++) {
          _appendPage(out, src.pages[i], 0);
        }
        _copyInfo(src, out);
        return Uint8List.fromList(out.saveSync());
      } finally {
        src.dispose();
        out.dispose();
      }
    });
  }

  /// Lossless-ish optimisation: re-saves with best stream compression and
  /// drops unused objects. Works well for text/vector PDFs.
  Future<Uint8List> optimize(String path, {String? password}) {
    final bytes = File(path).readAsBytesSync();
    return Isolate.run(() {
      final doc = _load(bytes, password);
      try {
        doc.compressionLevel = sf.PdfCompressionLevel.best;
        doc.fileStructure.incrementalUpdate = false;
        return Uint8List.fromList(doc.saveSync());
      } finally {
        doc.dispose();
      }
    });
  }

  /// Strong compression for scanned PDFs: every page is re-rendered at [dpi]
  /// and re-encoded as JPEG at [jpegQuality]. Text layers are lost.
  Future<Uint8List> rasterCompress(String path, {String? password, int dpi = 110, int jpegQuality = 60, void Function(int, int)? onProgress}) async {
    final tmpDir = await Directory.systemTemp.createTemp('compress');
    try {
      final paths = <String>[];
      await for (final page in renderPages(path, password: password, dpi: dpi.toDouble())) {
        final jpg = await images.encodeBgra(page.bgra, page.width, page.height, quality: jpegQuality);
        final f = File('${tmpDir.path}/p${page.index}.jpg')..writeAsBytesSync(jpg);
        paths.add(f.path);
        onProgress?.call(page.index + 1, -1);
      }
      return await pdf.buildFromPages(
        pagesFromImageFiles(paths),
        // Pages are already JPEG at the target quality: embed them as-is.
        const PdfExportOptions(pageSize: 'Fit', quality: PdfQuality.original, searchable: false),
      );
    } finally {
      await tmpDir.delete(recursive: true);
    }
  }

  // ------------------------------------------------------------ rendering

  /// Renders pages at [dpi]. Pages are produced one at a time to keep memory flat.
  Stream<RenderedPage> renderPages(String path, {String? password, double dpi = 150, List<int>? pages}) async* {
    final doc = await open(path, password: password);
    try {
      final indexes = pages ?? List.generate(doc.pages.length, (i) => i);
      for (final i in indexes) {
        final page = doc.pages[i];
        final w = (page.width * dpi / 72).round();
        final h = (page.height * dpi / 72).round();
        final image = await page.render(fullWidth: w.toDouble(), fullHeight: h.toDouble(), width: w, height: h, backgroundColor: 0xFFFFFFFF);
        if (image == null) continue;
        try {
          yield RenderedPage(i, Uint8List.fromList(image.pixels), image.width, image.height);
        } finally {
          image.dispose();
        }
      }
    } finally {
      await doc.dispose();
    }
  }

  /// Text per page (empty strings for pages without a text layer).
  Future<List<String>> extractText(String path, {String? password}) async {
    final doc = await open(path, password: password);
    try {
      final out = <String>[];
      for (final page in doc.pages) {
        final text = await page.loadStructuredText();
        out.add(text.fullText);
      }
      return out;
    } finally {
      await doc.dispose();
    }
  }
}

sf.PdfDocument _load(Uint8List bytes, String? password) {
  try {
    return sf.PdfDocument(inputBytes: bytes, password: password);
  } on ArgumentError catch (e) {
    final msg = e.toString().toLowerCase();
    if (msg.contains('password')) {
      throw password == null ? const PasswordRequiredException() : const WrongPasswordException();
    }
    throw CorruptedFileException('PDF', cause: e);
  } catch (e) {
    final msg = e.toString().toLowerCase();
    if (msg.contains('password')) {
      throw password == null ? const PasswordRequiredException() : const WrongPasswordException();
    }
    throw CorruptedFileException('PDF', cause: e);
  }
}

/// Copies [page] into [out] as a vector template on a page of identical size.
void _appendPage(sf.PdfDocument out, sf.PdfPage page, int extraTurns) {
  final size = page.size;
  final template = page.createTemplate();
  final section = out.sections!.add();
  section.pageSettings.margins.all = 0;
  section.pageSettings.size = size;
  final baseTurns = sf.PdfPageRotateAngle.values.indexOf(page.rotation);
  section.pageSettings.rotate = sf.PdfPageRotateAngle.values[(baseTurns + extraTurns) % 4];
  final target = section.pages.add();
  target.graphics.drawPdfTemplate(template, Offset.zero, size);
}

void _copyInfo(sf.PdfDocument src, sf.PdfDocument out) {
  try {
    final a = src.documentInformation, b = out.documentInformation;
    b
      ..title = a.title
      ..author = a.author
      ..subject = a.subject
      ..keywords = a.keywords
      ..creator = a.creator;
  } catch (_) {}
}
