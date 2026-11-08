import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:xml/xml.dart';

import '../errors/app_exception.dart';

/// Offline Office Open XML conversion.
///
/// Office files are ZIP packages of XML parts, so they can be read and
/// written without a server. Fidelity limits (documented in the UI):
///
/// * DOCX → PDF: paragraphs, headings, bold/italic, bullet lists, tables and
///   embedded JPEG/PNG images. Fonts, columns, text boxes, headers/footers,
///   footnotes and exact pagination are not reproduced.
/// * XLSX → PDF: cell values of every sheet as tables (formulas show their
///   cached result). No charts, formatting, merged cells or column widths.
/// * PPTX → PDF: one landscape page per slide with title, text and pictures.
///   No layout positions, themes, shapes or animations.
/// * PDF → DOCX/XLSX/PPTX: text per page (from the PDF text layer, or OCR for
///   scans) / page images. Layout is not reconstructed.
abstract final class OfficeConverter {
  // =========================================================== reading

  static Archive _zip(Uint8List bytes, String kind) {
    try {
      return ZipDecoder().decodeBytes(bytes);
    } catch (e) {
      throw CorruptedFileException(kind, cause: e);
    }
  }

  static XmlDocument? _xml(Archive zip, String path) {
    final f = zip.findFile(path);
    if (f == null) return null;
    return XmlDocument.parse(utf8.decode(f.content, allowMalformed: true));
  }

  static Map<String, String> _rels(Archive zip, String relsPath, String baseDir) {
    final doc = _xml(zip, relsPath);
    if (doc == null) return const {};
    final out = <String, String>{};
    for (final r in doc.findAllElements('Relationship')) {
      final id = r.getAttribute('Id');
      final target = r.getAttribute('Target');
      if (id == null || target == null) continue;
      out[id] = _resolve(baseDir, target);
    }
    return out;
  }

  static String _resolve(String baseDir, String target) {
    if (target.startsWith('/')) return target.substring(1);
    final parts = [...baseDir.split('/').where((s) => s.isNotEmpty)];
    for (final seg in target.split('/')) {
      if (seg == '..') {
        if (parts.isNotEmpty) parts.removeLast();
      } else if (seg != '.') {
        parts.add(seg);
      }
    }
    return parts.join('/');
  }

  static bool _isRaster(Uint8List b) =>
      b.length > 8 && ((b[0] == 0xFF && b[1] == 0xD8) || (b[0] == 0x89 && b[1] == 0x50 && b[2] == 0x4E && b[3] == 0x47));

  /// Parses a .docx into flow blocks.
  static List<DocBlock> parseDocx(Uint8List bytes) {
    final zip = _zip(bytes, 'DOCX');
    final doc = _xml(zip, 'word/document.xml');
    if (doc == null) throw const CorruptedFileException('DOCX');
    final rels = _rels(zip, 'word/_rels/document.xml.rels', 'word');
    final body = doc.findAllElements('w:body').firstOrNull;
    if (body == null) return const [];
    final blocks = <DocBlock>[];

    for (final node in body.childElements) {
      if (node.name.qualified == 'w:p') {
        blocks.addAll(_docxParagraph(node, rels, zip));
      } else if (node.name.qualified == 'w:tbl') {
        final rows = <List<String>>[];
        for (final tr in node.findElements('w:tr')) {
          rows.add([
            for (final tc in tr.findElements('w:tc'))
              tc.findAllElements('w:p').map((p) => p.findAllElements('w:t').map((t) => t.innerText).join()).join('\n'),
          ]);
        }
        if (rows.isNotEmpty) blocks.add(DocTable(rows));
      }
    }
    return blocks;
  }

  static List<DocBlock> _docxParagraph(XmlElement p, Map<String, String> rels, Archive zip) {
    final out = <DocBlock>[];
    final style = p.findAllElements('w:pStyle').firstOrNull?.getAttribute('w:val') ?? '';
    var heading = 0;
    final m = RegExp(r'(?:Heading|heading)\s?(\d)').firstMatch(style);
    if (m != null) heading = int.parse(m.group(1)!);
    if (style == 'Title') heading = 1;
    final bullet = p.findAllElements('w:numPr').isNotEmpty || style.toLowerCase().contains('list');

    final runs = <DocRun>[];
    for (final r in p.findAllElements('w:r')) {
      final rPr = r.getElement('w:rPr');
      bool on(String tag) {
        final e = rPr?.getElement(tag);
        if (e == null) return false;
        final v = e.getAttribute('w:val');
        return v == null || (v != '0' && v != 'false');
      }

      final text = StringBuffer();
      for (final c in r.childElements) {
        switch (c.name.qualified) {
          case 'w:t':
            text.write(c.innerText);
          case 'w:tab':
            text.write('\t');
          case 'w:br' || 'w:cr':
            if (c.getAttribute('w:type') == 'page') {
              if (text.isNotEmpty || runs.isNotEmpty) {
                runs.add(DocRun(text.toString(), bold: on('w:b'), italic: on('w:i'), underline: on('w:u')));
                text.clear();
                out.add(DocParagraph(List.of(runs), heading: heading, bullet: bullet));
                runs.clear();
              }
              out.add(const DocPageBreak());
            } else {
              text.write('\n');
            }
          default:
            break;
        }
      }
      if (text.isNotEmpty) runs.add(DocRun(text.toString(), bold: on('w:b'), italic: on('w:i'), underline: on('w:u')));
      for (final blip in r.findAllElements('a:blip')) {
        final id = blip.getAttribute('r:embed');
        final path = id == null ? null : rels[id];
        final data = path == null ? null : zip.findFile(path)?.content;
        if (data != null && _isRaster(data)) out.add(DocImage(Uint8List.fromList(data)));
      }
    }
    if (runs.isNotEmpty || out.isEmpty) out.insert(0, DocParagraph(runs, heading: heading, bullet: bullet));
    return out;
  }

  static int _colIndex(String ref) {
    var n = 0;
    for (final ch in ref.codeUnits) {
      if (ch < 65 || ch > 90) break;
      n = n * 26 + (ch - 64);
    }
    return n - 1;
  }

  static String _colName(int index) {
    var n = index + 1;
    final sb = StringBuffer();
    while (n > 0) {
      final r = (n - 1) % 26;
      sb.write(String.fromCharCode(65 + r));
      n = (n - 1) ~/ 26;
    }
    return sb.toString().split('').reversed.join();
  }

  /// Parses every sheet of an .xlsx into rows of cell strings.
  static List<SheetData> parseXlsx(Uint8List bytes, {int maxCols = 40, int maxRows = 5000}) {
    final zip = _zip(bytes, 'XLSX');
    final wb = _xml(zip, 'xl/workbook.xml');
    if (wb == null) throw const CorruptedFileException('XLSX');
    final rels = _rels(zip, 'xl/_rels/workbook.xml.rels', 'xl');
    final shared = <String>[];
    final ss = _xml(zip, 'xl/sharedStrings.xml');
    if (ss != null) {
      for (final si in ss.findAllElements('si')) {
        shared.add(si.findAllElements('t').map((t) => t.innerText).join());
      }
    }
    final out = <SheetData>[];
    for (final sheet in wb.findAllElements('sheet')) {
      final name = sheet.getAttribute('name') ?? 'Sheet';
      final rid = sheet.getAttribute('r:id');
      final path = rid == null ? null : rels[rid];
      final xml = path == null ? null : _xml(zip, path);
      if (xml == null) continue;
      final rows = <List<String>>[];
      for (final row in xml.findAllElements('row')) {
        if (rows.length >= maxRows) break;
        final cells = <int, String>{};
        var fallbackCol = 0;
        for (final c in row.findElements('c')) {
          final ref = c.getAttribute('r');
          final col = ref == null ? fallbackCol : _colIndex(ref);
          fallbackCol = col + 1;
          if (col >= maxCols) continue;
          final type = c.getAttribute('t');
          final v = c.getElement('v')?.innerText;
          String value;
          switch (type) {
            case 's':
              final i = int.tryParse(v ?? '');
              value = i != null && i < shared.length ? shared[i] : '';
            case 'inlineStr':
              value = c.findAllElements('t').map((t) => t.innerText).join();
            case 'b':
              value = v == '1' ? 'TRUE' : 'FALSE';
            default:
              value = v ?? '';
              final d = double.tryParse(value);
              if (d != null && d == d.roundToDouble() && d.abs() < 1e15) value = d.toInt().toString();
          }
          cells[col] = value;
        }
        if (cells.isEmpty) {
          rows.add(const []);
          continue;
        }
        final maxCol = cells.keys.reduce((a, b) => a > b ? a : b);
        rows.add([for (var i = 0; i <= maxCol; i++) cells[i] ?? '']);
      }
      while (rows.isNotEmpty && rows.last.every((c) => c.isEmpty)) {
        rows.removeLast();
      }
      out.add(SheetData(name, rows));
    }
    return out;
  }

  /// Parses slides of a .pptx (in presentation order).
  static List<SlideData> parsePptx(Uint8List bytes) {
    final zip = _zip(bytes, 'PPTX');
    final pres = _xml(zip, 'ppt/presentation.xml');
    if (pres == null) throw const CorruptedFileException('PPTX');
    final rels = _rels(zip, 'ppt/_rels/presentation.xml.rels', 'ppt');
    final slides = <SlideData>[];
    for (final id in pres.findAllElements('p:sldId')) {
      final path = rels[id.getAttribute('r:id')];
      if (path == null) continue;
      final xml = _xml(zip, path);
      if (xml == null) continue;
      final dir = path.substring(0, path.lastIndexOf('/'));
      final name = path.substring(path.lastIndexOf('/') + 1);
      final sRels = _rels(zip, '$dir/_rels/$name.rels', dir);
      String? title;
      final paragraphs = <String>[];
      for (final sp in xml.findAllElements('p:sp')) {
        final phType = sp.findAllElements('p:ph').firstOrNull?.getAttribute('type');
        final texts = [
          for (final p in sp.findAllElements('a:p'))
            p.findAllElements('a:t').map((t) => t.innerText).join(),
        ].where((t) => t.trim().isNotEmpty).toList();
        if (texts.isEmpty) continue;
        if (title == null && (phType == 'title' || phType == 'ctrTitle')) {
          title = texts.join(' ');
        } else {
          paragraphs.addAll(texts);
        }
      }
      final images = <Uint8List>[];
      for (final blip in xml.findAllElements('a:blip')) {
        final p = sRels[blip.getAttribute('r:embed')];
        final data = p == null ? null : zip.findFile(p)?.content;
        if (data != null && _isRaster(data)) images.add(Uint8List.fromList(data));
      }
      slides.add(SlideData(title, paragraphs, images));
    }
    return slides;
  }

  // ==================================================== Office → PDF

  static Future<Uint8List> docxToPdf(Uint8List bytes, {pw.ThemeData? theme}) async {
    final blocks = parseDocx(bytes);
    final doc = pw.Document(creator: 'DocuScan', theme: theme);
    doc.addPage(pw.MultiPage(
      pageFormat: PdfPageFormat.a4,
      margin: const pw.EdgeInsets.all(56),
      build: (_) => [
        for (final b in blocks)
          switch (b) {
            DocParagraph p => _pdfParagraph(p),
            DocTable t => pw.Padding(
                padding: const pw.EdgeInsets.symmetric(vertical: 6),
                child: pw.TableHelper.fromTextArray(
                  data: t.rows,
                  cellStyle: const pw.TextStyle(fontSize: 9),
                  headerStyle: pw.TextStyle(fontSize: 9, fontWeight: pw.FontWeight.bold),
                  cellAlignment: pw.Alignment.topLeft,
                ),
              ),
            DocImage i => pw.Padding(
                padding: const pw.EdgeInsets.symmetric(vertical: 6),
                child: pw.Image(pw.MemoryImage(i.bytes), fit: pw.BoxFit.contain, height: 360),
              ),
            DocPageBreak() => pw.NewPage(),
          },
      ],
    ));
    return doc.save();
  }

  static pw.Widget _pdfParagraph(DocParagraph p) {
    final size = switch (p.heading) {
      1 => 20.0,
      2 => 16.0,
      3 => 14.0,
      _ => 11.0,
    };
    final spans = [
      for (final r in p.runs)
        pw.TextSpan(
          text: _latin(r.text),
          style: pw.TextStyle(
            fontWeight: (r.bold || p.heading > 0) ? pw.FontWeight.bold : pw.FontWeight.normal,
            fontStyle: r.italic ? pw.FontStyle.italic : pw.FontStyle.normal,
            decoration: r.underline ? pw.TextDecoration.underline : null,
          ),
        ),
    ];
    final text = pw.RichText(text: pw.TextSpan(children: spans, style: pw.TextStyle(fontSize: size, lineSpacing: 2)));
    return pw.Padding(
      padding: pw.EdgeInsets.only(bottom: p.heading > 0 ? 8 : 5, top: p.heading > 0 ? 6 : 0),
      child: p.bullet
          ? pw.Row(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
              pw.SizedBox(width: 14, child: pw.Text('•', style: pw.TextStyle(fontSize: size))),
              pw.Expanded(child: text),
            ])
          : text,
    );
  }

  static Future<Uint8List> xlsxToPdf(Uint8List bytes, {pw.ThemeData? theme}) async {
    final sheets = parseXlsx(bytes);
    if (sheets.isEmpty) throw const AppException('The workbook has no sheets.');
    final doc = pw.Document(creator: 'DocuScan', theme: theme);
    for (final s in sheets) {
      final width = s.rows.fold<int>(0, (m, r) => r.length > m ? r.length : m);
      final rows = [for (final r in s.rows) [for (var i = 0; i < width; i++) i < r.length ? _latin(r[i]) : '']];
      doc.addPage(pw.MultiPage(
        pageFormat: width > 6 ? PdfPageFormat.a4.landscape : PdfPageFormat.a4,
        margin: const pw.EdgeInsets.all(28),
        header: (_) => pw.Padding(
          padding: const pw.EdgeInsets.only(bottom: 8),
          child: pw.Text(_latin(s.name), style: pw.TextStyle(fontSize: 13, fontWeight: pw.FontWeight.bold)),
        ),
        build: (_) => [
          if (rows.isEmpty)
            pw.Text('(empty sheet)')
          else
            pw.TableHelper.fromTextArray(
              data: rows,
              headerCount: 0,
              cellStyle: pw.TextStyle(fontSize: width > 10 ? 6.5 : 8),
              cellAlignment: pw.Alignment.centerLeft,
              cellPadding: const pw.EdgeInsets.symmetric(horizontal: 3, vertical: 2),
              border: pw.TableBorder.all(color: PdfColors.grey400, width: 0.4),
            ),
        ],
      ));
    }
    return doc.save();
  }

  static Future<Uint8List> pptxToPdf(Uint8List bytes, {pw.ThemeData? theme}) async {
    final slides = parsePptx(bytes);
    if (slides.isEmpty) throw const AppException('The presentation has no slides.');
    final doc = pw.Document(creator: 'DocuScan', theme: theme);
    final format = PdfPageFormat(960 * 0.75, 540 * 0.75);
    for (final s in slides) {
      doc.addPage(pw.Page(
        pageFormat: format,
        margin: const pw.EdgeInsets.all(28),
        build: (_) => pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
          if (s.title != null)
            pw.Text(_latin(s.title!), style: pw.TextStyle(fontSize: 22, fontWeight: pw.FontWeight.bold)),
          pw.SizedBox(height: 10),
          pw.Expanded(
            child: pw.Row(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
              if (s.paragraphs.isNotEmpty)
                pw.Expanded(
                  child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
                    for (final p in s.paragraphs.take(14))
                      pw.Padding(
                        padding: const pw.EdgeInsets.only(bottom: 5),
                        child: pw.Text('•  ${_latin(p)}', style: const pw.TextStyle(fontSize: 12)),
                      ),
                  ]),
                ),
              if (s.images.isNotEmpty)
                pw.Expanded(
                  child: pw.Column(children: [
                    for (final img in s.images.take(2))
                      pw.Expanded(child: pw.Padding(padding: const pw.EdgeInsets.all(4), child: pw.Image(pw.MemoryImage(img), fit: pw.BoxFit.contain))),
                  ]),
                ),
            ]),
          ),
        ]),
      ));
    }
    return doc.save();
  }

  /// Built-in Helvetica covers Latin-1 only (used when no Unicode font theme is set).
  static String _latin(String s) => String.fromCharCodes(s.runes.map((r) => (r == 9 || r == 10 || (r >= 32 && r < 127) || (r >= 160 && r <= 255)) ? r : 0x3F));

  // ===================================================== writing

  static String _esc(String s) => s
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;')
      .replaceAll(RegExp(r'[\x00-\x08\x0B\x0C\x0E-\x1F]'), '');

  static Uint8List _pack(Map<String, List<int>> parts) {
    final archive = Archive();
    // [Content_Types].xml must be the first entry for some readers.
    final keys = parts.keys.toList()..sort((a, b) => a == '[Content_Types].xml' ? -1 : (b == '[Content_Types].xml' ? 1 : 0));
    for (final k in keys) {
      archive.addFile(ArchiveFile.bytes(k, parts[k]!));
    }
    return ZipEncoder().encodeBytes(archive);
  }

  /// Builds a .docx. Each page contributes its text paragraphs and, optionally,
  /// a full-width image (JPEG); pages are separated by page breaks.
  static Uint8List buildDocx(List<DocxPage> pages, {String title = ''}) {
    final body = StringBuffer();
    final media = <String, List<int>>{};
    final rels = StringBuffer();
    var imageCount = 0;
    for (var i = 0; i < pages.length; i++) {
      final page = pages[i];
      if (page.image != null) {
        imageCount++;
        final rid = 'rIdImg$imageCount';
        media['word/media/image$imageCount.jpeg'] = page.image!;
        rels.write('<Relationship Id="$rid" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/image" Target="media/image$imageCount.jpeg"/>');
        const maxW = 6.3 * 914400; // 6.3" text width in EMU
        const maxH = 9.0 * 914400;
        final aspect = page.imageHeight / (page.imageWidth == 0 ? 1 : page.imageWidth);
        var cx = maxW, cy = maxW * aspect;
        if (cy > maxH) {
          cy = maxH;
          cx = maxH / aspect;
        }
        body.write('<w:p><w:r><w:drawing><wp:inline distT="0" distB="0" distL="0" distR="0">'
            '<wp:extent cx="${cx.round()}" cy="${cy.round()}"/><wp:docPr id="$imageCount" name="Page ${i + 1}"/>'
            '<a:graphic xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main">'
            '<a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture">'
            '<pic:pic xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture">'
            '<pic:nvPicPr><pic:cNvPr id="$imageCount" name="image$imageCount.jpeg"/><pic:cNvPicPr/></pic:nvPicPr>'
            '<pic:blipFill><a:blip r:embed="$rid"/><a:stretch><a:fillRect/></a:stretch></pic:blipFill>'
            '<pic:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="${cx.round()}" cy="${cy.round()}"/></a:xfrm>'
            '<a:prstGeom prst="rect"><a:avLst/></a:prstGeom></pic:spPr></pic:pic></a:graphicData></a:graphic>'
            '</wp:inline></w:drawing></w:r></w:p>');
      }
      for (final para in page.paragraphs) {
        body.write('<w:p>');
        final lines = para.split('\n');
        for (var l = 0; l < lines.length; l++) {
          if (l > 0) body.write('<w:r><w:br/></w:r>');
          body.write('<w:r><w:t xml:space="preserve">${_esc(lines[l])}</w:t></w:r>');
        }
        body.write('</w:p>');
      }
      if (i < pages.length - 1) body.write('<w:p><w:r><w:br w:type="page"/></w:r></w:p>');
    }
    const ns = 'xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" '
        'xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" '
        'xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing" '
        'xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" '
        'xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture"';
    final document = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<w:document $ns><w:body>$body'
        '<w:sectPr><w:pgSz w:w="11906" w:h="16838"/>'
        '<w:pgMar w:top="1134" w:right="1134" w:bottom="1134" w:left="1134" w:header="567" w:footer="567" w:gutter="0"/>'
        '</w:sectPr></w:body></w:document>';
    return _pack({
      '[Content_Types].xml': utf8.encode('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
          '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
          '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
          '<Default Extension="xml" ContentType="application/xml"/>'
          '<Default Extension="jpeg" ContentType="image/jpeg"/>'
          '<Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>'
          '<Override PartName="/docProps/core.xml" ContentType="application/vnd.openxmlformats-package.core-properties+xml"/>'
          '</Types>'),
      '_rels/.rels': utf8.encode('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
          '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
          '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>'
          '<Relationship Id="rId2" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" Target="docProps/core.xml"/>'
          '</Relationships>'),
      'docProps/core.xml': utf8.encode(_coreProps(title)),
      'word/document.xml': utf8.encode(document),
      'word/_rels/document.xml.rels': utf8.encode('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
          '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">$rels</Relationships>'),
      ...media,
    });
  }

  static String _coreProps(String title) => '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" '
      'xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:dcterms="http://purl.org/dc/terms/" '
      'xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">'
      '<dc:title>${_esc(title)}</dc:title><dc:creator>DocuScan</dc:creator>'
      '<dcterms:created xsi:type="dcterms:W3CDTF">${DateTime.now().toUtc().toIso8601String().split('.').first}Z</dcterms:created>'
      '</cp:coreProperties>';

  /// Builds an .xlsx with one sheet per entry. Numeric-looking cells are
  /// stored as numbers, everything else as inline strings.
  static Uint8List buildXlsx(List<SheetData> sheets) {
    if (sheets.isEmpty) sheets = [const SheetData('Sheet1', [])];
    final parts = <String, List<int>>{};
    final wbSheets = StringBuffer(), wbRels = StringBuffer(), overrides = StringBuffer();
    final usedNames = <String>{};
    for (var s = 0; s < sheets.length; s++) {
      var name = sheets[s].name.replaceAll(RegExp(r'[\\/?*\[\]:]'), ' ').trim();
      if (name.isEmpty) name = 'Sheet${s + 1}';
      if (name.length > 31) name = name.substring(0, 31);
      while (usedNames.contains(name.toLowerCase())) {
        name = '${name.substring(0, name.length > 27 ? 27 : name.length)} ${s + 1}';
      }
      usedNames.add(name.toLowerCase());
      wbSheets.write('<sheet name="${_esc(name)}" sheetId="${s + 1}" r:id="rId${s + 1}"/>');
      wbRels.write('<Relationship Id="rId${s + 1}" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet${s + 1}.xml"/>');
      overrides.write('<Override PartName="/xl/worksheets/sheet${s + 1}.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>');
      final data = StringBuffer();
      final rows = sheets[s].rows;
      for (var r = 0; r < rows.length; r++) {
        data.write('<row r="${r + 1}">');
        for (var c = 0; c < rows[r].length; c++) {
          final v = rows[r][c];
          if (v.isEmpty) continue;
          final ref = '${_colName(c)}${r + 1}';
          final numeric = RegExp(r'^-?\d+(\.\d+)?$').hasMatch(v.trim()) && v.trim().length < 15;
          if (numeric) {
            data.write('<c r="$ref"><v>${v.trim()}</v></c>');
          } else {
            data.write('<c r="$ref" t="inlineStr"><is><t xml:space="preserve">${_esc(v)}</t></is></c>');
          }
        }
        data.write('</row>');
      }
      parts['xl/worksheets/sheet${s + 1}.xml'] = utf8.encode('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
          '<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData>$data</sheetData></worksheet>');
    }
    parts['[Content_Types].xml'] = utf8.encode('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
        '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
        '<Default Extension="xml" ContentType="application/xml"/>'
        '<Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>'
        '$overrides</Types>');
    parts['_rels/.rels'] = utf8.encode('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
        '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>'
        '</Relationships>');
    parts['xl/workbook.xml'] = utf8.encode('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" '
        'xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets>$wbSheets</sheets></workbook>');
    parts['xl/_rels/workbook.xml.rels'] = utf8.encode('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">$wbRels</Relationships>');
    return _pack(parts);
  }

  /// Builds a 16:9 .pptx with one full-bleed picture slide per image (JPEG).
  static Uint8List buildPptx(List<PptxSlideImage> slides, {String title = ''}) {
    const cx = 12192000, cy = 6858000; // 13.333" × 7.5"
    final parts = <String, List<int>>{};
    final sldIds = StringBuffer(), presRels = StringBuffer(), overrides = StringBuffer();
    const pNs = 'xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" '
        'xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" '
        'xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main"';
    const emptyTree = '<p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr>'
        '<p:grpSpPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="0" cy="0"/><a:chOff x="0" y="0"/><a:chExt cx="0" cy="0"/></a:xfrm></p:grpSpPr>';
    presRels.write('<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideMaster" Target="slideMasters/slideMaster1.xml"/>');
    presRels.write('<Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/theme" Target="theme/theme1.xml"/>');
    for (var i = 0; i < slides.length; i++) {
      final n = i + 1;
      final s = slides[i];
      // Fit the picture inside the slide preserving aspect ratio.
      final aspect = s.width / (s.height == 0 ? 1 : s.height);
      var w = cx.toDouble(), h = cx / aspect;
      if (h > cy) {
        h = cy.toDouble();
        w = cy * aspect;
      }
      final x = ((cx - w) / 2).round(), y = ((cy - h) / 2).round();
      parts['ppt/media/image$n.jpeg'] = s.jpeg;
      parts['ppt/slides/slide$n.xml'] = utf8.encode('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
          '<p:sld $pNs><p:cSld><p:spTree>$emptyTree'
          '<p:pic><p:nvPicPr><p:cNvPr id="2" name="Page $n"/><p:cNvPicPr><a:picLocks noChangeAspect="1"/></p:cNvPicPr><p:nvPr/></p:nvPicPr>'
          '<p:blipFill><a:blip r:embed="rId2"/><a:stretch><a:fillRect/></a:stretch></p:blipFill>'
          '<p:spPr><a:xfrm><a:off x="$x" y="$y"/><a:ext cx="${w.round()}" cy="${h.round()}"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom></p:spPr></p:pic>'
          '</p:spTree></p:cSld><p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sld>');
      parts['ppt/slides/_rels/slide$n.xml.rels'] = utf8.encode('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
          '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
          '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideLayout" Target="../slideLayouts/slideLayout1.xml"/>'
          '<Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/image" Target="../media/image$n.jpeg"/>'
          '</Relationships>');
      sldIds.write('<p:sldId id="${255 + n}" r:id="rId${n + 2}"/>');
      presRels.write('<Relationship Id="rId${n + 2}" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slide" Target="slides/slide$n.xml"/>');
      overrides.write('<Override PartName="/ppt/slides/slide$n.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slide+xml"/>');
    }
    parts['[Content_Types].xml'] = utf8.encode('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
        '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
        '<Default Extension="xml" ContentType="application/xml"/>'
        '<Default Extension="jpeg" ContentType="image/jpeg"/>'
        '<Override PartName="/ppt/presentation.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.presentation.main+xml"/>'
        '<Override PartName="/ppt/slideMasters/slideMaster1.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slideMaster+xml"/>'
        '<Override PartName="/ppt/slideLayouts/slideLayout1.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slideLayout+xml"/>'
        '<Override PartName="/ppt/theme/theme1.xml" ContentType="application/vnd.openxmlformats-officedocument.theme+xml"/>'
        '<Override PartName="/docProps/core.xml" ContentType="application/vnd.openxmlformats-package.core-properties+xml"/>'
        '$overrides</Types>');
    parts['_rels/.rels'] = utf8.encode('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
        '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="ppt/presentation.xml"/>'
        '<Relationship Id="rId2" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" Target="docProps/core.xml"/>'
        '</Relationships>');
    parts['docProps/core.xml'] = utf8.encode(_coreProps(title));
    parts['ppt/presentation.xml'] = utf8.encode('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<p:presentation $pNs saveSubsetFonts="1">'
        '<p:sldMasterIdLst><p:sldMasterId id="2147483648" r:id="rId1"/></p:sldMasterIdLst>'
        '<p:sldIdLst>$sldIds</p:sldIdLst><p:sldSz cx="$cx" cy="$cy"/><p:notesSz cx="6858000" cy="9144000"/>'
        '</p:presentation>');
    parts['ppt/_rels/presentation.xml.rels'] = utf8.encode('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">$presRels</Relationships>');
    parts['ppt/slideMasters/slideMaster1.xml'] = utf8.encode('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<p:sldMaster $pNs><p:cSld><p:bg><p:bgRef idx="1001"><a:schemeClr val="bg1"/></p:bgRef></p:bg><p:spTree>$emptyTree</p:spTree></p:cSld>'
        '<p:clrMap bg1="lt1" tx1="dk1" bg2="lt2" tx2="dk2" accent1="accent1" accent2="accent2" accent3="accent3" accent4="accent4" accent5="accent5" accent6="accent6" hlink="hlink" folHlink="folHlink"/>'
        '<p:sldLayoutIdLst><p:sldLayoutId id="2147483649" r:id="rId1"/></p:sldLayoutIdLst></p:sldMaster>');
    parts['ppt/slideMasters/_rels/slideMaster1.xml.rels'] = utf8.encode('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
        '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideLayout" Target="../slideLayouts/slideLayout1.xml"/>'
        '<Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/theme" Target="../theme/theme1.xml"/>'
        '</Relationships>');
    parts['ppt/slideLayouts/slideLayout1.xml'] = utf8.encode('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<p:sldLayout $pNs type="blank" preserve="1"><p:cSld name="Blank"><p:spTree>$emptyTree</p:spTree></p:cSld>'
        '<p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sldLayout>');
    parts['ppt/slideLayouts/_rels/slideLayout1.xml.rels'] = utf8.encode('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
        '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideMaster" Target="../slideMasters/slideMaster1.xml"/>'
        '</Relationships>');
    parts['ppt/theme/theme1.xml'] = utf8.encode(_theme);
    return _pack(parts);
  }

  static const _theme = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<a:theme xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" name="DocuScan">'
      '<a:themeElements><a:clrScheme name="DocuScan">'
      '<a:dk1><a:sysClr val="windowText" lastClr="000000"/></a:dk1><a:lt1><a:sysClr val="window" lastClr="FFFFFF"/></a:lt1>'
      '<a:dk2><a:srgbClr val="15201C"/></a:dk2><a:lt2><a:srgbClr val="F6F7F4"/></a:lt2>'
      '<a:accent1><a:srgbClr val="1E7054"/></a:accent1><a:accent2><a:srgbClr val="3466C9"/></a:accent2>'
      '<a:accent3><a:srgbClr val="B4532A"/></a:accent3><a:accent4><a:srgbClr val="7A4BC2"/></a:accent4>'
      '<a:accent5><a:srgbClr val="C03A6B"/></a:accent5><a:accent6><a:srgbClr val="2F8F9D"/></a:accent6>'
      '<a:hlink><a:srgbClr val="0563C1"/></a:hlink><a:folHlink><a:srgbClr val="954F72"/></a:folHlink></a:clrScheme>'
      '<a:fontScheme name="DocuScan"><a:majorFont><a:latin typeface="Calibri"/><a:ea typeface=""/><a:cs typeface=""/></a:majorFont>'
      '<a:minorFont><a:latin typeface="Calibri"/><a:ea typeface=""/><a:cs typeface=""/></a:minorFont></a:fontScheme>'
      '<a:fmtScheme name="DocuScan"><a:fillStyleLst>'
      '<a:solidFill><a:schemeClr val="phClr"/></a:solidFill><a:solidFill><a:schemeClr val="phClr"/></a:solidFill><a:solidFill><a:schemeClr val="phClr"/></a:solidFill>'
      '</a:fillStyleLst><a:lnStyleLst>'
      '<a:ln w="6350"><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:ln><a:ln w="12700"><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:ln><a:ln w="19050"><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:ln>'
      '</a:lnStyleLst><a:effectStyleLst><a:effectStyle><a:effectLst/></a:effectStyle><a:effectStyle><a:effectLst/></a:effectStyle><a:effectStyle><a:effectLst/></a:effectStyle></a:effectStyleLst>'
      '<a:bgFillStyleLst><a:solidFill><a:schemeClr val="phClr"/></a:solidFill><a:solidFill><a:schemeClr val="phClr"/></a:solidFill><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:bgFillStyleLst>'
      '</a:fmtScheme></a:themeElements></a:theme>';
}

// ------------------------------------------------------------- models

sealed class DocBlock {
  const DocBlock();
}

class DocRun {
  const DocRun(this.text, {this.bold = false, this.italic = false, this.underline = false});
  final String text;
  final bool bold, italic, underline;
}

class DocParagraph extends DocBlock {
  const DocParagraph(this.runs, {this.heading = 0, this.bullet = false});
  final List<DocRun> runs;
  final int heading;
  final bool bullet;
  String get text => runs.map((r) => r.text).join();
}

class DocTable extends DocBlock {
  const DocTable(this.rows);
  final List<List<String>> rows;
}

class DocImage extends DocBlock {
  const DocImage(this.bytes);
  final Uint8List bytes;
}

class DocPageBreak extends DocBlock {
  const DocPageBreak();
}

class SheetData {
  const SheetData(this.name, this.rows);
  final String name;
  final List<List<String>> rows;
}

class SlideData {
  const SlideData(this.title, this.paragraphs, this.images);
  final String? title;
  final List<String> paragraphs;
  final List<Uint8List> images;
}

class DocxPage {
  const DocxPage({this.paragraphs = const [], this.image, this.imageWidth = 0, this.imageHeight = 0});
  final List<String> paragraphs;
  final Uint8List? image;
  final int imageWidth;
  final int imageHeight;
}

class PptxSlideImage {
  const PptxSlideImage(this.jpeg, this.width, this.height);
  final Uint8List jpeg;
  final int width;
  final int height;
}
