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
import '../shell/app_shell.dart';

class OcrScreen extends ConsumerStatefulWidget {
  const OcrScreen({super.key, this.initialDocumentId, this.isRootTab = false});
  final String? initialDocumentId;

  /// True when shown as a bottom-navigation tab (shows the drawer button).
  final bool isRootTab;

  @override
  ConsumerState<OcrScreen> createState() => _OcrScreenState();
}

class _OcrScreenState extends ConsumerState<OcrScreen> {
  String? _imagePath;
  String? _documentId;
  late OcrLanguage _selectedLanguage = ref.read(settingsProvider).ocrLanguage;
  bool _busy = false;
  int _requestId = 0;
  OcrOutput? _lastResult;
  late final TextEditingController _textController;

  /// Pages of the document being recognised (empty for a loose image).
  List<DocPage> _docPages = const [];
  int _pageIndex = 0;

  static const _languageLabels = {
    OcrLanguage.latin: ('EN', 'English / Latin'),
    OcrLanguage.devanagari: ('हि', 'Hindi / Marathi'),
    OcrLanguage.chinese: ('中', 'Chinese'),
    OcrLanguage.japanese: ('日', 'Japanese'),
    OcrLanguage.korean: ('한', 'Korean'),
  };

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
        _docPages = pages;
        await _selectPage(0);
      }
    } catch (e) {
      if (mounted) {
        showSnack(context, 'Could not open this document: $e', error: true);
      }
    }
  }

  Future<void> _selectPage(int index) async {
    if (index < 0 || index >= _docPages.length) return;
    setState(() {
      _pageIndex = index;
      _imagePath = ref.read(fileStoreProvider).abs(_docPages[index].imagePath);
      _textController.clear();
      _lastResult = null;
    });
    await _runOcr();
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
      _docPages = const [];
      _pageIndex = 0;
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
      if (_documentId != null && _pageIndex < _docPages.length) {
        final page = _docPages[_pageIndex];
        {
          await ref
              .read(assetRepositoryProvider)
              .saveOcr(
                pageId: page.id,
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
    final lang = _languageLabels[_selectedLanguage]!;
    return Scaffold(
      appBar: AppBar(
        leading: widget.isRootTab ? const DrawerMenuButton() : null,
        title: const Text('Text recognition'),
        actions: [
          if (Platform.isAndroid && _lastResult != null)
            IconButton(
              onPressed: _busy ? null : _improveOcrText,
              tooltip: 'Improve text with on-device AI',
              icon: const Icon(Icons.auto_awesome_outlined),
            ),
          PopupMenuButton<OcrLanguage>(
            tooltip: 'Recognition language',
            initialValue: _selectedLanguage,
            onSelected: (v) {
              setState(() => _selectedLanguage = v);
              if (_imagePath != null) _runOcr();
            },
            itemBuilder: (_) => [
              for (final e in _languageLabels.entries)
                CheckedPopupMenuItem(value: e.key, checked: e.key == _selectedLanguage, child: Text(e.value.$2)),
            ],
            child: Container(
              margin: const EdgeInsets.only(right: 12, left: 4),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: context.colors.primary.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(AppRadius.pill),
              ),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(Icons.translate_rounded, size: 16, color: context.colors.primary),
                const SizedBox(width: 6),
                Text(lang.$1, style: TextStyle(fontWeight: FontWeight.w800, color: context.colors.primary)),
                Icon(Icons.arrow_drop_down_rounded, color: context.colors.primary),
              ]),
            ),
          ),
        ],
      ),
      body: _imagePath == null ? _buildEmptyPicker() : _buildOcrView(),
    );
  }

  Widget _buildEmptyPicker() {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 96,
              height: 96,
              decoration: const BoxDecoration(gradient: AppColors.brandGradient, shape: BoxShape.circle),
              child: const Icon(Icons.text_snippet_rounded, size: 46, color: Colors.white),
            ),
            const SizedBox(height: 24),
            Text('Extract text from any page', textAlign: TextAlign.center, style: context.text.headlineSmall),
            const SizedBox(height: 10),
            Text(
              'Recognise printed text in documents, receipts and cards — fully offline, in ${_languageLabels.length} scripts.',
              textAlign: TextAlign.center,
              style: context.text.bodyMedium?.copyWith(color: context.muted, height: 1.4),
            ),
            const SizedBox(height: 28),
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    onPressed: () => _pickImage(ImageSource.camera),
                    icon: const Icon(Icons.photo_camera_outlined),
                    label: const Text('Camera'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () => _pickImage(ImageSource.gallery),
                    icon: const Icon(Icons.photo_library_outlined),
                    label: const Text('Gallery'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildOcrView() {
    final words = _textController.text.split(RegExp(r'\s+')).where((s) => s.isNotEmpty).length;
    final langName = _languageLabels[_selectedLanguage]!.$2;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 8, 4),
          child: Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(AppRadius.sm),
                child: SizedBox(width: 48, height: 60, child: Image.file(File(_imagePath!), fit: BoxFit.cover, cacheWidth: 160)),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(_busy ? 'Recognising text…' : '$words word${words == 1 ? '' : 's'} found', style: context.text.titleSmall),
                    const SizedBox(height: 2),
                    Text(
                      _docPages.length > 1 ? 'Page ${_pageIndex + 1} of ${_docPages.length} · $langName' : langName,
                      style: context.text.bodySmall?.copyWith(color: context.muted),
                    ),
                  ],
                ),
              ),
              if (_busy)
                const Padding(padding: EdgeInsets.all(12), child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)))
              else
                IconButton(icon: const Icon(Icons.refresh_rounded), tooltip: 'Run again', onPressed: _runOcr),
              IconButton(
                icon: const Icon(Icons.add_photo_alternate_outlined),
                tooltip: 'Pick another image',
                onPressed: () => _pickImage(ImageSource.gallery),
              ),
            ],
          ),
        ),
        if (_docPages.length > 1)
          SizedBox(
            height: 44,
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.fromLTRB(16, 4, 8, 4),
              itemCount: _docPages.length,
              itemBuilder: (ctx, i) => PillChip(
                label: 'Page ${i + 1}',
                selected: i == _pageIndex,
                onTap: _busy ? null : () => _selectPage(i),
              ),
            ),
          ),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
            child: TextField(
              controller: _textController,
              maxLines: null,
              expands: true,
              textAlignVertical: TextAlignVertical.top,
              style: context.text.bodyLarge?.copyWith(height: 1.45),
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                hintText: _busy ? 'Reading the page…' : 'Recognised text appears here. You can edit it.',
              ),
            ),
          ),
        ),
        Container(
          padding: const EdgeInsets.fromLTRB(12, 10, 16, 12),
          decoration: BoxDecoration(
            color: context.colors.surface,
            border: Border(top: BorderSide(color: context.outline)),
          ),
          child: Row(
            children: [
              IconButton(icon: const Icon(Icons.copy_rounded), tooltip: 'Copy', onPressed: _copyText),
              IconButton(icon: const Icon(Icons.ios_share_rounded), tooltip: 'Share', onPressed: _shareText),
              IconButton(icon: const Icon(Icons.save_alt_rounded), tooltip: 'Save as .txt', onPressed: _exportToTxt),
              const Spacer(),
              FilledButton.icon(
                onPressed: _busy ? null : _createSearchablePdf,
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
