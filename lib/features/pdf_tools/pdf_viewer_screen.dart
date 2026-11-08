import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:printing/printing.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/theme/app_theme.dart';
import '../../shared/widgets/common.dart';

class PdfViewerScreen extends ConsumerStatefulWidget {
  const PdfViewerScreen({
    super.key,
    required this.pdfPath,
    this.title = 'PDF Document',
  });

  final String pdfPath;
  final String title;

  @override
  ConsumerState<PdfViewerScreen> createState() => _PdfViewerScreenState();
}

class _PdfViewerScreenState extends ConsumerState<PdfViewerScreen> {
  final PdfViewerController _controller = PdfViewerController();
  int _pageNumber = 1;
  int _pageCount = 0;

  @override
  void dispose() {
    super.dispose();
  }

  Future<void> _share() async {
    await SharePlus.instance.share(ShareParams(files: [XFile(widget.pdfPath)], title: widget.title));
  }

  Future<void> _print() async {
    try {
      final bytes = await File(widget.pdfPath).readAsBytes();
      await Printing.layoutPdf(
        onLayout: (_) => bytes,
        name: widget.title,
      );
    } catch (e) {
      if (mounted) showSnack(context, 'Printing failed: $e', error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.title, style: context.text.titleMedium?.copyWith(fontWeight: FontWeight.bold)),
            if (_pageCount > 0)
              Text(
                'Page $_pageNumber of $_pageCount',
                style: context.text.bodySmall?.copyWith(color: context.muted),
              ),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.print_outlined),
            tooltip: 'Print PDF',
            onPressed: _print,
          ),
          IconButton(
            icon: const Icon(Icons.share_outlined),
            tooltip: 'Share PDF',
            onPressed: _share,
          ),
        ],
      ),
      body: PdfViewer.file(
        widget.pdfPath,
        controller: _controller,
        params: PdfViewerParams(
          onPageChanged: (page) {
            if (mounted && page != null) {
              setState(() => _pageNumber = page);
            }
          },
          onDocumentChanged: (document) {
            if (mounted && document != null) {
              setState(() => _pageCount = document.pages.length);
            }
          },
          loadingBannerBuilder: (context, bytesDownloaded, totalBytes) => const Center(
            child: CircularProgressIndicator(color: AppColors.brand),
          ),
          errorBannerBuilder: (context, error, stackTrace, documentRef) => Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.error_outline, size: 48, color: Colors.red),
                  const SizedBox(height: 12),
                  Text('Could not load PDF: $error', textAlign: TextAlign.center),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
