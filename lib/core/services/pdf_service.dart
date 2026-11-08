import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../../data/models/models.dart';
import '../image/rgb_buffer.dart';
import '../storage/settings_store.dart';

enum PageOrientation { auto, portrait, landscape }

/// Everything that controls PDF creation.
class PdfExportOptions {
  const PdfExportOptions({
    this.pageSize = 'A4',
    this.customWidthMm = 210,
    this.customHeightMm = 297,
    this.orientation = PageOrientation.auto,
    this.marginMm = 0,
    this.quality = PdfQuality.high,
    this.pageNumbers = false,
    this.header,
    this.footer,
    this.watermark,
    this.watermarkOpacity = 0.15,
    this.searchable = true,
    this.includeAnnotations = true,
    this.title,
    this.author,
    this.subject,
    this.keywords,
    this.password,
  });

  /// A4, A3, A5, Letter, Legal, Fit (page = image aspect), Custom.
  final String pageSize;
  final double customWidthMm;
  final double customHeightMm;
  final PageOrientation orientation;
  final double marginMm;
  final PdfQuality quality;
  final bool pageNumbers;
  final String? header;
  final String? footer;
  final String? watermark;
  final double watermarkOpacity;

  /// Adds an invisible OCR text layer so the PDF is searchable/selectable.
  final bool searchable;
  final bool includeAnnotations;
  final String? title;
  final String? author;
  final String? subject;
  final String? keywords;

  /// Applied after generation by `PdfToolsService.protect`.
  final String? password;

  PdfExportOptions copyWith({String? title, String? password, bool clearPassword = false}) => PdfExportOptions(
        pageSize: pageSize,
        customWidthMm: customWidthMm,
        customHeightMm: customHeightMm,
        orientation: orientation,
        marginMm: marginMm,
        quality: quality,
        pageNumbers: pageNumbers,
        header: header,
        footer: footer,
        watermark: watermark,
        watermarkOpacity: watermarkOpacity,
        searchable: searchable,
        includeAnnotations: includeAnnotations,
        title: title ?? this.title,
        author: author,
        subject: subject,
        keywords: keywords,
        password: clearPassword ? null : (password ?? this.password),
      );

  Map<String, Object?> toMap() => {
        'pageSize': pageSize,
        'cw': customWidthMm,
        'ch': customHeightMm,
        'orientation': orientation.index,
        'margin': marginMm,
        'qEdge': quality.maxEdge,
        'qJpeg': quality.jpegQuality,
        'qOriginal': quality == PdfQuality.original,
        'pageNumbers': pageNumbers,
        'header': header,
        'footer': footer,
        'watermark': watermark,
        'wmOpacity': watermarkOpacity,
        'searchable': searchable,
        'annotations': includeAnnotations,
        'title': title,
        'author': author,
        'subject': subject,
        'keywords': keywords,
      };
}

/// One page to render: absolute image path plus overlays.
class PdfPageInput {
  const PdfPageInput({
    required this.imagePath,
    this.width = 0,
    this.height = 0,
    this.annotations = const [],
    this.ocrLines = const [],
    this.resolveImage,
  });

  final String imagePath;
  final int width;
  final int height;
  final List<Annotation> annotations;
  final List<OcrBlock> ocrLines;

  /// Maps an annotation's relative image path to an absolute one.
  final String Function(String relative)? resolveImage;

  Map<String, Object?> toMap() => {
        'image': imagePath,
        'w': width,
        'h': height,
        'ann': [
          for (final a in annotations)
            {
              'kind': a.kind.name,
              ...a.dataJson(),
              'imageAbs': a.imagePath == null ? null : (resolveImage?.call(a.imagePath!) ?? a.imagePath),
            },
        ],
        'ocr': [for (final l in ocrLines) l.toJson()],
      };
}

/// Optional Unicode fonts bundled in assets/fonts (see README there).
class PdfFonts {
  const PdfFonts({this.regular, this.devanagari});
  final Uint8List? regular;
  final Uint8List? devanagari;

  bool get hasUnicode => regular != null;

  static PdfFonts? _cache;

  static Future<PdfFonts> load() async {
    if (_cache != null) return _cache!;
    Future<Uint8List?> tryLoad(String name) async {
      try {
        final data = await rootBundle.load('assets/fonts/$name');
        return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
      } catch (_) {
        return null;
      }
    }

    return _cache = PdfFonts(
      regular: await tryLoad('NotoSans-Regular.ttf'),
      devanagari: await tryLoad('NotoSansDevanagari-Regular.ttf'),
    );
  }
}

/// Builds PDFs with the `pdf` package entirely on-device, in a background isolate.
class PdfService {
  const PdfService();

  Future<Uint8List> buildFromPages(List<PdfPageInput> pages, PdfExportOptions options, {PdfFonts? fonts}) async {
    final f = fonts ?? await PdfFonts.load();
    final pageMaps = pages.map((p) => p.toMap()).toList();
    final opts = options.toMap();
    final regular = f.regular, deva = f.devanagari;
    return Isolate.run(() => buildPdfSync(pageMaps, opts, regular, deva));
  }

  /// Plain text (TXT, OCR output) → paginated PDF.
  Future<Uint8List> buildFromText(String text, {String? title, String pageSize = 'A4', PdfFonts? fonts, double fontSize = 11}) async {
    final f = fonts ?? await PdfFonts.load();
    final regular = f.regular, deva = f.devanagari;
    return Isolate.run(() async {
      final theme = _theme(regular, deva);
      final doc = pw.Document(title: title, creator: 'DocuScan', theme: theme);
      final hasUnicode = regular != null;
      final paragraphs = text.replaceAll('\r\n', '\n').split('\n');
      doc.addPage(pw.MultiPage(
        pageFormat: _format(pageSize, 210, 297),
        margin: const pw.EdgeInsets.all(48),
        build: (_) => [
          if (title != null && title.isNotEmpty)
            pw.Padding(
              padding: const pw.EdgeInsets.only(bottom: 16),
              child: pw.Text(_safe(title, hasUnicode), style: pw.TextStyle(fontSize: fontSize + 7, fontWeight: pw.FontWeight.bold)),
            ),
          for (final p in paragraphs)
            pw.Paragraph(
              text: p.isEmpty ? ' ' : _safe(p, hasUnicode),
              style: pw.TextStyle(fontSize: fontSize, lineSpacing: 2),
              margin: const pw.EdgeInsets.only(bottom: 4),
            ),
        ],
      ));
      return doc.save();
    });
  }
}

pw.ThemeData? _theme(Uint8List? regular, Uint8List? deva) {
  if (regular == null) return null;
  final base = pw.Font.ttf(ByteData.sublistView(regular));
  return pw.ThemeData.withFont(
    base: base,
    bold: base,
    fontFallback: [if (deva != null) pw.Font.ttf(ByteData.sublistView(deva))],
  );
}

/// Without a Unicode font the built-in Helvetica only covers Latin-1.
String _safe(String s, bool unicode) {
  if (unicode) return s;
  final b = StringBuffer();
  for (final r in s.runes) {
    if (r == 0x2018 || r == 0x2019) {
      b.write("'");
    } else if (r == 0x201C || r == 0x201D) {
      b.write('"');
    } else if (r == 0x2013 || r == 0x2014) {
      b.write('-');
    } else if (r == 0x2022) {
      b.write('*');
    } else if (r == 0x2026) {
      b.write('...');
    } else if (r == 9 || r == 10 || (r >= 32 && r < 127) || (r >= 160 && r <= 255)) {
      b.writeCharCode(r);
    } else {
      b.write('?');
    }
  }
  return b.toString();
}

PdfPageFormat _format(String size, double cwMm, double chMm) => switch (size) {
      'A3' => PdfPageFormat.a3,
      'A5' => PdfPageFormat.a5,
      'Letter' => PdfPageFormat.letter,
      'Legal' => PdfPageFormat.legal,
      'Custom' => PdfPageFormat(cwMm * PdfPageFormat.mm, chMm * PdfPageFormat.mm),
      _ => PdfPageFormat.a4,
    };

PdfColor _color(int argb) => PdfColor.fromInt(argb);

/// Synchronous builder (runs inside an isolate; also used directly by tests).
Future<Uint8List> buildPdfSync(List<Map<String, Object?>> pages, Map<String, Object?> o, Uint8List? regular, Uint8List? deva) async {
  final hasUnicode = regular != null;
  final doc = pw.Document(
    title: o['title'] as String?,
    author: o['author'] as String?,
    subject: o['subject'] as String?,
    keywords: o['keywords'] as String?,
    creator: 'DocuScan',
    producer: 'DocuScan (on-device)',
    theme: _theme(regular, deva),
  );
  final total = pages.length;
  final margin = ((o['margin'] as num?) ?? 0).toDouble() * PdfPageFormat.mm;
  final orientation = PageOrientation.values[(o['orientation'] as int?) ?? 0];
  final sizeKey = (o['pageSize'] as String?) ?? 'A4';
  final watermark = o['watermark'] as String?;
  final header = o['header'] as String?;
  final footer = o['footer'] as String?;
  final searchable = (o['searchable'] as bool?) ?? true;
  final withAnnotations = (o['annotations'] as bool?) ?? true;

  for (var index = 0; index < pages.length; index++) {
    final page = pages[index];
    final path = page['image'] as String;
    final raw = await File(path).readAsBytes();
    final anns = withAnnotations ? (page['ann'] as List).cast<Map<String, Object?>>() : <Map<String, Object?>>[];
    final redactions = anns.where((a) => a['kind'] == 'redact').toList();

    // Decode once to get true dimensions, burn pending redactions and recompress.
    final buf = RgbBuffer.decode(raw, maxEdge: (o['qEdge'] as int?) ?? 2480, name: path);
    for (final r in redactions) {
      buf.fillRect(
        (((r['l'] as num).toDouble()) * buf.width).floor(),
        (((r['t'] as num).toDouble()) * buf.height).floor(),
        (((r['w'] as num).toDouble()) * buf.width).ceil() + 1,
        (((r['h'] as num).toDouble()) * buf.height).ceil() + 1,
        0,
        0,
        0,
      );
    }
    final useRaw = (o['qOriginal'] as bool? ?? false) && redactions.isEmpty && _isJpeg(raw);
    final imageBytes = useRaw ? raw : buf.encodeJpg(quality: (o['qJpeg'] as int?) ?? 85);
    final imgW = buf.width.toDouble(), imgH = buf.height.toDouble();
    final landscapeImage = imgW > imgH;

    PdfPageFormat format;
    if (sizeKey == 'Fit') {
      // Page matches the image aspect; width normalised to A4 width (595pt).
      const base = 595.0;
      format = PdfPageFormat(base + margin * 2, base * imgH / imgW + margin * 2);
    } else {
      format = _format(sizeKey, ((o['cw'] as num?) ?? 210).toDouble(), ((o['ch'] as num?) ?? 297).toDouble());
      final wantLandscape = switch (orientation) {
        PageOrientation.auto => landscapeImage,
        PageOrientation.landscape => true,
        PageOrientation.portrait => false,
      };
      format = wantLandscape ? format.landscape : format.portrait;
    }

    // Content box (image fitted with "contain").
    final boxW = format.width - margin * 2;
    final boxH = format.height - margin * 2 - ((header != null && header.isNotEmpty) ? 18 : 0) -
        (((footer != null && footer.isNotEmpty) || ((o['pageNumbers'] as bool?) ?? false)) ? 18 : 0);
    final scale = math.min(boxW / imgW, boxH / imgH);
    final drawW = imgW * scale, drawH = imgH * scale;
    final left = (format.width - drawW) / 2;
    final top = margin + ((header != null && header.isNotEmpty) ? 18 : 0) + (boxH - drawH) / 2;

    // Pre-load overlay images (signatures / stamps).
    final overlayImages = <int, pw.MemoryImage>{};
    for (var i = 0; i < anns.length; i++) {
      final abs = anns[i]['imageAbs'] as String?;
      if (anns[i]['kind'] == 'image' && abs != null && File(abs).existsSync()) {
        overlayImages[i] = pw.MemoryImage(File(abs).readAsBytesSync());
      }
    }
    final ocr = searchable ? (page['ocr'] as List).map((e) => OcrBlock.fromJson(e as List)).toList() : <OcrBlock>[];

    doc.addPage(pw.Page(
      pageFormat: format,
      margin: pw.EdgeInsets.zero,
      build: (context) {
        final children = <pw.Widget>[
          pw.Positioned(left: left, top: top, child: pw.Image(pw.MemoryImage(imageBytes), width: drawW, height: drawH)),
        ];
        // Invisible OCR layer for search/copy.
        for (final line in ocr) {
          final w = line.width * drawW, h = line.height * drawH;
          if (w < 2 || h < 2 || line.text.trim().isEmpty) continue;
          children.add(pw.Positioned(
            left: left + line.left * drawW,
            top: top + line.top * drawH,
            child: pw.SizedBox(
              width: w,
              height: h,
              child: pw.FittedBox(
                fit: pw.BoxFit.fill,
                child: pw.Text(
                  _safe(line.text, hasUnicode),
                  style: pw.TextStyle(fontSize: math.max(4, h * 0.85), renderingMode: PdfTextRenderingMode.invisible),
                ),
              ),
            ),
          ));
        }
        // Vector annotations.
        final vector = anns.where((a) => const {'pen', 'highlighter', 'underline', 'strikeout', 'line', 'arrow', 'rect', 'ellipse', 'redact'}.contains(a['kind'])).toList();
        if (vector.isNotEmpty) {
          children.add(pw.Positioned(
            left: left,
            top: top,
            child: pw.CustomPaint(
              size: PdfPoint(drawW, drawH),
              painter: (canvas, size) {
                for (final a in vector) {
                  _paintVector(canvas, a, drawW, drawH);
                }
              },
            ),
          ));
        }
        for (var i = 0; i < anns.length; i++) {
          final a = anns[i];
          final l = left + (a['l'] as num).toDouble() * drawW;
          final t = top + (a['t'] as num).toDouble() * drawH;
          final w = (a['w'] as num).toDouble() * drawW;
          final h = (a['h'] as num).toDouble() * drawH;
          final rot = -((a['rot'] as num?) ?? 0).toDouble() * math.pi / 180;
          if (a['kind'] == 'image' && overlayImages[i] != null && w > 0 && h > 0) {
            children.add(pw.Positioned(
              left: l,
              top: t,
              child: pw.SizedBox(
                width: w,
                height: h,
                child: pw.Transform.rotate(angle: rot, child: pw.Image(overlayImages[i]!, fit: pw.BoxFit.contain)),
              ),
            ));
          } else if (a['kind'] == 'text' && (a['text'] as String?)?.isNotEmpty == true) {
            final fontSize = math.max(4.0, ((a['font'] as num?) ?? 0.03).toDouble() * drawW);
            children.add(pw.Positioned(
              left: l,
              top: t,
              child: pw.Transform.rotate(
                angle: rot,
                child: pw.Text(
                  _safe(a['text'] as String, hasUnicode),
                  style: pw.TextStyle(fontSize: fontSize, color: _color((a['color'] as int?) ?? 0xFF000000)),
                ),
              ),
            ));
          }
        }
        if (watermark != null && watermark.trim().isNotEmpty) {
          children.add(pw.Positioned.fill(
            child: pw.Center(
              child: pw.Opacity(
                opacity: ((o['wmOpacity'] as num?) ?? 0.15).toDouble(),
                child: pw.Transform.rotate(
                  angle: math.pi / 5,
                  child: pw.Text(
                    _safe(watermark, hasUnicode),
                    style: pw.TextStyle(fontSize: format.width / math.max(6, watermark.length * 0.75), color: PdfColors.grey700, fontWeight: pw.FontWeight.bold),
                  ),
                ),
              ),
            ),
          ));
        }
        final small = pw.TextStyle(fontSize: 9, color: PdfColors.grey700);
        if (header != null && header.isNotEmpty) {
          children.add(pw.Positioned(
            left: margin + 8,
            right: margin + 8,
            top: math.max(6, margin * 0.5),
            child: pw.Center(child: pw.Text(_safe(header, hasUnicode), style: small)),
          ));
        }
        final bottom = math.max(6.0, margin * 0.5);
        if (footer != null && footer.isNotEmpty) {
          children.add(pw.Positioned(left: margin + 8, bottom: bottom, child: pw.Text(_safe(footer, hasUnicode), style: small)));
        }
        if ((o['pageNumbers'] as bool?) ?? false) {
          children.add(pw.Positioned(right: margin + 8, bottom: bottom, child: pw.Text('${index + 1} / $total', style: small)));
        }
        return pw.Stack(children: children);
      },
    ));
  }
  return doc.save();
}

bool _isJpeg(Uint8List b) => b.length > 3 && b[0] == 0xFF && b[1] == 0xD8;

void _paintVector(PdfGraphics canvas, Map<String, Object?> a, double w, double h) {
  final kind = a['kind'] as String;
  final color = _color((a['color'] as int?) ?? 0xFFE53935);
  final stroke = math.max(0.5, ((a['stroke'] as num?) ?? 0.004).toDouble() * w);
  final raw = ((a['points'] as List?) ?? const []).map((e) => (e as num).toDouble()).toList();
  final pts = [for (var i = 0; i + 1 < raw.length; i += 2) PdfPoint(raw[i] * w, h - raw[i + 1] * h)];
  final l = (a['l'] as num).toDouble() * w;
  final t = (a['t'] as num).toDouble() * h;
  final bw = (a['w'] as num).toDouble() * w;
  final bh = (a['h'] as num).toDouble() * h;
  canvas
    ..saveContext()
    ..setStrokeColor(color)
    ..setFillColor(color)
    ..setLineWidth(stroke)
    ..setLineCap(PdfLineCap.round)
    ..setLineJoin(PdfLineJoin.round);
  switch (kind) {
    case 'highlighter':
      canvas.setGraphicState(const PdfGraphicState(opacity: 0.35));
      canvas.setLineWidth(stroke * 4);
      _poly(canvas, pts);
    case 'pen' || 'underline' || 'strikeout' || 'line':
      _poly(canvas, pts);
    case 'arrow':
      if (pts.length >= 2) {
        final a0 = pts.first, a1 = pts.last;
        _poly(canvas, [a0, a1]);
        final ang = math.atan2(a1.y - a0.y, a1.x - a0.x);
        final head = stroke * 5;
        canvas
          ..moveTo(a1.x, a1.y)
          ..lineTo(a1.x - head * math.cos(ang - 0.45), a1.y - head * math.sin(ang - 0.45))
          ..lineTo(a1.x - head * math.cos(ang + 0.45), a1.y - head * math.sin(ang + 0.45))
          ..closePath()
          ..fillPath();
      }
    case 'rect':
      canvas.drawRect(l, h - t - bh, bw, bh);
      (a['fill'] as bool? ?? false) ? canvas.fillPath() : canvas.strokePath();
    case 'ellipse':
      canvas.drawEllipse(l + bw / 2, h - t - bh / 2, bw / 2, bh / 2);
      (a['fill'] as bool? ?? false) ? canvas.fillPath() : canvas.strokePath();
    case 'redact':
      canvas
        ..setFillColor(PdfColors.black)
        ..drawRect(l, h - t - bh, bw, bh)
        ..fillPath();
  }
  canvas.restoreContext();
}

void _poly(PdfGraphics canvas, List<PdfPoint> pts) {
  if (pts.length < 2) return;
  canvas.moveTo(pts.first.x, pts.first.y);
  for (final p in pts.skip(1)) {
    canvas.lineTo(p.x, p.y);
  }
  canvas.strokePath();
}

/// Convenience used by the image→PDF tool for arbitrary image files.
List<PdfPageInput> pagesFromImageFiles(List<String> paths) => [for (final p in paths) PdfPageInput(imagePath: p)];

/// Default options derived from settings.
PdfExportOptions defaultExportOptions(AppSettings s, {String? title}) =>
    PdfExportOptions(pageSize: s.pageSize, quality: s.pdfQuality, title: title);

