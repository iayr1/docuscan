import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_doc_scanner/flutter_doc_scanner.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import '../../app/providers.dart';
import '../../core/image/image_types.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utils/formatters.dart';
import '../../data/models/models.dart';
import '../../data/repositories/document_repository.dart';
import '../../shared/widgets/common.dart';
import '../image_editor/image_enhancer_screen.dart';
import 'id_card_scan_screen.dart';
import 'qr_scan_screen.dart';

/// Multi-page camera scanner.
///
/// Pops with the created [Document] or, when [targetDocumentId] is set, with
/// `true` after the captured pages were appended to that document.
class ScannerScreen extends ConsumerStatefulWidget {
  const ScannerScreen({
    super.key,
    this.targetFolderId,
    this.targetDocumentId,
    this.initialMode = ScanMode.document,
  });
  final String? targetFolderId;
  final String? targetDocumentId;
  final ScanMode initialMode;

  @override
  ConsumerState<ScannerScreen> createState() => _ScannerScreenState();
}

class _ScannerScreenState extends ConsumerState<ScannerScreen> with WidgetsBindingObserver {
  CameraController? _cameraController;
  List<CameraDescription> _cameras = [];
  int _selectedCameraIndex = 0;
  bool _cameraInitialized = false;
  bool _cameraUnavailable = false;
  bool _initializing = false;

  late ScanMode _selectedMode;
  FlashMode _flashMode = FlashMode.off;
  late bool _gridEnabled;

  final List<PageDraft> _capturedPages = [];
  bool _isCapturing = false;
  bool _flash = false;

  bool get _addingToDocument => widget.targetDocumentId != null;

  /// Modes that make sense in the camera mode strip (ID card and QR open their
  /// own dedicated screens).
  static final _modes = ScanMode.values.toList();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _selectedMode = widget.initialMode;
    _gridEnabled = ref.read(settingsProvider).showGrid;
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
    if (state == AppLifecycleState.inactive || state == AppLifecycleState.paused) {
      _releaseCamera();
    } else if (state == AppLifecycleState.resumed && _cameraController == null) {
      _initCamera();
    }
  }

  Future<void> _releaseCamera() async {
    final c = _cameraController;
    if (c == null) return;
    _cameraController = null;
    if (mounted) setState(() => _cameraInitialized = false);
    await c.dispose();
  }

  Future<void> _initCamera() async {
    if (_initializing) return;
    _initializing = true;
    try {
      if (_cameras.isEmpty) _cameras = await availableCameras();
      if (_cameras.isEmpty) {
        if (mounted) setState(() => _cameraUnavailable = true);
        return;
      }
      final controller = CameraController(
        _cameras[_selectedCameraIndex],
        ResolutionPreset.veryHigh,
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.jpeg,
      );
      await controller.initialize();
      try {
        await controller.setFlashMode(_flashMode);
        await controller.setFocusMode(FocusMode.auto);
      } catch (_) {}
      if (!mounted) {
        await controller.dispose();
        return;
      }
      _cameraController = controller;
      setState(() {
        _cameraInitialized = true;
        _cameraUnavailable = false;
      });
    } catch (_) {
      // Camera missing or permission denied.
      if (mounted) setState(() => _cameraUnavailable = true);
    } finally {
      _initializing = false;
    }
  }

  Future<void> _toggleCamera() async {
    if (_cameras.length < 2) return;
    _selectedCameraIndex = (_selectedCameraIndex + 1) % _cameras.length;
    await _releaseCamera();
    await _initCamera();
  }

  Future<void> _toggleFlash() async {
    final c = _cameraController;
    if (c == null) return;
    final next = switch (_flashMode) {
      FlashMode.off => FlashMode.auto,
      FlashMode.auto => FlashMode.always,
      FlashMode.always => FlashMode.torch,
      FlashMode.torch => FlashMode.off,
    };
    try {
      await c.setFlashMode(next);
      setState(() => _flashMode = next);
    } catch (_) {
      if (mounted) showSnack(context, 'Flash is not supported on this camera');
    }
  }

  Future<void> _addCapturedFile(String path) async {
    Quad? detected;
    if (ref.read(settingsProvider).autoCrop && _selectedMode.autoCrop) {
      try {
        detected = await ref.read(imageServiceProvider).detectDocument(path);
      } catch (_) {}
    }
    if (!mounted) return;
    setState(() => _capturedPages.add(PageDraft(path, edit: PageEdit(quad: detected, filter: _selectedMode.defaultFilter))));
  }

  /// Takes a photo with the live camera preview.
  Future<void> _capture() async {
    final c = _cameraController;
    if (_isCapturing) return;
    if (c == null || !_cameraInitialized) {
      // No live camera: fall back to the system document scanner.
      return _useSystemScanner();
    }
    setState(() => _isCapturing = true);
    try {
      HapticFeedback.mediumImpact();
      final xfile = await c.takePicture();
      setState(() => _flash = true);
      Future<void>.delayed(const Duration(milliseconds: 120), () {
        if (mounted) setState(() => _flash = false);
      });
      await _addCapturedFile(xfile.path);
    } catch (e) {
      if (mounted) showSnack(context, 'Capture failed: $e', error: true);
    } finally {
      if (mounted) setState(() => _isCapturing = false);
    }
  }

  Future<void> _pickFromGallery() async {
    try {
      final images = await ImagePicker().pickMultiImage();
      if (images.isEmpty) return;
      for (final img in images) {
        await _addCapturedFile(img.path);
      }
    } catch (e) {
      if (mounted) showSnack(context, 'Gallery import failed: $e', error: true);
    }
  }

  /// Platform document scanner (ML Kit on Android, VisionKit on iOS) with its
  /// own edge detection and perspective correction.
  Future<void> _useSystemScanner() async {
    if (_isCapturing) return;
    setState(() => _isCapturing = true);
    try {
      final result = await FlutterDocScanner().getScannedDocumentAsImages(page: 20);
      if (result == null || result.images.isEmpty || !mounted) return;
      setState(() {
        for (final path in result.images) {
          _capturedPages.add(PageDraft(path, edit: PageEdit(filter: _selectedMode.defaultFilter), preProcessed: true));
        }
      });
    } catch (e) {
      if (mounted) showSnack(context, 'Auto scan is unavailable on this device. Use the shutter instead.', error: true);
    } finally {
      if (mounted) setState(() => _isCapturing = false);
    }
  }

  Future<void> _editPage(int index) async {
    final page = _capturedPages[index];
    final updated = await Navigator.of(context).push<PageEdit>(
      MaterialPageRoute(
        builder: (_) => ImageEnhancerScreen(originalImagePath: page.sourcePath, initialEdit: page.edit, title: 'Edit page ${index + 1}'),
      ),
    );
    if (updated != null && mounted) {
      setState(() => _capturedPages[index] = PageDraft(page.sourcePath, edit: updated, preProcessed: false));
    }
  }

  Future<bool> _confirmDiscard() async {
    if (_capturedPages.isEmpty) return true;
    return confirm(
      context,
      'Discard scans?',
      'You have ${_capturedPages.length} unsaved page${_capturedPages.length == 1 ? '' : 's'}.',
      confirmLabel: 'Discard',
      destructive: true,
    );
  }

  Future<void> _finishAndSave() async {
    if (_capturedPages.isEmpty) return;

    if (_addingToDocument) {
      final ok = await runWithProgress(context, 'Adding pages…', (progress) async {
        await ref.read(documentRepositoryProvider).addPages(
              widget.targetDocumentId!,
              _capturedPages,
              onProgress: (done, total) => progress('Processing page $done of $total…', done / total),
            );
        return true;
      });
      if (ok == true && mounted) {
        _capturedPages.clear();
        Navigator.of(context).pop(true);
      }
      return;
    }

    final now = DateTime.now();
    final title = await promptText(
      context,
      'Save document',
      initial: '${_selectedMode == ScanMode.document ? 'Scan' : _selectedMode.label} ${formatDateTime(now)}',
      label: 'Document name',
    );
    if (title == null || title.trim().isEmpty || !mounted) return;

    final doc = await runWithProgress(context, 'Saving document…', (progress) {
      return ref.read(documentRepositoryProvider).createDocument(
            title: title.trim(),
            folderId: widget.targetFolderId,
            mode: _selectedMode,
            pages: _capturedPages,
            onProgress: (done, total) => progress('Processing page $done of $total…', done / total),
          );
    });

    if (doc != null && mounted) {
      _capturedPages.clear();
      showSnack(context, 'Saved “${doc.title}”');
      Navigator.of(context).pop(doc);
    }
  }

  void _selectMode(ScanMode mode) {
    if (mode == ScanMode.idCard) {
      Navigator.of(context).push<Document>(MaterialPageRoute(builder: (_) => IdCardScanScreen(targetFolderId: widget.targetFolderId))).then((doc) {
        // Hand the finished ID card back to whoever opened the scanner.
        if (doc != null && mounted && _capturedPages.isEmpty && !_addingToDocument) Navigator.of(context).pop(doc);
      });
    } else if (mode == ScanMode.qrCode) {
      Navigator.of(context).push(MaterialPageRoute(builder: (_) => const QrScanScreen()));
    } else {
      setState(() => _selectedMode = mode);
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: _capturedPages.isEmpty,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        if (await _confirmDiscard() && mounted) {
          _capturedPages.clear();
          Navigator.of(this.context).pop();
        }
      },
      child: AnnotatedRegion<SystemUiOverlayStyle>(
        value: SystemUiOverlayStyle.light,
        child: Scaffold(
          backgroundColor: Colors.black,
          body: SafeArea(
            child: Column(
              children: [
                _buildTopBar(),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(AppRadius.xl),
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          _buildCameraPreview(),
                          if (_gridEnabled && _cameraInitialized) IgnorePointer(child: CustomPaint(painter: _GridOverlayPainter())),
                          if (_cameraInitialized)
                            Positioned(
                              top: 12,
                              left: 0,
                              right: 0,
                              child: Center(
                                child: Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                                  decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(AppRadius.pill)),
                                  child: Text(
                                    _addingToDocument ? 'Adding pages to document' : _selectedMode.description,
                                    style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600),
                                  ),
                                ),
                              ),
                            ),
                          IgnorePointer(
                            child: AnimatedOpacity(
                              opacity: _flash ? 0.7 : 0,
                              duration: const Duration(milliseconds: 100),
                              child: const ColoredBox(color: Colors.white),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                if (_capturedPages.isNotEmpty) _buildCapturedTray(),
                _buildScanModesBar(),
                _buildShutterControls(),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildTopBar() {
    Widget btn(IconData icon, String tooltip, VoidCallback? onTap, {Color color = Colors.white}) =>
        IconButton(icon: Icon(icon, color: color), tooltip: tooltip, onPressed: onTap);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
      child: Row(
        children: [
          btn(Icons.close_rounded, 'Close', () => Navigator.of(context).maybePop()),
          const Spacer(),
          btn(
            switch (_flashMode) {
              FlashMode.auto => Icons.flash_auto_rounded,
              FlashMode.always => Icons.flash_on_rounded,
              FlashMode.torch => Icons.flashlight_on_rounded,
              FlashMode.off => Icons.flash_off_rounded,
            },
            'Flash',
            _cameraInitialized ? _toggleFlash : null,
            color: _flashMode == FlashMode.off ? Colors.white70 : Colors.amber,
          ),
          btn(Icons.grid_on_rounded, 'Grid', () => setState(() => _gridEnabled = !_gridEnabled), color: _gridEnabled ? AppColors.brandDark : Colors.white70),
          if (_cameras.length > 1) btn(Icons.cameraswitch_outlined, 'Switch camera', _toggleCamera),
          btn(Icons.auto_awesome_outlined, 'Auto scan (edge detection)', _isCapturing ? null : _useSystemScanner),
        ],
      ),
    );
  }

  Widget _buildCameraPreview() {
    final c = _cameraController;
    if (_cameraInitialized && c != null) {
      return FittedBox(
        fit: BoxFit.cover,
        child: SizedBox(
          width: c.value.previewSize?.height ?? 1080,
          height: c.value.previewSize?.width ?? 1920,
          child: CameraPreview(c),
        ),
      );
    }

    if (!_cameraUnavailable) {
      return const Center(child: CircularProgressIndicator(color: Colors.white54, strokeWidth: 2));
    }

    return ColoredBox(
      color: const Color(0xFF111614),
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.no_photography_outlined, size: 56, color: Colors.white38),
              const SizedBox(height: 14),
              const Text('Camera unavailable', style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w700)),
              const SizedBox(height: 6),
              const Text(
                'Allow camera access in system settings, or use auto scan / gallery import.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white60),
              ),
              const SizedBox(height: 18),
              Wrap(spacing: 10, runSpacing: 10, alignment: WrapAlignment.center, children: [
                FilledButton.icon(onPressed: _useSystemScanner, icon: const Icon(Icons.auto_awesome_outlined), label: const Text('Auto scan')),
                OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(foregroundColor: Colors.white, side: const BorderSide(color: Colors.white38)),
                  onPressed: _pickFromGallery,
                  icon: const Icon(Icons.photo_library_outlined),
                  label: const Text('Gallery'),
                ),
                TextButton(onPressed: _initCamera, child: const Text('Retry camera')),
              ]),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildCapturedTray() {
    return SizedBox(
      height: 84,
      child: ReorderableListView.builder(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
        itemCount: _capturedPages.length,
        onReorderItem: (oldIndex, newIndex) => setState(() {
          _capturedPages.insert(newIndex, _capturedPages.removeAt(oldIndex));
        }),
        itemBuilder: (ctx, i) {
          final page = _capturedPages[i];
          return Padding(
            key: ObjectKey(page),
            padding: const EdgeInsets.only(right: 8),
            child: GestureDetector(
              onTap: () => _editPage(i),
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  Container(
                    width: 52,
                    height: 68,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: Colors.white70, width: 1.5),
                    ),
                    clipBehavior: Clip.antiAlias,
                    child: Image.file(File(page.sourcePath), fit: BoxFit.cover, cacheWidth: 160),
                  ),
                  Positioned(
                    left: 3,
                    bottom: 3,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                      decoration: BoxDecoration(color: Colors.black87, borderRadius: BorderRadius.circular(4)),
                      child: Text('${i + 1}', style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.w800)),
                    ),
                  ),
                  Positioned(
                    top: -6,
                    right: -6,
                    child: GestureDetector(
                      onTap: () => setState(() => _capturedPages.removeAt(i)),
                      child: Container(
                        decoration: const BoxDecoration(color: AppColors.danger, shape: BoxShape.circle),
                        padding: const EdgeInsets.all(3),
                        child: const Icon(Icons.close_rounded, size: 12, color: Colors.white),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildScanModesBar() {
    return SizedBox(
      height: 48,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        itemCount: _modes.length,
        separatorBuilder: (_, _) => const SizedBox(width: 6),
        itemBuilder: (ctx, i) {
          final mode = _modes[i];
          final isSelected = _selectedMode == mode;
          return GestureDetector(
            onTap: () => _selectMode(mode),
            child: AnimatedContainer(
              duration: AppDurations.fast,
              padding: const EdgeInsets.symmetric(horizontal: 14),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: isSelected ? Colors.white : Colors.white.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(AppRadius.pill),
              ),
              child: Text(
                mode.label,
                style: TextStyle(
                  color: isSelected ? Colors.black : Colors.white70,
                  fontSize: 12.5,
                  fontWeight: isSelected ? FontWeight.w800 : FontWeight.w600,
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildShutterControls() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 6, 24, 16),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          SizedBox(
            width: 64,
            child: _roundButton(Icons.photo_library_outlined, 'Import images', _pickFromGallery),
          ),
          Semantics(
            button: true,
            label: 'Capture page',
            child: GestureDetector(
              onTap: _isCapturing ? null : _capture,
              child: Container(
                width: 78,
                height: 78,
                padding: const EdgeInsets.all(5),
                decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: Colors.white, width: 4)),
                child: AnimatedContainer(
                  duration: AppDurations.fast,
                  decoration: BoxDecoration(color: _isCapturing ? Colors.white54 : Colors.white, shape: BoxShape.circle),
                  child: _isCapturing
                      ? const Padding(padding: EdgeInsets.all(20), child: CircularProgressIndicator(color: AppColors.brand, strokeWidth: 2.5))
                      : null,
                ),
              ),
            ),
          ),
          SizedBox(
            width: 64,
            child: _capturedPages.isEmpty
                ? const SizedBox.shrink()
                : FilledButton(
                    onPressed: _isCapturing ? null : _finishAndSave,
                    style: FilledButton.styleFrom(
                      backgroundColor: AppColors.brandDark,
                      foregroundColor: Colors.black,
                      padding: EdgeInsets.zero,
                      minimumSize: const Size(64, 52),
                    ),
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                      const Icon(Icons.check_rounded, size: 20),
                      Text('${_capturedPages.length}', style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w800)),
                    ]),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _roundButton(IconData icon, String tooltip, VoidCallback onTap) => IconButton(
        tooltip: tooltip,
        onPressed: onTap,
        style: IconButton.styleFrom(backgroundColor: Colors.white.withValues(alpha: 0.12), fixedSize: const Size(52, 52)),
        icon: Icon(icon, color: Colors.white, size: 24),
      );
}

class _GridOverlayPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.white.withValues(alpha: 0.3)
      ..strokeWidth = 1.0;
    for (var i = 1; i < 3; i++) {
      final x = size.width * i / 3;
      final y = size.height * i / 3;
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), paint);
      canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
