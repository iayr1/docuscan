import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:printing/printing.dart';
import 'package:share_plus/share_plus.dart';

import '../../app/providers.dart';
import '../../core/image/image_types.dart';
import '../../core/services/pdf_service.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utils/formatters.dart';
import '../../data/models/models.dart';
import '../../data/repositories/document_repository.dart';
import '../../shared/widgets/common.dart';
import '../../shared/widgets/document_widgets.dart';
import '../image_editor/image_enhancer_screen.dart';
import '../ocr/ocr_screen.dart';
import '../pdf_tools/pdf_viewer_screen.dart';
import '../scanner/scanner_screen.dart';
import 'page_markup_screen.dart';

class DocumentDetailScreen extends ConsumerStatefulWidget {
  const DocumentDetailScreen({super.key, required this.documentId});
  final String documentId;

  @override
  ConsumerState<DocumentDetailScreen> createState() => _DocumentDetailScreenState();
}

class _DocumentDetailScreenState extends ConsumerState<DocumentDetailScreen> {
  Future<void> _renameDocument(Document doc) async {
    final controller = TextEditingController(text: doc.title);
    final newTitle = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Rename Document'),
        content: TextField(controller: controller, autofocus: true),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, controller.text), child: const Text('Rename')),
        ],
      ),
    );

    if (newTitle != null && newTitle.trim().isNotEmpty && newTitle.trim() != doc.title) {
      await ref.read(documentRepositoryProvider).rename(doc.id, newTitle.trim());
    }
  }

  Future<void> _addPageFromCamera() async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const ScannerScreen()),
    );
  }

  Future<void> _addPageFromGallery(Document doc) async {
    final picker = ImagePicker();
    final picked = await picker.pickMultiImage();
    if (picked.isEmpty) return;

    await runWithProgress(context, 'Adding pages...', (progress) async {
      final drafts = picked.map((x) => PageDraft(x.path)).toList();
      await ref.read(documentRepositoryProvider).addPages(doc.id, drafts);
    });
  }

  Future<void> _rotatePage(DocPage page) async {
    await ref.read(documentRepositoryProvider).rotatePage(page.id, 1);
  }

  Future<void> _deletePage(Document doc, DocPage page, int totalPages) async {
    if (totalPages <= 1) {
      showSnack(context, 'Cannot delete the only page in a document');
      return;
    }
    if (await confirm(context, 'Delete Page', 'Delete page ${page.index + 1}?', destructive: true)) {
      await ref.read(documentRepositoryProvider).deletePages(doc.id, [page.id]);
    }
  }

  Future<void> _duplicatePage(DocPage page) async {
    await runWithProgress(context, 'Duplicating page...', (p) async {
      await ref.read(documentRepositoryProvider).duplicatePage(page.id);
    });
  }

  Future<void> _editPageEnhancement(Document doc, DocPage page) async {
    final updatedEdit = await Navigator.of(context).push<PageEdit>(
      MaterialPageRoute(
        builder: (_) => ImageEnhancerScreen(
          originalImagePath: ref.read(fileStoreProvider).abs(page.originalPath),
          initialEdit: page.edit,
          title: 'Enhance Page ${page.index + 1}',
        ),
      ),
    );

    if (updatedEdit != null && mounted) {
      await runWithProgress(context, 'Applying enhancements...', (p) async {
        await ref.read(documentRepositoryProvider).updatePageEdit(page.id, updatedEdit);
      });
    }
  }

  Future<void> _openMarkup(Document doc, DocPage page) async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => PageMarkupScreen(document: doc, page: page),
      ),
    );
  }

  Future<void> _exportPdf(Document doc, {bool previewFirst = true}) async {
    final pdfBytes = await runWithProgress(context, 'Generating PDF...', (p) async {
      return await ref.read(exportRepositoryProvider).buildPdfBytes(doc.id, const PdfExportOptions());
    });

    if (pdfBytes != null && mounted) {
      final tempFile = File('${ref.read(fileStoreProvider).temp.path}/${doc.title.replaceAll(' ', '_')}.pdf');
      await tempFile.writeAsBytes(pdfBytes);

      if (previewFirst) {
        Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => PdfViewerScreen(pdfPath: tempFile.path, title: doc.title)),
        );
      } else {
        await SharePlus.instance.share(ShareParams(files: [XFile(tempFile.path)], title: doc.title));
      }
    }
  }

  Future<void> _printDocument(Document doc) async {
    await runWithProgress(context, 'Preparing print job...', (p) async {
      final bytes = await ref.read(exportRepositoryProvider).buildPdfBytes(doc.id, const PdfExportOptions());
      await Printing.layoutPdf(
        onLayout: (_) => bytes,
        name: doc.title,
      );
    });
  }

  Future<void> _runOcr(Document doc) async {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => OcrScreen(initialDocumentId: doc.id)),
    );
  }

  Future<void> _configureWatermark(Document doc) async {
    final controller = TextEditingController();
    final watermark = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Add Document Watermark'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(hintText: 'e.g. CONFIDENTIAL / DRAFT', border: OutlineInputBorder()),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, controller.text), child: const Text('Apply')),
        ],
      ),
    );

    if (watermark != null && watermark.trim().isNotEmpty && mounted) {
      await runWithProgress(context, 'Applying watermark to PDF...', (p) async {
        final bytes = await ref.read(exportRepositoryProvider).buildPdfBytes(
              doc.id,
              PdfExportOptions(watermark: watermark.trim()),
            );
        final temp = File('${ref.read(fileStoreProvider).temp.path}/${doc.title}_watermarked.pdf');
        await temp.writeAsBytes(bytes);
        if (mounted) {
          Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => PdfViewerScreen(pdfPath: temp.path, title: '${doc.title} (Watermarked)')),
          );
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final docAsync = ref.watch(documentProvider(widget.documentId));
    final pagesAsync = ref.watch(pagesProvider(widget.documentId));

    return docAsync.when(
      data: (doc) {
        if (doc == null) {
          return const Scaffold(body: Center(child: Text('Document not found')));
        }

        return Scaffold(
          appBar: AppBar(
            title: InkWell(
              onTap: () => _renameDocument(doc),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Flexible(
                    child: Text(
                      doc.title,
                      overflow: TextOverflow.ellipsis,
                      style: context.text.titleMedium?.copyWith(fontWeight: FontWeight.bold),
                    ),
                  ),
                  const SizedBox(width: 6),
                  const Icon(Icons.edit_outlined, size: 16),
                ],
              ),
            ),
            actions: [
              IconButton(
                icon: Icon(doc.isFavorite ? Icons.star : Icons.star_border, color: doc.isFavorite ? Colors.amber : null),
                onPressed: () => ref.read(documentRepositoryProvider).setFavorite(doc.id, !doc.isFavorite),
              ),
              IconButton(
                icon: const Icon(Icons.print_outlined),
                tooltip: 'Print',
                onPressed: () => _printDocument(doc),
              ),
              IconButton(
                icon: const Icon(Icons.picture_as_pdf_outlined),
                tooltip: 'View PDF',
                onPressed: () => _exportPdf(doc, previewFirst: true),
              ),
              IconButton(
                icon: const Icon(Icons.share_outlined),
                tooltip: 'Share',
                onPressed: () => _exportPdf(doc, previewFirst: false),
              ),
              PopupMenuButton<String>(
                onSelected: (v) {
                  switch (v) {
                    case 'ocr':
                      _runOcr(doc);
                      break;
                    case 'watermark':
                      _configureWatermark(doc);
                      break;
                    case 'gallery':
                      _addPageFromGallery(doc);
                      break;
                    case 'lock':
                      ref.read(documentRepositoryProvider).setFlags(doc.id, locked: !doc.isLocked);
                      break;
                    case 'vault':
                      ref.read(vaultRepositoryProvider).moveToVault(doc.id);
                      Navigator.of(context).pop();
                      showSnack(context, 'Moved to Secure Vault');
                      break;
                    case 'delete':
                      ref.read(documentRepositoryProvider).trashDocuments([doc.id]);
                      Navigator.of(context).pop();
                      showSnack(context, 'Document moved to Trash');
                      break;
                  }
                },
                itemBuilder: (_) => [
                  const PopupMenuItem(value: 'ocr', child: Text('Extract Text (OCR)')),
                  const PopupMenuItem(value: 'watermark', child: Text('Add Watermark')),
                  const PopupMenuItem(value: 'gallery', child: Text('Import Page from Gallery')),
                  PopupMenuItem(value: 'lock', child: Text(doc.isLocked ? 'Unlock Document' : 'Lock with PIN')),
                  const PopupMenuItem(value: 'vault', child: Text('Move to Secure Vault')),
                  const PopupMenuItem(value: 'delete', child: Text('Move to Trash', style: TextStyle(color: Colors.red))),
                ],
              ),
            ],
          ),
          body: pagesAsync.when(
            data: (pages) => Column(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                  color: context.colors.surfaceContainerLowest,
                  child: Row(
                    children: [
                      Text('${pages.length} Pages · ${formatBytes(doc.fileSize)}', style: context.text.bodySmall?.copyWith(color: context.muted)),
                      const Spacer(),
                      FilledButton.tonalIcon(
                        onPressed: () => _addPageFromGallery(doc),
                        icon: const Icon(Icons.add_photo_alternate_outlined, size: 16),
                        label: const Text('Add Pages'),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: GridView.builder(
                    padding: const EdgeInsets.all(16),
                    gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: 2,
                      childAspectRatio: 0.72,
                      crossAxisSpacing: 14,
                      mainAxisSpacing: 14,
                    ),
                    itemCount: pages.length,
                    itemBuilder: (ctx, i) {
                      final p = pages[i];
                      return Card(
                        clipBehavior: Clip.antiAlias,
                        child: InkWell(
                          onTap: () => _openMarkup(doc, p),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Expanded(
                                child: Stack(
                                  fit: StackFit.expand,
                                  children: [
                                    StoredImage(p.thumbnailPath ?? p.imagePath, fit: BoxFit.cover),
                                    Positioned(
                                      top: 8,
                                      left: 8,
                                      child: Container(
                                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                                        decoration: BoxDecoration(color: Colors.black87, borderRadius: BorderRadius.circular(AppRadius.sm)),
                                        child: Text('${i + 1}', style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold)),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              Container(
                                color: context.colors.surfaceContainerHighest.withValues(alpha: 0.5),
                                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                                child: Row(
                                  mainAxisAlignment: MainAxisAlignment.spaceAround,
                                  children: [
                                    IconButton(
                                      icon: const Icon(Icons.crop_rotate, size: 18),
                                      tooltip: 'Enhance & Crop',
                                      onPressed: () => _editPageEnhancement(doc, p),
                                    ),
                                    IconButton(
                                      icon: const Icon(Icons.draw_outlined, size: 18),
                                      tooltip: 'Markup & Sign',
                                      onPressed: () => _openMarkup(doc, p),
                                    ),
                                    IconButton(
                                      icon: const Icon(Icons.rotate_right, size: 18),
                                      tooltip: 'Rotate',
                                      onPressed: () => _rotatePage(p),
                                    ),
                                    PopupMenuButton<String>(
                                      iconSize: 18,
                                      onSelected: (action) {
                                        if (action == 'dup') _duplicatePage(p);
                                        if (action == 'del') _deletePage(doc, p, pages.length);
                                      },
                                      itemBuilder: (_) => [
                                        const PopupMenuItem(value: 'dup', child: Text('Duplicate')),
                                        const PopupMenuItem(value: 'del', child: Text('Delete Page', style: TextStyle(color: Colors.red))),
                                      ],
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (e, _) => Center(child: Text('Error: $e')),
          ),
          floatingActionButton: FloatingActionButton.extended(
            onPressed: _addPageFromCamera,
            icon: const Icon(Icons.camera_alt_outlined),
            label: const Text('Scan Page'),
          ),
        );
      },
      loading: () => const Scaffold(body: Center(child: CircularProgressIndicator())),
      error: (e, _) => Scaffold(body: Center(child: Text('Error: $e'))),
    );
  }
}
