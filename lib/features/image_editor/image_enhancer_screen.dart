import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/image/image_types.dart';
import '../../core/theme/app_theme.dart';
import '../scanner/manual_crop_screen.dart';

class ImageEnhancerScreen extends ConsumerStatefulWidget {
  const ImageEnhancerScreen({
    super.key,
    required this.originalImagePath,
    this.initialEdit = const PageEdit(),
    this.title = 'Enhance Document',
  });

  final String originalImagePath;
  final PageEdit initialEdit;
  final String title;

  @override
  ConsumerState<ImageEnhancerScreen> createState() =>
      _ImageEnhancerScreenState();
}

class _ImageEnhancerScreenState extends ConsumerState<ImageEnhancerScreen> {
  late PageEdit _edit;
  bool _comparing = false;
  int _activeSliderTab = 0; // 0: Filters, 1: Sliders
  final bool _processing = false;

  final List<(String, ScanFilter, IconData)> _filterPresets = const [
    ('Original', ScanFilter.original, Icons.image_outlined),
    ('Auto', ScanFilter.auto, Icons.auto_fix_high),
    ('Magic Color', ScanFilter.magic, Icons.color_lens_outlined),
    ('B & W', ScanFilter.blackWhite, Icons.contrast),
    ('Clear Text', ScanFilter.clearText, Icons.text_fields_rounded),
    ('Grayscale', ScanFilter.grayscale, Icons.filter_b_and_w),
    ('Soft Gray', ScanFilter.softGray, Icons.grain_rounded),
    ('Whiteboard', ScanFilter.whiteboard, Icons.dashboard_outlined),
    ('Vivid', ScanFilter.vivid, Icons.palette_outlined),
    ('Photo', ScanFilter.photo, Icons.camera_alt_outlined),
    ('Low Light', ScanFilter.lowLight, Icons.wb_sunny_outlined),
    ('Eco Print', ScanFilter.ecoPrint, Icons.eco_outlined),
  ];

  @override
  void initState() {
    super.initState();
    _edit = widget.initialEdit;
  }

  Future<void> _openCrop() async {
    final result = await Navigator.of(context)
        .push<({Quad quad, int rotation})>(
          MaterialPageRoute(
            builder: (_) => ManualCropScreen(
              imagePath: widget.originalImagePath,
              initialQuad: _edit.quad,
              initialRotation: _edit.rotation,
            ),
          ),
        );

    if (result != null && mounted) {
      setState(() {
        _edit = _edit.copyWith(quad: result.quad, rotation: result.rotation);
      });
    }
  }

  void _rotate() {
    setState(() {
      _edit = _edit.copyWith(rotation: (_edit.rotation + 1) % 4);
    });
  }

  void _save() {
    Navigator.of(context).pop(_edit);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(widget.title, style: const TextStyle(color: Colors.white)),
        actions: [
          IconButton(
            icon: const Icon(Icons.crop_outlined),
            tooltip: 'Crop & Perspective',
            onPressed: _openCrop,
          ),
          IconButton(
            icon: const Icon(Icons.rotate_right_outlined),
            tooltip: 'Rotate 90°',
            onPressed: _rotate,
          ),
          FilledButton.tonal(
            onPressed: _processing ? null : _save,
            child: const Text('Save'),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: Column(
        children: [
          // Preview Area
          Expanded(
            child: GestureDetector(
              onLongPressStart: (_) => setState(() => _comparing = true),
              onLongPressEnd: (_) => setState(() => _comparing = false),
              child: Center(
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    RotatedBox(
                      quarterTurns: _edit.rotation,
                      child: ColorFiltered(
                        colorFilter: _getColorFilter(
                          _comparing ? ScanFilter.original : _edit.filter,
                        ),
                        child: Image.file(
                          File(widget.originalImagePath),
                          fit: BoxFit.contain,
                          gaplessPlayback: true,
                        ),
                      ),
                    ),
                    if (_comparing)
                      Positioned(
                        top: 16,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 6,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.black87,
                            borderRadius: BorderRadius.circular(AppRadius.pill),
                            border: Border.all(color: Colors.white24),
                          ),
                          child: const Text(
                            'ORIGINAL CAPTURE',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 12,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),

          // Control Bar: Presets vs Manual Sliders
          Container(
            color: const Color(0xFF141A17),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                ChoiceChip(
                  label: const Text('Preset Filters'),
                  selected: _activeSliderTab == 0,
                  onSelected: (v) {
                    if (v) setState(() => _activeSliderTab = 0);
                  },
                ),
                const SizedBox(width: 12),
                ChoiceChip(
                  label: const Text('Fine Adjustments'),
                  selected: _activeSliderTab == 1,
                  onSelected: (v) {
                    if (v) setState(() => _activeSliderTab = 1);
                  },
                ),
                const Spacer(),
                TextButton.icon(
                  onPressed: () {
                    setState(() {
                      _comparing = !_comparing;
                    });
                  },
                  icon: Icon(
                    _comparing
                        ? Icons.visibility_off_outlined
                        : Icons.visibility_outlined,
                    size: 18,
                  ),
                  label: Text(_comparing ? 'Show Edit' : 'Compare'),
                ),
              ],
            ),
          ),

          // Sub-panel based on active tab
          Container(
            color: const Color(0xFF1B2320),
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
            child: _activeSliderTab == 0
                ? _buildFilterPresetsRow()
                : _buildManualSlidersColumn(),
          ),
        ],
      ),
    );
  }

  Widget _buildFilterPresetsRow() {
    return SizedBox(
      height: 84,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: _filterPresets.length,
        separatorBuilder: (_, _) => const SizedBox(width: 12),
        itemBuilder: (ctx, i) {
          final item = _filterPresets[i];
          final isSelected = _edit.filter == item.$2;

          return InkWell(
            onTap: () {
              setState(() {
                _edit = _edit.copyWith(filter: item.$2);
              });
            },
            borderRadius: BorderRadius.circular(AppRadius.md),
            child: Container(
              width: 76,
              padding: const EdgeInsets.symmetric(vertical: 8),
              decoration: BoxDecoration(
                color: isSelected
                    ? AppColors.brand.withValues(alpha: 0.25)
                    : Colors.black26,
                borderRadius: BorderRadius.circular(AppRadius.md),
                border: Border.all(
                  color: isSelected ? AppColors.brandDark : Colors.white12,
                  width: isSelected ? 2 : 1,
                ),
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    item.$3,
                    color: isSelected ? AppColors.brandDark : Colors.white70,
                    size: 26,
                  ),
                  const SizedBox(height: 6),
                  Text(
                    item.$1,
                    textAlign: TextAlign.center,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: isSelected ? Colors.white : Colors.white70,
                      fontSize: 11,
                      fontWeight: isSelected
                          ? FontWeight.bold
                          : FontWeight.normal,
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

  Widget _buildManualSlidersColumn() {
    final adj = _edit.adjustments;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _buildSlider(
          label: 'Brightness',
          value: adj.brightness,
          min: -0.5,
          max: 0.5,
          onChanged: (v) => setState(
            () => _edit = _edit.copyWith(
              adjustments: adj.copyWith(brightness: v),
            ),
          ),
        ),
        _buildSlider(
          label: 'Contrast',
          value: adj.contrast,
          min: -0.5,
          max: 0.5,
          onChanged: (v) => setState(
            () =>
                _edit = _edit.copyWith(adjustments: adj.copyWith(contrast: v)),
          ),
        ),
        _buildSlider(
          label: 'Saturation',
          value: adj.saturation,
          min: -1.0,
          max: 1.0,
          onChanged: (v) => setState(
            () => _edit = _edit.copyWith(
              adjustments: adj.copyWith(saturation: v),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildSlider({
    required String label,
    required double value,
    required double min,
    required double max,
    required ValueChanged<double> onChanged,
  }) {
    return Row(
      children: [
        SizedBox(
          width: 80,
          child: Text(
            label,
            style: const TextStyle(color: Colors.white70, fontSize: 12),
          ),
        ),
        Expanded(
          child: Slider(
            value: value.clamp(min, max),
            min: min,
            max: max,
            activeColor: AppColors.brandDark,
            inactiveColor: Colors.white24,
            onChanged: onChanged,
          ),
        ),
        SizedBox(
          width: 44,
          child: Text(
            '${(value * 100).toInt()}',
            textAlign: TextAlign.end,
            style: const TextStyle(color: Colors.white, fontSize: 12),
          ),
        ),
      ],
    );
  }

  ColorFilter _getColorFilter(ScanFilter filter) {
    switch (filter) {
      case ScanFilter.blackWhite:
        return const ColorFilter.matrix([
          1.5,
          1.5,
          1.5,
          0,
          -160,
          1.5,
          1.5,
          1.5,
          0,
          -160,
          1.5,
          1.5,
          1.5,
          0,
          -160,
          0,
          0,
          0,
          1,
          0,
        ]);
      case ScanFilter.grayscale:
      case ScanFilter.softGray:
        return const ColorFilter.matrix([
          0.299,
          0.587,
          0.114,
          0,
          0,
          0.299,
          0.587,
          0.114,
          0,
          0,
          0.299,
          0.587,
          0.114,
          0,
          0,
          0,
          0,
          0,
          1,
          0,
        ]);
      case ScanFilter.clearText:
        return const ColorFilter.matrix([
          0.478,
          0.939,
          0.182,
          0,
          -110,
          0.478,
          0.939,
          0.182,
          0,
          -110,
          0.478,
          0.939,
          0.182,
          0,
          -110,
          0,
          0,
          0,
          1,
          0,
        ]);
      case ScanFilter.vivid:
        return const ColorFilter.matrix([
          1.35,
          -0.17,
          -0.17,
          0,
          0,
          -0.17,
          1.35,
          -0.17,
          0,
          0,
          -0.17,
          -0.17,
          1.35,
          0,
          0,
          0,
          0,
          0,
          1,
          0,
        ]);
      case ScanFilter.lowLight:
        return const ColorFilter.matrix([
          1.1,
          0,
          0,
          0,
          22,
          0,
          1.1,
          0,
          0,
          22,
          0,
          0,
          1.1,
          0,
          22,
          0,
          0,
          0,
          1,
          0,
        ]);
      case ScanFilter.magic:
        return const ColorFilter.matrix([
          1.2,
          0,
          0,
          0,
          15,
          0,
          1.25,
          0,
          0,
          15,
          0,
          0,
          1.2,
          0,
          15,
          0,
          0,
          0,
          1,
          0,
        ]);
      case ScanFilter.whiteboard:
        return const ColorFilter.matrix([
          1.3,
          0,
          0,
          0,
          20,
          0,
          1.3,
          0,
          0,
          20,
          0,
          0,
          1.3,
          0,
          20,
          0,
          0,
          0,
          1,
          0,
        ]);
      case ScanFilter.auto:
        return const ColorFilter.matrix([
          1.1,
          0,
          0,
          0,
          10,
          0,
          1.1,
          0,
          0,
          10,
          0,
          0,
          1.1,
          0,
          10,
          0,
          0,
          0,
          1,
          0,
        ]);
      default:
        return const ColorFilter.matrix([
          1,
          0,
          0,
          0,
          0,
          0,
          1,
          0,
          0,
          0,
          0,
          0,
          1,
          0,
          0,
          0,
          0,
          0,
          1,
          0,
        ]);
    }
  }
}
