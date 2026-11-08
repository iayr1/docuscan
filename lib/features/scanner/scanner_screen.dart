import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter_doc_scanner/flutter_doc_scanner.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import '../../app/providers.dart';
import '../../core/image/image_types.dart';
import '../../core/theme/app_theme.dart';
import '../../data/models/models.dart';
import '../../data/repositories/document_repository.dart';
import '../../shared/widgets/common.dart';
import '../image_editor/image_enhancer_screen.dart';
import 'id_card_scan_screen.dart';

class ScannerScreen extends ConsumerStatefulWidget {
  const ScannerScreen({super.key, this.targetFolderId, this.initialMode = ScanMode.document});
  final String? targetFolderId;
  final ScanMode initialMode;

  @override
  ConsumerState<ScannerScreen> createState() => _ScannerScreenState();
}

class _ScannerScreenState extends ConsumerState<ScannerScreen> with WidgetsBindingObserver {
  CameraController? _cameraController;
  List<CameraDescription> _cameras = [];
  int _selectedCameraIndex = 0;
  bool _cameraInitialized = false;

  late ScanMode _selectedMode;
  FlashMode _flashMode = FlashMode.auto;
  bool _gridEnabled = false;

  final List<PageDraft> _capturedPages = [];
  bool _isCapturing = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _selectedMode = widget.initialMode;
    _initCamera();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _cameraController?.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_cameraController == null || !_cameraController!.value.isInitialized) return;
    if (state == AppLifecycleState.inactive) {
      _cameraController?.dispose();
      setState(() => _cameraInitialized = false);
    } else if (state == AppLifecycleState.resumed) {
      _initCamera();
    }
  }

  Future<void> _initCamera() async {
    try {
      _cameras = await availableCameras();
      if (_cameras.isEmpty) return;

      final controller = CameraController(
        _cameras[_selectedCameraIndex],
        ResolutionPreset.ultraHigh,
        enableAudio: false,
      );
      await controller.initialize();
      _cameraController = controller;

      if (mounted) setState(() => _cameraInitialized = true);
    } catch (_) {
      // Camera may not be available (e.g. desktop/emulator)
    }
  }

  Future<void> _toggleCamera() async {
    if (_cameras.length < 2) return;
    _selectedCameraIndex = (_selectedCameraIndex + 1) % _cameras.length;
    await _cameraController?.dispose();
    setState(() => _cameraInitialized = false);
    await _initCamera();
  }

  Future<void> _toggleFlash() async {
    if (_cameraController == null) return;
    FlashMode next;
    switch (_flashMode) {
      case FlashMode.auto:
        next = FlashMode.always;
        break;
      case FlashMode.always:
        next = FlashMode.torch;
        break;
      case FlashMode.torch:
        next = FlashMode.off;
        break;
      case FlashMode.off:
        next = FlashMode.auto;
        break;
    }
    try {
      await _cameraController!.setFlashMode(next);
      setState(() => _flashMode = next);
    } catch (_) {}
  }

  Future<void> _capture() async {
    if (_isCapturing) return;
    setState(() => _isCapturing = true);

    try {
      String? path;
      if (_cameraInitialized && _cameraController != null) {
        final xfile = await _cameraController!.takePicture();
        path = xfile.path;
      } else {
        // Fallback to image picker if camera hardware is unavailable
        final picked = await ImagePicker().pickImage(source: ImageSource.gallery);
        if (picked != null) path = picked.path;
      }

      if (path != null) {
        // Run auto boundary detection in background
        Quad? detected;
        try {
          detected = await ref.read(imageServiceProvider).detectDocument(path);
        } catch (_) {}

        final draft = PageDraft(
          path,
          edit: PageEdit(
            quad: detected,
            filter: _selectedMode.defaultFilter,
          ),
        );

        setState(() {
          _capturedPages.add(draft);
        });
      }
    } catch (e) {
      if (mounted) showSnack(context, 'Capture failed: $e', error: true);
    } finally {
      if (mounted) setState(() => _isCapturing = false);
    }
  }

  Future<void> _pickFromGallery() async {
    try {
      final picker = ImagePicker();
      final images = await picker.pickMultiImage();
      if (images.isEmpty) return;

      for (final img in images) {
        _capturedPages.add(PageDraft(
          img.path,
          edit: PageEdit(filter: _selectedMode.defaultFilter),
        ));
      }
      setState(() {});
    } catch (e) {
      if (mounted) showSnack(context, 'Gallery import failed: $e', error: true);
    }
  }

  Future<void> _useMlKitDocScanner() async {
    try {
      final scanner = FlutterDocScanner();
      final result = await scanner.getScannedDocumentAsImages(page: 20);
      if (result == null || result.images.isEmpty) return;

      for (final p in result.images) {
        _capturedPages.add(PageDraft(
          p,
          edit: PageEdit(filter: _selectedMode.defaultFilter),
          preProcessed: true,
        ));
      }
      setState(() {});
    } catch (e) {
      if (mounted) showSnack(context, 'Native scanner unavailable: $e', error: true);
    }
  }

  Future<void> _editPage(int index) async {
    final page = _capturedPages[index];
    final updated = await Navigator.of(context).push<PageEdit>(
      MaterialPageRoute(
        builder: (_) => ImageEnhancerScreen(
          originalImagePath: page.sourcePath,
          initialEdit: page.edit,
          title: 'Edit Page ${index + 1}',
        ),
      ),
    );

    if (updated != null && mounted) {
      setState(() {
        _capturedPages[index] = PageDraft(
          page.sourcePath,
          edit: updated,
          preProcessed: false,
        );
      });
    }
  }

  Future<void> _finishAndSave() async {
    if (_capturedPages.isEmpty) return;

    final controller = TextEditingController(
      text: 'Scan ${DateTime.now().day}/${DateTime.now().month} ${DateTime.now().hour}:${DateTime.now().minute.toString().padLeft(2, '0')}',
    );

    final title = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Save Document'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Document Name', border: OutlineInputBorder()),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, controller.text), child: const Text('Save')),
        ],
      ),
    );

    if (title == null || title.trim().isEmpty || !mounted) return;

    final doc = await runWithProgress(
      context,
      'Saving and processing document...',
      (progress) async {
        return await ref.read(documentRepositoryProvider).createDocument(
              title: title.trim(),
              folderId: widget.targetFolderId,
              mode: _selectedMode,
              pages: _capturedPages,
              onProgress: (done, total) => progress('Processing page $done of $total...', done / total),
            );
      },
    );

    if (doc != null && mounted) {
      showSnack(context, 'Document saved: "${doc.title}"');
      Navigator.of(context).pop(doc);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Column(
          children: [
            // Top Controls Bar
            _buildTopBar(),

            // Camera Viewport
            Expanded(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  _buildCameraPreview(),
                  if (_gridEnabled) _buildGridOverlay(),
                  if (_isCapturing)
                    Container(
                      color: Colors.white.withValues(alpha: 0.3),
                    ),
                ],
              ),
            ),

            // Captured Thumbnails Tray
            if (_capturedPages.isNotEmpty) _buildCapturedTray(),

            // Scan Mode Selector
            _buildScanModesBar(),

            // Bottom Shutter & Controls
            _buildShutterControls(),
          ],
        ),
      ),
    );
  }

  Widget _buildTopBar() {
    return Container(
      color: Colors.black,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          IconButton(
            icon: const Icon(Icons.arrow_back, color: Colors.white),
            onPressed: () => Navigator.of(context).pop(),
          ),
          IconButton(
            icon: Icon(
              switch (_flashMode) {
                FlashMode.auto => Icons.flash_auto,
                FlashMode.always => Icons.flash_on,
                FlashMode.torch => Icons.highlight,
                FlashMode.off => Icons.flash_off,
              },
              color: _flashMode == FlashMode.off ? Colors.white54 : Colors.amber,
            ),
            tooltip: 'Flash mode',
            onPressed: _toggleFlash,
          ),
          IconButton(
            icon: Icon(
              Icons.grid_on,
              color: _gridEnabled ? AppColors.brandDark : Colors.white54,
            ),
            tooltip: 'Camera Grid',
            onPressed: () => setState(() => _gridEnabled = !_gridEnabled),
          ),
          IconButton(
            icon: const Icon(Icons.document_scanner_outlined, color: AppColors.brandDark),
            tooltip: 'AI ML-Kit Auto Scanner',
            onPressed: _useMlKitDocScanner,
          ),
          IconButton(
            icon: const Icon(Icons.flip_camera_ios_outlined, color: Colors.white),
            tooltip: 'Switch camera',
            onPressed: _toggleCamera,
          ),
        ],
      ),
    );
  }

  Widget _buildCameraPreview() {
    if (_cameraInitialized && _cameraController != null) {
      return Center(
        child: CameraPreview(_cameraController!),
      );
    }

    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.camera_alt_outlined, size: 64, color: Colors.white30),
          const SizedBox(height: 12),
          const Text('Camera preview not active', style: TextStyle(color: Colors.white60)),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: _pickFromGallery,
            icon: const Icon(Icons.photo_library),
            label: const Text('Pick from Gallery'),
          ),
        ],
      ),
    );
  }

  Widget _buildGridOverlay() {
    return IgnorePointer(
      child: CustomPaint(
        painter: _GridOverlayPainter(),
      ),
    );
  }

  Widget _buildCapturedTray() {
    return Container(
      height: 72,
      color: const Color(0xFF161C19),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Row(
        children: [
          Text(
            '${_capturedPages.length} ${ _capturedPages.length == 1 ? 'Page' : 'Pages' }',
            style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: _capturedPages.length,
              separatorBuilder: (_, _) => const SizedBox(width: 8),
              itemBuilder: (ctx, i) {
                final page = _capturedPages[i];
                return InkWell(
                  onTap: () => _editPage(i),
                  child: Stack(
                    children: [
                      Container(
                        width: 50,
                        height: 60,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(color: AppColors.brandDark, width: 1.5),
                        ),
                        clipBehavior: Clip.antiAlias,
                        child: Image.file(File(page.sourcePath), fit: BoxFit.cover),
                      ),
                      Positioned(
                        top: 2,
                        right: 2,
                        child: InkWell(
                          onTap: () => setState(() => _capturedPages.removeAt(i)),
                          child: Container(
                            decoration: const BoxDecoration(color: Colors.black87, shape: BoxShape.circle),
                            padding: const EdgeInsets.all(2),
                            child: const Icon(Icons.close, size: 12, color: Colors.white),
                          ),
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildScanModesBar() {
    return Container(
      color: Colors.black,
      height: 48,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        itemCount: ScanMode.values.length,
        separatorBuilder: (_, _) => const SizedBox(width: 16),
        itemBuilder: (ctx, i) {
          final mode = ScanMode.values[i];
          final isSelected = _selectedMode == mode;
          return Center(
            child: InkWell(
              onTap: () {
                if (mode == ScanMode.idCard) {
                  Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => IdCardScanScreen(targetFolderId: widget.targetFolderId)),
                  );
                } else {
                  setState(() => _selectedMode = mode);
                }
              },
              child: Text(
                mode.label.toUpperCase(),
                style: TextStyle(
                  color: isSelected ? AppColors.brandDark : Colors.white54,
                  fontSize: 12,
                  letterSpacing: 0.8,
                  fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildShutterControls() {
    return Container(
      color: Colors.black,
      padding: const EdgeInsets.fromLTRB(24, 12, 24, 20),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          // Gallery import
          IconButton(
            icon: const Icon(Icons.photo_library_outlined, color: Colors.white, size: 30),
            tooltip: 'Import images',
            onPressed: _pickFromGallery,
          ),

          // Shutter Button
          InkWell(
            onTap: _isCapturing ? null : _capture,
            borderRadius: BorderRadius.circular(99),
            child: Container(
              width: 76,
              height: 76,
              padding: const EdgeInsets.all(4),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(color: Colors.white, width: 3.5),
              ),
              child: Container(
                decoration: const BoxDecoration(
                  color: AppColors.brand,
                  shape: BoxShape.circle,
                ),
                child: _isCapturing
                    ? const Padding(padding: EdgeInsets.all(22), child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                    : const Icon(Icons.camera_alt, color: Colors.white, size: 32),
              ),
            ),
          ),

          // Finish / Next Button
          _capturedPages.isEmpty
              ? const SizedBox(width: 48)
              : Badge(
                  label: Text('${_capturedPages.length}'),
                  backgroundColor: AppColors.brandDark,
                  textColor: Colors.black,
                  child: FilledButton.tonal(
                    onPressed: _finishAndSave,
                    style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 16)),
                    child: const Text('Save'),
                  ),
                ),
        ],
      ),
    );
  }
}

class _GridOverlayPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.white.withValues(alpha: 0.25)
      ..strokeWidth = 1.0;

    final x1 = size.width / 3;
    final x2 = (size.width / 3) * 2;
    final y1 = size.height / 3;
    final y2 = (size.height / 3) * 2;

    canvas.drawLine(Offset(x1, 0), Offset(x1, size.height), paint);
    canvas.drawLine(Offset(x2, 0), Offset(x2, size.height), paint);
    canvas.drawLine(Offset(0, y1), Offset(size.width, y1), paint);
    canvas.drawLine(Offset(0, y2), Offset(size.width, y2), paint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
