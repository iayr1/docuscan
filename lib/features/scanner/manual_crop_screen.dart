import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../core/image/image_types.dart';
import '../../core/theme/app_theme.dart';
import '../../shared/widgets/common.dart';

/// Screen allowing the user to inspect and manually adjust the 4 perspective corners
/// with visual feedback, touch handles, and auto-detect.
class ManualCropScreen extends ConsumerStatefulWidget {
  const ManualCropScreen({
    super.key,
    required this.imagePath,
    this.initialQuad,
    this.initialRotation = 0,
  });

  final String imagePath;
  final Quad? initialQuad;
  final int initialRotation;

  @override
  ConsumerState<ManualCropScreen> createState() => _ManualCropScreenState();
}

class _ManualCropScreenState extends ConsumerState<ManualCropScreen> {
  late Quad _quad;
  late int _rotation; // 0..3 quarter turns
  int? _activeCorner;
  (int, int)? _imageDimensions;
  bool _loading = true;

  Quad get _displayQuad => _quad.rotated(_rotation);

  void _setDisplayQuad(Quad quad) {
    setState(() => _quad = quad.rotated((4 - _rotation) % 4));
  }

  @override
  void initState() {
    super.initState();
    _rotation = widget.initialRotation;
    _quad = widget.initialQuad ?? Quad.full();
    _loadDimensionsAndDetect();
  }

  Future<void> _loadDimensionsAndDetect() async {
    try {
      final dims = await ref
          .read(imageServiceProvider)
          .dimensions(widget.imagePath);
      _imageDimensions = dims;
      if (widget.initialQuad == null) {
        final detected = await ref
            .read(imageServiceProvider)
            .detectDocument(widget.imagePath);
        if (detected != null && detected.area > 0.08) {
          _quad = detected;
        }
      }
    } catch (_) {
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _autoDetect() async {
    setState(() => _loading = true);
    try {
      final detected = await ref
          .read(imageServiceProvider)
          .detectDocument(widget.imagePath);
      if (detected != null) {
        setState(() => _quad = detected);
        if (mounted) showSnack(context, 'Document edges detected');
      } else {
        if (mounted) {
          showSnack(
            context,
            'Could not auto-detect edges. Please adjust manually.',
          );
        }
      }
    } catch (e) {
      if (mounted) showSnack(context, 'Detection error: $e', error: true);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _resetToFull() {
    setState(() {
      _quad = Quad.full();
    });
  }

  void _rotateClockwise() {
    setState(() {
      _rotation = (_rotation + 1) % 4;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: const Text(
          'Crop & Perspective',
          style: TextStyle(color: Colors.white),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.rotate_right_outlined),
            tooltip: 'Rotate 90°',
            onPressed: _rotateClockwise,
          ),
          IconButton(
            icon: const Icon(Icons.auto_fix_high_outlined),
            tooltip: 'Auto Detect',
            onPressed: _autoDetect,
          ),
          IconButton(
            icon: const Icon(Icons.fullscreen_outlined),
            tooltip: 'Full Image',
            onPressed: _resetToFull,
          ),
          FilledButton.tonal(
            onPressed: () {
              Navigator.of(context).pop((quad: _quad, rotation: _rotation));
            },
            child: const Text('Done'),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: _loading
          ? const Center(
              child: CircularProgressIndicator(color: AppColors.brand),
            )
          : LayoutBuilder(
              builder: (ctx, constraints) {
                final imgW = _imageDimensions?.$1.toDouble() ?? 1000.0;
                final imgH = _imageDimensions?.$2.toDouble() ?? 1000.0;

                final isSideways = _rotation == 1 || _rotation == 3;
                final displayW = isSideways ? imgH : imgW;
                final displayH = isSideways ? imgW : imgH;

                final fitted = applyBoxFit(
                  BoxFit.contain,
                  Size(displayW, displayH),
                  Size(constraints.maxWidth, constraints.maxHeight),
                );

                final renderSize = fitted.destination;
                final offsetX = (constraints.maxWidth - renderSize.width) / 2;
                final offsetY = (constraints.maxHeight - renderSize.height) / 2;
                final contentRect = Rect.fromLTWH(
                  offsetX,
                  offsetY,
                  renderSize.width,
                  renderSize.height,
                );

                return Stack(
                  fit: StackFit.expand,
                  children: [
                    Positioned.fromRect(
                      rect: contentRect,
                      child: RotatedBox(
                        quarterTurns: _rotation,
                        child: Image.file(
                          File(widget.imagePath),
                          fit: BoxFit.fill,
                          gaplessPlayback: true,
                        ),
                      ),
                    ),
                    Positioned.fill(
                      child: GestureDetector(
                        onPanStart: (details) {
                          final touch = details.localPosition;
                          final normX = (touch.dx - offsetX) / renderSize.width;
                          final normY =
                              (touch.dy - offsetY) / renderSize.height;

                          int nearest = 0;
                          double minDistance = double.infinity;
                          final pts = _displayQuad.points;
                          for (var i = 0; i < 4; i++) {
                            final dx = pts[i].x - normX;
                            final dy = pts[i].y - normY;
                            final dist = math.sqrt(dx * dx + dy * dy);
                            if (dist < minDistance) {
                              minDistance = dist;
                              nearest = i;
                            }
                          }

                          const thresholdNorm = 0.12;
                          if (minDistance < thresholdNorm) {
                            setState(() {
                              _activeCorner = nearest;
                            });
                          }
                        },
                        onPanUpdate: (details) {
                          if (_activeCorner == null) return;
                          final touch = details.localPosition;
                          final normX =
                              ((touch.dx - offsetX) / renderSize.width).clamp(
                                0.0,
                                1.0,
                              );
                          final normY =
                              ((touch.dy - offsetY) / renderSize.height).clamp(
                                0.0,
                                1.0,
                              );

                          _setDisplayQuad(
                            _displayQuad.withPoint(
                              _activeCorner!,
                              Pt(normX, normY),
                            ),
                          );
                        },
                        onPanEnd: (_) {
                          setState(() {
                            _activeCorner = null;
                          });
                        },
                        child: CustomPaint(
                          painter: _QuadCropPainter(
                            quad: _displayQuad,
                            contentRect: contentRect,
                            activeCorner: _activeCorner,
                          ),
                        ),
                      ),
                    ),
                    Positioned(
                      bottom: 24,
                      left: 20,
                      right: 20,
                      child: Center(
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 8,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.black.withValues(alpha: 0.75),
                            borderRadius: BorderRadius.circular(AppRadius.pill),
                            border: Border.all(color: Colors.white24),
                          ),
                          child: const Text(
                            'Drag circular handles to align with document corners',
                            style: TextStyle(color: Colors.white, fontSize: 13),
                          ),
                        ),
                      ),
                    ),
                  ],
                );
              },
            ),
    );
  }
}

class _QuadCropPainter extends CustomPainter {
  const _QuadCropPainter({
    required this.quad,
    required this.contentRect,
    required this.activeCorner,
  });

  final Quad quad;
  final Rect contentRect;
  final int? activeCorner;

  @override
  void paint(Canvas canvas, Size size) {
    final screenPts = quad.points.map((p) {
      return Offset(
        contentRect.left + p.x * contentRect.width,
        contentRect.top + p.y * contentRect.height,
      );
    }).toList();

    final path = Path()
      ..moveTo(screenPts[0].dx, screenPts[0].dy)
      ..lineTo(screenPts[1].dx, screenPts[1].dy)
      ..lineTo(screenPts[2].dx, screenPts[2].dy)
      ..lineTo(screenPts[3].dx, screenPts[3].dy)
      ..close();

    final outside = Path()
      ..addRect(contentRect)
      ..addPath(path, Offset.zero)
      ..fillType = PathFillType.evenOdd;

    canvas.drawPath(
      outside,
      Paint()..color = Colors.black.withValues(alpha: 0.45),
    );

    final edgePaint = Paint()
      ..color = AppColors.brandDark
      ..strokeWidth = 2.5
      ..style = PaintingStyle.stroke;
    canvas.drawPath(path, edgePaint);

    final gridPaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.35)
      ..strokeWidth = 1.0;

    for (var f = 0.33; f < 0.7; f += 0.33) {
      final top = Offset.lerp(screenPts[0], screenPts[1], f)!;
      final bottom = Offset.lerp(screenPts[3], screenPts[2], f)!;
      canvas.drawLine(top, bottom, gridPaint);

      final left = Offset.lerp(screenPts[0], screenPts[3], f)!;
      final right = Offset.lerp(screenPts[1], screenPts[2], f)!;
      canvas.drawLine(left, right, gridPaint);
    }

    for (var i = 0; i < 4; i++) {
      final pt = screenPts[i];
      final isActive = activeCorner == i;

      canvas.drawCircle(
        pt,
        isActive ? 22 : 16,
        Paint()
          ..color = (isActive ? AppColors.brand : AppColors.brandDark)
              .withValues(alpha: 0.35),
      );

      canvas.drawCircle(pt, isActive ? 14 : 10, Paint()..color = Colors.white);

      canvas.drawCircle(
        pt,
        isActive ? 8 : 6,
        Paint()..color = isActive ? AppColors.brand : AppColors.brandDark,
      );
    }
  }

  @override
  bool shouldRepaint(_QuadCropPainter old) =>
      old.quad != quad ||
      old.contentRect != contentRect ||
      old.activeCorner != activeCorner;
}
