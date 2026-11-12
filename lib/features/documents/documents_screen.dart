import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../core/theme/app_theme.dart';
import '../../data/models/models.dart';
import '../../shared/widgets/common.dart';
import '../../shared/widgets/document_widgets.dart';
import '../document_editor/document_detail_screen.dart';
import '../scanner/scanner_screen.dart';
import '../shell/app_shell.dart';
import 'duplicates_screen.dart';
import 'storage_analyzer_screen.dart';
import 'trash_screen.dart';

class DocumentsScreen extends ConsumerStatefulWidget {
  const DocumentsScreen({super.key, this.initialFolderId, this.isRootTab = false});
  final String? initialFolderId;

  /// True when shown as a bottom-navigation tab (shows the drawer button).
  final bool isRootTab;

  @override
  ConsumerState<DocumentsScreen> createState() => _DocumentsScreenState();
}

class _DocumentsScreenState extends ConsumerState<DocumentsScreen> {
  /// Folder navigation stack; the last entry is the open folder.
  final List<String> _folderStack = [];
  bool _isGridView = false;
  DocSort _sort = DocSort.modifiedDesc;
  String _searchQuery = '';
  String? _selectedTagId;
  final Set<String> _selectedDocIds = {};

  late final TextEditingController _searchController;

  String? get _currentFolderId => _folderStack.isEmpty ? null : _folderStack.last;
  bool get _multiSelect => _selectedDocIds.isNotEmpty;

  /// Whether "back" should go up a folder level instead of leaving the screen.
  bool get _canGoUp => widget.initialFolderId == null ? _folderStack.isNotEmpty : _folderStack.length > 1;

  @override
  void initState() {
    super.initState();
    if (widget.initialFolderId != null) _folderStack.add(widget.initialFolderId!);
    _searchController = TextEditingController();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  void _openFolder(String id) => setState(() {
        _folderStack.add(id);
        _selectedDocIds.clear();
      });

  void _handleBack() {
    if (_multiSelect) {
      setState(_selectedDocIds.clear);
    } else if (_canGoUp) {
      setState(_folderStack.removeLast);
    }
  }

  void _toggleSelect(String id) => setState(() {
        if (!_selectedDocIds.remove(id)) _selectedDocIds.add(id);
      });

  Future<void> _openScanner() async {
    final doc = await Navigator.push<Document>(
      context,
      MaterialPageRoute(builder: (_) => ScannerScreen(targetFolderId: _currentFolderId)),
    );
    if (doc != null && mounted) {
      Navigator.push(context, MaterialPageRoute(builder: (_) => DocumentDetailScreen(documentId: doc.id)));
    }
  }

  Future<void> _createFolder() async {
    final name = await promptText(context, 'New folder', label: 'Folder name', confirmLabel: 'Create');
    if (name == null || name.trim().isEmpty) return;
    try {
      await ref.read(folderRepositoryProvider).create(name.trim(), parentId: _currentFolderId);
    } catch (e) {
      if (mounted) showSnack(context, '$e', error: true);
    }
  }

  Future<void> _folderOptions(Folder folder) async {
    final action = await pickOption<String>(context, folder.name, const [
      ('rename', 'Rename', Icons.drive_file_rename_outline),
      ('delete', 'Delete folder', Icons.delete_outline_rounded),
    ]);
    if (!mounted || action == null) return;
    if (action == 'rename') {
      final name = await promptText(context, 'Rename folder', initial: folder.name, label: 'Folder name');
      if (name != null && name.trim().isNotEmpty) {
        await ref.read(folderRepositoryProvider).rename(folder.id, name.trim());
      }
    } else if (action == 'delete') {
      if (await confirm(context, 'Delete folder', 'Delete “${folder.name}”? Documents inside will move to the main library.',
          confirmLabel: 'Delete', destructive: true)) {
        await ref.read(folderRepositoryProvider).delete(folder.id, ref.read(documentRepositoryProvider));
      }
    }
  }

  Future<void> _bulkDelete() async {
    final n = _selectedDocIds.length;
    if (await confirm(context, 'Move to trash', 'Move $n document${n == 1 ? '' : 's'} to the recycle bin?', confirmLabel: 'Move', destructive: true)) {
      await ref.read(documentRepositoryProvider).trashDocuments(_selectedDocIds.toList());
      setState(_selectedDocIds.clear);
      if (mounted) showSnack(context, 'Moved to recycle bin');
    }
  }

  Future<void> _bulkMove() async {
    final target = await pickFolder(context, title: 'Move to folder');
    if (target == null || !target.$1 || !mounted) return; // sheet dismissed
    await ref.read(documentRepositoryProvider).moveDocuments(_selectedDocIds.toList(), target.$2);
    setState(_selectedDocIds.clear);
    if (mounted) showSnack(context, 'Documents moved');
  }

  Future<void> _bulkFavorite() async {
    final repo = ref.read(documentRepositoryProvider);
    for (final id in _selectedDocIds) {
      await repo.setFavorite(id, true);
    }
    setState(_selectedDocIds.clear);
    if (mounted) showSnack(context, 'Added to favorites');
  }

  void _openDoc(Document doc) {
    if (_multiSelect) {
      _toggleSelect(doc.id);
    } else {
      Navigator.push(context, MaterialPageRoute(builder: (_) => DocumentDetailScreen(documentId: doc.id)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final searching = _searchQuery.isNotEmpty;
    final query = DocumentQuery(
      folderId: _currentFolderId,
      // Search covers the whole library; browsing shows the open folder only.
      allFolders: searching,
      search: searching ? _searchQuery : null,
      tagId: _selectedTagId,
      sort: _sort,
    );

    final docsAsync = ref.watch(documentsProvider(query));
    final foldersAsync = ref.watch(foldersProvider(_currentFolderId));
    final tagsAsync = ref.watch(tagsProvider);
    final pathAsync = _currentFolderId == null ? null : ref.watch(folderPathProvider(_currentFolderId!));
    final folderName = pathAsync?.value?.lastOrNull?.name;

    final inFolder = _currentFolderId != null;
    final interceptBack = _multiSelect || _canGoUp;

    return PopScope(
      canPop: !interceptBack,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _handleBack();
      },
      child: Scaffold(
        appBar: AppBar(
          leading: _multiSelect
              ? IconButton(icon: const Icon(Icons.close_rounded), tooltip: 'Cancel selection', onPressed: () => setState(_selectedDocIds.clear))
              : _canGoUp
                  ? BackButton(onPressed: _handleBack)
                  : (widget.isRootTab ? const DrawerMenuButton() : null),
          title: Text(_multiSelect ? '${_selectedDocIds.length} selected' : (folderName ?? (inFolder ? 'Folder' : 'Documents'))),
          actions: _multiSelect
              ? [
                  IconButton(icon: const Icon(Icons.star_outline_rounded), tooltip: 'Add to favorites', onPressed: _bulkFavorite),
                  IconButton(icon: const Icon(Icons.drive_file_move_outline), tooltip: 'Move', onPressed: _bulkMove),
                  IconButton(icon: Icon(Icons.delete_outline_rounded, color: context.colors.error), tooltip: 'Delete', onPressed: _bulkDelete),
                ]
              : [
                  IconButton(
                    icon: Icon(_isGridView ? Icons.view_agenda_outlined : Icons.grid_view_rounded),
                    tooltip: _isGridView ? 'List view' : 'Grid view',
                    onPressed: () => setState(() => _isGridView = !_isGridView),
                  ),
                  PopupMenuButton<String>(
                    onSelected: (v) {
                      switch (v) {
                        case 'create_folder':
                          _createFolder();
                        case 'trash':
                          Navigator.push(context, MaterialPageRoute(builder: (_) => const TrashScreen()));
                        case 'duplicates':
                          Navigator.push(context, MaterialPageRoute(builder: (_) => const DuplicatesScreen()));
                        case 'storage':
                          Navigator.push(context, MaterialPageRoute(builder: (_) => const StorageAnalyzerScreen()));
                      }
                    },
                    itemBuilder: (_) => const [
                      PopupMenuItem(value: 'create_folder', child: ListTile(leading: Icon(Icons.create_new_folder_outlined), title: Text('New folder'))),
                      PopupMenuItem(value: 'trash', child: ListTile(leading: Icon(Icons.delete_outline_rounded), title: Text('Recycle bin'))),
                      PopupMenuItem(value: 'duplicates', child: ListTile(leading: Icon(Icons.copy_all_outlined), title: Text('Find duplicates'))),
                      PopupMenuItem(value: 'storage', child: ListTile(leading: Icon(Icons.pie_chart_outline_rounded), title: Text('Storage analyzer'))),
                    ],
                  ),
                ],
        ),
        body: Column(
          children: [
            // Search + sort
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 8, 8),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _searchController,
                      textInputAction: TextInputAction.search,
                      decoration: InputDecoration(
                        hintText: 'Search titles, text and tags',
                        prefixIcon: const Icon(Icons.search_rounded, size: 20),
                        suffixIcon: searching
                            ? IconButton(
                                icon: const Icon(Icons.close_rounded, size: 18),
                                onPressed: () {
                                  _searchController.clear();
                                  setState(() => _searchQuery = '');
                                },
                              )
                            : null,
                        isDense: true,
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(AppRadius.pill), borderSide: BorderSide(color: context.outline)),
                        enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(AppRadius.pill), borderSide: BorderSide(color: context.outline)),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(AppRadius.pill),
                          borderSide: BorderSide(color: context.colors.primary, width: 1.6),
                        ),
                        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                      ),
                      onChanged: (v) => setState(() => _searchQuery = v.trim()),
                    ),
                  ),
                  PopupMenuButton<DocSort>(
                    icon: const Icon(Icons.swap_vert_rounded),
                    tooltip: 'Sort by',
                    initialValue: _sort,
                    onSelected: (s) => setState(() => _sort = s),
                    itemBuilder: (_) => [for (final s in DocSort.values) CheckedPopupMenuItem(value: s, checked: s == _sort, child: Text(s.label))],
                  ),
                ],
              ),
            ),

            // Tag filter chips
            tagsAsync.when(
              skipLoadingOnReload: true,
              data: (tags) => tags.isEmpty
                  ? const SizedBox.shrink()
                  : SizedBox(
                      height: 44,
                      child: ListView(
                        scrollDirection: Axis.horizontal,
                        padding: const EdgeInsets.fromLTRB(16, 0, 8, 8),
                        children: [
                          PillChip(label: 'All', selected: _selectedTagId == null, onTap: () => setState(() => _selectedTagId = null)),
                          for (final t in tags)
                            PillChip(
                              label: '#${t.name}',
                              selected: _selectedTagId == t.id,
                              onTap: () => setState(() => _selectedTagId = _selectedTagId == t.id ? null : t.id),
                            ),
                        ],
                      ),
                    ),
              loading: () => const SizedBox.shrink(),
              error: (_, _) => const SizedBox.shrink(),
            ),

            Expanded(
              child: docsAsync.when(
                skipLoadingOnReload: true,
                data: (docs) {
                  final folders = searching ? const <Folder>[] : (foldersAsync.value ?? const <Folder>[]);
                  if (docs.isEmpty && folders.isEmpty) {
                    return EmptyState(
                      icon: searching ? Icons.search_off_rounded : Icons.folder_open_rounded,
                      title: searching ? 'No results for “$_searchQuery”' : (inFolder ? 'This folder is empty' : 'No documents yet'),
                      message: searching ? 'Try a different word — OCR text is searched too.' : 'Scan a document or import files to get started.',
                      action: searching ? null : 'Scan document',
                      onAction: searching ? null : _openScanner,
                    );
                  }

                  return CustomScrollView(
                    slivers: [
                      if (folders.isNotEmpty) ...[
                        SliverToBoxAdapter(child: _label(context, 'Folders')),
                        SliverPadding(
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                          sliver: SliverGrid(
                            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                              maxCrossAxisExtent: 240,
                              mainAxisExtent: 76,
                              crossAxisSpacing: 10,
                              mainAxisSpacing: 10,
                            ),
                            delegate: SliverChildBuilderDelegate(
                              (ctx, i) => FolderTile(
                                folder: folders[i],
                                compact: true,
                                onTap: () => _openFolder(folders[i].id),
                                onLongPress: () => _folderOptions(folders[i]),
                              ),
                              childCount: folders.length,
                            ),
                          ),
                        ),
                      ],
                      if (docs.isNotEmpty)
                        SliverToBoxAdapter(child: _label(context, searching ? '${docs.length} result${docs.length == 1 ? '' : 's'}' : 'Documents')),
                      if (_isGridView)
                        SliverPadding(
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                          sliver: SliverGrid(
                            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                              maxCrossAxisExtent: 200,
                              childAspectRatio: 0.72,
                              crossAxisSpacing: 12,
                              mainAxisSpacing: 12,
                            ),
                            delegate: SliverChildBuilderDelegate(
                              (ctx, i) {
                                final doc = docs[i];
                                return DocumentGridCard(
                                  doc: doc,
                                  selecting: _multiSelect,
                                  selected: _selectedDocIds.contains(doc.id),
                                  onTap: () => _openDoc(doc),
                                  onLongPress: () => _toggleSelect(doc.id),
                                );
                              },
                              childCount: docs.length,
                            ),
                          ),
                        )
                      else
                        SliverPadding(
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                          sliver: SliverList.builder(
                            itemCount: docs.length,
                            itemBuilder: (ctx, i) {
                              final doc = docs[i];
                              return DocumentListTile(
                                doc: doc,
                                selecting: _multiSelect,
                                selected: _selectedDocIds.contains(doc.id),
                                onTap: () => _openDoc(doc),
                                onLongPress: () => _toggleSelect(doc.id),
                                trailing: _multiSelect
                                    ? null
                                    : IconButton(
                                        icon: Icon(
                                          doc.isFavorite ? Icons.star_rounded : Icons.star_outline_rounded,
                                          color: doc.isFavorite ? const Color(0xFFFFC107) : context.muted,
                                        ),
                                        onPressed: () => ref.read(documentRepositoryProvider).setFavorite(doc.id, !doc.isFavorite),
                                      ),
                              );
                            },
                          ),
                        ),
                      const SliverToBoxAdapter(child: SizedBox(height: 96)),
                    ],
                  );
                },
                loading: () => const LoadingView(),
                error: (e, _) => ErrorView(e),
              ),
            ),
          ],
        ),
        floatingActionButton: _multiSelect
            ? null
            : FloatingActionButton(
                heroTag: 'docs-scan',
                tooltip: 'Scan document',
                onPressed: _openScanner,
                child: const Icon(Icons.document_scanner_rounded),
              ),
      ),
    );
  }

  Widget _label(BuildContext context, String text) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
        child: Text(text.toUpperCase(), style: context.text.labelSmall?.copyWith(color: context.muted, letterSpacing: 1.1, fontWeight: FontWeight.w800)),
      );
}
