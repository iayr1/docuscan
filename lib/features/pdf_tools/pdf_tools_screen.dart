import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:share_plus/share_plus.dart';

import '../../app/providers.dart';
import '../../core/services/pdf_service.dart';
import '../../core/theme/app_theme.dart';
import '../../data/repositories/document_repository.dart';
import '../../shared/widgets/common.dart';
import 'pdf_viewer_screen.dart';

class PdfToolsScreen extends ConsumerStatefulWidget {
  const PdfToolsScreen({super.key});

  @override
  ConsumerState<PdfToolsScreen> createState() => _PdfToolsScreenState();
}

class _PdfToolsScreenState extends ConsumerState<PdfToolsScreen> {
  // 1. Image to PDF
  Future<void> _imageToPdf() async {
    final picker = ImagePicker();
    final picked = await picker.pickMultiImage();
    if (picked.isEmpty) return;

    final titleController = TextEditingController(text: 'Converted Images');
    final title = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Create PDF from Images'),
        content: TextField(controller: titleController, decoration: const InputDecoration(labelText: 'PDF Title')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, titleController.text), child: const Text('Create')),
        ],
      ),
    );

    if (title == null || title.trim().isEmpty || !mounted) return;

    await runWithProgress(context, 'Converting images to PDF...', (progress) async {
      final drafts = picked.map((x) => PageDraft(x.path)).toList();
      final doc = await ref.read(documentRepositoryProvider).createDocument(
            title: title.trim(),
            pages: drafts,
          );
      final pdfBytes = await ref.read(exportRepositoryProvider).buildPdfBytes(doc.id, const PdfExportOptions());
      final out = await ref.read(conversionRepositoryProvider).saveOutput(pdfBytes, '${title.trim()}.pdf');
      if (mounted) {
        Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => PdfViewerScreen(pdfPath: out.path, title: title.trim())),
        );
      }
    });
  }

  // 2. Merge PDFs
  Future<void> _mergePdfs() async {
    final result = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['pdf'],
    );
    final validPaths = result.map((f) => f.path).whereType<String>().toList();
    if (validPaths.length < 2) {
      if (mounted) showSnack(context, 'Please select at least 2 PDF files to merge');
      return;
    }

    final mergedBytes = await runWithProgress(context, 'Merging PDFs...', (progress) async {
      final inputs = validPaths.map((p) => (p, null as String?)).toList();
      return await ref.read(pdfToolsProvider).merge(inputs);
    });

    if (mergedBytes != null && mounted) {
      final out = await ref.read(conversionRepositoryProvider).saveOutput(mergedBytes, 'Merged_${DateTime.now().millisecondsSinceEpoch}.pdf');
      showSnack(context, 'PDFs merged successfully');
      Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => PdfViewerScreen(pdfPath: out.path, title: 'Merged Document')),
      );
    }
  }

  // 3. Split PDF
  Future<void> _splitPdf() async {
    final result = await FilePicker.pickFiles(type: FileType.custom, allowedExtensions: ['pdf']);
    if (result.isEmpty || result.first.path == null) return;
    final path = result.first.path!;

    final pageCount = await ref.read(pdfToolsProvider).pageCount(path);
    if (!mounted) return;

    final controller = TextEditingController(text: '1-$pageCount');
    final range = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Split PDF ($pageCount pages)'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Enter page range or comma-separated pages (e.g. 1-3, 5):'),
            const SizedBox(height: 10),
            TextField(controller: controller, autofocus: true),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, controller.text), child: const Text('Split')),
        ],
      ),
    );

    if (range == null || range.trim().isEmpty || !mounted) return;

    await runWithProgress(context, 'Splitting PDF...', (p) async {
      final pagesToExtract = <int>[];
      for (final part in range.split(',')) {
        final trimmed = part.trim();
        if (trimmed.contains('-')) {
          final bounds = trimmed.split('-');
          final start = int.tryParse(bounds[0].trim()) ?? 1;
          final end = int.tryParse(bounds[1].trim()) ?? pageCount;
          for (var i = start; i <= end && i <= pageCount; i++) {
            if (i >= 1) pagesToExtract.add(i - 1);
          }
        } else {
          final single = int.tryParse(trimmed);
          if (single != null && single >= 1 && single <= pageCount) {
            pagesToExtract.add(single - 1);
          }
        }
      }

      if (pagesToExtract.isEmpty) throw Exception('No valid pages in range');

      final splitBytes = await ref.read(pdfToolsProvider).selectPages(path, pagesToExtract);
      final out = await ref.read(conversionRepositoryProvider).saveOutput(splitBytes, 'Split_Pages.pdf');
      if (mounted) {
        Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => PdfViewerScreen(pdfPath: out.path, title: 'Split PDF')),
        );
      }
    });
  }

  // 4. Compress PDF
  Future<void> _compressPdf() async {
    final result = await FilePicker.pickFiles(type: FileType.custom, allowedExtensions: ['pdf']);
    if (result.isEmpty || result.first.path == null) return;
    final path = result.first.path!;

    final originalSize = await File(path).length();
    if (!mounted) return;

    final compressedBytes = await runWithProgress(context, 'Compressing PDF...', (p) async {
      return await ref.read(pdfToolsProvider).rasterCompress(path, dpi: 120, jpegQuality: 65);
    });

    if (compressedBytes != null && mounted) {
      final out = await ref.read(conversionRepositoryProvider).saveOutput(compressedBytes, 'Compressed_${DateTime.now().millisecondsSinceEpoch}.pdf');
      final newSize = compressedBytes.length;
      final savedPercent = (((originalSize - newSize) / originalSize) * 100).clamp(0, 99).toInt();

      showSnack(context, 'Compressed: $savedPercent% size reduction');
      Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => PdfViewerScreen(pdfPath: out.path, title: 'Compressed PDF')),
      );
    }
  }

  // 5. Password Protect PDF
  Future<void> _passwordProtectPdf() async {
    final result = await FilePicker.pickFiles(type: FileType.custom, allowedExtensions: ['pdf']);
    if (result.isEmpty || result.first.path == null) return;
    final path = result.first.path!;

    final controller = TextEditingController();
    final password = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Password Protect PDF'),
        content: TextField(
          controller: controller,
          obscureText: true,
          decoration: const InputDecoration(labelText: 'Enter Password', border: OutlineInputBorder()),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, controller.text), child: const Text('Protect')),
        ],
      ),
    );

    if (password == null || password.isEmpty || !mounted) return;

    await runWithProgress(context, 'Encrypting PDF...', (p) async {
      final srcBytes = await File(path).readAsBytes();
      final protectedBytes = await ref.read(pdfToolsProvider).protect(srcBytes, password);
      final out = await ref.read(conversionRepositoryProvider).saveOutput(protectedBytes, 'Protected_${DateTime.now().millisecondsSinceEpoch}.pdf');
      if (mounted) {
        showSnack(context, 'PDF protected with password');
        await SharePlus.instance.share(ShareParams(files: [XFile(out.path)], title: 'Protected PDF'));
      }
    });
  }

  // 6. Unlock Protected PDF
  Future<void> _unlockPdf() async {
    final result = await FilePicker.pickFiles(type: FileType.custom, allowedExtensions: ['pdf']);
    if (result.isEmpty || result.first.path == null) return;
    final path = result.first.path!;

    final controller = TextEditingController();
    final password = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Remove PDF Password'),
        content: TextField(
          controller: controller,
          obscureText: true,
          decoration: const InputDecoration(labelText: 'Enter Current Password', border: OutlineInputBorder()),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, controller.text), child: const Text('Unlock')),
        ],
      ),
    );

    if (password == null || password.isEmpty || !mounted) return;

    await runWithProgress(context, 'Decrypting PDF...', (p) async {
      final unlockedBytes = await ref.read(pdfToolsProvider).unlock(path, password);
      final out = await ref.read(conversionRepositoryProvider).saveOutput(unlockedBytes, 'Unlocked_${DateTime.now().millisecondsSinceEpoch}.pdf');
      if (mounted) {
        showSnack(context, 'Password removed from PDF');
        Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => PdfViewerScreen(pdfPath: out.path, title: 'Unlocked PDF')),
        );
      }
    });
  }

  // 7. Office File to PDF (DOCX, XLSX, PPTX, TXT)
  Future<void> _convertOfficeToPdf() async {
    final result = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['docx', 'xlsx', 'pptx', 'txt'],
    );
    if (result.isEmpty || result.first.path == null) return;
    final path = result.first.path!;
    final ext = path.split('.').last.toLowerCase();

    await runWithProgress(context, 'Converting $ext to PDF...', (p) async {
      File out;
      if (ext == 'txt') {
        out = await ref.read(conversionRepositoryProvider).txtToPdf(path);
      } else {
        out = await ref.read(conversionRepositoryProvider).officeToPdf(path);
      }

      if (mounted) {
        showSnack(context, 'Converted $ext to PDF successfully');
        Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => PdfViewerScreen(pdfPath: out.path, title: out.path.split(Platform.pathSeparator).last)),
        );
      }
    });
  }

  // 8. PDF to DOCX / TXT
  Future<void> _convertPdfToOffice(String targetFormat) async {
    final result = await FilePicker.pickFiles(type: FileType.custom, allowedExtensions: ['pdf']);
    if (result.isEmpty || result.first.path == null) return;
    final path = result.first.path!;

    await runWithProgress(context, 'Extracting content to $targetFormat...', (p) async {
      File out;
      if (targetFormat == 'DOCX') {
        out = await ref.read(conversionRepositoryProvider).pdfToDocx(path);
      } else if (targetFormat == 'XLSX') {
        out = await ref.read(conversionRepositoryProvider).pdfToXlsx(path);
      } else {
        out = await ref.read(conversionRepositoryProvider).pdfToTxt(path);
      }

      if (mounted) {
        showSnack(context, 'Exported to $targetFormat: ${out.path.split(Platform.pathSeparator).last}');
        await SharePlus.instance.share(ShareParams(files: [XFile(out.path)], title: 'Exported $targetFormat'));
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('PDF Toolkit'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _buildCategoryHeader('Core PDF Tools'),
          _buildToolTile(
            icon: Icons.add_photo_alternate_outlined,
            color: const Color(0xFF1E7054),
            title: 'Images to PDF',
            subtitle: 'Combine photos & gallery images into a clean PDF',
            onTap: _imageToPdf,
          ),
          _buildToolTile(
            icon: Icons.call_merge_outlined,
            color: const Color(0xFF3466C9),
            title: 'Merge PDFs',
            subtitle: 'Combine multiple PDF documents into one',
            onTap: _mergePdfs,
          ),
          _buildToolTile(
            icon: Icons.call_split_outlined,
            color: const Color(0xFFB4532A),
            title: 'Split PDF',
            subtitle: 'Extract specific pages or page ranges',
            onTap: _splitPdf,
          ),
          _buildToolTile(
            icon: Icons.compress_outlined,
            color: const Color(0xFF7A4BC2),
            title: 'Compress PDF',
            subtitle: 'Reduce PDF file size for easy offline sharing',
            onTap: _compressPdf,
          ),

          const SizedBox(height: 16),
          _buildCategoryHeader('Security & Encryption'),
          _buildToolTile(
            icon: Icons.lock_outline,
            color: const Color(0xFFC03A6B),
            title: 'Protect with Password',
            subtitle: 'Encrypt PDF with custom AES password',
            onTap: _passwordProtectPdf,
          ),
          _buildToolTile(
            icon: Icons.lock_open_outlined,
            color: const Color(0xFF2F8F9D),
            title: 'Unlock Protected PDF',
            subtitle: 'Remove password protection from PDF',
            onTap: _unlockPdf,
          ),

          const SizedBox(height: 16),
          _buildCategoryHeader('Local Conversions (100% Offline)'),
          _buildToolTile(
            icon: Icons.description_outlined,
            color: const Color(0xFF1E7054),
            title: 'DOCX / XLSX / PPTX to PDF',
            subtitle: 'Convert Microsoft Office documents locally',
            onTap: _convertOfficeToPdf,
          ),
          _buildToolTile(
            icon: Icons.text_snippet_outlined,
            color: const Color(0xFF3466C9),
            title: 'PDF to Word (.docx)',
            subtitle: 'Convert PDF content into editable Word format',
            onTap: () => _convertPdfToOffice('DOCX'),
          ),
          _buildToolTile(
            icon: Icons.table_chart_outlined,
            color: const Color(0xFF8A7A1F),
            title: 'PDF to Excel (.xlsx)',
            subtitle: 'Extract tables and lines into spreadsheet format',
            onTap: () => _convertPdfToOffice('XLSX'),
          ),
          _buildToolTile(
            icon: Icons.text_fields_outlined,
            color: const Color(0xFF4F5B66),
            title: 'PDF to Plain Text (.txt)',
            subtitle: 'Extract all textual content into raw text',
            onTap: () => _convertPdfToOffice('TXT'),
          ),
        ],
      ),
    );
  }

  Widget _buildCategoryHeader(String title) {
    return Padding(
      padding: const EdgeInsets.only(left: 4, bottom: 8, top: 4),
      child: Text(
        title,
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.bold,
          color: context.colors.primary,
          letterSpacing: 0.8,
        ),
      ),
    );
  }

  Widget _buildToolTile({
    required IconData icon,
    required Color color,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
  }) {
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: ListTile(
        leading: Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.14),
            borderRadius: BorderRadius.circular(AppRadius.md),
          ),
          child: Icon(icon, color: color, size: 24),
        ),
        title: Text(title, style: context.text.titleSmall?.copyWith(fontWeight: FontWeight.bold)),
        subtitle: Text(subtitle, style: context.text.bodySmall?.copyWith(color: context.muted)),
        trailing: const Icon(Icons.chevron_right, size: 20),
        onTap: onTap,
      ),
    );
  }
}
