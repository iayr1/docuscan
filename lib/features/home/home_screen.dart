import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import '../../app/providers.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utils/formatters.dart';
import '../../data/models/models.dart';
import '../../data/repositories/document_repository.dart';
import '../../shared/widgets/common.dart';
import '../../shared/widgets/document_widgets.dart';
import '../document_editor/document_detail_screen.dart';
import '../documents/documents_screen.dart';
import '../ocr/ocr_screen.dart';
import '../scanner/id_card_scan_screen.dart';
import '../scanner/scanner_screen.dart';
import '../secure_vault/secure_vault_screen.dart';
import '../signatures/signatures_screen.dart';

class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  Future<void> _importFromGallery() async {
    final picker = ImagePicker();
    final picked = await picker.pickMultiImage();
    if (picked.isEmpty) return;

    final controller = TextEditingController(text: 'Imported Scan ${DateTime.now().day}/${DateTime.now().month}');
    final title = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Name Document'),
        content: TextField(controller: controller, autofocus: true),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, controller.text), child: const Text('Save')),
        ],
      ),
    );

    if (title != null && title.trim().isNotEmpty && mounted) {
      await runWithProgress(context, 'Importing photos...', (p) async {
        final drafts = picked.map((x) => PageDraft(x.path)).toList();
        final doc = await ref.read(documentRepositoryProvider).createDocument(
              title: title.trim(),
              pages: drafts,
            );
        if (mounted) {
          Navigator.push(context, MaterialPageRoute(builder: (_) => DocumentDetailScreen(documentId: doc.id)));
        }
      });
    }
  }

  Future<void> _importFiles() async {
    final result = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['pdf', 'docx', 'xlsx', 'pptx', 'txt', 'png', 'jpg'],
    );
    if (result.isEmpty || result.first.path == null) return;
    final path = result.first.path!;
    final ext = path.split('.').last.toLowerCase();

    if (!mounted) return;
    await runWithProgress(context, 'Importing $ext document...', (p) async {
      Document doc;
      if (ext == 'pdf') {
        doc = await ref.read(conversionRepositoryProvider).importPdf(path);
      } else if (ext == 'docx' || ext == 'xlsx' || ext == 'pptx') {
        final pdf = await ref.read(conversionRepositoryProvider).officeToPdf(path);
        doc = await ref.read(conversionRepositoryProvider).importPdf(pdf.path, title: path.split(RegExp(r'[\\/]')).last.replaceAll(RegExp(r'\.[^.]+$'), ''));
      } else if (ext == 'txt') {
        final pdf = await ref.read(conversionRepositoryProvider).txtToPdf(path);
        doc = await ref.read(conversionRepositoryProvider).importPdf(pdf.path, title: path.split(RegExp(r'[\\/]')).last.replaceAll(RegExp(r'\.[^.]+$'), ''));
      } else {
        doc = await ref.read(documentRepositoryProvider).createDocument(
              title: path.split(RegExp(r'[\\/]')).last.replaceAll(RegExp(r'\.[^.]+$'), ''),
              pages: [PageDraft(path)],
            );
      }

      if (mounted) {
        showSnack(context, 'Imported: "${doc.title}"');
        Navigator.push(context, MaterialPageRoute(builder: (_) => DocumentDetailScreen(documentId: doc.id)));
      }
    });
  }

  Future<void> _createFolder() async {
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Create Folder'),
        content: TextField(controller: controller, autofocus: true, decoration: const InputDecoration(labelText: 'Folder Name')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, controller.text), child: const Text('Create')),
        ],
      ),
    );

    if (name != null && name.trim().isNotEmpty) {
      await ref.read(folderRepositoryProvider).create(name.trim());
    }
  }

  @override
  Widget build(BuildContext context) {
    final statsAsync = ref.watch(statsProvider);
    final recentDocsAsync = ref.watch(recentDocumentsProvider);
    final foldersAsync = ref.watch(allFoldersProvider);

    return Scaffold(
      body: SafeArea(
        child: CustomScrollView(
          slivers: [
            // Top Header App Bar
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(20, 14, 20, 10),
              sliver: SliverToBoxAdapter(
                child: Row(
                  children: [
                    Container(
                      width: 44,
                      height: 44,
                      decoration: BoxDecoration(
                        color: AppColors.brand,
                        borderRadius: BorderRadius.circular(14),
                        boxShadow: [
                          BoxShadow(
                            color: AppColors.brand.withValues(alpha: 0.25),
                            blurRadius: 10,
                            offset: const Offset(0, 4),
                          ),
                        ],
                      ),
                      child: const Icon(Icons.document_scanner_outlined, color: Colors.white, size: 24),
                    ),
                    const SizedBox(width: 12),
                    RichText(
                      text: TextSpan(
                        text: 'docu',
                        style: TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.w900,
                          color: context.isDark ? Colors.white : AppColors.ink,
                          letterSpacing: -0.5,
                        ),
                        children: const [
                          TextSpan(
                            text: 'scan',
                            style: TextStyle(color: AppColors.brand, fontWeight: FontWeight.w900),
                          ),
                        ],
                      ),
                    ),
                    const Spacer(),
                    IconButton(
                      icon: const Icon(Icons.shield_outlined),
                      tooltip: 'Secure Vault',
                      onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const SecureVaultScreen())),
                    ),
                    IconButton(
                      icon: const Icon(Icons.search),
                      tooltip: 'Search Documents',
                      onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const DocumentsScreen())),
                    ),
                  ],
                ),
              ),
            ),

            // Hero Storage & Scan Counter Banner
            SliverPadding(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
              sliver: SliverToBoxAdapter(
                child: statsAsync.when(
                  data: (stats) => Container(
                    padding: const EdgeInsets.all(20),
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: context.isDark
                            ? [const Color(0xFF162520), const Color(0xFF0F1A16)]
                            : [const Color(0xFFEAF3EE), const Color(0xFFDFEDE5)],
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                      ),
                      borderRadius: BorderRadius.circular(AppRadius.xl),
                      border: Border.all(color: context.outline),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                              decoration: BoxDecoration(
                                color: AppColors.brand.withValues(alpha: 0.15),
                                borderRadius: BorderRadius.circular(AppRadius.sm),
                              ),
                              child: const Text(
                                '100% PRIVATE & OFFLINE',
                                style: TextStyle(fontSize: 10, letterSpacing: 1.2, fontWeight: FontWeight.w800, color: AppColors.brand),
                              ),
                            ),
                            const Spacer(),
                            const Icon(Icons.offline_bolt_outlined, size: 16, color: AppColors.brand),
                            const SizedBox(width: 4),
                            Text('On Device', style: TextStyle(color: AppColors.brand, fontSize: 11, fontWeight: FontWeight.bold)),
                          ],
                        ),
                        const SizedBox(height: 12),
                        Text(
                          'Everything in its right place.',
                          style: TextStyle(
                            fontSize: 22,
                            fontWeight: FontWeight.w900,
                            height: 1.15,
                            color: context.isDark ? Colors.white : AppColors.ink,
                          ),
                        ),
                        const SizedBox(height: 16),
                        Row(
                          children: [
                            _statChip(Icons.description_outlined, '${stats.documents}', 'Documents'),
                            const SizedBox(width: 12),
                            _statChip(Icons.auto_stories_outlined, '${stats.pages}', 'Pages'),
                            const SizedBox(width: 12),
                            _statChip(Icons.sd_storage_outlined, formatBytes(stats.bytes), 'Used'),
                          ],
                        ),
                      ],
                    ),
                  ),
                  loading: () => const SizedBox(height: 130),
                  error: (_, _) => const SizedBox.shrink(),
                ),
              ),
            ),

            // Quick Actions Section
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
              sliver: SliverToBoxAdapter(
                child: Text('Quick Actions', style: context.text.titleMedium?.copyWith(fontWeight: FontWeight.bold)),
              ),
            ),
            SliverPadding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              sliver: SliverToBoxAdapter(
                child: Row(
                  children: [
                    _quickActionTile(
                      icon: Icons.camera_alt_outlined,
                      title: 'Camera Scan',
                      subtitle: 'Auto page detect',
                      color: const Color(0xFF1E7054),
                      onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const ScannerScreen())),
                    ),
                    const SizedBox(width: 10),
                    _quickActionTile(
                      icon: Icons.photo_library_outlined,
                      title: 'Import Images',
                      subtitle: 'From gallery',
                      color: const Color(0xFFB4532A),
                      onTap: _importFromGallery,
                    ),
                    const SizedBox(width: 10),
                    _quickActionTile(
                      icon: Icons.file_open_outlined,
                      title: 'Import Files',
                      subtitle: 'PDF, Word, Excel',
                      color: const Color(0xFF3466C9),
                      onTap: _importFiles,
                    ),
                  ],
                ),
              ),
            ),

            // Secondary Quick Actions
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(20, 10, 20, 0),
              sliver: SliverToBoxAdapter(
                child: Row(
                  children: [
                    _quickActionTile(
                      icon: Icons.text_snippet_outlined,
                      title: 'On-Device OCR',
                      subtitle: 'Extract text',
                      color: const Color(0xFF7A4BC2),
                      onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const OcrScreen())),
                    ),
                    const SizedBox(width: 10),
                    _quickActionTile(
                      icon: Icons.badge_outlined,
                      title: 'ID Card Mode',
                      subtitle: 'Front & back on 1p',
                      color: const Color(0xFF2F8F9D),
                      onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const IdCardScanScreen())),
                    ),
                    const SizedBox(width: 10),
                    _quickActionTile(
                      icon: Icons.draw_outlined,
                      title: 'Sign & Stamp',
                      subtitle: 'Digital signature',
                      color: const Color(0xFFC03A6B),
                      onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const SignaturesScreen())),
                    ),
                  ],
                ),
              ),
            ),

            // Folders Section
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(20, 24, 20, 8),
              sliver: SliverToBoxAdapter(
                child: Row(
                  children: [
                    Text('Folders', style: context.text.titleMedium?.copyWith(fontWeight: FontWeight.bold)),
                    const Spacer(),
                    TextButton.icon(
                      icon: const Icon(Icons.add, size: 16),
                      label: const Text('New Folder'),
                      onPressed: _createFolder,
                    ),
                  ],
                ),
              ),
            ),
            SliverPadding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              sliver: SliverToBoxAdapter(
                child: foldersAsync.when(
                  data: (folders) => SizedBox(
                    height: 52,
                    child: ListView.separated(
                      scrollDirection: Axis.horizontal,
                      itemCount: folders.length + 1,
                      separatorBuilder: (_, _) => const SizedBox(width: 10),
                      itemBuilder: (ctx, i) {
                        if (i == 0) {
                          return ActionChip(
                            avatar: const Icon(Icons.folder_open, size: 18, color: AppColors.brand),
                            label: const Text('All Documents'),
                            onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const DocumentsScreen())),
                          );
                        }
                        final f = folders[i - 1];
                        return ActionChip(
                          avatar: const Icon(Icons.folder, size: 18, color: AppColors.brand),
                          label: Text('${f.name} (${f.documentCount})'),
                          onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => DocumentsScreen(initialFolderId: f.id))),
                        );
                      },
                    ),
                  ),
                  loading: () => const SizedBox(height: 50),
                  error: (_, _) => const SizedBox.shrink(),
                ),
              ),
            ),

            // Recent Documents Section
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(20, 24, 20, 10),
              sliver: SliverToBoxAdapter(
                child: Row(
                  children: [
                    Text('Recent Documents', style: context.text.titleMedium?.copyWith(fontWeight: FontWeight.bold)),
                    const Spacer(),
                    TextButton(
                      child: const Text('View All'),
                      onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const DocumentsScreen())),
                    ),
                  ],
                ),
              ),
            ),

            // Documents List Items
            recentDocsAsync.when(
              data: (docs) => docs.isEmpty
                  ? SliverPadding(
                      padding: const EdgeInsets.symmetric(horizontal: 20),
                      sliver: SliverToBoxAdapter(
                        child: EmptyState(
                          icon: Icons.document_scanner_outlined,
                          title: 'Your scans live here',
                          message: 'Capture a page or import photos. All documents remain securely on this phone.',
                          action: 'Scan First Document',
                          onAction: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const ScannerScreen())),
                        ),
                      ),
                    )
                  : SliverPadding(
                      padding: const EdgeInsets.symmetric(horizontal: 20),
                      sliver: SliverList.separated(
                        itemCount: docs.length,
                        separatorBuilder: (_, _) => const SizedBox(height: 10),
                        itemBuilder: (ctx, i) {
                          final doc = docs[i];
                          return Card(
                            child: ListTile(
                              leading: SizedBox(
                                width: 48,
                                height: 48,
                                child: ClipRRect(
                                  borderRadius: BorderRadius.circular(8),
                                  child: StoredImage(doc.thumbnailPath),
                                ),
                              ),
                              title: Text(doc.title, style: const TextStyle(fontWeight: FontWeight.bold), maxLines: 1, overflow: TextOverflow.ellipsis),
                              subtitle: Text('${doc.pageCount} pages · ${formatBytes(doc.fileSize)} · ${formatDate(doc.updatedAt)}'),
                              trailing: IconButton(
                                icon: Icon(doc.isFavorite ? Icons.star : Icons.star_border, color: doc.isFavorite ? Colors.amber : null),
                                onPressed: () => ref.read(documentRepositoryProvider).setFavorite(doc.id, !doc.isFavorite),
                              ),
                              onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => DocumentDetailScreen(documentId: doc.id))),
                            ),
                          );
                        },
                      ),
                    ),
              loading: () => const SliverToBoxAdapter(child: Center(child: CircularProgressIndicator())),
              error: (e, _) => SliverToBoxAdapter(child: Center(child: Text('Error: $e'))),
            ),

            // Extra space at bottom
            const SliverToBoxAdapter(child: SizedBox(height: 100)),
          ],
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const ScannerScreen())),
        icon: const Icon(Icons.document_scanner_outlined),
        label: const Text('Scan Document', style: TextStyle(fontWeight: FontWeight.bold)),
      ),
    );
  }

  Widget _statChip(IconData icon, String value, String label) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: context.colors.surface.withValues(alpha: 0.8),
          borderRadius: BorderRadius.circular(AppRadius.md),
          border: Border.all(color: context.outline),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, size: 14, color: AppColors.brand),
                const SizedBox(width: 4),
                Text(value, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
              ],
            ),
            const SizedBox(height: 2),
            Text(label, style: TextStyle(fontSize: 10, color: context.muted)),
          ],
        ),
      ),
    );
  }

  Widget _quickActionTile({
    required IconData icon,
    required String title,
    required String subtitle,
    required Color color,
    required VoidCallback onTap,
  }) {
    return Expanded(
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        child: Container(
          height: 105,
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: context.colors.surface,
            borderRadius: BorderRadius.circular(AppRadius.lg),
            border: Border.all(color: context.outline),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(icon, size: 20, color: color),
              ),
              const Spacer(),
              Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w800)),
              const SizedBox(height: 2),
              Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 9, color: context.muted)),
            ],
          ),
        ),
      ),
    );
  }
}
