import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../core/image/image_service.dart';
import '../../core/image/image_types.dart';
import '../../core/storage/file_store.dart';
import '../../core/theme/app_theme.dart';
import '../../data/models/models.dart';
import '../../shared/widgets/common.dart';
import '../signatures/signature_pad_dialog.dart';

class PageMarkupScreen extends ConsumerStatefulWidget {
  const PageMarkupScreen({
    super.key,
    required this.document,
    required this.page,
  });

  final Document document;
  final DocPage page;

  @override
  ConsumerState<PageMarkupScreen> createState() => _PageMarkupScreenState();
}

class _PageMarkupScreenState extends ConsumerState<PageMarkupScreen> {
  final List<Annotation> _annotations = [];
  final List<Annotation> _redoStack = [];

  AnnotationKind _currentTool = AnnotationKind.pen;
  Color _currentColor = Colors.red;
  final double _strokeWidth = 0.005;

  List<Pt>? _activeStroke;
  Offset? _boxStart;
  Offset? _boxCurrent;

  bool _loading = true;
  bool _saving = false;

  final _colors = const [
    Colors.red,
    Colors.black,
    Color(0xFF003366), // Blue
    Color(0xFF1E7054), // Green
    Colors.amber,
    Colors.purple,
  ];

  @override
  void initState() {
    super.initState();
    _loadAnnotations();
  }

  Future<void> _loadAnnotations() async {
    try {
      final list = await ref.read(assetRepositoryProvider).annotations(widget.page.id);
      _annotations.addAll(list);
    } catch (_) {
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _undo() {
    if (_annotations.isNotEmpty) {
      setState(() {
        _redoStack.add(_annotations.removeLast());
      });
    }
  }

  void _redo() {
    if (_redoStack.isNotEmpty) {
      setState(() {
        _annotations.add(_redoStack.removeLast());
      });
    }
  }

  Future<void> _addTextAnnotation() async {
    final controller = TextEditingController();
    final text = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Insert Text Note'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Note Text', border: OutlineInputBorder()),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, controller.text), child: const Text('Insert')),
        ],
      ),
    );

    if (text != null && text.trim().isNotEmpty) {
      setState(() {
        _annotations.add(Annotation(
          id: newId(),
          pageId: widget.page.id,
          kind: AnnotationKind.text,
          text: text.trim(),
          color: _currentColor.toARGB32(),
          left: 0.1,
          top: 0.2,
          width: 0.8,
          height: 0.08,
          fontSize: 0.04,
        ));
      });
    }
  }

  Future<void> _addSignature() async {
    final sigs = await ref.read(assetRepositoryProvider).signatures();
    if (!mounted) return;

    Signature? chosen;
    if (sigs.isEmpty) {
      chosen = await SignaturePadDialog.show(context);
    } else {
      chosen = await showModalBottomSheet<Signature>(
        context: context,
        builder: (ctx) => SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  children: [
                    Text('Select Signature', style: context.text.titleMedium?.copyWith(fontWeight: FontWeight.bold)),
                    const Spacer(),
                    TextButton.icon(
                      icon: const Icon(Icons.add),
                      label: const Text('Draw New'),
                      onPressed: () async {
                        Navigator.pop(ctx);
                        final s = await SignaturePadDialog.show(context);
                        if (s != null && mounted) {
                          _placePlacedImage(s.path, AnnotationKind.image);
                        }
                      },
                    ),
                  ],
                ),
              ),
              Expanded(
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: sigs.length,
                  itemBuilder: (ctx, i) {
                    final s = sigs[i];
                    return ListTile(
                      title: Text(s.name),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => Navigator.pop(ctx, s),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      );
    }

    if (chosen != null && mounted) {
      await _placePlacedImage(chosen.path, AnnotationKind.image);
    }
  }

  Future<void> _addStamp() async {
    final stamps = await ref.read(assetRepositoryProvider).stamps();
    if (!mounted) return;

    if (stamps.isEmpty) {
      showSnack(context, 'No stamps found. Create stamps in the Signatures & Stamps section.');
      return;
    }

    final chosen = await showModalBottomSheet<Stamp>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text('Select Stamp to Place', style: context.text.titleMedium?.copyWith(fontWeight: FontWeight.bold)),
            ),
            Expanded(
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: stamps.length,
                itemBuilder: (ctx, i) {
                  final st = stamps[i];
                  return ListTile(
                    title: Text(st.name),
                    subtitle: st.subtext != null ? Text(st.subtext!) : null,
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => Navigator.pop(ctx, st),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );

    if (chosen != null && mounted) {
      final stampPath = chosen.path;
      if (stampPath != null) {
        await _placePlacedImage(stampPath, AnnotationKind.image);
      }
    }
  }

  Future<void> _placePlacedImage(String sourceRelPath, AnnotationKind kind) async {
    try {
      final placedPath = await ref.read(assetRepositoryProvider).placeImage(widget.document.id, sourceRelPath);
      setState(() {
        _annotations.add(Annotation(
          id: newId(),
          pageId: widget.page.id,
          kind: kind,
          imagePath: placedPath,
          left: 0.25,
          top: 0.4,
          width: 0.5,
          height: 0.18,
        ));
      });
    } catch (e) {
      if (mounted) showSnack(context, 'Failed to place image: $e', error: true);
    }
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      // Check for redactions
      final redactions = _annotations.where((a) => a.kind == AnnotationKind.redact).toList();
      if (redactions.isNotEmpty) {
        final confirmed = await confirm(
          context,
          'Burn Redactions',
          'You have ${redactions.length} redaction box(es). Redactions permanently blackout the underlying image content. Continue?',
          confirmLabel: 'Burn Redactions',
          destructive: true,
        );
        if (confirmed) {
          final absImagePath = ref.read(fileStoreProvider).abs(widget.page.imagePath);
          final nrects = redactions.map((r) => NRect(r.left, r.top, r.width, r.height)).toList();
          await ref.read(imageServiceProvider).burnRedactions(absImagePath, nrects);
          // Remove redact annotations now that they are burned into the image pixels
          _annotations.removeWhere((a) => a.kind == AnnotationKind.redact);
        }
      }

      await ref.read(assetRepositoryProvider).saveAnnotations(widget.page.id, _annotations);
      if (mounted) {
        showSnack(context, 'Annotations saved');
        Navigator.of(context).pop(true);
      }
    } catch (e) {
      if (mounted) showSnack(context, 'Failed to save markup: $e', error: true);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text('Markup - Page ${widget.page.index + 1}', style: const TextStyle(color: Colors.white)),
        actions: [
          IconButton(
            icon: const Icon(Icons.undo),
            tooltip: 'Undo',
            onPressed: _annotations.isEmpty ? null : _undo,
          ),
          IconButton(
            icon: const Icon(Icons.redo),
            tooltip: 'Redo',
            onPressed: _redoStack.isEmpty ? null : _redo,
          ),
          FilledButton.tonal(
            onPressed: _saving ? null : _save,
            child: _saving
                ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                : const Text('Save'),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator(color: AppColors.brand))
          : Column(
              children: [
                // Canvas Area
                Expanded(
                  child: LayoutBuilder(
                    builder: (ctx, constraints) {
                      final imgW = widget.page.width > 0 ? widget.page.width.toDouble() : 1000.0;
                      final imgH = widget.page.height > 0 ? widget.page.height.toDouble() : 1414.0;

                      final fitted = applyBoxFit(BoxFit.contain, Size(imgW, imgH), Size(constraints.maxWidth, constraints.maxHeight));
                      final renderSize = fitted.destination;
                      final offsetX = (constraints.maxWidth - renderSize.width) / 2;
                      final offsetY = (constraints.maxHeight - renderSize.height) / 2;
                      final contentRect = Rect.fromLTWH(offsetX, offsetY, renderSize.width, renderSize.height);

                      return Stack(
                        fit: StackFit.expand,
                        children: [
                          Positioned.fromRect(
                            rect: contentRect,
                            child: Image.file(
                              ref.watch(fileStoreProvider).file(widget.page.imagePath),
                              fit: BoxFit.fill,
                              gaplessPlayback: true,
                            ),
                          ),
                          // Annotation rendering
                          Positioned.fromRect(
                            rect: contentRect,
                            child: CustomPaint(
                              painter: _AnnotationPainter(
                                annotations: _annotations,
                                fileStore: ref.watch(fileStoreProvider),
                              ),
                            ),
                          ),
                          // Active drawing gesture detector
                          Positioned.fromRect(
                            rect: contentRect,
                            child: GestureDetector(
                              onPanStart: (d) {
                                final norm = Pt(d.localPosition.dx / renderSize.width, d.localPosition.dy / renderSize.height);
                                if (_currentTool == AnnotationKind.pen || _currentTool == AnnotationKind.highlighter) {
                                  setState(() => _activeStroke = [norm]);
                                } else if (_currentTool == AnnotationKind.rect ||
                                    _currentTool == AnnotationKind.ellipse ||
                                    _currentTool == AnnotationKind.arrow ||
                                    _currentTool == AnnotationKind.redact) {
                                  setState(() {
                                    _boxStart = d.localPosition;
                                    _boxCurrent = d.localPosition;
                                  });
                                }
                              },
                              onPanUpdate: (d) {
                                final norm = Pt(
                                  (d.localPosition.dx / renderSize.width).clamp(0.0, 1.0),
                                  (d.localPosition.dy / renderSize.height).clamp(0.0, 1.0),
                                );
                                if (_activeStroke != null) {
                                  setState(() => _activeStroke!.add(norm));
                                } else if (_boxStart != null) {
                                  setState(() => _boxCurrent = d.localPosition);
                                }
                              },
                              onPanEnd: (_) {
                                if (_activeStroke != null && _activeStroke!.isNotEmpty) {
                                  setState(() {
                                    _annotations.add(Annotation(
                                      id: newId(),
                                      pageId: widget.page.id,
                                      kind: _currentTool,
                                      points: List.of(_activeStroke!),
                                      color: _currentTool == AnnotationKind.highlighter
                                          ? (_currentColor == Colors.red ? Colors.yellow.toARGB32() : _currentColor.withValues(alpha: 0.4).toARGB32())
                                          : _currentColor.toARGB32(),
                                      strokeWidth: _currentTool == AnnotationKind.highlighter ? 0.025 : _strokeWidth,
                                    ));
                                    _activeStroke = null;
                                  });
                                } else if (_boxStart != null && _boxCurrent != null) {
                                  final l = (math.min(_boxStart!.dx, _boxCurrent!.dx) / renderSize.width).clamp(0.0, 1.0);
                                  final t = (math.min(_boxStart!.dy, _boxCurrent!.dy) / renderSize.height).clamp(0.0, 1.0);
                                  final w = ((_boxStart!.dx - _boxCurrent!.dx).abs() / renderSize.width).clamp(0.01, 1.0);
                                  final h = ((_boxStart!.dy - _boxCurrent!.dy).abs() / renderSize.height).clamp(0.01, 1.0);

                                  setState(() {
                                    _annotations.add(Annotation(
                                      id: newId(),
                                      pageId: widget.page.id,
                                      kind: _currentTool,
                                      left: l,
                                      top: t,
                                      width: w,
                                      height: h,
                                      color: _currentTool == AnnotationKind.redact ? Colors.black.toARGB32() : _currentColor.toARGB32(),
                                      strokeWidth: _strokeWidth,
                                    ));
                                    _boxStart = null;
                                    _boxCurrent = null;
                                  });
                                }
                              },
                              child: CustomPaint(
                                painter: _ActiveDrawPainter(
                                  stroke: _activeStroke,
                                  boxStart: _boxStart,
                                  boxCurrent: _boxCurrent,
                                  tool: _currentTool,
                                  color: _currentColor,
                                  strokeWidth: _strokeWidth,
                                  renderSize: renderSize,
                                ),
                              ),
                            ),
                          ),
                        ],
                      );
                    },
                  ),
                ),

                // Tool selection bottom bar
                _buildToolBar(),
              ],
            ),
    );
  }

  Widget _buildToolBar() {
    return Container(
      color: const Color(0xFF141A17),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Color & Stroke controls
          Row(
            children: [
              ..._colors.map((c) => Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: InkWell(
                      onTap: () => setState(() => _currentColor = c),
                      child: Container(
                        width: 26,
                        height: 26,
                        decoration: BoxDecoration(
                          color: c,
                          shape: BoxShape.circle,
                          border: Border.all(color: _currentColor == c ? Colors.white : Colors.white24, width: 2),
                        ),
                      ),
                    ),
                  )),
              const Spacer(),
              // Redo clear button
              IconButton(
                icon: const Icon(Icons.delete_sweep_outlined, color: Colors.white70),
                tooltip: 'Clear All Annotations',
                onPressed: _annotations.isEmpty
                    ? null
                    : () async {
                        if (await confirm(context, 'Clear All', 'Remove all markup on this page?', destructive: true)) {
                          setState(() => _annotations.clear());
                        }
                      },
              ),
            ],
          ),
          const SizedBox(height: 8),
          // Tool Buttons Row
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                _toolButton(AnnotationKind.pen, Icons.edit, 'Pen'),
                _toolButton(AnnotationKind.highlighter, Icons.border_color, 'Highlight'),
                _toolButton(AnnotationKind.rect, Icons.crop_square, 'Rect'),
                _toolButton(AnnotationKind.ellipse, Icons.circle_outlined, 'Circle'),
                _toolButton(AnnotationKind.arrow, Icons.arrow_forward, 'Arrow'),
                _toolButton(AnnotationKind.redact, Icons.block, 'Redact'),
                const VerticalDivider(color: Colors.white24, width: 16),
                ActionChip(
                  avatar: const Icon(Icons.text_fields, size: 16),
                  label: const Text('Text'),
                  onPressed: _addTextAnnotation,
                ),
                const SizedBox(width: 8),
                ActionChip(
                  avatar: const Icon(Icons.draw_outlined, size: 16),
                  label: const Text('Signature'),
                  onPressed: _addSignature,
                ),
                const SizedBox(width: 8),
                ActionChip(
                  avatar: const Icon(Icons.verified_outlined, size: 16),
                  label: const Text('Stamp'),
                  onPressed: _addStamp,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _toolButton(AnnotationKind kind, IconData icon, String label) {
    final isSelected = _currentTool == kind;
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: ChoiceChip(
        avatar: Icon(icon, size: 16, color: isSelected ? Colors.white : Colors.white70),
        label: Text(label),
        selected: isSelected,
        onSelected: (v) {
          if (v) setState(() => _currentTool = kind);
        },
      ),
    );
  }
}

class _AnnotationPainter extends CustomPainter {
  const _AnnotationPainter({required this.annotations, required this.fileStore});
  final List<Annotation> annotations;
  final dynamic fileStore;

  @override
  void paint(Canvas canvas, Size size) {
    for (final a in annotations) {
      final paint = Paint()
        ..color = Color(a.color)
        ..strokeWidth = a.strokeWidth * size.width
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..style = PaintingStyle.stroke;

      switch (a.kind) {
        case AnnotationKind.pen:
          if (a.points.length > 1) {
            final path = Path();
            path.moveTo(a.points.first.x * size.width, a.points.first.y * size.height);
            for (var i = 1; i < a.points.length; i++) {
              path.lineTo(a.points[i].x * size.width, a.points[i].y * size.height);
            }
            canvas.drawPath(path, paint);
          }
          break;

        case AnnotationKind.highlighter:
          if (a.points.length > 1) {
            final path = Path();
            path.moveTo(a.points.first.x * size.width, a.points.first.y * size.height);
            for (var i = 1; i < a.points.length; i++) {
              path.lineTo(a.points[i].x * size.width, a.points[i].y * size.height);
            }
            canvas.drawPath(path, paint..color = Color(a.color).withValues(alpha: 0.45));
          }
          break;

        case AnnotationKind.rect:
          canvas.drawRect(
            Rect.fromLTWH(a.left * size.width, a.top * size.height, a.width * size.width, a.height * size.height),
            paint,
          );
          break;

        case AnnotationKind.ellipse:
          canvas.drawOval(
            Rect.fromLTWH(a.left * size.width, a.top * size.height, a.width * size.width, a.height * size.height),
            paint,
          );
          break;

        case AnnotationKind.redact:
          canvas.drawRect(
            Rect.fromLTWH(a.left * size.width, a.top * size.height, a.width * size.width, a.height * size.height),
            Paint()
              ..color = Colors.black
              ..style = PaintingStyle.fill,
          );
          break;

        case AnnotationKind.text:
          if (a.text != null) {
            final span = TextSpan(
              text: a.text,
              style: TextStyle(color: Color(a.color), fontSize: a.fontSize * size.width, fontWeight: FontWeight.bold),
            );
            final tp = TextPainter(text: span, textDirection: TextDirection.ltr)..layout(maxWidth: a.width * size.width);
            tp.paint(canvas, Offset(a.left * size.width, a.top * size.height));
          }
          break;

        case AnnotationKind.image:
          // Draw placed stamp/signature placeholder or box
          canvas.drawRect(
            Rect.fromLTWH(a.left * size.width, a.top * size.height, a.width * size.width, a.height * size.height),
            Paint()
              ..color = Colors.white.withValues(alpha: 0.2)
              ..style = PaintingStyle.fill,
          );
          break;

        default:
          break;
      }
    }
  }

  @override
  bool shouldRepaint(_AnnotationPainter old) => true;
}

class _ActiveDrawPainter extends CustomPainter {
  const _ActiveDrawPainter({
    required this.stroke,
    required this.boxStart,
    required this.boxCurrent,
    required this.tool,
    required this.color,
    required this.strokeWidth,
    required this.renderSize,
  });

  final List<Pt>? stroke;
  final Offset? boxStart;
  final Offset? boxCurrent;
  final AnnotationKind tool;
  final Color color;
  final double strokeWidth;
  final Size renderSize;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = tool == AnnotationKind.redact ? Colors.black : color
      ..strokeWidth = strokeWidth * size.width
      ..strokeCap = StrokeCap.round
      ..style = tool == AnnotationKind.redact ? PaintingStyle.fill : PaintingStyle.stroke;

    if (stroke != null && stroke!.length > 1) {
      final path = Path();
      path.moveTo(stroke!.first.x * size.width, stroke!.first.y * size.height);
      for (var i = 1; i < stroke!.length; i++) {
        path.lineTo(stroke![i].x * size.width, stroke![i].y * size.height);
      }
      canvas.drawPath(path, paint);
    } else if (boxStart != null && boxCurrent != null) {
      final rect = Rect.fromPoints(boxStart!, boxCurrent!);
      if (tool == AnnotationKind.ellipse) {
        canvas.drawOval(rect, paint);
      } else {
        canvas.drawRect(rect, paint);
      }
    }
  }

  @override
  bool shouldRepaint(_ActiveDrawPainter old) => true;
}
