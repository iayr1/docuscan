import 'dart:math' as math;
import 'dart:typed_data';

import 'image_types.dart';
import 'rgb_buffer.dart';

/// Document enhancement filters and tonal adjustments.
abstract final class Filters {
  static RgbBuffer apply(RgbBuffer src, ScanFilter filter) {
    switch (filter) {
      case ScanFilter.original:
        return src;
      case ScanFilter.auto:
        return sharpen(autoLevels(src, lowPct: 0.01, highPct: 0.985), 0.35);
      case ScanFilter.magic:
        return saturate(autoLevels(removeShadows(src), lowPct: 0.02, highPct: 0.97), 0.35);
      case ScanFilter.grayscale:
        return autoLevels(grayscale(removeShadows(src, strength: 0.6)), lowPct: 0.01, highPct: 0.99);
      case ScanFilter.blackWhite:
        return adaptiveThreshold(src);
      case ScanFilter.whiteboard:
        return whitenBackground(saturate(autoLevels(removeShadows(src), lowPct: 0.03, highPct: 0.9), 0.6), 0.8);
      case ScanFilter.ecoPrint:
        return whitenBackground(grayscale(autoLevels(removeShadows(src), lowPct: 0.0, highPct: 0.92)), 1.0);
      case ScanFilter.photo:
        return saturate(autoLevels(src, lowPct: 0.005, highPct: 0.995), 0.1);
    }
  }

  static RgbBuffer grayscale(RgbBuffer src) {
    final out = RgbBuffer(src.width, src.height);
    final d = src.data, o = out.data;
    for (var i = 0; i < d.length; i += 3) {
      final l = (d[i] * 77 + d[i + 1] * 150 + d[i + 2] * 29) >> 8;
      o[i] = l;
      o[i + 1] = l;
      o[i + 2] = l;
    }
    return out;
  }

  /// Linear contrast stretch using luma percentiles (applied equally to RGB to keep hue).
  static RgbBuffer autoLevels(RgbBuffer src, {double lowPct = 0.01, double highPct = 0.99}) {
    final hist = List<int>.filled(256, 0);
    final d = src.data;
    for (var i = 0; i < d.length; i += 3) {
      hist[(d[i] * 77 + d[i + 1] * 150 + d[i + 2] * 29) >> 8]++;
    }
    final n = src.pixelCount;
    var acc = 0, lo = 0, hi = 255;
    for (var v = 0; v < 256; v++) {
      acc += hist[v];
      if (acc >= n * lowPct) {
        lo = v;
        break;
      }
    }
    acc = 0;
    for (var v = 255; v >= 0; v--) {
      acc += hist[v];
      if (acc >= n * (1 - highPct)) {
        hi = v;
        break;
      }
    }
    if (hi - lo < 10) return src;
    final lut = Uint8List(256);
    for (var v = 0; v < 256; v++) {
      lut[v] = (((v - lo) * 255) / (hi - lo)).round().clamp(0, 255);
    }
    return _mapLut(src, lut, lut, lut);
  }

  /// Estimates the illumination (paper colour incl. shadows) per channel with a
  /// downscaled max-filter + blur, then divides it out. This removes shadows,
  /// uneven lighting and colour casts while keeping ink colours.
  static RgbBuffer removeShadows(RgbBuffer src, {double strength = 1.0}) {
    final w = src.width, h = src.height;
    const factor = 8;
    final sw = math.max(1, w ~/ factor), sh = math.max(1, h ~/ factor);
    final planes = splitPlanes(src);
    final out = RgbBuffer(w, h);
    for (var c = 0; c < 3; c++) {
      final plane = planes[c];
      // Downscale taking the block maximum (ink is darker than paper).
      var small = Uint8List(sw * sh);
      for (var y = 0; y < sh; y++) {
        for (var x = 0; x < sw; x++) {
          var m = 0;
          final y0 = y * factor, x0 = x * factor;
          final y1 = math.min(h, y0 + factor), x1 = math.min(w, x0 + factor);
          for (var yy = y0; yy < y1; yy++) {
            for (var xx = x0; xx < x1; xx++) {
              final v = plane[yy * w + xx];
              if (v > m) m = v;
            }
          }
          small[y * sw + x] = m;
        }
      }
      small = _maxFilter(small, sw, sh, 2);
      small = boxBlurPlane(small, sw, sh, 3);
      // Bilinear upsample of the background estimate and divide.
      for (var y = 0; y < h; y++) {
        final fy = (y / factor - 0.5).clamp(0.0, sh - 1.0);
        final y0 = fy.floor(), y1 = math.min(sh - 1, y0 + 1);
        final ay = fy - y0;
        for (var x = 0; x < w; x++) {
          final fx = (x / factor - 0.5).clamp(0.0, sw - 1.0);
          final x0 = fx.floor(), x1 = math.min(sw - 1, x0 + 1);
          final ax = fx - x0;
          final top = small[y0 * sw + x0] + (small[y0 * sw + x1] - small[y0 * sw + x0]) * ax;
          final bot = small[y1 * sw + x0] + (small[y1 * sw + x1] - small[y1 * sw + x0]) * ax;
          final bg = math.max(16.0, top + (bot - top) * ay);
          final v = plane[y * w + x];
          final normalized = (v / bg * 255).clamp(0.0, 255.0);
          out.data[(y * w + x) * 3 + c] = (v + (normalized - v) * strength).round();
        }
      }
    }
    return out;
  }

  static Uint8List _maxFilter(Uint8List src, int w, int h, int r) {
    final tmp = Uint8List(w * h), out = Uint8List(w * h);
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        var m = 0;
        for (var k = math.max(0, x - r); k <= math.min(w - 1, x + r); k++) {
          if (src[y * w + k] > m) m = src[y * w + k];
        }
        tmp[y * w + x] = m;
      }
    }
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        var m = 0;
        for (var k = math.max(0, y - r); k <= math.min(h - 1, y + r); k++) {
          if (tmp[k * w + x] > m) m = tmp[k * w + x];
        }
        out[y * w + x] = m;
      }
    }
    return out;
  }

  /// Bradley–Roth adaptive threshold on shadow-corrected luma → crisp B&W.
  static RgbBuffer adaptiveThreshold(RgbBuffer src, {double t = 0.12}) {
    final norm = removeShadows(src);
    final w = src.width, h = src.height;
    final gray = norm.luma();
    final window = math.max(8, math.max(w, h) ~/ 24);
    final mean = boxBlurPlane(gray, w, h, window ~/ 2);
    final out = RgbBuffer(w, h);
    for (var i = 0; i < gray.length; i++) {
      final v = gray[i] < mean[i] * (1 - t) && gray[i] < 200 ? 0 : 255;
      out.data[i * 3] = v;
      out.data[i * 3 + 1] = v;
      out.data[i * 3 + 2] = v;
    }
    return out;
  }

  static RgbBuffer saturate(RgbBuffer src, double amount) {
    if (amount == 0) return src;
    final out = RgbBuffer(src.width, src.height);
    final d = src.data, o = out.data;
    final f = 1 + amount;
    for (var i = 0; i < d.length; i += 3) {
      final l = (d[i] * 77 + d[i + 1] * 150 + d[i + 2] * 29) >> 8;
      o[i] = (l + (d[i] - l) * f).round().clamp(0, 255);
      o[i + 1] = (l + (d[i + 1] - l) * f).round().clamp(0, 255);
      o[i + 2] = (l + (d[i + 2] - l) * f).round().clamp(0, 255);
    }
    return out;
  }

  /// Pushes bright, low-saturation (paper) pixels to pure white.
  static RgbBuffer whitenBackground(RgbBuffer src, double amount) {
    if (amount <= 0) return src;
    final out = src.clone();
    final d = out.data;
    final threshold = 235 - 70 * amount;
    for (var i = 0; i < d.length; i += 3) {
      final r = d[i], g = d[i + 1], b = d[i + 2];
      final l = (r * 77 + g * 150 + b * 29) >> 8;
      if (l <= threshold) continue;
      final chroma = math.max(r, math.max(g, b)) - math.min(r, math.min(g, b));
      if (chroma > 60) continue;
      final k = ((l - threshold) / (255 - threshold)).clamp(0.0, 1.0) * amount;
      final kk = math.min(1.0, k * 1.6);
      d[i] = (r + (255 - r) * kk).round();
      d[i + 1] = (g + (255 - g) * kk).round();
      d[i + 2] = (b + (255 - b) * kk).round();
    }
    return out;
  }

  /// Unsharp mask (radius 1).
  static RgbBuffer sharpen(RgbBuffer src, double amount) {
    if (amount <= 0) return src;
    final planes = splitPlanes(src);
    final out = RgbBuffer(src.width, src.height);
    for (var c = 0; c < 3; c++) {
      final blur = boxBlurPlane(planes[c], src.width, src.height, 1);
      final p = planes[c];
      for (var i = 0; i < p.length; i++) {
        out.data[i * 3 + c] = (p[i] + (p[i] - blur[i]) * amount * 1.5).round().clamp(0, 255);
      }
    }
    return out;
  }

  /// Edge-preserving smoothing: replaces a pixel by its local mean only where
  /// local variation is small (flat paper / sensor noise), keeping text edges.
  static RgbBuffer denoise(RgbBuffer src, double amount) {
    if (amount <= 0) return src;
    final planes = splitPlanes(src);
    final out = RgbBuffer(src.width, src.height);
    final radius = amount > 0.6 ? 2 : 1;
    final tolerance = 10 + 30 * amount;
    for (var c = 0; c < 3; c++) {
      final blur = boxBlurPlane(planes[c], src.width, src.height, radius);
      final p = planes[c];
      for (var i = 0; i < p.length; i++) {
        final diff = (p[i] - blur[i]).abs();
        out.data[i * 3 + c] = diff < tolerance ? (p[i] + (blur[i] - p[i]) * amount).round() : p[i];
      }
    }
    return out;
  }

  /// Applies all fine adjustments. Tonal ones are fused into a single per-channel LUT.
  static RgbBuffer adjust(RgbBuffer src, ImageAdjustments a) {
    if (a.isNeutral) return src;
    var out = src;
    if (a.denoise > 0) out = denoise(out, a.denoise);

    final lutR = Uint8List(256), lutG = Uint8List(256), lutB = Uint8List(256);
    final exposure = math.pow(2, a.exposure * 1.5).toDouble();
    final contrast = 1 + a.contrast * (a.contrast > 0 ? 1.2 : 0.8);
    for (var v = 0; v < 256; v++) {
      var x = v / 255.0;
      x *= exposure;
      x += a.brightness * 0.3;
      x = (x - 0.5) * contrast + 0.5;
      final cx = x.clamp(0.0, 1.0);
      x += a.shadows * 0.35 * (1 - cx) * (1 - cx) * cx * 2;
      x += a.highlights * 0.35 * cx * cx * (1 - cx) * 2;
      if (a.glare > 0 && x > 0.82) x = 0.82 + (x - 0.82) * (1 - a.glare * 0.75);
      final base = x.clamp(0.0, 1.0) * 255;
      lutR[v] = (base + a.warmth * 22).round().clamp(0, 255);
      lutG[v] = (base + a.warmth * 4).round().clamp(0, 255);
      lutB[v] = (base - a.warmth * 22).round().clamp(0, 255);
    }
    out = _mapLut(out, lutR, lutG, lutB);
    if (a.saturation != 0) out = saturate(out, a.saturation);
    if (a.whiten > 0) out = whitenBackground(out, a.whiten);
    if (a.sharpness > 0) out = sharpen(out, a.sharpness);
    return out;
  }

  static RgbBuffer _mapLut(RgbBuffer src, Uint8List r, Uint8List g, Uint8List b) {
    final out = RgbBuffer(src.width, src.height);
    final d = src.data, o = out.data;
    for (var i = 0; i < d.length; i += 3) {
      o[i] = r[d[i]];
      o[i + 1] = g[d[i + 1]];
      o[i + 2] = b[d[i + 2]];
    }
    return out;
  }
}
