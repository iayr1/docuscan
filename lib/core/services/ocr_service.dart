import 'dart:math' as math;

import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';

import '../../data/models/models.dart';
import '../storage/settings_store.dart';

class OcrOutput {
  const OcrOutput(this.text, this.lines, this.script);
  final String text;
  final List<OcrBlock> lines;
  final String script;
  bool get isEmpty => text.trim().isEmpty;
}

/// On-device OCR using Google ML Kit Text Recognition v2.
///
/// * Models are bundled with the app (no download, works offline).
/// * Scripts: Latin, Devanagari (Hindi, Marathi, Nepali…), Chinese, Japanese,
///   Korean. One script model is used per pass.
/// * Handwriting: ML Kit's text recognizer is trained for printed text; neat
///   handwriting often works for Latin script, cursive generally does not.
///   (ML Kit Digital Ink is for live stylus strokes, not photos.)
class OcrService {
  OcrService();

  final Map<OcrLanguage, TextRecognizer> _recognizers = {};

  TextRecognizer _recognizer(OcrLanguage lang) => _recognizers.putIfAbsent(
        lang,
        () => TextRecognizer(
          script: switch (lang) {
            OcrLanguage.latin => TextRecognitionScript.latin,
            OcrLanguage.devanagari => TextRecognitionScript.devanagiri,
            OcrLanguage.chinese => TextRecognitionScript.chinese,
            OcrLanguage.japanese => TextRecognitionScript.japanese,
            OcrLanguage.korean => TextRecognitionScript.korean,
          },
        ),
      );

  /// Recognises text in an image file. [width]/[height] are the image's pixel
  /// dimensions, used to normalise line boxes for the searchable PDF layer.
  Future<OcrOutput> recognizeFile(String path, {required OcrLanguage language, required int width, required int height}) async {
    final result = await _recognizer(language).processImage(InputImage.fromFilePath(path));
    final lines = <OcrBlock>[];
    final w = math.max(1, width).toDouble(), h = math.max(1, height).toDouble();
    for (final block in result.blocks) {
      for (final line in block.lines) {
        final r = line.boundingBox;
        lines.add(OcrBlock(line.text, r.left / w, r.top / h, r.width / w, r.height / h));
      }
    }
    return OcrOutput(result.text, lines, language.name);
  }

  Future<void> dispose() async {
    for (final r in _recognizers.values) {
      await r.close();
    }
    _recognizers.clear();
  }
}

/// Layout helpers that turn line boxes into structure.
abstract final class OcrLayout {
  /// Groups OCR lines into table rows by vertical overlap, then orders cells
  /// left-to-right. Works for printed tables with clear row spacing; merged
  /// cells and multi-line cells are not reconstructed.
  static List<List<String>> toTableRows(List<OcrBlock> lines) {
    final sorted = List.of(lines)..sort((a, b) => (a.top + a.height / 2).compareTo(b.top + b.height / 2));
    final rows = <List<OcrBlock>>[];
    for (final l in sorted) {
      final cy = l.top + l.height / 2;
      final row = rows.isEmpty ? null : rows.last;
      if (row != null) {
        final ref = row.first;
        final refCy = ref.top + ref.height / 2;
        if ((cy - refCy).abs() < math.max(ref.height, l.height) * 0.55) {
          row.add(l);
          continue;
        }
      }
      rows.add([l]);
    }
    return [
      for (final r in rows) [for (final c in (r..sort((a, b) => a.left.compareTo(b.left)))) c.text.trim()],
    ];
  }

  static String toCsv(List<List<String>> rows) => rows
      .map((r) => r.map((c) => c.contains(RegExp('[",\n]')) ? '"${c.replaceAll('"', '""')}"' : c).join(','))
      .join('\n');

  /// Reading-order text rebuilt from lines (useful after edits to boxes).
  static String toText(List<OcrBlock> lines) => toTableRows(lines).map((r) => r.join('  ')).join('\n');
}
