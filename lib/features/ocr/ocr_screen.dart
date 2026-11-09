import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:share_plus/share_plus.dart';

import '../../app/providers.dart';
import '../../core/services/pdf_service.dart';
import '../../core/services/ocr_service.dart';
import '../../core/storage/settings_store.dart';
import '../../core/theme/app_theme.dart';
import '../../data/models/models.dart';
import '../../shared/widgets/common.dart';
import '../pdf_tools/pdf_viewer_screen.dart';

class OcrScreen extends ConsumerStatefulWidget {
  const OcrScreen({super.key, this.initialDocumentId});
  final String? initialDocumentId;

  @override
  ConsumerState<OcrScreen> createState() => _OcrScreenState();
}

class _OcrScreenState extends ConsumerState<OcrScreen> {
  String? _imagePath;
  String? _documentId;
  OcrLanguage _selectedLanguage = OcrLanguage.latin;
  bool _busy = false;
  int _requestId = 0;
  OcrOutput? _lastResult;
  late final TextEditingController _textController;

  @override
  void initState() {
    super.initState();
    _textController = TextEditingController();
    _documentId = widget.initialDocumentId;
    if (_documentId != null) {
      _loadDocumentFirstPage();
    }
  }

  @override
  void dispose() {
    _textController.dispose();
    super.dispose();
  }

  Future<void> _loadDocumentFirstPage() async {
    try {
      final pages = await ref
          .read(documentRepositoryProvider)
          .getPages(_documentId!);
      if (pages.isNotEmpty && mounted) {
        setState(
          () => _imagePath = ref
              .read(fileStoreProvider)
              .abs(pages.first.imagePath),
        );
        await _runOcr();
      }
    } catch (e) {
      if (mounted) {
        showSnack(context, 'Could not open this document: $e', error: true);
      }
    }
  }

  Future<void> _pickImage(ImageSource source) async {
    final picker = ImagePicker();
    final picked = await picker.pickImage(
      source: source,
      // Keep OCR inputs detailed enough for small print while avoiding
      // multi-megapixel camera images that increase ML Kit latency and memory.
      maxWidth: 2600,
      maxHeight: 2600,
      imageQuality: 92,
    );
    if (picked == null || !mounted) return;

    setState(() {
      _imagePath = picked.path;
      _documentId = null;
      _textController.clear();
      _lastResult = null;
    });

    _runOcr();
  }

  Future<void> _runOcr() async {
    if (_imagePath == null) return;
    final requestId = ++_requestId;
    final path = _imagePath!;
    final language = _selectedLanguage;
    setState(() => _busy = true);

    try {
      final ocr = ref.read(ocrServiceProvider);
      if (ocr == null) {
        throw Exception('OCR service unavailable on this device');
      }

      final dims = await ref.read(imageServiceProvider).dimensions(path);
      final result = await ocr.recognizeFile(
        path,
        language: language,
        width: dims.$1,
        height: dims.$2,
        shouldProcess: () => mounted && requestId == _requestId,
      );

      if (!mounted || requestId != _requestId) return;
      _lastResult = result;
      _textController.text = result.text;
      if (_documentId != null) {
        final pages = await ref
            .read(documentRepositoryProvider)
            .getPages(_documentId!);
        if (pages.isNotEmpty) {
          await ref
              .read(assetRepositoryProvider)
              .saveOcr(
                pageId: pages.first.id,
                documentId: _documentId!,
                script: language.name,
                text: result.text,
                lines: result.lines,
              );
        }
      }

      if (result.isEmpty && mounted) {
        showSnack(
          context,
          'No text detected in this image. Try another language or clearer image.',
        );
      }
    } catch (e) {
      if (mounted && requestId == _requestId) {
        showSnack(context, 'OCR failed: $e', error: true);
      }
    } finally {
      if (mounted && requestId == _requestId) setState(() => _busy = false);
    }
  }

  Future<void> _copyText() async {
    final text = _textController.text;
    if (text.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: text));
    if (mounted) showSnack(context, 'Extracted text copied to clipboard');
  }

  Future<void> _shareText() async {
    final text = _textController.text;
    if (text.isEmpty) return;
    await SharePlus.instance.share(
      ShareParams(text: text, title: 'Extracted OCR Text'),
    );
  }

  Future<void> _improveOcrText() async {
    final originalResult = _lastResult;
    final originalText = _textController.text;
    if (originalResult == null || originalText.trim().isEmpty) return;

    final proceed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Improve OCR text offline?'),
        content: const Text(
          'This uses Qwen2.5 0.5B (Apache-2.0) on your device. First use downloads about 491 MB over the internet; later uses work offline. Your recognized text stays on this device.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Continue'),
          ),
        ],
      ),
    );
    if (proceed != true || !mounted) return;

    final correction = await runWithProgress(
      context,
      'Loading the offline text helper...',
      (update) => ref
          .read(ocrCorrectionServiceProvider)
          .improve(
            originalText,
            onDownloadProgress: (fraction) {
              if (fraction == null) {
                update('Preparing the offline language model...');
              } else if (fraction < 1) {
                update(
                  'Downloading model: ${(fraction * 100).round()}%',
                  fraction,
                );
              } else {
                update('Correcting OCR text on this device...', 1);
              }
            },
          ),
    );
    if (correction == null || !mounted) return;
    if (correction.message != null) {
      showSnack(context, correction.message!, error: !correction.changed);
      return;
    }
    if (!correction.changed) {
      showSnack(context, 'No clear OCR corrections were needed.');
      return;
    }

    final correctedLines = correction.text.split('\n');
    if (originalResult.lines.isNotEmpty &&
        correctedLines.length != originalResult.lines.length) {
      showSnack(
        context,
        'Text layout changed, so the original OCR was kept to protect PDF search positions.',
      );
      return;
    }
    final updatedResult = OcrOutput(correction.text, [
      for (var i = 0; i < originalResult.lines.length; i++)
        OcrBlock(
          correctedLines[i],
          originalResult.lines[i].left,
          originalResult.lines[i].top,
          originalResult.lines[i].width,
          originalResult.lines[i].height,
        ),
    ], originalResult.script);
    setState(() {
      _lastResult = updatedResult;
      _textController.text = correction.text;
    });
    showSnack(
      context,
      'OCR text improved on this device.',
      action: SnackBarAction(
        label: 'UNDO',
        onPressed: () {
          if (!mounted) return;
          setState(() {
            _lastResult = originalResult;
            _textController.text = originalText;
          });
        },
      ),
    );
  }

  Future<void> _exportToTxt() async {
    final text = _textController.text;
    if (text.isEmpty) return;

    final bytes = Uint8List.fromList(utf8.encode(text));
    final out = await ref
        .read(conversionRepositoryProvider)
        .saveOutput(
          bytes,
          'Extracted_Text_${DateTime.now().millisecondsSinceEpoch}.txt',
        );

    if (mounted) {
      showSnack(
        context,
        'Saved to TXT: ${out.path.split(Platform.pathSeparator).last}',
      );
      await SharePlus.instance.share(
        ShareParams(files: [XFile(out.path)], title: 'Extracted Text'),
      );
    }
  }

  Future<void> _createSearchablePdf() async {
    if (_imagePath == null) return;
    final result = _lastResult;
    if (result == null) {
      showSnack(
        context,
        'Run OCR before creating a searchable PDF.',
        error: true,
      );
      return;
    }

    final imagePath = _imagePath!;
    final textWasEdited = _textController.text != result.text;
    final title = 'Searchable Scan ${DateTime.now().millisecondsSinceEpoch}';

    await runWithProgress(context, 'Preparing page...', (update) async {
      final dimensions = await ref
          .read(imageServiceProvider)
          .dimensions(imagePath);
      update('Building searchable PDF...');
      final pdfBytes = await ref.read(pdfServiceProvider).buildFromPages([
        PdfPageInput(
          imagePath: imagePath,
          width: dimensions.$1,
          height: dimensions.$2,
          // OCR boxes only match the recognized text. If the user changed
          // the text, preserve the page image and avoid an incorrect layer.
          ocrLines: textWasEdited ? const <OcrBlock>[] : result.lines,
        ),
      ], PdfExportOptions(searchable: true, title: title));
      update('Saving PDF...');
      final out = await ref
          .read(conversionRepositoryProvider)
          .saveOutput(pdfBytes, '$title.pdf');
      if (mounted) {
        showSnack(
          context,
          result.isEmpty
              ? 'PDF created. No text was detected in the image.'
              : 'Searchable PDF created',
        );
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => PdfViewerScreen(pdfPath: out.path, title: title),
          ),
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('On-Device OCR'),
        actions: [
          if (Platform.isAndroid)
            IconButton(
              onPressed: _busy ? null : _improveOcrText,
              tooltip: 'Improve OCR text locally',
              icon: const Icon(Icons.auto_awesome),
            ),
          DropdownButton<OcrLanguage>(
            value: _selectedLanguage,
            underline: const SizedBox(),
            items: const [
              DropdownMenuItem(
                value: OcrLanguage.latin,
                child: Text('English / Latin'),
              ),
              DropdownMenuItem(
                value: OcrLanguage.devanagari,
                child: Text('Hindi / Marathi'),
              ),
              DropdownMenuItem(
                value: OcrLanguage.chinese,
                child: Text('Chinese'),
              ),
              DropdownMenuItem(
                value: OcrLanguage.japanese,
                child: Text('Japanese'),
              ),
              DropdownMenuItem(
                value: OcrLanguage.korean,
                child: Text('Korean'),
              ),
            ],
            onChanged: (v) {
              if (v != null) {
                setState(() => _selectedLanguage = v);
                if (_imagePath != null) _runOcr();
              }
            },
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: _imagePath == null ? _buildEmptyPicker() : _buildOcrView(),
    );
  }

  Widget _buildEmptyPicker() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 80,
              height: 80,
              decoration: BoxDecoration(
                color: AppColors.brand.withValues(alpha: 0.12),
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.document_scanner_outlined,
                size: 40,
                color: AppColors.brand,
              ),
            ),
            const SizedBox(height: 20),
            Text(
              'Offline Text Recognition',
              style: context.text.titleLarge?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Extract editable text from documents, receipts, business cards and certificates with zero internet connection.',
              textAlign: TextAlign.center,
              style: context.text.bodyMedium?.copyWith(color: context.muted),
            ),
            const SizedBox(height: 28),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                FilledButton.icon(
                  onPressed: () => _pickImage(ImageSource.camera),
                  icon: const Icon(Icons.camera_alt_outlined),
                  label: const Text('Camera'),
                ),
                const SizedBox(width: 12),
                FilledButton.tonalIcon(
                  onPressed: () => _pickImage(ImageSource.gallery),
                  icon: const Icon(Icons.photo_library_outlined),
                  label: const Text('Gallery'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildOcrView() {
    return Column(
      children: [
        // Top Split: Image thumbnail & status
        Container(
          color: context.colors.surfaceContainerLowest,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: SizedBox(
                  width: 44,
                  height: 44,
                  child: Image.file(File(_imagePath!), fit: BoxFit.cover),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _busy
                          ? 'Recognizing text...'
                          : '${_textController.text.split(RegExp(r'\s+')).where((s) => s.isNotEmpty).length} Words extracted',
                      style: context.text.titleSmall?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    Text(
                      'Model: ${_selectedLanguage.name.toUpperCase()} (Offline ML-Kit)',
                      style: context.text.bodySmall?.copyWith(
                        color: context.muted,
                      ),
                    ),
                  ],
                ),
              ),
              if (_busy)
                const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: AppColors.brand,
                  ),
                )
              else
                IconButton(
                  icon: const Icon(Icons.refresh),
                  tooltip: 'Rerun OCR',
                  onPressed: _runOcr,
                ),
              IconButton(
                icon: const Icon(Icons.image_outlined),
                tooltip: 'Pick another image',
                onPressed: () => _pickImage(ImageSource.gallery),
              ),
            ],
          ),
        ),

        // Middle: Editable Extracted Text
        Expanded(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: TextField(
              controller: _textController,
              maxLines: null,
              expands: true,
              textAlignVertical: TextAlignVertical.top,
              decoration: const InputDecoration(
                hintText: 'Recognized text will appear here...',
                border: OutlineInputBorder(),
              ),
            ),
          ),
        ),

        // Bottom Action Bar
        Container(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 20),
          decoration: BoxDecoration(
            color: context.colors.surface,
            border: Border(top: BorderSide(color: context.outline)),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              IconButton(
                icon: const Icon(Icons.copy_outlined),
                tooltip: 'Copy Text',
                onPressed: _copyText,
              ),
              IconButton(
                icon: const Icon(Icons.share_outlined),
                tooltip: 'Share Text',
                onPressed: _shareText,
              ),
              IconButton(
                icon: const Icon(Icons.file_download_outlined),
                tooltip: 'Export to .TXT',
                onPressed: _exportToTxt,
              ),
              FilledButton.icon(
                onPressed: _createSearchablePdf,
                icon: const Icon(Icons.picture_as_pdf_outlined, size: 18),
                label: const Text('Searchable PDF'),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
