import 'dart:math' as math;
import 'dart:typed_data';

import 'image_types.dart';
import 'rgb_buffer.dart';

/// Result of a detection pass, normalized to the analysed frame.
class DetectionResult {
  const DetectionResult(this.quad, this.confidence);
  final Quad quad;

  /// 0..1: how rectangular / well separated the found region is.
  final double confidence;
}

/// Finds the dominant document (a bright, roughly quadrilateral region that
/// contrasts with its surroundings) in a grayscale frame.
///
/// Pipeline: downscale → blur → Otsu binarisation → largest connected
/// component → convex hull → maximum-area inscribed quadrilateral → validation.
/// It runs in a few milliseconds on a 160 px frame, so it is used both for
/// still images (in an isolate) and for live camera preview frames.
abstract final class DocumentDetector {
  static const _workEdge = 180;

  static DetectionResult? detect(RgbBuffer image) {
    final small = image.fitWithin(_workEdge);
    return detectLuma(small.luma(), small.width, small.height);
  }

  static DetectionResult? detectLuma(Uint8List luma, int width, int height) {
    var w = width, h = height;
    var plane = luma;
    // Nearest-neighbour downsample if the caller handed us a large plane.
    final longest = math.max(w, h);
    if (longest > _workEdge * 1.5) {
      final step = longest / _workEdge;
      final nw = (w / step).floor(), nh = (h / step).floor();
      final out = Uint8List(nw * nh);
      for (var y = 0; y < nh; y++) {
        final sy = (y * step).floor() * w;
        for (var x = 0; x < nw; x++) {
          out[y * nw + x] = plane[sy + (x * step).floor()];
        }
      }
      plane = out;
      w = nw;
      h = nh;
    }
    if (w < 16 || h < 16) return null;

    final blurred = boxBlurPlane(plane, w, h, 2);
    final threshold = otsuThreshold(blurred);
    // Reject frames without meaningful contrast.
    var lo = 0, hi = 0, nLo = 0, nHi = 0;
    for (final v in blurred) {
      if (v > threshold) {
        hi += v;
        nHi++;
      } else {
        lo += v;
        nLo++;
      }
    }
    if (nLo == 0 || nHi == 0 || (hi / nHi - lo / nLo) < 28) return null;

    final mask = Uint8List(w * h);
    for (var i = 0; i < mask.length; i++) {
      mask[i] = blurred[i] > threshold ? 1 : 0;
    }
    final component = _largestComponent(mask, w, h);
    if (component == null) return null;
    final (labels, size) = component;
    final total = w * h;
    if (size < total * 0.12) return null;

    final boundary = <Pt>[];
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        if (labels[y * w + x] == 0) continue;
        final edge = x == 0 ||
            y == 0 ||
            x == w - 1 ||
            y == h - 1 ||
            labels[y * w + x - 1] == 0 ||
            labels[y * w + x + 1] == 0 ||
            labels[(y - 1) * w + x] == 0 ||
            labels[(y + 1) * w + x] == 0;
        if (edge) boundary.add(Pt(x.toDouble(), y.toDouble()));
      }
    }
    final hull = convexHull(boundary);
    if (hull.length < 4) return null;
    final corners = maxAreaQuad(hull);
    if (corners == null) return null;

    final quad = Quad(
      Pt(corners[0].x / (w - 1), corners[0].y / (h - 1)),
      Pt(corners[1].x / (w - 1), corners[1].y / (h - 1)),
      Pt(corners[2].x / (w - 1), corners[2].y / (h - 1)),
      Pt(corners[3].x / (w - 1), corners[3].y / (h - 1)),
    );
    if (!quad.isConvex) return null;
    final area = quad.area;
    if (area < 0.12 || area > 0.985) return null;
    final fill = (size / total) / area; // how much of the quad is "paper"
    if (fill < 0.82) return null;
    return DetectionResult(quad, fill.clamp(0.0, 1.0));
  }

  static (Uint8List, int)? _largestComponent(Uint8List mask, int w, int h) {
    final labels = Int32List(w * h);
    var current = 0, bestLabel = 0, bestSize = 0;
    final stack = Int32List(w * h);
    for (var start = 0; start < mask.length; start++) {
      if (mask[start] == 0 || labels[start] != 0) continue;
      current++;
      var sp = 0, size = 0;
      stack[sp++] = start;
      labels[start] = current;
      while (sp > 0) {
        final p = stack[--sp];
        size++;
        final x = p % w, y = p ~/ w;
        void visit(int q) {
          if (mask[q] == 1 && labels[q] == 0) {
            labels[q] = current;
            stack[sp++] = q;
          }
        }

        if (x > 0) visit(p - 1);
        if (x < w - 1) visit(p + 1);
        if (y > 0) visit(p - w);
        if (y < h - 1) visit(p + w);
      }
      if (size > bestSize) {
        bestSize = size;
        bestLabel = current;
      }
    }
    if (bestLabel == 0) return null;
    final out = Uint8List(w * h);
    for (var i = 0; i < out.length; i++) {
      if (labels[i] == bestLabel) out[i] = 1;
    }
    return (out, bestSize);
  }

  /// Andrew's monotone chain. Returns hull in counter-clockwise order (y down = clockwise on screen).
  static List<Pt> convexHull(List<Pt> points) {
    if (points.length < 3) return List.of(points);
    final pts = List.of(points)
      ..sort((a, b) => a.x != b.x ? a.x.compareTo(b.x) : a.y.compareTo(b.y));
    double cross(Pt o, Pt a, Pt b) => (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x);
    final lower = <Pt>[];
    for (final p in pts) {
      while (lower.length >= 2 && cross(lower[lower.length - 2], lower.last, p) <= 0) {
        lower.removeLast();
      }
      lower.add(p);
    }
    final upper = <Pt>[];
    for (final p in pts.reversed) {
      while (upper.length >= 2 && cross(upper[upper.length - 2], upper.last, p) <= 0) {
        upper.removeLast();
      }
      upper.add(p);
    }
    lower.removeLast();
    upper.removeLast();
    return [...lower, ...upper];
  }

  /// Picks 4 hull vertices that (locally) maximise the enclosed area and returns
  /// them ordered TL, TR, BR, BL.
  static List<Pt>? maxAreaQuad(List<Pt> hull) {
    if (hull.length < 4) return null;
    // Seed with the classic extreme-point corners.
    Pt pick(double Function(Pt) score, bool max) =>
        hull.reduce((a, b) => (max ? score(a) >= score(b) : score(a) <= score(b)) ? a : b);
    var quad = [
      pick((p) => p.x + p.y, false),
      pick((p) => p.x - p.y, true),
      pick((p) => p.x + p.y, true),
      pick((p) => p.x - p.y, false),
    ];
    double area(List<Pt> q) {
      var s = 0.0;
      for (var i = 0; i < 4; i++) {
        s += q[i].x * q[(i + 1) % 4].y - q[(i + 1) % 4].x * q[i].y;
      }
      return s.abs() / 2;
    }

    // Sub-sample long hulls to keep refinement cheap.
    final candidates = hull.length > 120
        ? [for (var i = 0; i < hull.length; i += (hull.length / 120).ceil()) hull[i]]
        : hull;
    var best = area(quad);
    for (var iter = 0; iter < 3; iter++) {
      var improved = false;
      for (var k = 0; k < 4; k++) {
        for (final c in candidates) {
          final trial = List.of(quad)..[k] = c;
          final a = area(trial);
          if (a > best + 1e-6 && Quad(trial[0], trial[1], trial[2], trial[3]).isConvex) {
            best = a;
            quad = trial;
            improved = true;
          }
        }
      }
      if (!improved) break;
    }
    return orderCorners(quad);
  }

  /// Orders four arbitrary points as TL, TR, BR, BL.
  static List<Pt> orderCorners(List<Pt> pts) {
    final cx = pts.fold<double>(0, (s, p) => s + p.x) / 4;
    final cy = pts.fold<double>(0, (s, p) => s + p.y) / 4;
    final sorted = List.of(pts)
      ..sort((a, b) => math.atan2(a.y - cy, a.x - cx).compareTo(math.atan2(b.y - cy, b.x - cx)));
    // atan2 ascending starts near −π (left), goes up through top (−π/2) on screen coordinates.
    // Rotate the list so the point with smallest x+y comes first.
    var start = 0;
    for (var i = 1; i < 4; i++) {
      if (sorted[i].x + sorted[i].y < sorted[start].x + sorted[start].y) start = i;
    }
    return [for (var i = 0; i < 4; i++) sorted[(start + i) % 4]];
  }
}
