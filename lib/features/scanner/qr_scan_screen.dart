import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/theme/app_theme.dart';
import '../../shared/widgets/common.dart';

/// Reads QR codes and barcodes on-device and shows the decoded value.
class QrScanScreen extends StatefulWidget {
  const QrScanScreen({super.key});

  @override
  State<QrScanScreen> createState() => _QrScanScreenState();
}

class _QrScanScreenState extends State<QrScanScreen> {
  final MobileScannerController _controller = MobileScannerController(detectionSpeed: DetectionSpeed.noDuplicates);
  bool _showingResult = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _onDetect(BarcodeCapture capture) async {
    if (_showingResult) return;
    final code = capture.barcodes.where((b) => (b.rawValue ?? '').isNotEmpty).firstOrNull;
    if (code == null) return;
    _showingResult = true;
    HapticFeedback.mediumImpact();
    await _controller.stop();
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => _ResultSheet(barcode: code),
    );
    _showingResult = false;
    if (mounted) await _controller.start();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        foregroundColor: Colors.white,
        title: const Text('QR & barcode', style: TextStyle(color: Colors.white)),
        actions: [
          IconButton(icon: const Icon(Icons.flashlight_on_outlined), tooltip: 'Torch', onPressed: () => _controller.toggleTorch()),
          IconButton(icon: const Icon(Icons.cameraswitch_outlined), tooltip: 'Switch camera', onPressed: () => _controller.switchCamera()),
        ],
      ),
      body: Stack(
        fit: StackFit.expand,
        children: [
          MobileScanner(
            controller: _controller,
            onDetect: _onDetect,
            errorBuilder: (context, error) => Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  'Camera unavailable: ${error.errorCode.name}',
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white70),
                ),
              ),
            ),
          ),
          IgnorePointer(
            child: Center(
              child: Container(
                width: 250,
                height: 250,
                decoration: BoxDecoration(
                  border: Border.all(color: AppColors.brandDark, width: 3),
                  borderRadius: BorderRadius.circular(AppRadius.xl),
                ),
              ),
            ),
          ),
          const Positioned(
            left: 24,
            right: 24,
            bottom: 48,
            child: Text(
              'Point the camera at a QR code or barcode',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }
}

class _ResultSheet extends StatelessWidget {
  const _ResultSheet({required this.barcode});
  final Barcode barcode;

  @override
  Widget build(BuildContext context) {
    final value = barcode.rawValue ?? '';
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              IconBadge(barcode.format == BarcodeFormat.qrCode ? Icons.qr_code_2_rounded : Icons.barcode_reader, size: 44),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('Code detected', style: context.text.titleMedium),
                  Text(barcode.format.name.toUpperCase(), style: context.text.labelSmall?.copyWith(color: context.muted)),
                ]),
              ),
            ]),
            const SizedBox(height: 16),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: context.colors.surfaceContainerHighest.withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(AppRadius.md),
              ),
              child: SelectableText(value, style: context.text.bodyLarge),
            ),
            const SizedBox(height: 16),
            Row(children: [
              Expanded(
                child: OutlinedButton.icon(
                  icon: const Icon(Icons.copy_rounded),
                  label: const Text('Copy'),
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: value));
                    Navigator.pop(context);
                    showSnack(context, 'Copied to clipboard');
                  },
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton.icon(
                  icon: const Icon(Icons.ios_share_rounded),
                  label: const Text('Share'),
                  onPressed: () => SharePlus.instance.share(ShareParams(text: value)),
                ),
              ),
            ]),
          ],
        ),
      ),
    );
  }
}
