import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:share_plus/share_plus.dart';

import '../../app/providers.dart';
import '../../core/services/pdf_service.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utils/formatters.dart';
import '../../data/repositories/document_repository.dart';
import '../../shared/widgets/common.dart';
import '../shell/app_shell.dart';
import 'pdf_viewer_screen.dart';

class PdfToolsScreen extends ConsumerStatefulWidget {
  const PdfToolsScreen({super.key});

  @override
  ConsumerState<PdfToolsScreen> createState() => _PdfToolsScreenState();
}

class _PdfToolsScreenState extends ConsumerState<PdfToolsScreen> {
  static String _stamp() => DateTime.now().millisecondsSinceEpoch.toString();
  static String _fileName(String path) => path.split(RegExp(r'[\\/]')).last;

  Future<String?> _pickPdf() async {
    final result = await FilePicker.pickFiles(type: FileType.custom, allowedExtensions: ['pdf']);
    if (result.isEmpty) return null;
    return result.first.path;
  }

  void _openPdf(File out, String title) =>
      Navigator.of(context).push(MaterialPageRoute(builder: (_) => PdfViewerScreen(pdfPath: out.path, title: title)));

  Future<void> _shareFile(File out, String title) => SharePlus.instance.share(ShareParams(files: [XFile(out.path)], title: title));

  Future<String?> _askPassword(String title, String label, String confirmLabel) =>
      promptText(context, title, label: label, obscure: true, confirmLabel: confirmLabel);

  // 1. Images to PDF
  Future<void> _imageToPdf() async {
    final picked = await ImagePicker().pickMultiImage();
    if (picked.isEmpty || !mounted) return;

    final title = await promptText(context, 'Create PDF', initial: 'Images ${formatDate(DateTime.now())}', label: 'PDF name', confirmLabel: 'Create');
    if (title == null || title.trim().isEmpty || !mounted) return;
    final name = title.trim();

    final out = await runWithProgress(context, 'Building PDF…', (progress) async {
      final doc = await ref.read(documentRepositoryProvider).createDocument(
            title: name,
            pages: picked.map((x) => PageDraft(x.path)).toList(),
            onProgress: (done, total) => progress('Processing image $done of $total…', done / total),
          );
      progress('Writing PDF…');
      final pdfBytes = await ref.read(exportRepositoryProvider).buildPdfBytes(doc.id, defaultExportOptions(ref.read(settingsProvider), title: name));
      return ref.read(conversionRepositoryProvider).saveOutput(pdfBytes, '$name.pdf');
    });
    if (out != null && mounted) {
      showSnack(context, 'PDF created and saved to your library');
      _openPdf(out, name);
    }
  }

  // 2. Merge PDFs
  Future<void> _mergePdfs() async {
    final result = await FilePicker.pickFiles(type: FileType.custom, allowedExtensions: ['pdf']);
    final validPaths = result.map((f) => f.path).whereType<String>().toList();
    if (!mounted || validPaths.isEmpty) return;
    if (validPaths.length < 2) {
      showSnack(context, 'Select at least 2 PDF files to merge');
      return;
    }

    final out = await runWithProgress(context, 'Merging ${validPaths.length} PDFs…', (progress) async {
      final bytes = await ref.read(pdfToolsProvider).merge([for (final p in validPaths) (p, null)]);
      return ref.read(conversionRepositoryProvider).saveOutput(bytes, 'Merged_${_stamp()}.pdf');
    });
    if (out != null && mounted) {
      showSnack(context, 'PDFs merged');
      _openPdf(out, 'Merged PDF');
    }
  }

  // 3. Split PDF
  Future<void> _splitPdf() async {
    final path = await _pickPdf();
    if (path == null || !mounted) return;

    int pageCount;
    try {
      pageCount = await ref.read(pdfToolsProvider).pageCount(path);
    } catch (e) {
      if (mounted) showSnack(context, 'Could not read this PDF. If it is password-protected, unlock it first.', error: true);
      return;
    }
    if (!mounted) return;

    final range = await promptText(
      context,
      'Split PDF',
      initial: '1-$pageCount',
      label: 'Pages to keep',
      helper: 'This file has $pageCount pages. Use ranges and commas, e.g. 1-3, 5, 8-10',
      confirmLabel: 'Split',
    );
    if (range == null || range.trim().isEmpty || !mounted) return;

    final pages = <int>[];
    for (final part in range.split(',')) {
      final t = part.trim();
      if (t.contains('-')) {
        final b = t.split('-');
        final start = int.tryParse(b[0].trim()) ?? 1;
        final end = int.tryParse(b.length > 1 ? b[1].trim() : '') ?? pageCount;
        for (var i = start.clamp(1, pageCount); i <= end.clamp(1, pageCount); i++) {
          if (!pages.contains(i - 1)) pages.add(i - 1);
        }
      } else {
        final single = int.tryParse(t);
        if (single != null && single >= 1 && single <= pageCount && !pages.contains(single - 1)) pages.add(single - 1);
      }
    }
    if (pages.isEmpty) {
      showSnack(context, 'No valid pages in “$range”', error: true);
      return;
    }

    final out = await runWithProgress(context, 'Extracting ${pages.length} page${pages.length == 1 ? '' : 's'}…', (p) async {
      final bytes = await ref.read(pdfToolsProvider).selectPages(path, pages);
      return ref.read(conversionRepositoryProvider).saveOutput(bytes, 'Split_${_stamp()}.pdf');
    });
    if (out != null && mounted) _openPdf(out, 'Split PDF');
  }

  // 4. Compress PDF
  Future<void> _compressPdf() async {
    final path = await _pickPdf();
    if (path == null || !mounted) return;
    final originalSize = await File(path).length();
    if (!mounted) return;

    final out = await runWithProgress(context, 'Compressing PDF…', (p) async {
      final bytes = await ref.read(pdfToolsProvider).rasterCompress(path, dpi: 120, jpegQuality: 65);
      return ref.read(conversionRepositoryProvider).saveOutput(bytes, 'Compressed_${_stamp()}.pdf');
    });
    if (out == null || !mounted) return;
    final newSize = await out.length();
    if (!mounted) return;
    final saved = originalSize == 0 ? 0 : (((originalSize - newSize) / originalSize) * 100).clamp(0, 99).round();
    showSnack(context, saved > 0 ? '${formatBytes(originalSize)} → ${formatBytes(newSize)} ($saved% smaller)' : 'This PDF is already well compressed');
    _openPdf(out, 'Compressed PDF');
  }

  // 5. Password-protect PDF
  Future<void> _passwordProtectPdf() async {
    final path = await _pickPdf();
    if (path == null || !mounted) return;
    final password = await _askPassword('Protect PDF', 'New password', 'Protect');
    if (password == null || password.isEmpty || !mounted) return;

    final out = await runWithProgress(context, 'Encrypting PDF…', (p) async {
      final protectedBytes = await ref.read(pdfToolsProvider).protect(await File(path).readAsBytes(), password);
      return ref.read(conversionRepositoryProvider).saveOutput(protectedBytes, 'Protected_${_fileName(path)}');
    });
    if (out != null && mounted) {
      showSnack(context, 'Password added');
      await _shareFile(out, 'Protected PDF');
    }
  }

  // 6. Remove a PDF password
  Future<void> _unlockPdf() async {
    final path = await _pickPdf();
    if (path == null || !mounted) return;
    final password = await _askPassword('Unlock PDF', 'Current password', 'Unlock');
    if (password == null || password.isEmpty || !mounted) return;

    final out = await runWithProgress(context, 'Removing password…', (p) async {
      final bytes = await ref.read(pdfToolsProvider).unlock(path, password);
      return ref.read(conversionRepositoryProvider).saveOutput(bytes, 'Unlocked_${_fileName(path)}');
    });
    if (out != null && mounted) {
      showSnack(context, 'Password removed');
      _openPdf(out, 'Unlocked PDF');
    }
  }

  // 7. Office / text file to PDF
  Future<void> _convertOfficeToPdf() async {
    final result = await FilePicker.pickFiles(type: FileType.custom, allowedExtensions: ['docx', 'xlsx', 'pptx', 'txt']);
    if (result.isEmpty || result.first.path == null || !mounted) return;
    final path = result.first.path!;
    final ext = path.split('.').last.toLowerCase();

    final out = await runWithProgress(context, 'Converting ${ext.toUpperCase()} to PDF…', (p) {
      final conv = ref.read(conversionRepositoryProvider);
      return ext == 'txt' ? conv.txtToPdf(path) : conv.officeToPdf(path);
    });
    if (out != null && mounted) {
      showSnack(context, 'Converted to PDF');
      _openPdf(out, _fileName(out.path));
    }
  }

  // 8. PDF to DOCX / XLSX / TXT
  Future<void> _convertPdfToOffice(String targetFormat) async {
    final path = await _pickPdf();
    if (path == null || !mounted) return;

    final out = await runWithProgress(context, 'Converting to $targetFormat…', (p) {
      final conv = ref.read(conversionRepositoryProvider);
      return switch (targetFormat) {
        'DOCX' => conv.pdfToDocx(path),
        'XLSX' => conv.pdfToXlsx(path),
        _ => conv.pdfToTxt(path),
      };
    });
    if (out != null && mounted) {
      showSnack(context, 'Saved ${_fileName(out.path)}');
      await _shareFile(out, 'Exported $targetFormat');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: CustomScrollView(
        slivers: [
          const SliverAppBar(
            pinned: true,
            leading: DrawerMenuButton(),
            title: Text('PDF Toolkit'),
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 0),
              child: Text(
                'Everything runs on your device — files never leave your phone.',
                style: context.text.bodyMedium?.copyWith(color: context.muted),
              ),
            ),
          ),
          ..._section('Create & organise', [
            _Tool(Icons.add_photo_alternate_outlined, AppColors.tints[0], 'Images to PDF', 'Turn photos into a PDF', _imageToPdf),
            _Tool(Icons.merge_type_rounded, AppColors.tints[1], 'Merge PDFs', 'Combine several files', _mergePdfs),
            _Tool(Icons.call_split_rounded, AppColors.tints[2], 'Split PDF', 'Extract page ranges', _splitPdf),
            _Tool(Icons.compress_rounded, AppColors.tints[3], 'Compress', 'Shrink file size', _compressPdf),
          ]),
          ..._section('Security', [
            _Tool(Icons.lock_outline_rounded, AppColors.tints[4], 'Protect', 'Add a password', _passwordProtectPdf),
            _Tool(Icons.lock_open_rounded, AppColors.tints[5], 'Unlock', 'Remove a password', _unlockPdf),
          ]),
          ..._section('Convert', [
            _Tool(Icons.description_outlined, AppColors.tints[0], 'Office to PDF', 'DOCX, XLSX, PPTX, TXT', _convertOfficeToPdf),
            _Tool(Icons.article_outlined, AppColors.tints[1], 'PDF to Word', 'Editable .docx', () => _convertPdfToOffice('DOCX')),
            _Tool(Icons.table_chart_outlined, AppColors.tints[6], 'PDF to Excel', 'Tables to .xlsx', () => _convertPdfToOffice('XLSX')),
            _Tool(Icons.text_fields_rounded, AppColors.tints[7], 'PDF to Text', 'Plain .txt', () => _convertPdfToOffice('TXT')),
          ]),
          const SliverToBoxAdapter(child: SizedBox(height: 32)),
        ],
      ),
    );
  }

  List<Widget> _section(String title, List<_Tool> tools) => [
        SliverToBoxAdapter(child: SectionHeader(title, padding: const EdgeInsets.fromLTRB(20, 20, 20, 10))),
        SliverPadding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          sliver: SliverGrid(
            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: 220,
              mainAxisExtent: 128,
              crossAxisSpacing: 12,
              mainAxisSpacing: 12,
            ),
            delegate: SliverChildBuilderDelegate((ctx, i) => _ToolCard(tools[i]), childCount: tools.length),
          ),
        ),
      ];
}

class _Tool {
  const _Tool(this.icon, this.color, this.title, this.subtitle, this.onTap);
  final IconData icon;
  final Color color;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
}

class _ToolCard extends StatelessWidget {
  const _ToolCard(this.tool);
  final _Tool tool;

  @override
  Widget build(BuildContext context) => TapCard(
        onTap: tool.onTap,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            IconBadge(tool.icon, color: tool.color, size: 42),
            const Spacer(),
            Text(tool.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: context.text.titleSmall),
            const SizedBox(height: 2),
            Text(tool.subtitle, maxLines: 1, overflow: TextOverflow.ellipsis, style: context.text.labelSmall?.copyWith(color: context.muted)),
          ],
        ),
      );
}
