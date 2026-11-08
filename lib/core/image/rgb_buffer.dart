import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;

import '../errors/app_exception.dart';

/// A tightly packed 8-bit RGB raster. All processing works on this type
/// instead of `img.Image` pixel accessors, which keeps hot loops fast in AOT.
class RgbBuffer {
  RgbBuffer(this.width, this.height, [Uint8List? data])
      : data = data ?? Uint8List(width * height * 3) {
    assert(this.data.length == width * height * 3);
  }

  final int width;
  final int height;
  final Uint8List data;

  int get pixelCount => width * height;

  RgbBuffer clone() => RgbBuffer(width, height, Uint8List.fromList(data));

  factory RgbBuffer.filled(int width, int height, int r, int g, int b) {
    final buf = RgbBuffer(width, height);
    for (var i = 0; i < buf.data.length; i += 3) {
      buf.data[i] = r;
      buf.data[i + 1] = g;
      buf.data[i + 2] = b;
    }
    return buf;
  }

  /// Decodes JPEG/PNG/WebP/BMP/etc, applies EXIF orientation, flattens alpha onto
  /// white and downsamples so the longest edge is at most [maxEdge].
  static RgbBuffer decode(Uint8List bytes, {int? maxEdge, String name = 'image'}) {
    img.Image? decoded;
    try {
      decoded = img.decodeImage(bytes);
    } catch (e) {
      throw CorruptedFileException(name, cause: e);
    }
    if (decoded == null) throw CorruptedFileException(name);
    var image = img.bakeOrientation(decoded);
    if (maxEdge != null) {
      final longest = math.max(image.width, image.height);
      if (longest > maxEdge) {
        final scale = maxEdge / longest;
        image = img.copyResize(
          image,
          width: math.max(1, (image.width * scale).round()),
          height: math.max(1, (image.height * scale).round()),
          interpolation: img.Interpolation.average,
        );
      }
    }
    return fromImage(image);
  }

  static RgbBuffer fromImage(img.Image image) {
    final w = image.width, h = image.height;
    if (image.hasAlpha) {
      final rgba = image.convert(format: img.Format.uint8, numChannels: 4).getBytes(order: img.ChannelOrder.rgba);
      final out = Uint8List(w * h * 3);
      for (var i = 0, j = 0; i < rgba.length; i += 4, j += 3) {
        final a = rgba[i + 3];
        final inv = 255 - a;
        out[j] = (rgba[i] * a + 255 * inv) ~/ 255;
        out[j + 1] = (rgba[i + 1] * a + 255 * inv) ~/ 255;
        out[j + 2] = (rgba[i + 2] * a + 255 * inv) ~/ 255;
      }
      return RgbBuffer(w, h, out);
    }
    final rgb = image.convert(format: img.Format.uint8, numChannels: 3).getBytes(order: img.ChannelOrder.rgb);
    return RgbBuffer(w, h, Uint8List.fromList(rgb));
  }

  img.Image toImage() => img.Image.fromBytes(
        width: width,
        height: height,
        bytes: data.buffer,
        bytesOffset: data.offsetInBytes,
        numChannels: 3,
        order: img.ChannelOrder.rgb,
      );

  Uint8List encodeJpg({int quality = 90}) => img.encodeJpg(toImage(), quality: quality);

  Uint8List encodePng() => img.encodePng(toImage());

  /// Rec.601 luma plane.
  Uint8List luma() {
    final out = Uint8List(pixelCount);
    for (var i = 0, j = 0; j < out.length; i += 3, j++) {
      out[j] = (data[i] * 77 + data[i + 1] * 150 + data[i + 2] * 29) >> 8;
    }
    return out;
  }

  RgbBuffer resized(int newWidth, int newHeight) {
    if (newWidth == width && newHeight == height) return clone();
    final resized = img.copyResize(toImage(),
        width: newWidth, height: newHeight, interpolation: img.Interpolation.average);
    return fromImage(resized);
  }

  RgbBuffer fitWithin(int maxEdge) {
    final longest = math.max(width, height);
    if (longest <= maxEdge) return this;
    final s = maxEdge / longest;
    return resized(math.max(1, (width * s).round()), math.max(1, (height * s).round()));
  }

  /// Rotates by [turns] × 90° clockwise.
  RgbBuffer rotate90(int turns) {
    final t = ((turns % 4) + 4) % 4;
    if (t == 0) return this;
    final nw = t == 2 ? width : height;
    final nh = t == 2 ? height : width;
    final out = Uint8List(data.length);
    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        int nx, ny;
        switch (t) {
          case 1:
            nx = height - 1 - y;
            ny = x;
          case 2:
            nx = width - 1 - x;
            ny = height - 1 - y;
          default:
            nx = y;
            ny = width - 1 - x;
        }
        final si = (y * width + x) * 3;
        final di = (ny * nw + nx) * 3;
        out[di] = data[si];
        out[di + 1] = data[si + 1];
        out[di + 2] = data[si + 2];
      }
    }
    return RgbBuffer(nw, nh, out);
  }

  /// Crops an axis-aligned rectangle (pixel units, clamped to bounds).
  RgbBuffer crop(int x, int y, int w, int h) {
    final x0 = x.clamp(0, width - 1), y0 = y.clamp(0, height - 1);
    final cw = math.min(w, width - x0), ch = math.min(h, height - y0);
    final out = RgbBuffer(cw, ch);
    for (var row = 0; row < ch; row++) {
      final src = ((y0 + row) * width + x0) * 3;
      out.data.setRange(row * cw * 3, (row + 1) * cw * 3, data, src);
    }
    return out;
  }

  /// Copies [src] into this buffer with its top-left at ([dx], [dy]).
  void blit(RgbBuffer src, int dx, int dy) {
    for (var row = 0; row < src.height; row++) {
      final ty = dy + row;
      if (ty < 0 || ty >= height) continue;
      for (var col = 0; col < src.width; col++) {
        final tx = dx + col;
        if (tx < 0 || tx >= width) continue;
        final si = (row * src.width + col) * 3;
        final di = (ty * width + tx) * 3;
        data[di] = src.data[si];
        data[di + 1] = src.data[si + 1];
        data[di + 2] = src.data[si + 2];
      }
    }
  }

  /// Fills a rectangle (pixel units) with a solid color.
  void fillRect(int x, int y, int w, int h, int r, int g, int b) {
    final x0 = x.clamp(0, width), y0 = y.clamp(0, height);
    final x1 = (x + w).clamp(0, width), y1 = (y + h).clamp(0, height);
    for (var yy = y0; yy < y1; yy++) {
      for (var xx = x0; xx < x1; xx++) {
        final i = (yy * width + xx) * 3;
        data[i] = r;
        data[i + 1] = g;
        data[i + 2] = b;
      }
    }
  }
}

/// Fast box blur of a single 8-bit plane using a summed-area table.
Uint8List boxBlurPlane(Uint8List src, int w, int h, int radius) {
  if (radius <= 0) return Uint8List.fromList(src);
  final stride = w + 1;
  final sat = Uint32List(stride * (h + 1));
  for (var y = 0; y < h; y++) {
    var rowSum = 0;
    for (var x = 0; x < w; x++) {
      rowSum += src[y * w + x];
      sat[(y + 1) * stride + x + 1] = sat[y * stride + x + 1] + rowSum;
    }
  }
  final out = Uint8List(w * h);
  for (var y = 0; y < h; y++) {
    final y0 = math.max(0, y - radius), y1 = math.min(h, y + radius + 1);
    for (var x = 0; x < w; x++) {
      final x0 = math.max(0, x - radius), x1 = math.min(w, x + radius + 1);
      final sum = sat[y1 * stride + x1] - sat[y0 * stride + x1] - sat[y1 * stride + x0] + sat[y0 * stride + x0];
      out[y * w + x] = sum ~/ ((x1 - x0) * (y1 - y0));
    }
  }
  return out;
}

/// Splits RGB into three planes.
List<Uint8List> splitPlanes(RgbBuffer b) {
  final n = b.pixelCount;
  final r = Uint8List(n), g = Uint8List(n), bl = Uint8List(n);
  for (var i = 0, j = 0; j < n; i += 3, j++) {
    r[j] = b.data[i];
    g[j] = b.data[i + 1];
    bl[j] = b.data[i + 2];
  }
  return [r, g, bl];
}

/// Otsu's threshold for an 8-bit plane.
int otsuThreshold(Uint8List plane) {
  final hist = List<int>.filled(256, 0);
  for (final v in plane) {
    hist[v]++;
  }
  final total = plane.length;
  var sum = 0.0;
  for (var i = 0; i < 256; i++) {
    sum += i * hist[i];
  }
  var sumB = 0.0, wB = 0, maxVar = 0.0, threshold = 127;
  for (var t = 0; t < 256; t++) {
    wB += hist[t];
    if (wB == 0) continue;
    final wF = total - wB;
    if (wF == 0) break;
    sumB += t * hist[t];
    final mB = sumB / wB, mF = (sum - sumB) / wF;
    final between = wB * wF * (mB - mF) * (mB - mF);
    if (between > maxVar) {
      maxVar = between;
      threshold = t;
    }
  }
  return threshold;
}
