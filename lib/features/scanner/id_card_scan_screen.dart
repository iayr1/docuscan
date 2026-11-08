import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import '../../app/providers.dart';
import '../../core/theme/app_theme.dart';
import '../../data/models/models.dart';
import '../../data/repositories/document_repository.dart';
import '../../shared/widgets/common.dart';

/// Guided 2-step scanning mode for ID Cards, driver's licenses, and passports:
/// captures front side, then back side, and combines both onto a single document page.
class IdCardScanScreen extends ConsumerStatefulWidget {
  const IdCardScanScreen({super.key, this.targetFolderId});
  final String? targetFolderId;

  @override
  ConsumerState<IdCardScanScreen> createState() => _IdCardScanScreenState();
}

class _IdCardScanScreenState extends ConsumerState<IdCardScanScreen> {
  CameraController? _cameraController;
  List<CameraDescription> _cameras = [];
  bool _cameraInitialized = false;
  int _step = 0; // 0: Capture front, 1: Capture back, 2: Review both
  String? _frontPath;
  String? _backPath;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _initCamera();
  }

  Future<void> _initCamera() async {
    try {
      _cameras = await availableCameras();
      if (_cameras.isEmpty) return;
      _cameraController = CameraController(
        _cameras.first,
        ResolutionPreset.high,
        enableAudio: false,
      );
      await _cameraController!.initialize();
      if (mounted) setState(() => _cameraInitialized = true);
    } catch (_) {
      // Camera may not be available on desktop or simulator; fallback to gallery picker
    }
  }

  @override
  void dispose() {
    _cameraController?.dispose();
    super.dispose();
  }

  Future<void> _captureOrPick({bool fromGallery = false}) async {
    if (_busy) return;
    setState(() => _busy = true);

    try {
      String? path;
      if (fromGallery || !_cameraInitialized) {
        final picked = await ImagePicker().pickImage(source: ImageSource.gallery);
        if (picked != null) path = picked.path;
      } else {
        final xfile = await _cameraController!.takePicture();
        path = xfile.path;
      }

      if (path == null) {
        setState(() => _busy = false);
        return;
      }

      if (_step == 0) {
        setState(() {
          _frontPath = path;
          _step = 1;
          _busy = false;
        });
      } else if (_step == 1) {
        setState(() {
          _backPath = path;
          _step = 2;
          _busy = false;
        });
      }
    } catch (e) {
      if (mounted) {
        showSnack(context, 'Capture failed: $e', error: true);
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _saveCombinedIdCard() async {
    if (_frontPath == null || _backPath == null) return;
    setState(() => _busy = true);

    try {
      // Compose both onto a single page using imageService
      final composedBytes = await ref.read(imageServiceProvider).composeIdCard(_frontPath!, _backPath!);
      final tempFile = File('${ref.read(fileStoreProvider).temp.path}/id_card_${DateTime.now().millisecondsSinceEpoch}.jpg');
      await tempFile.writeAsBytes(composedBytes);

      // Create new document in repository
      final title = 'ID Card ${DateTime.now().day}/${DateTime.now().month}/${DateTime.now().year}';
      final doc = await ref.read(documentRepositoryProvider).createDocument(
            title: title,
            folderId: widget.targetFolderId,
            mode: ScanMode.idCard,
            pages: [PageDraft(tempFile.path, preProcessed: true)],
          );

      if (mounted) {
        showSnack(context, 'ID card created successfully');
        Navigator.of(context).pop(doc);
      }
    } catch (e) {
      if (mounted) showSnack(context, 'Failed to compose ID card: $e', error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(
          _step == 0
              ? 'Scan ID Front'
              : _step == 1
                  ? 'Scan ID Back'
                  : 'Review ID Card',
          style: const TextStyle(color: Colors.white),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.photo_library_outlined),
            tooltip: 'Pick from gallery',
            onPressed: () => _captureOrPick(fromGallery: true),
          ),
        ],
      ),
      body: _step < 2 ? _buildCameraView() : _buildReviewView(),
    );
  }

  Widget _buildCameraView() {
    return Stack(
      fit: StackFit.expand,
      children: [
        if (_cameraInitialized && _cameraController != null)
          Center(child: CameraPreview(_cameraController!))
        else
          Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.badge_outlined, size: 72, color: Colors.white38),
                const SizedBox(height: 16),
                Text(
                  _step == 0 ? 'Select or capture Front side of ID' : 'Select or capture Back side of ID',
                  style: const TextStyle(color: Colors.white70),
                ),
                const SizedBox(height: 20),
                FilledButton.icon(
                  onPressed: () => _captureOrPick(fromGallery: true),
                  icon: const Icon(Icons.photo_library),
                  label: const Text('Choose Photo'),
                ),
              ],
            ),
          ),

        // ID Card Overlay Frame Guide (aspect ratio ~ 1.58)
        Center(
          child: Container(
            width: 320,
            height: 202,
            decoration: BoxDecoration(
              border: Border.all(color: AppColors.brandDark, width: 2.5),
              borderRadius: BorderRadius.circular(16),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.5),
                  spreadRadius: 999,
                ),
              ],
            ),
            child: Stack(
              children: [
                Positioned(
                  top: 14,
                  left: 14,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: AppColors.brand,
                      borderRadius: BorderRadius.circular(AppRadius.sm),
                    ),
                    child: Text(
                      _step == 0 ? 'FRONT SIDE' : 'BACK SIDE',
                      style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold),
                    ),
                  ),
                ),
                Center(
                  child: Text(
                    'Align card within frame',
                    style: TextStyle(color: Colors.white.withValues(alpha: 0.8), fontSize: 13),
                  ),
                ),
              ],
            ),
          ),
        ),

        // Bottom Capture Controls
        Positioned(
          bottom: 30,
          left: 0,
          right: 0,
          child: Column(
            children: [
              Text(
                _step == 0 ? 'Step 1 of 2: Front' : 'Step 2 of 2: Back',
                style: const TextStyle(color: Colors.white70, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  InkWell(
                    onTap: _busy ? null : () => _captureOrPick(),
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
                        child: _busy
                            ? const Padding(padding: EdgeInsets.all(20), child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                            : const Icon(Icons.camera_alt, color: Colors.white, size: 32),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildReviewView() {
    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        children: [
          const Text(
            'Both sides captured! Both will be merged onto a single document page.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.white70),
          ),
          const SizedBox(height: 20),
          Expanded(
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    children: [
                      const Text('Front', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                      const SizedBox(height: 8),
                      Expanded(
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(12),
                          child: _frontPath != null ? Image.file(File(_frontPath!), fit: BoxFit.cover) : const SizedBox(),
                        ),
                      ),
                      TextButton.icon(
                        onPressed: () => setState(() => _step = 0),
                        icon: const Icon(Icons.replay),
                        label: const Text('Retake Front'),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    children: [
                      const Text('Back', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                      const SizedBox(height: 8),
                      Expanded(
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(12),
                          child: _backPath != null ? Image.file(File(_backPath!), fit: BoxFit.cover) : const SizedBox(),
                        ),
                      ),
                      TextButton.icon(
                        onPressed: () => setState(() => _step = 1),
                        icon: const Icon(Icons.replay),
                        label: const Text('Retake Back'),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),
          SizedBox(
            width: double.infinity,
            height: 52,
            child: FilledButton.icon(
              onPressed: _busy ? null : _saveCombinedIdCard,
              icon: _busy
                  ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                  : const Icon(Icons.check_circle_outline),
              label: const Text('Combine & Save Document', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            ),
          ),
        ],
      ),
    );
  }
}
