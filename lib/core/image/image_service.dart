import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;

import '../constants/app_constants.dart';
import 'document_detector.dart';
import 'filters.dart';
import 'geometry.dart';
import 'image_types.dart';
import 'rgb_buffer.dart';

class ProcessedImage {
  const ProcessedImage({required this.bytes, required this.thumbnail, required this.width, required this.height});
  final Uint8List bytes;
  final Uint8List thumbnail;
  final int width;
  final int height;
}

/// A normalized rectangle (0..1) on a page.
class NRect {
  const NRect(this.left, this.top, this.width, this.height);
  final double left, top, width, height;
}

/// CPU-heavy image work. Every public method runs in a background isolate so
/// the UI thread never blocks; only plain data crosses isolate boundaries.
class ImageService {
  const ImageService();

  /// Full-quality render of a page from its original capture.
  Future<ProcessedImage> processPage(
    String originalPath,
    PageEdit edit, {
    int maxEdge = AppConstants.maxProcessedEdge,
    int quality = 88,
  }) {
    final json = edit.toJson();
    return Isolate.run(() {
      final bytes = File(originalPath).readAsBytesSync();
      final out = renderEdit(
        RgbBuffer.decode(bytes, maxEdge: (maxEdge * 1.4).round(), name: originalPath),
        PageEdit.fromJson(json),
        maxEdge: maxEdge,
      );
      return ProcessedImage(
        bytes: out.encodeJpg(quality: quality),
        thumbnail: out.fitWithin(AppConstants.thumbnailEdge).encodeJpg(quality: 78),
        width: out.width,
        height: out.height,
      );
    });
  }

  /// Decodes an image file into a small RGB buffer suitable for live previews.
  Future<RgbBuffer> loadPreviewBase(String path, {int maxEdge = 1100}) =>
      Isolate.run(() => RgbBuffer.decode(File(path).readAsBytesSync(), maxEdge: maxEdge, name: path));

  /// Renders [edit] on an already decoded preview buffer and returns JPEG bytes.
  Future<Uint8List> renderPreview(RgbBuffer base, PageEdit edit) {
    final json = edit.toJson();
    return Isolate.run(() => renderEdit(base, PageEdit.fromJson(json)).encodeJpg(quality: 85));
  }

  /// Automatic boundary detection on an image file. Returns null when no
  /// confident document outline was found.
  Future<Quad?> detectDocument(String path) => Isolate.run(() {
        final buf = RgbBuffer.decode(File(path).readAsBytesSync(), maxEdge: 600, name: path);
        return DocumentDetector.detect(buf)?.quad;
      });

  Future<(int, int)> dimensions(String path) => Isolate.run(() {
        final buf = RgbBuffer.decode(File(path).readAsBytesSync(), name: path);
        return (buf.width, buf.height);
      });

  Future<Uint8List> thumbnail(String path, {int edge = AppConstants.thumbnailEdge}) =>
      Isolate.run(() => RgbBuffer.decode(File(path).readAsBytesSync(), maxEdge: edge, name: path).encodeJpg(quality: 78));

  /// Normalizes any image file into an oriented JPEG (and clamps size).
  Future<Uint8List> normalizeToJpeg(Uint8List bytes, {int maxEdge = 4000, int quality = 92}) =>
      Isolate.run(() => RgbBuffer.decode(bytes, maxEdge: maxEdge).encodeJpg(quality: quality));

  Future<Uint8List> toPng(Uint8List bytes) => Isolate.run(() => RgbBuffer.decode(bytes).encodePng());

  /// Re-encodes for compression.
  Future<Uint8List> recompress(Uint8List bytes, {required int maxEdge, required int quality}) =>
      Isolate.run(() => RgbBuffer.decode(bytes, maxEdge: maxEdge).encodeJpg(quality: quality));

  /// Paints black boxes into an image file in place (permanent redaction).
  Future<void> burnRedactions(String path, List<NRect> rects) {
    final data = [for (final r in rects) [r.left, r.top, r.width, r.height]];
    return Isolate.run(() {
      final buf = RgbBuffer.decode(File(path).readAsBytesSync(), name: path);
      for (final r in data) {
        buf.fillRect(
          (r[0] * buf.width).floor(),
          (r[1] * buf.height).floor(),
          (r[2] * buf.width).ceil() + 1,
          (r[3] * buf.height).ceil() + 1,
          0,
          0,
          0,
        );
      }
      final tmp = File('$path.tmp')..writeAsBytesSync(buf.encodeJpg(quality: 92), flush: true);
      tmp.renameSync(path);
    });
  }

  /// Extracts ink strokes from a photo of a signature/stamp: background becomes
  /// transparent and strokes are recoloured with [argb] (0 keeps original colours).
  Future<Uint8List> extractInk(Uint8List bytes, {int argb = 0xFF0D1B4C, double sensitivity = 0.5}) =>
      Isolate.run(() => extractInkSync(bytes, argb: argb, sensitivity: sensitivity));

  /// Places the front and back of an ID card on a single A4 page (300 dpi).
  Future<Uint8List> composeIdCard(String frontPath, String backPath) => Isolate.run(() {
        const pageW = 2480, pageH = 3508; // A4 @ 300dpi
        const cardW = 1300; // ~110 mm: slightly enlarged ID-1 for legibility
        final page = RgbBuffer.filled(pageW, pageH, 255, 255, 255);
        var y = 360;
        for (final path in [frontPath, backPath]) {
          final card = RgbBuffer.decode(File(path).readAsBytesSync(), name: path);
          final scale = cardW / card.width;
          final h = math.min((card.height * scale).round(), 1300);
          final w = (card.width * (h / card.height)).round();
          final resized = card.resized(w, h);
          page.blit(resized, (pageW - w) ~/ 2, y);
          y += h + 260;
        }
        return page.encodeJpg(quality: 90);
      });

  /// Splits a two-page book spread into left and right pages.
  Future<List<Uint8List>> splitSpread(String path) => Isolate.run(() {
        final buf = RgbBuffer.decode(File(path).readAsBytesSync(), name: path);
        final half = buf.width ~/ 2;
        return [
          buf.crop(0, 0, half, buf.height).encodeJpg(quality: 92),
          buf.crop(half, 0, buf.width - half, buf.height).encodeJpg(quality: 92),
        ];
      });

  /// Rotates an image file by quarter turns, in place.
  Future<void> rotateFile(String path, int turns) => Isolate.run(() {
        final buf = RgbBuffer.decode(File(path).readAsBytesSync(), name: path).rotate90(turns);
        final tmp = File('$path.tmp')..writeAsBytesSync(buf.encodeJpg(quality: 92), flush: true);
        tmp.renameSync(path);
      });

  /// Converts raw BGRA pixels (e.g. from the PDF renderer) to JPEG or PNG.
  Future<Uint8List> encodeBgra(Uint8List bgra, int width, int height, {bool png = false, int quality = 90}) =>
      Isolate.run(() {
        final image = img.Image.fromBytes(
          width: width,
          height: height,
          bytes: bgra.buffer,
          bytesOffset: bgra.offsetInBytes,
          numChannels: 4,
          order: img.ChannelOrder.bgra,
        );
        return png ? img.encodePng(image) : RgbBuffer.fromImage(image).encodeJpg(quality: quality);
      });
}

/// Pure pipeline shared by previews, saving and tests.
RgbBuffer renderEdit(RgbBuffer base, PageEdit edit, {int? maxEdge}) {
  var buf = base;
  final quad = edit.quad;
  if (quad != null && !quad.isFull && quad.isConvex && quad.area > 0.01) {
    buf = warpPerspective(buf, quad, maxEdge: maxEdge);
  } else if (maxEdge != null) {
    buf = buf.fitWithin(maxEdge);
  }
  buf = buf.rotate90(edit.rotation);
  if (edit.deskew) {
    final angle = estimateSkew(buf);
    if (angle.abs() >= 0.3) buf = rotateArbitrary(buf, angle);
  }
  buf = Filters.apply(buf, edit.filter);
  buf = Filters.adjust(buf, edit.adjustments);
  return buf;
}

Uint8List extractInkSync(Uint8List bytes, {int argb = 0xFF0D1B4C, double sensitivity = 0.5}) {
  final src = RgbBuffer.decode(bytes, maxEdge: 1600);
  final norm = Filters.removeShadows(src);
  final gray = norm.luma();
  final t = otsuThreshold(gray);
  final cutoff = (t + (255 - t) * (0.15 + 0.35 * sensitivity)).clamp(40, 250).toDouble();
  final out = img.Image(width: src.width, height: src.height, numChannels: 4);
  final keepColor = argb == 0;
  final r0 = (argb >> 16) & 0xFF, g0 = (argb >> 8) & 0xFF, b0 = argb & 0xFF;
  // Crop to the ink bounding box so placed signatures have no empty margins.
  var minX = src.width, minY = src.height, maxX = -1, maxY = -1;
  for (var y = 0; y < src.height; y++) {
    for (var x = 0; x < src.width; x++) {
      final i = y * src.width + x;
      final l = gray[i];
      if (l >= cutoff) {
        out.setPixelRgba(x, y, 0, 0, 0, 0);
        continue;
      }
      final alpha = ((cutoff - l) / cutoff * 255 * 1.8).clamp(0, 255).round();
      if (alpha < 24) {
        out.setPixelRgba(x, y, 0, 0, 0, 0);
        continue;
      }
      if (keepColor) {
        out.setPixelRgba(x, y, norm.data[i * 3], norm.data[i * 3 + 1], norm.data[i * 3 + 2], alpha);
      } else {
        out.setPixelRgba(x, y, r0, g0, b0, alpha);
      }
      if (x < minX) minX = x;
      if (y < minY) minY = y;
      if (x > maxX) maxX = x;
      if (y > maxY) maxY = y;
    }
  }
  if (maxX < 0) return img.encodePng(out);
  const pad = 8;
  final cx = math.max(0, minX - pad), cy = math.max(0, minY - pad);
  final cropped = img.copyCrop(out,
      x: cx, y: cy, width: math.min(src.width - cx, maxX - minX + pad * 2), height: math.min(src.height - cy, maxY - minY + pad * 2));
  return img.encodePng(cropped);
}
