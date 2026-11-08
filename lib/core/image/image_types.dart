import 'dart:convert';
import 'dart:math' as math;

/// A 2D point. Pure Dart so it can cross isolate boundaries and be unit tested.
class Pt {
  const Pt(this.x, this.y);
  final double x;
  final double y;

  Pt operator +(Pt o) => Pt(x + o.x, y + o.y);
  Pt operator -(Pt o) => Pt(x - o.x, y - o.y);
  Pt scale(double sx, [double? sy]) => Pt(x * sx, y * (sy ?? sx));
  double distanceTo(Pt o) => math.sqrt((x - o.x) * (x - o.x) + (y - o.y) * (y - o.y));

  @override
  bool operator ==(Object other) => other is Pt && other.x == x && other.y == y;
  @override
  int get hashCode => Object.hash(x, y);
  @override
  String toString() => 'Pt(${x.toStringAsFixed(3)}, ${y.toStringAsFixed(3)})';
}

/// Four document corners in **normalized** coordinates (0..1) of the source image,
/// ordered top-left, top-right, bottom-right, bottom-left.
class Quad {
  const Quad(this.tl, this.tr, this.br, this.bl);

  factory Quad.full() => const Quad(Pt(0, 0), Pt(1, 0), Pt(1, 1), Pt(0, 1));

  factory Quad.fromList(List<double> v) =>
      Quad(Pt(v[0], v[1]), Pt(v[2], v[3]), Pt(v[4], v[5]), Pt(v[6], v[7]));

  static Quad? tryDecode(String? json) {
    if (json == null || json.isEmpty) return null;
    try {
      final list = (jsonDecode(json) as List).map((e) => (e as num).toDouble()).toList();
      return list.length == 8 ? Quad.fromList(list) : null;
    } catch (_) {
      return null;
    }
  }

  final Pt tl;
  final Pt tr;
  final Pt br;
  final Pt bl;

  List<Pt> get points => [tl, tr, br, bl];
  List<double> toList() => [tl.x, tl.y, tr.x, tr.y, br.x, br.y, bl.x, bl.y];
  String encode() => jsonEncode(toList().map((e) => double.parse(e.toStringAsFixed(5))).toList());

  bool get isFull => points.every((p) => (p.x == 0 || p.x == 1) && (p.y == 0 || p.y == 1)) &&
      tl == const Pt(0, 0) && br == const Pt(1, 1);

  Quad withPoint(int index, Pt p) {
    final c = Pt(p.x.clamp(0.0, 1.0), p.y.clamp(0.0, 1.0));
    return Quad(index == 0 ? c : tl, index == 1 ? c : tr, index == 2 ? c : br, index == 3 ? c : bl);
  }

  /// Shoelace area in normalized units.
  double get area {
    final p = points;
    var s = 0.0;
    for (var i = 0; i < 4; i++) {
      final a = p[i], b = p[(i + 1) % 4];
      s += a.x * b.y - b.x * a.y;
    }
    return s.abs() / 2;
  }

  /// True when the polygon is convex (a requirement for a sane perspective warp).
  bool get isConvex {
    final p = points;
    double? sign;
    for (var i = 0; i < 4; i++) {
      final a = p[i], b = p[(i + 1) % 4], c = p[(i + 2) % 4];
      final cross = (b.x - a.x) * (c.y - b.y) - (b.y - a.y) * (c.x - b.x);
      if (cross.abs() < 1e-9) continue;
      sign ??= cross.sign;
      if (cross.sign != sign) return false;
    }
    return true;
  }

  /// Rotates normalized coordinates by 90° clockwise [turns] times.
  Quad rotated(int turns) {
    Pt r(Pt p) => Pt(1 - p.y, p.x);
    var q = this;
    for (var i = 0; i < turns % 4; i++) {
      // Rotating the image moves every corner; re-order so tl stays top-left.
      q = Quad(r(q.bl), r(q.tl), r(q.tr), r(q.br));
    }
    return q;
  }

  @override
  bool operator ==(Object other) => other is Quad && other.toList().toString() == toList().toString();
  @override
  int get hashCode => toList().toString().hashCode;
}

/// Preset document filters.
enum ScanFilter {
  original('Original'),
  auto('Auto'),
  magic('Magic color'),
  grayscale('Grayscale'),
  blackWhite('B&W'),
  whiteboard('Whiteboard'),
  ecoPrint('Eco print'),
  photo('Photo');

  const ScanFilter(this.label);
  final String label;

  static ScanFilter fromName(String? name) =>
      ScanFilter.values.firstWhere((f) => f.name == name, orElse: () => ScanFilter.auto);
}

/// Fine adjustments, each in -1..1 (0 = neutral) unless noted.
class ImageAdjustments {
  const ImageAdjustments({
    this.brightness = 0,
    this.contrast = 0,
    this.saturation = 0,
    this.exposure = 0,
    this.warmth = 0,
    this.highlights = 0,
    this.shadows = 0,
    this.sharpness = 0,
    this.denoise = 0,
    this.whiten = 0,
    this.glare = 0,
  });

  final double brightness;
  final double contrast;
  final double saturation;
  final double exposure;

  /// White balance: negative = cooler, positive = warmer.
  final double warmth;
  final double highlights;
  final double shadows;

  /// 0..1
  final double sharpness;

  /// 0..1
  final double denoise;

  /// 0..1 – pushes near-white background pixels to pure white.
  final double whiten;

  /// 0..1 – compresses blown-out specular highlights.
  final double glare;

  static const none = ImageAdjustments();

  bool get isNeutral => toMap().values.every((v) => v == 0);

  ImageAdjustments copyWith({
    double? brightness,
    double? contrast,
    double? saturation,
    double? exposure,
    double? warmth,
    double? highlights,
    double? shadows,
    double? sharpness,
    double? denoise,
    double? whiten,
    double? glare,
  }) =>
      ImageAdjustments(
        brightness: brightness ?? this.brightness,
        contrast: contrast ?? this.contrast,
        saturation: saturation ?? this.saturation,
        exposure: exposure ?? this.exposure,
        warmth: warmth ?? this.warmth,
        highlights: highlights ?? this.highlights,
        shadows: shadows ?? this.shadows,
        sharpness: sharpness ?? this.sharpness,
        denoise: denoise ?? this.denoise,
        whiten: whiten ?? this.whiten,
        glare: glare ?? this.glare,
      );

  Map<String, double> toMap() => {
        'brightness': brightness,
        'contrast': contrast,
        'saturation': saturation,
        'exposure': exposure,
        'warmth': warmth,
        'highlights': highlights,
        'shadows': shadows,
        'sharpness': sharpness,
        'denoise': denoise,
        'whiten': whiten,
        'glare': glare,
      };

  factory ImageAdjustments.fromMap(Map<String, dynamic> m) {
    double v(String k) => (m[k] as num?)?.toDouble() ?? 0;
    return ImageAdjustments(
      brightness: v('brightness'),
      contrast: v('contrast'),
      saturation: v('saturation'),
      exposure: v('exposure'),
      warmth: v('warmth'),
      highlights: v('highlights'),
      shadows: v('shadows'),
      sharpness: v('sharpness'),
      denoise: v('denoise'),
      whiten: v('whiten'),
      glare: v('glare'),
    );
  }

  String encode() => jsonEncode(toMap());

  static ImageAdjustments decode(String? json) {
    if (json == null || json.isEmpty) return none;
    try {
      return ImageAdjustments.fromMap(jsonDecode(json) as Map<String, dynamic>);
    } catch (_) {
      return none;
    }
  }
}

/// Everything needed to turn an original capture into a finished page.
class PageEdit {
  const PageEdit({
    this.quad,
    this.rotation = 0,
    this.filter = ScanFilter.auto,
    this.adjustments = ImageAdjustments.none,
    this.deskew = false,
  });

  /// Crop corners (normalized to the *unrotated* original). Null = no crop.
  final Quad? quad;

  /// Clockwise quarter turns, 0..3.
  final int rotation;
  final ScanFilter filter;
  final ImageAdjustments adjustments;
  final bool deskew;

  PageEdit copyWith({
    Quad? quad,
    bool clearQuad = false,
    int? rotation,
    ScanFilter? filter,
    ImageAdjustments? adjustments,
    bool? deskew,
  }) =>
      PageEdit(
        quad: clearQuad ? null : (quad ?? this.quad),
        rotation: rotation ?? this.rotation,
        filter: filter ?? this.filter,
        adjustments: adjustments ?? this.adjustments,
        deskew: deskew ?? this.deskew,
      );

  Map<String, dynamic> toJson() => {
        'quad': quad?.toList(),
        'rotation': rotation,
        'filter': filter.name,
        'adjustments': adjustments.toMap(),
        'deskew': deskew,
      };

  factory PageEdit.fromJson(Map<String, dynamic> j) => PageEdit(
        quad: j['quad'] == null
            ? null
            : Quad.fromList((j['quad'] as List).map((e) => (e as num).toDouble()).toList()),
        rotation: (j['rotation'] as int?) ?? 0,
        filter: ScanFilter.fromName(j['filter'] as String?),
        adjustments: j['adjustments'] == null
            ? ImageAdjustments.none
            : ImageAdjustments.fromMap(j['adjustments'] as Map<String, dynamic>),
        deskew: (j['deskew'] as bool?) ?? false,
      );
}
