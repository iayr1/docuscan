import 'dart:math' as math;
import 'dart:typed_data';

import 'image_types.dart';
import 'rgb_buffer.dart';

/// 3×3 projective transform stored row-major with h[8] == 1.
class Homography {
  Homography(this.h);
  final List<double> h;

  Pt apply(double x, double y) {
    final w = h[6] * x + h[7] * y + h[8];
    return Pt((h[0] * x + h[1] * y + h[2]) / w, (h[3] * x + h[4] * y + h[5]) / w);
  }

  /// Solves the transform mapping each `from[i]` onto `to[i]` (4 point pairs).
  static Homography fromPoints(List<Pt> from, List<Pt> to) {
    // Build the 8×9 augmented system A·h = b.
    final a = List.generate(8, (_) => List<double>.filled(9, 0));
    for (var i = 0; i < 4; i++) {
      final x = from[i].x, y = from[i].y, u = to[i].x, v = to[i].y;
      a[2 * i]
        ..[0] = x
        ..[1] = y
        ..[2] = 1
        ..[6] = -u * x
        ..[7] = -u * y
        ..[8] = u;
      a[2 * i + 1]
        ..[3] = x
        ..[4] = y
        ..[5] = 1
        ..[6] = -v * x
        ..[7] = -v * y
        ..[8] = v;
    }
    // Gaussian elimination with partial pivoting.
    for (var col = 0; col < 8; col++) {
      var pivot = col;
      for (var r = col + 1; r < 8; r++) {
        if (a[r][col].abs() > a[pivot][col].abs()) pivot = r;
      }
      if (a[pivot][col].abs() < 1e-12) {
        throw ArgumentError('Degenerate corner configuration');
      }
      final tmp = a[col];
      a[col] = a[pivot];
      a[pivot] = tmp;
      for (var r = 0; r < 8; r++) {
        if (r == col) continue;
        final f = a[r][col] / a[col][col];
        if (f == 0) continue;
        for (var c = col; c < 9; c++) {
          a[r][c] -= f * a[col][c];
        }
      }
    }
    return Homography([for (var i = 0; i < 8; i++) a[i][8] / a[i][i], 1]);
  }
}

/// Output size (px) for warping the pixel-space quad [q]: the longest opposing edges.
(int, int) warpOutputSize(List<Pt> q) {
  final w = math.max(q[0].distanceTo(q[1]), q[3].distanceTo(q[2]));
  final h = math.max(q[0].distanceTo(q[3]), q[1].distanceTo(q[2]));
  return (math.max(1, w.round()), math.max(1, h.round()));
}

/// Four-point perspective correction. [quad] is normalized to [src].
RgbBuffer warpPerspective(RgbBuffer src, Quad quad, {int? maxEdge}) {
  final pts = quad.points.map((p) => Pt(p.x * (src.width - 1), p.y * (src.height - 1))).toList();
  var (outW, outH) = warpOutputSize(pts);
  if (maxEdge != null && math.max(outW, outH) > maxEdge) {
    final s = maxEdge / math.max(outW, outH);
    outW = math.max(1, (outW * s).round());
    outH = math.max(1, (outH * s).round());
  }
  final dst = [Pt(0, 0), Pt(outW - 1.0, 0), Pt(outW - 1.0, outH - 1.0), Pt(0, outH - 1.0)];
  final hm = Homography.fromPoints(dst, pts).h;
  final out = Uint8List(outW * outH * 3);
  final sw = src.width, sh = src.height, sd = src.data;
  var o = 0;
  for (var y = 0; y < outH; y++) {
    for (var x = 0; x < outW; x++) {
      final w = hm[6] * x + hm[7] * y + hm[8];
      final fx = (hm[0] * x + hm[1] * y + hm[2]) / w;
      final fy = (hm[3] * x + hm[4] * y + hm[5]) / w;
      _bilinear(sd, sw, sh, fx, fy, out, o);
      o += 3;
    }
  }
  return RgbBuffer(outW, outH, out);
}

/// Rotates by an arbitrary [degrees] (clockwise) around the center, filling with white.
RgbBuffer rotateArbitrary(RgbBuffer src, double degrees) {
  if (degrees.abs() < 0.05) return src;
  final rad = degrees * math.pi / 180;
  final c = math.cos(rad), s = math.sin(rad);
  final w = src.width, h = src.height;
  final nw = (w * c.abs() + h * s.abs()).round();
  final nh = (w * s.abs() + h * c.abs()).round();
  final out = Uint8List(nw * nh * 3)..fillRange(0, nw * nh * 3, 255);
  final cx = w / 2, cy = h / 2, ncx = nw / 2, ncy = nh / 2;
  var o = 0;
  for (var y = 0; y < nh; y++) {
    for (var x = 0; x < nw; x++) {
      final dx = x - ncx, dy = y - ncy;
      final sx = c * dx + s * dy + cx;
      final sy = -s * dx + c * dy + cy;
      if (sx >= 0 && sy >= 0 && sx <= w - 1 && sy <= h - 1) {
        _bilinear(src.data, w, h, sx, sy, out, o);
      }
      o += 3;
    }
  }
  return RgbBuffer(nw, nh, out);
}

void _bilinear(Uint8List sd, int sw, int sh, double fx, double fy, Uint8List out, int o) {
  if (fx < 0) fx = 0;
  if (fy < 0) fy = 0;
  if (fx > sw - 1) fx = sw - 1.0;
  if (fy > sh - 1) fy = sh - 1.0;
  final x0 = fx.floor(), y0 = fy.floor();
  final x1 = x0 + 1 < sw ? x0 + 1 : x0, y1 = y0 + 1 < sh ? y0 + 1 : y0;
  final ax = fx - x0, ay = fy - y0;
  final i00 = (y0 * sw + x0) * 3, i10 = (y0 * sw + x1) * 3;
  final i01 = (y1 * sw + x0) * 3, i11 = (y1 * sw + x1) * 3;
  for (var ch = 0; ch < 3; ch++) {
    final top = sd[i00 + ch] + (sd[i10 + ch] - sd[i00 + ch]) * ax;
    final bottom = sd[i01 + ch] + (sd[i11 + ch] - sd[i01 + ch]) * ax;
    out[o + ch] = (top + (bottom - top) * ay).round();
  }
}

/// Estimates text skew in degrees (−[maxAngle]..[maxAngle]) using the
/// projection-profile method on dark pixels. Positive = rotate clockwise to fix.
double estimateSkew(RgbBuffer src, {double maxAngle = 10, double step = 0.25}) {
  final small = src.fitWithin(700);
  final gray = small.luma();
  final t = otsuThreshold(gray);
  final xs = <int>[], ys = <int>[];
  for (var y = 0; y < small.height; y++) {
    for (var x = 0; x < small.width; x++) {
      if (gray[y * small.width + x] < t) {
        xs.add(x);
        ys.add(y);
      }
    }
  }
  // Too few or too many dark pixels: not a text page; leave it alone.
  if (xs.length < 200 || xs.length > small.pixelCount * 0.5) return 0;
  final diag = (math.sqrt(small.width * small.width + small.height * small.height)).ceil();
  var bestAngle = 0.0, bestScore = -1.0;
  for (var a = -maxAngle; a <= maxAngle + 1e-9; a += step) {
    final rad = a * math.pi / 180;
    final s = math.sin(rad), c = math.cos(rad);
    final bins = Int32List(diag * 2 + 2);
    for (var i = 0; i < xs.length; i++) {
      final r = (-xs[i] * s + ys[i] * c).round() + diag;
      bins[r]++;
    }
    var score = 0.0;
    for (var i = 1; i < bins.length; i++) {
      final d = (bins[i] - bins[i - 1]).toDouble();
      score += d * d;
    }
    if (score > bestScore) {
      bestScore = score;
      bestAngle = a;
    }
  }
  return -bestAngle;
}
