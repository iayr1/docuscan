import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import '../../app/providers.dart';
import '../../core/theme/app_theme.dart';
import '../../data/models/models.dart';
import '../../shared/widgets/common.dart';

/// Interactive signature drawing pad with smooth curve rendering and export to PNG.
class SignaturePadDialog extends ConsumerStatefulWidget {
  const SignaturePadDialog({super.key, this.initialName});
  final String? initialName;

  static Future<Signature?> show(BuildContext context, {String? initialName}) =>
      showDialog<Signature>(
        context: context,
        barrierDismissible: false,
        builder: (_) => SignaturePadDialog(initialName: initialName),
      );

  @override
  ConsumerState<SignaturePadDialog> createState() => _SignaturePadDialogState();
}

class _SignaturePadDialogState extends ConsumerState<SignaturePadDialog> {
  final List<List<Offset>> _strokes = [];
  List<Offset>? _currentStroke;
  Color _selectedColor = Colors.black;
  final double _strokeWidth = 3.5;
  late final TextEditingController _nameController;
  bool _saving = false;

  final _colors = const [
    Colors.black,
    Color(0xFF003366), // Navy
    Color(0xFF1E7054), // Forest Green
    Color(0xFF990000), // Crimson
  ];

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(
      text: widget.initialName ?? 'Signature ${DateTime.now().day}/${DateTime.now().month}',
    );
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  void _onPanStart(DragStartDetails details) {
    setState(() {
      _currentStroke = [details.localPosition];
      _strokes.add(_currentStroke!);
    });
  }

  void _onPanUpdate(DragUpdateDetails details) {
    setState(() {
      _currentStroke?.add(details.localPosition);
    });
  }

  void _onPanEnd(DragEndDetails details) {
    setState(() {
      _currentStroke = null;
    });
  }

  void _clear() {
    setState(() {
      _strokes.clear();
      _currentStroke = null;
    });
  }

  void _undo() {
    if (_strokes.isNotEmpty) {
      setState(() {
        _strokes.removeLast();
      });
    }
  }

  Future<void> _importFromGallery() async {
    final picker = ImagePicker();
    final picked = await picker.pickImage(source: ImageSource.gallery);
    if (picked == null || !mounted) return;

    try {
      final bytes = await picked.readAsBytes();
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      final image = frame.image;

      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      final paint = Paint()
        ..colorFilter = const ColorFilter.matrix([
          0.33, 0.33, 0.33, 0, 0,
          0.33, 0.33, 0.33, 0, 0,
          0.33, 0.33, 0.33, 0, 0,
          0, 0, 0, 1, 0,
        ]);

      canvas.drawImage(image, Offset.zero, paint);
      final picture = recorder.endRecording();
      final rendered = await picture.toImage(image.width, image.height);
      final pngByteData = await rendered.toByteData(format: ui.ImageByteFormat.png);
      if (pngByteData == null) return;

      final pngBytes = pngByteData.buffer.asUint8List();
      final name = _nameController.text.trim().isEmpty ? 'Imported Signature' : _nameController.text.trim();

      final sig = await ref.read(assetRepositoryProvider).saveSignature(
            name: name,
            png: pngBytes,
            color: _selectedColor.toARGB32(),
          );
      if (mounted) Navigator.of(context).pop(sig);
    } catch (e) {
      if (mounted) showSnack(context, 'Failed to import signature: $e', error: true);
    }
  }

  Future<Uint8List?> _renderSignaturePng() async {
    if (_strokes.isEmpty) return null;

    double minX = double.infinity, minY = double.infinity;
    double maxX = double.negativeInfinity, maxY = double.negativeInfinity;

    for (final stroke in _strokes) {
      for (final pt in stroke) {
        if (pt.dx < minX) minX = pt.dx;
        if (pt.dy < minY) minY = pt.dy;
        if (pt.dx > maxX) maxX = pt.dx;
        if (pt.dy > maxY) maxY = pt.dy;
      }
    }

    const padding = 20.0;
    final width = ((maxX - minX) + padding * 2).clamp(100.0, 1000.0);
    final height = ((maxY - minY) + padding * 2).clamp(60.0, 600.0);

    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);

    canvas.translate(-minX + padding, -minY + padding);

    final paint = Paint()
      ..color = _selectedColor
      ..strokeWidth = _strokeWidth
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..style = PaintingStyle.stroke;

    for (final stroke in _strokes) {
      if (stroke.isEmpty) continue;
      if (stroke.length == 1) {
        canvas.drawCircle(stroke.first, _strokeWidth / 2, paint..style = PaintingStyle.fill);
        paint.style = PaintingStyle.stroke;
      } else {
        final path = Path()..moveTo(stroke.first.dx, stroke.first.dy);
        for (var i = 1; i < stroke.length; i++) {
          final p0 = stroke[i - 1];
          final p1 = stroke[i];
          path.quadraticBezierTo(p0.dx, p0.dy, (p0.dx + p1.dx) / 2, (p0.dy + p1.dy) / 2);
        }
        canvas.drawPath(path, paint);
      }
    }

    final picture = recorder.endRecording();
    final img = await picture.toImage(width.toInt(), height.toInt());
    final byteData = await img.toByteData(format: ui.ImageByteFormat.png);
    return byteData?.buffer.asUint8List();
  }

  Future<void> _save() async {
    if (_strokes.isEmpty) {
      showSnack(context, 'Please draw a signature first');
      return;
    }
    setState(() => _saving = true);
    try {
      final png = await _renderSignaturePng();
      if (png == null) return;
      final name = _nameController.text.trim().isEmpty ? 'Signature' : _nameController.text.trim();
      final sig = await ref.read(assetRepositoryProvider).saveSignature(
            name: name,
            png: png,
            color: _selectedColor.toARGB32(),
          );
      if (mounted) Navigator.of(context).pop(sig);
    } catch (e) {
      if (mounted) showSnack(context, 'Failed to save signature: $e', error: true);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 500),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  const Icon(Icons.draw_outlined, color: AppColors.brand),
                  const SizedBox(width: 10),
                  Text('New Signature', style: context.text.titleLarge?.copyWith(fontWeight: FontWeight.bold)),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.image_outlined),
                    tooltip: 'Import from gallery',
                    onPressed: _importFromGallery,
                  ),
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _nameController,
                decoration: const InputDecoration(
                  labelText: 'Signature Name',
                  isDense: true,
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 14),
              // Canvas
              Container(
                height: 220,
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(AppRadius.md),
                  border: Border.all(color: context.outline, width: 1.5),
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(AppRadius.md),
                  child: Stack(
                    children: [
                      CustomPaint(
                        size: Size.infinite,
                        painter: _GridLinePainter(),
                      ),
                      GestureDetector(
                        onPanStart: _onPanStart,
                        onPanUpdate: _onPanUpdate,
                        onPanEnd: _onPanEnd,
                        child: CustomPaint(
                          size: Size.infinite,
                          painter: _SignaturePainter(_strokes, _selectedColor, _strokeWidth),
                        ),
                      ),
                      if (_strokes.isEmpty)
                        Center(
                          child: Text(
                            'Sign here with your finger',
                            style: TextStyle(color: Colors.grey.shade400, fontStyle: FontStyle.italic),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),
              // Controls row
              Row(
                children: [
                  ..._colors.map((c) => Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: InkWell(
                          onTap: () => setState(() => _selectedColor = c),
                          borderRadius: BorderRadius.circular(99),
                          child: Container(
                            width: 30,
                            height: 30,
                            decoration: BoxDecoration(
                              color: c,
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: _selectedColor == c ? AppColors.brand : Colors.white,
                                width: _selectedColor == c ? 3 : 1,
                              ),
                            ),
                          ),
                        ),
                      )),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.undo_rounded),
                    tooltip: 'Undo',
                    onPressed: _strokes.isEmpty ? null : _undo,
                  ),
                  IconButton(
                    icon: const Icon(Icons.delete_outline),
                    tooltip: 'Clear',
                    onPressed: _strokes.isEmpty ? null : _clear,
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('Cancel'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton.icon(
                    onPressed: _saving ? null : _save,
                    icon: _saving
                        ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                        : const Icon(Icons.check),
                    label: const Text('Save Signature'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SignaturePainter extends CustomPainter {
  const _SignaturePainter(this.strokes, this.color, this.strokeWidth);
  final List<List<Offset>> strokes;
  final Color color;
  final double strokeWidth;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..style = PaintingStyle.stroke;

    for (final stroke in strokes) {
      if (stroke.isEmpty) continue;
      if (stroke.length == 1) {
        canvas.drawCircle(stroke.first, strokeWidth / 2, paint..style = PaintingStyle.fill);
        paint.style = PaintingStyle.stroke;
      } else {
        final path = Path()..moveTo(stroke.first.dx, stroke.first.dy);
        for (var i = 1; i < stroke.length; i++) {
          final p0 = stroke[i - 1];
          final p1 = stroke[i];
          path.quadraticBezierTo(p0.dx, p0.dy, (p0.dx + p1.dx) / 2, (p0.dy + p1.dy) / 2);
        }
        canvas.drawPath(path, paint);
      }
    }
  }

  @override
  bool shouldRepaint(_SignaturePainter old) => true;
}

class _GridLinePainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.grey.shade200
      ..strokeWidth = 1.0;

    final y = size.height * 0.72;
    canvas.drawLine(Offset(20, y), Offset(size.width - 20, y), paint);

    final textPainter = TextPainter(
      text: TextSpan(text: '✕', style: TextStyle(color: Colors.grey.shade300, fontSize: 16)),
      textDirection: ui.TextDirection.ltr,
    )..layout();
    textPainter.paint(canvas, Offset(24, y - 20));
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
