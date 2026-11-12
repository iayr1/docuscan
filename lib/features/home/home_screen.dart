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
import '../scanner/id_card_scan_screen.dart';
import '../scanner/scanner_screen.dart';
import '../secure_vault/secure_vault_screen.dart';
import '../shell/app_shell.dart';
import '../signatures/signatures_screen.dart';

class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  static String _baseName(String path) =>
      path.split(RegExp(r'[\\/]')).last.replaceAll(RegExp(r'\.[^.]+$'), '');

  void _openDocument(String id) =>
      Navigator.push(context, MaterialPageRoute(builder: (_) => DocumentDetailScreen(documentId: id)));

  Future<void> _openScanner() async {
    final doc = await Navigator.push<Document>(context, MaterialPageRoute(builder: (_) => const ScannerScreen()));
    if (doc != null && mounted) _openDocument(doc.id);
  }

  Future<void> _openIdCard() async {
    final doc = await Navigator.push<Document>(context, MaterialPageRoute(builder: (_) => const IdCardScanScreen()));
    if (doc != null && mounted) _openDocument(doc.id);
  }

  Future<void> _importFromGallery() async {
    final picked = await ImagePicker().pickMultiImage();
    if (picked.isEmpty || !mounted) return;

    final now = DateTime.now();
    final title = await promptText(
      context,
      'Name document',
      initial: 'Imported ${formatDate(now)}',
      label: 'Document name',
      confirmLabel: 'Import',
    );
    if (title == null || title.trim().isEmpty || !mounted) return;

    final doc = await runWithProgress(context, 'Importing ${picked.length} photo${picked.length == 1 ? '' : 's'}…', (p) {
      return ref.read(documentRepositoryProvider).createDocument(
            title: title.trim(),
            pages: picked.map((x) => PageDraft(x.path)).toList(),
            onProgress: (done, total) => p('Processing page $done of $total…', done / total),
          );
    });
    if (doc != null && mounted) _openDocument(doc.id);
  }

  Future<void> _importFiles() async {
    final result = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['pdf', 'docx', 'xlsx', 'pptx', 'txt', 'png', 'jpg', 'jpeg', 'webp'],
    );
    if (result.isEmpty || result.first.path == null || !mounted) return;
    final path = result.first.path!;
    final ext = path.split('.').last.toLowerCase();
    final name = _baseName(path);

    final doc = await runWithProgress(context, 'Importing ${ext.toUpperCase()}…', (p) async {
      final conv = ref.read(conversionRepositoryProvider);
      if (ext == 'pdf') return conv.importPdf(path);
      if (ext == 'docx' || ext == 'xlsx' || ext == 'pptx') {
        final pdf = await conv.officeToPdf(path);
        return conv.importPdf(pdf.path, title: name);
      }
      if (ext == 'txt') {
        final pdf = await conv.txtToPdf(path);
        return conv.importPdf(pdf.path, title: name);
      }
      return ref.read(documentRepositoryProvider).createDocument(title: name, pages: [PageDraft(path)]);
    });

    if (doc != null && mounted) {
      showSnack(context, 'Imported “${doc.title}”');
      _openDocument(doc.id);
    }
  }

  Future<void> _createFolder() async {
    final name = await promptText(context, 'New folder', label: 'Folder name', confirmLabel: 'Create');
    if (name == null || name.trim().isEmpty) return;
    try {
      await ref.read(folderRepositoryProvider).create(name.trim());
    } catch (e) {
      if (mounted) showSnack(context, '$e', error: true);
    }
  }

  void _push(Widget screen) => Navigator.push(context, MaterialPageRoute(builder: (_) => screen));

  @override
  Widget build(BuildContext context) {
    final statsAsync = ref.watch(statsProvider);
    final recentDocsAsync = ref.watch(recentDocumentsProvider);
    final foldersAsync = ref.watch(foldersProvider(null));

    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: CustomScrollView(
          slivers: [
            // Header
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(8, 8, 12, 4),
              sliver: SliverToBoxAdapter(
                child: Row(
                  children: [
                    const DrawerMenuButton(),
                    const SizedBox(width: 2),
                    const BrandMark(size: 34),
                    const SizedBox(width: 10),
                    const BrandWordmark(),
                    const Spacer(),
                    IconButton(
                      icon: const Icon(Icons.search_rounded),
                      tooltip: 'Search documents',
                      onPressed: () => ref.read(shellTabProvider.notifier).go(1),
                    ),
                    IconButton(
                      icon: const Icon(Icons.shield_outlined),
                      tooltip: 'Secure Vault',
                      onPressed: () => _push(const SecureVaultScreen()),
                    ),
                  ],
                ),
              ),
            ),

            // Hero
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 4),
              sliver: SliverToBoxAdapter(
                child: _HeroCard(
                  stats: statsAsync.value,
                  onScan: _openScanner,
                ),
              ),
            ),

            // Quick actions
            const SliverToBoxAdapter(child: SectionHeader('Quick actions', padding: EdgeInsets.fromLTRB(20, 22, 12, 10))),
            SliverPadding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              sliver: SliverGrid.count(
                crossAxisCount: 3,
                mainAxisSpacing: 10,
                crossAxisSpacing: 10,
                childAspectRatio: 1.0,
                children: [
                  _QuickAction(icon: Icons.photo_library_outlined, title: 'Photos', color: AppColors.tints[2], onTap: _importFromGallery),
                  _QuickAction(icon: Icons.upload_file_outlined, title: 'Files', color: AppColors.tints[1], onTap: _importFiles),
                  _QuickAction(icon: Icons.badge_outlined, title: 'ID card', color: AppColors.tints[5], onTap: _openIdCard),
                  _QuickAction(
                    icon: Icons.text_snippet_outlined,
                    title: 'Extract text',
                    color: AppColors.tints[3],
                    onTap: () => ref.read(shellTabProvider.notifier).go(3),
                  ),
                  _QuickAction(icon: Icons.draw_outlined, title: 'Sign', color: AppColors.tints[4], onTap: () => _push(const SignaturesScreen())),
                  _QuickAction(
                    icon: Icons.handyman_outlined,
                    title: 'PDF tools',
                    color: AppColors.tints[0],
                    onTap: () => ref.read(shellTabProvider.notifier).go(2),
                  ),
                ],
              ),
            ),

            // Folders
            SliverToBoxAdapter(
              child: SectionHeader('Folders', action: 'New folder', onAction: _createFolder, padding: const EdgeInsets.fromLTRB(20, 20, 8, 4)),
            ),
            SliverToBoxAdapter(
              child: foldersAsync.when(
                skipLoadingOnReload: true,
                data: (folders) => folders.isEmpty
                    ? Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 20),
                        child: TapCard(
                          onTap: _createFolder,
                          child: Row(children: [
                            IconBadge(Icons.create_new_folder_outlined, color: context.muted, size: 36),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Text('Group related scans into folders', style: context.text.bodyMedium?.copyWith(color: context.muted)),
                            ),
                            Icon(Icons.add_rounded, color: context.colors.primary),
                          ]),
                        ),
                      )
                    : SizedBox(
                        height: 84,
                        child: ListView.separated(
                          scrollDirection: Axis.horizontal,
                          padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
                          itemCount: folders.length,
                          separatorBuilder: (_, _) => const SizedBox(width: 10),
                          itemBuilder: (ctx, i) => SizedBox(
                            width: 170,
                            child: FolderTile(
                              folder: folders[i],
                              compact: true,
                              onTap: () => _push(DocumentsScreen(initialFolderId: folders[i].id)),
                            ),
                          ),
                        ),
                      ),
                loading: () => const SizedBox(height: 84),
                error: (_, _) => const SizedBox.shrink(),
              ),
            ),

            // Recent documents
            SliverToBoxAdapter(
              child: SectionHeader(
                'Recent documents',
                action: 'View all',
                onAction: () => ref.read(shellTabProvider.notifier).go(1),
                padding: const EdgeInsets.fromLTRB(20, 20, 8, 4),
              ),
            ),
            recentDocsAsync.when(
              skipLoadingOnReload: true,
              data: (docs) => docs.isEmpty
                  ? SliverToBoxAdapter(
                      child: EmptyState(
                        icon: Icons.document_scanner_outlined,
                        title: 'Your scans live here',
                        message: 'Capture a page or import photos. Everything stays on this device.',
                        action: 'Scan your first document',
                        onAction: _openScanner,
                      ),
                    )
                  : SliverPadding(
                      padding: const EdgeInsets.fromLTRB(20, 4, 20, 0),
                      sliver: SliverList.builder(
                        itemCount: docs.length,
                        itemBuilder: (ctx, i) {
                          final doc = docs[i];
                          return DocumentListTile(
                            doc: doc,
                            onTap: () => _openDocument(doc.id),
                            trailing: IconButton(
                              icon: Icon(
                                doc.isFavorite ? Icons.star_rounded : Icons.star_outline_rounded,
                                color: doc.isFavorite ? const Color(0xFFFFC107) : context.muted,
                              ),
                              tooltip: doc.isFavorite ? 'Remove from favorites' : 'Add to favorites',
                              onPressed: () => ref.read(documentRepositoryProvider).setFavorite(doc.id, !doc.isFavorite),
                            ),
                          );
                        },
                      ),
                    ),
              loading: () => const SliverToBoxAdapter(child: Padding(padding: EdgeInsets.all(32), child: LoadingView())),
              error: (e, _) => SliverToBoxAdapter(child: ErrorView(e)),
            ),

            const SliverToBoxAdapter(child: SizedBox(height: 110)),
          ],
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        heroTag: 'home-scan',
        onPressed: _openScanner,
        icon: const Icon(Icons.document_scanner_rounded),
        label: const Text('Scan', style: TextStyle(fontWeight: FontWeight.w800)),
      ),
    );
  }
}

class _HeroCard extends StatelessWidget {
  const _HeroCard({required this.stats, required this.onScan});
  final LibraryStats? stats;
  final VoidCallback onScan;

  @override
  Widget build(BuildContext context) {
    final s = stats;
    return Container(
      decoration: BoxDecoration(
        gradient: AppColors.brandGradient,
        borderRadius: BorderRadius.circular(AppRadius.xl + 2),
        boxShadow: [BoxShadow(color: AppColors.brand.withValues(alpha: 0.28), blurRadius: 24, offset: const Offset(0, 10))],
      ),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        children: [
          Positioned(
            right: -30,
            top: -30,
            child: Container(width: 140, height: 140, decoration: BoxDecoration(shape: BoxShape.circle, color: Colors.white.withValues(alpha: 0.07))),
          ),
          Positioned(
            right: 40,
            bottom: -50,
            child: Container(width: 110, height: 110, decoration: BoxDecoration(shape: BoxShape.circle, color: Colors.white.withValues(alpha: 0.05))),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 18, 20, 18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.16), borderRadius: BorderRadius.circular(AppRadius.pill)),
                    child: const Row(mainAxisSize: MainAxisSize.min, children: [
                      Icon(Icons.offline_bolt_rounded, size: 13, color: Colors.white),
                      SizedBox(width: 4),
                      Text('100% OFFLINE', style: TextStyle(color: Colors.white, fontSize: 10, letterSpacing: 1.1, fontWeight: FontWeight.w800)),
                    ]),
                  ),
                ]),
                const SizedBox(height: 14),
                const Text(
                  'Scan, organise and sign —\nall on your phone.',
                  style: TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.w800, height: 1.25, letterSpacing: -0.3),
                ),
                const SizedBox(height: 16),
                Row(children: [
                  _HeroStat(value: s == null ? '–' : '${s.documents}', label: 'Documents'),
                  _HeroStat(value: s == null ? '–' : '${s.pages}', label: 'Pages'),
                  _HeroStat(value: s == null ? '–' : formatBytes(s.bytes), label: 'Storage'),
                ]),
                const SizedBox(height: 16),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    style: FilledButton.styleFrom(backgroundColor: Colors.white, foregroundColor: AppColors.brand),
                    onPressed: onScan,
                    icon: const Icon(Icons.document_scanner_rounded),
                    label: const Text('Start a new scan'),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _HeroStat extends StatelessWidget {
  const _HeroStat({required this.value, required this.label});
  final String value;
  final String label;

  @override
  Widget build(BuildContext context) => Expanded(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(value, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w800)),
          const SizedBox(height: 2),
          Text(label, style: TextStyle(color: Colors.white.withValues(alpha: 0.75), fontSize: 11, fontWeight: FontWeight.w600)),
        ]),
      );
}

class _QuickAction extends StatelessWidget {
  const _QuickAction({required this.icon, required this.title, required this.color, required this.onTap});
  final IconData icon;
  final String title;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => TapCard(
        onTap: onTap,
        padding: const EdgeInsets.all(10),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            IconBadge(icon, color: color, size: 44),
            const SizedBox(height: 10),
            Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, textAlign: TextAlign.center, style: context.text.labelMedium?.copyWith(fontWeight: FontWeight.w700)),
          ],
        ),
      );
}
