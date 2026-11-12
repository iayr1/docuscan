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
import '../../shared/widgets/security_widgets.dart';
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
  bool _markedOpened = false;

  PdfExportOptions _exportOptions(Document doc, {String? watermark}) {
    final s = ref.read(settingsProvider);
    return PdfExportOptions(pageSize: s.pageSize, quality: s.pdfQuality, title: doc.title, watermark: watermark);
  }

  Future<void> _renameDocument(Document doc) async {
    final newTitle = await promptText(context, 'Rename document', initial: doc.title, label: 'Document name', confirmLabel: 'Rename');
    if (newTitle != null && newTitle.trim().isNotEmpty && newTitle.trim() != doc.title) {
      await ref.read(documentRepositoryProvider).rename(doc.id, newTitle.trim());
    }
  }

  Future<void> _addPageFromCamera(Document doc) async {
    final added = await Navigator.of(context).push<Object>(
      MaterialPageRoute(builder: (_) => ScannerScreen(targetDocumentId: doc.id, initialMode: doc.scanMode == ScanMode.idCard || doc.scanMode == ScanMode.qrCode ? ScanMode.document : doc.scanMode)),
    );
    if (added != null && mounted) showSnack(context, 'Pages added');
  }

  Future<void> _addPageFromGallery(Document doc) async {
    final picked = await ImagePicker().pickMultiImage();
    if (picked.isEmpty || !mounted) return;
    await runWithProgress(context, 'Adding ${picked.length} page${picked.length == 1 ? '' : 's'}…', (progress) async {
      await ref.read(documentRepositoryProvider).addPages(
            doc.id,
            picked.map((x) => PageDraft(x.path)).toList(),
            onProgress: (done, total) => progress('Processing page $done of $total…', done / total),
          );
    });
  }

  Future<void> _deletePage(Document doc, DocPage page, int totalPages) async {
    if (totalPages <= 1) {
      showSnack(context, 'A document needs at least one page');
      return;
    }
    if (await confirm(context, 'Delete page', 'Delete page ${page.index + 1}?', confirmLabel: 'Delete', destructive: true)) {
      await ref.read(documentRepositoryProvider).deletePages(doc.id, [page.id]);
    }
  }

  Future<void> _editPageEnhancement(DocPage page) async {
    final updatedEdit = await Navigator.of(context).push<PageEdit>(
      MaterialPageRoute(
        builder: (_) => ImageEnhancerScreen(
          originalImagePath: ref.read(fileStoreProvider).abs(page.originalPath),
          initialEdit: page.edit,
          title: 'Edit page ${page.index + 1}',
        ),
      ),
    );
    if (updatedEdit != null && mounted) {
      await runWithProgress(context, 'Applying changes…', (p) => ref.read(documentRepositoryProvider).updatePageEdit(page.id, updatedEdit));
    }
  }

  Future<void> _openMarkup(Document doc, DocPage page) =>
      Navigator.of(context).push(MaterialPageRoute(builder: (_) => PageMarkupScreen(document: doc, page: page)));

  void _openViewer(Document doc, List<DocPage> pages, int index) => Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => _PageViewer(
            pages: pages,
            initialIndex: index,
            onMarkup: doc.inVault ? null : (p) => _openMarkup(doc, p),
          ),
        ),
      );

  void _openOcr(Document doc) =>
      Navigator.of(context).push(MaterialPageRoute(builder: (_) => OcrScreen(initialDocumentId: doc.id)));

  Future<void> _exportPdf(Document doc, {bool previewFirst = true}) async {
    final pdfFile = await runWithProgress(context, 'Generating PDF…', (p) => ref.read(exportRepositoryProvider).exportPdfFile(doc.id, _exportOptions(doc)));
    if (pdfFile == null || !mounted) return;
    if (previewFirst) {
      Navigator.of(context).push(MaterialPageRoute(builder: (_) => PdfViewerScreen(pdfPath: pdfFile.path, title: doc.title)));
    } else {
      await SharePlus.instance.share(ShareParams(files: [XFile(pdfFile.path)], title: doc.title));
    }
  }

  Future<void> _printDocument(Document doc) async {
    final bytes = await runWithProgress(context, 'Preparing print job…', (p) => ref.read(exportRepositoryProvider).buildPdfBytes(doc.id, _exportOptions(doc)));
    if (bytes == null) return;
    try {
      await Printing.layoutPdf(onLayout: (_) => bytes, name: doc.title);
    } catch (e) {
      if (mounted) showSnack(context, 'Printing failed: $e', error: true);
    }
  }

  Future<void> _configureWatermark(Document doc) async {
    final watermark = await promptText(context, 'Add watermark', label: 'Watermark text', hint: 'e.g. CONFIDENTIAL', confirmLabel: 'Apply');
    if (watermark == null || watermark.trim().isEmpty || !mounted) return;
    final file = await runWithProgress(context, 'Applying watermark…', (p) async {
      final bytes = await ref.read(exportRepositoryProvider).buildPdfBytes(doc.id, _exportOptions(doc, watermark: watermark.trim()));
      final temp = await ref.read(fileStoreProvider).newTempFile('pdf');
      return temp.writeAsBytes(bytes, flush: true);
    });
    if (file != null && mounted) {
      Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => PdfViewerScreen(pdfPath: file.path, title: '${doc.title} (watermarked)')),
      );
    }
  }

  Future<void> _toggleLock(Document doc) async {
    final repo = ref.read(documentRepositoryProvider);
    if (doc.isLocked) {
      if (!await authenticateUser(context, ref, reason: 'Remove lock')) return;
      await repo.setFlags(doc.id, locked: false);
      if (mounted) showSnack(context, 'Lock removed');
    } else {
      if (!await ensurePin(context, ref)) return;
      await repo.setFlags(doc.id, locked: true);
      // Keep it open for the rest of this session.
      ref.read(unlockedDocsProvider.notifier).add(doc.id);
      if (mounted) showSnack(context, 'Document locked — your PIN is needed to open it');
    }
  }

  Future<void> _moveToVault(Document doc) async {
    if (!await ensurePin(context, ref) || !mounted) return;
    if (!await confirm(context, 'Move to Secure Vault', 'Encrypt “${doc.title}” and move it to the vault? It will be hidden from your library and search.',
        confirmLabel: 'Encrypt & move')) {
      return;
    }
    if (!mounted) return;
    final ok = await runWithProgress(context, 'Encrypting…', (p) async {
      await ref.read(vaultRepositoryProvider).moveToVault(doc.id);
      return true;
    });
    if (ok == true && mounted) {
      showSnack(context, 'Moved to Secure Vault');
      Navigator.of(context).pop();
    }
  }

  Future<void> _trash(Document doc) async {
    if (!await confirm(context, 'Move to trash', 'Move “${doc.title}” to the recycle bin? You can restore it for 30 days.',
        confirmLabel: 'Move', destructive: true)) {
      return;
    }
    await ref.read(documentRepositoryProvider).trashDocuments([doc.id]);
    if (!mounted) return;
    showSnack(context, 'Moved to recycle bin');
    Navigator.of(context).pop();
  }

  Future<void> _unlockDoc(Document doc) async {
    if (await authenticateUser(context, ref, reason: 'Open “${doc.title}”')) {
      ref.read(unlockedDocsProvider.notifier).add(doc.id);
    }
  }

  @override
  Widget build(BuildContext context) {
    final docAsync = ref.watch(documentProvider(widget.documentId));

    return docAsync.when(
      skipLoadingOnReload: true,
      data: (doc) {
        if (doc == null) {
          return Scaffold(
            appBar: AppBar(),
            body: const EmptyState(icon: Icons.search_off_rounded, title: 'Document not found', message: 'It may have been deleted.'),
          );
        }

        final unlocked = ref.watch(unlockedDocsProvider).contains(doc.id);
        if (doc.isLocked && !unlocked) return _buildLockedGate(doc);

        if (!_markedOpened) {
          _markedOpened = true;
          ref.read(documentRepositoryProvider).markOpened(doc.id);
        }
        return _buildDocument(doc);
      },
      loading: () => const Scaffold(body: LoadingView()),
      error: (e, _) => Scaffold(appBar: AppBar(), body: ErrorView(e)),
    );
  }

  Widget _buildLockedGate(Document doc) => Scaffold(
        appBar: AppBar(),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              const IconBadge(Icons.lock_rounded, size: 80),
              const SizedBox(height: 20),
              Text(doc.title, textAlign: TextAlign.center, style: context.text.headlineSmall),
              const SizedBox(height: 8),
              Text('This document is locked.', style: context.text.bodyMedium?.copyWith(color: context.muted)),
              const SizedBox(height: 24),
              FilledButton.icon(onPressed: () => _unlockDoc(doc), icon: const Icon(Icons.lock_open_rounded), label: const Text('Unlock')),
            ]),
          ),
        ),
      );

  Widget _buildDocument(Document doc) {
    final pagesAsync = ref.watch(pagesProvider(widget.documentId));
    final editable = !doc.inVault;

    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: InkWell(
          borderRadius: BorderRadius.circular(AppRadius.sm),
          onTap: editable ? () => _renameDocument(doc) : null,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Flexible(child: Text(doc.title, overflow: TextOverflow.ellipsis, style: context.text.titleMedium)),
              if (editable) ...[const SizedBox(width: 6), Icon(Icons.edit_outlined, size: 15, color: context.muted)],
            ]),
          ),
        ),
        actions: [
          if (editable)
            IconButton(
              icon: Icon(doc.isFavorite ? Icons.star_rounded : Icons.star_outline_rounded, color: doc.isFavorite ? const Color(0xFFFFC107) : null),
              tooltip: doc.isFavorite ? 'Remove from favorites' : 'Add to favorites',
              onPressed: () => ref.read(documentRepositoryProvider).setFavorite(doc.id, !doc.isFavorite),
            ),
          IconButton(icon: const Icon(Icons.ios_share_rounded), tooltip: 'Share PDF', onPressed: () => _exportPdf(doc, previewFirst: false)),
          PopupMenuButton<String>(
            onSelected: (v) {
              switch (v) {
                case 'pdf':
                  _exportPdf(doc);
                case 'print':
                  _printDocument(doc);
                case 'ocr':
                  _openOcr(doc);
                case 'watermark':
                  _configureWatermark(doc);
                case 'lock':
                  _toggleLock(doc);
                case 'vault':
                  _moveToVault(doc);
                case 'delete':
                  _trash(doc);
              }
            },
            itemBuilder: (_) => [
              _menuItem('pdf', Icons.picture_as_pdf_outlined, 'View as PDF'),
              _menuItem('print', Icons.print_outlined, 'Print'),
              if (editable) _menuItem('ocr', Icons.text_snippet_outlined, 'Extract text (OCR)'),
              _menuItem('watermark', Icons.branding_watermark_outlined, 'Export with watermark'),
              if (editable) ...[
                const PopupMenuDivider(),
                _menuItem('lock', doc.isLocked ? Icons.lock_open_rounded : Icons.lock_outline_rounded, doc.isLocked ? 'Remove lock' : 'Lock with PIN'),
                _menuItem('vault', Icons.shield_outlined, 'Move to Secure Vault'),
                const PopupMenuDivider(),
                _menuItem('delete', Icons.delete_outline_rounded, 'Move to trash', danger: true),
              ],
            ],
          ),
        ],
      ),
      body: pagesAsync.when(
        skipLoadingOnReload: true,
        data: (pages) => CustomScrollView(
          slivers: [
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
                child: Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
                  TagPill('${pages.length} PAGE${pages.length == 1 ? '' : 'S'}', icon: Icons.layers_outlined),
                  TagPill(formatBytes(doc.fileSize).toUpperCase(), color: AppColors.info, icon: Icons.sd_storage_outlined),
                  TagPill(formatDate(doc.updatedAt).toUpperCase(), color: AppColors.tints[7], icon: Icons.schedule_rounded),
                  if (doc.inVault) const TagPill('ENCRYPTED', color: AppColors.warning, icon: Icons.shield_rounded),
                  if (doc.isLocked) const TagPill('LOCKED', color: AppColors.danger, icon: Icons.lock_rounded),
                ]),
              ),
            ),
            if (editable)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                  child: Row(children: [
                    _ActionChip(icon: Icons.picture_as_pdf_outlined, label: 'PDF', onTap: () => _exportPdf(doc)),
                    _ActionChip(icon: Icons.text_snippet_outlined, label: 'OCR', onTap: () => _openOcr(doc)),
                    _ActionChip(icon: Icons.add_photo_alternate_outlined, label: 'Import', onTap: () => _addPageFromGallery(doc)),
                    _ActionChip(icon: Icons.print_outlined, label: 'Print', onTap: () => _printDocument(doc)),
                  ]),
                ),
              ),
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 100),
              sliver: SliverGrid(
                gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                  maxCrossAxisExtent: 220,
                  childAspectRatio: 0.66,
                  crossAxisSpacing: 14,
                  mainAxisSpacing: 14,
                ),
                delegate: SliverChildBuilderDelegate(
                  (ctx, i) => _PageCard(
                    page: pages[i],
                    number: i + 1,
                    editable: editable,
                    onTap: () => _openViewer(doc, pages, i),
                    onEdit: () => _editPageEnhancement(pages[i]),
                    onMarkup: () => _openMarkup(doc, pages[i]),
                    onRotate: () => ref.read(documentRepositoryProvider).rotatePage(pages[i].id, 1),
                    onDuplicate: () => runWithProgress(context, 'Duplicating page…', (p) => ref.read(documentRepositoryProvider).duplicatePage(pages[i].id)),
                    onDelete: () => _deletePage(doc, pages[i], pages.length),
                  ),
                  childCount: pages.length,
                ),
              ),
            ),
          ],
        ),
        loading: () => const LoadingView(),
        error: (e, _) => ErrorView(e),
      ),
      floatingActionButton: editable
          ? FloatingActionButton.extended(
              heroTag: 'detail-scan',
              onPressed: () => _addPageFromCamera(doc),
              icon: const Icon(Icons.add_a_photo_outlined),
              label: const Text('Add page'),
            )
          : null,
    );
  }

  PopupMenuItem<String> _menuItem(String value, IconData icon, String label, {bool danger = false}) {
    final color = danger ? context.colors.error : null;
    return PopupMenuItem(
      value: value,
      child: Row(children: [
        Icon(icon, size: 20, color: color ?? context.muted),
        const SizedBox(width: 12),
        Text(label, style: TextStyle(color: color)),
      ]),
    );
  }
}

class _ActionChip extends StatelessWidget {
  const _ActionChip({required this.icon, required this.label, required this.onTap});
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Expanded(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: TapCard(
            onTap: onTap,
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Column(children: [
              Icon(icon, size: 22, color: context.colors.primary),
              const SizedBox(height: 6),
              Text(label, style: context.text.labelMedium),
            ]),
          ),
        ),
      );
}

class _PageCard extends StatelessWidget {
  const _PageCard({
    required this.page,
    required this.number,
    required this.editable,
    required this.onTap,
    required this.onEdit,
    required this.onMarkup,
    required this.onRotate,
    required this.onDuplicate,
    required this.onDelete,
  });

  final DocPage page;
  final int number;
  final bool editable;
  final VoidCallback onTap;
  final VoidCallback onEdit;
  final VoidCallback onMarkup;
  final VoidCallback onRotate;
  final VoidCallback onDuplicate;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) => TapCard(
        onTap: onTap,
        padding: EdgeInsets.zero,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(AppRadius.sm),
                  child: Stack(fit: StackFit.expand, children: [
                    ColoredBox(color: context.colors.surfaceContainerHighest.withValues(alpha: 0.4)),
                    StoredImage(page.thumbnailPath ?? page.imagePath, fit: BoxFit.contain, cacheWidth: 420),
                    Positioned(
                      top: 6,
                      left: 6,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                        decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.65), borderRadius: BorderRadius.circular(AppRadius.pill)),
                        child: Text('$number', style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w800)),
                      ),
                    ),
                  ]),
                ),
              ),
            ),
            if (editable)
              SizedBox(
                height: 44,
                child: Row(
                  children: [
                    _iconBtn(Icons.crop_rotate_rounded, 'Crop & enhance', onEdit),
                    _iconBtn(Icons.draw_outlined, 'Markup & sign', onMarkup),
                    _iconBtn(Icons.rotate_right_rounded, 'Rotate', onRotate),
                    Expanded(
                      child: PopupMenuButton<String>(
                        iconSize: 19,
                        tooltip: 'More',
                        padding: EdgeInsets.zero,
                        onSelected: (a) => a == 'dup' ? onDuplicate() : onDelete(),
                        itemBuilder: (_) => [
                          const PopupMenuItem(value: 'dup', child: Text('Duplicate')),
                          PopupMenuItem(value: 'del', child: Text('Delete page', style: TextStyle(color: context.colors.error))),
                        ],
                      ),
                    ),
                  ],
                ),
              )
            else
              const SizedBox(height: 8),
          ],
        ),
      );

  Widget _iconBtn(IconData icon, String tooltip, VoidCallback onTap) => Expanded(
        child: IconButton(
          icon: Icon(icon, size: 19),
          tooltip: tooltip,
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(minWidth: 32, minHeight: 40),
          onPressed: onTap,
        ),
      );
}

/// Full-screen, swipeable, zoomable page preview.
class _PageViewer extends StatefulWidget {
  const _PageViewer({required this.pages, required this.initialIndex, this.onMarkup});
  final List<DocPage> pages;
  final int initialIndex;
  final void Function(DocPage page)? onMarkup;

  @override
  State<_PageViewer> createState() => _PageViewerState();
}

class _PageViewerState extends State<_PageViewer> {
  late final PageController _controller = PageController(initialPage: widget.initialIndex);
  late int _index = widget.initialIndex;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(
          backgroundColor: Colors.black,
          foregroundColor: Colors.white,
          title: Text('Page ${_index + 1} of ${widget.pages.length}', style: const TextStyle(color: Colors.white, fontSize: 16)),
          actions: [
            if (widget.onMarkup != null)
              IconButton(
                icon: const Icon(Icons.draw_outlined),
                tooltip: 'Markup & sign',
                onPressed: () {
                  final page = widget.pages[_index];
                  Navigator.pop(context);
                  widget.onMarkup!(page);
                },
              ),
          ],
        ),
        body: PageView.builder(
          controller: _controller,
          itemCount: widget.pages.length,
          onPageChanged: (i) => setState(() => _index = i),
          itemBuilder: (ctx, i) => InteractiveViewer(
            maxScale: 5,
            child: Center(child: StoredImage(widget.pages[i].imagePath, fit: BoxFit.contain)),
          ),
        ),
      );
}
