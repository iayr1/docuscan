import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utils/formatters.dart';
import '../../data/models/models.dart';
import '../../shared/widgets/common.dart';
import '../../shared/widgets/document_widgets.dart';
import '../document_editor/document_detail_screen.dart';
import '../scanner/scanner_screen.dart';
import 'duplicates_screen.dart';
import 'storage_analyzer_screen.dart';
import 'trash_screen.dart';

class DocumentsScreen extends ConsumerStatefulWidget {
  const DocumentsScreen({super.key, this.initialFolderId});
  final String? initialFolderId;

  @override
  ConsumerState<DocumentsScreen> createState() => _DocumentsScreenState();
}

class _DocumentsScreenState extends ConsumerState<DocumentsScreen> {
  String? _currentFolderId;
  bool _isGridView = false;
  DocSort _sort = DocSort.createdDesc;
  String _searchQuery = '';
  String? _selectedTagId;
  final Set<String> _selectedDocIds = {};
  bool _multiSelect = false;

  late final TextEditingController _searchController;

  @override
  void initState() {
    super.initState();
    _currentFolderId = widget.initialFolderId;
    _searchController = TextEditingController();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _createFolder() async {
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Create New Folder'),
        content: TextField(controller: controller, autofocus: true, decoration: const InputDecoration(labelText: 'Folder Name')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, controller.text), child: const Text('Create')),
        ],
      ),
    );

    if (name != null && name.trim().isNotEmpty) {
      await ref.read(folderRepositoryProvider).create(name.trim(), parentId: _currentFolderId);
    }
  }

  Future<void> _deleteFolder(Folder folder) async {
    if (await confirm(context, 'Delete Folder', 'Delete "${folder.name}"? Documents inside will be moved to root.', destructive: true)) {
      await ref.read(folderRepositoryProvider).delete(folder.id, ref.read(documentRepositoryProvider));
    }
  }

  Future<void> _bulkDelete() async {
    if (_selectedDocIds.isEmpty) return;
    if (await confirm(context, 'Move to Trash', 'Move ${_selectedDocIds.length} document(s) to trash?', destructive: true)) {
      await ref.read(documentRepositoryProvider).trashDocuments(_selectedDocIds.toList());
      setState(() {
        _selectedDocIds.clear();
        _multiSelect = false;
      });
      if (mounted) showSnack(context, 'Moved to trash');
    }
  }

  Future<void> _bulkMove() async {
    if (_selectedDocIds.isEmpty) return;
    final folders = await ref.read(allFoldersProvider.future);
    if (!mounted) return;

    final target = await showModalBottomSheet<Folder?>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Padding(padding: EdgeInsets.all(16), child: Text('Move to Folder', style: TextStyle(fontWeight: FontWeight.bold))),
            ListTile(
              leading: const Icon(Icons.home_outlined),
              title: const Text('Root Library (No folder)'),
              onTap: () => Navigator.pop(ctx, null),
            ),
            ...folders.map((f) => ListTile(
                  leading: const Icon(Icons.folder_outlined, color: AppColors.brand),
                  title: Text(f.name),
                  onTap: () => Navigator.pop(ctx, f),
                )),
          ],
        ),
      ),
    );

    await ref.read(documentRepositoryProvider).moveDocuments(_selectedDocIds.toList(), target?.id);
    setState(() {
      _selectedDocIds.clear();
      _multiSelect = false;
    });
    if (mounted) showSnack(context, 'Documents moved');
  }

  @override
  Widget build(BuildContext context) {
    final query = DocumentQuery(
      folderId: _currentFolderId,
      search: _searchQuery.isEmpty ? null : _searchQuery,
      tagId: _selectedTagId,
      sort: _sort,
    );

    final docsAsync = ref.watch(documentsProvider(query));
    final foldersAsync = ref.watch(foldersProvider(_currentFolderId));
    final tagsAsync = ref.watch(tagsProvider);

    return Scaffold(
      appBar: AppBar(
        title: _multiSelect
            ? Text('${_selectedDocIds.length} Selected')
            : Text(_currentFolderId == null ? 'Documents' : 'Folder'),
        leading: _multiSelect
            ? IconButton(
                icon: const Icon(Icons.close),
                onPressed: () => setState(() {
                  _multiSelect = false;
                  _selectedDocIds.clear();
                }),
              )
            : _currentFolderId != null
                ? IconButton(
                    icon: const Icon(Icons.arrow_back),
                    onPressed: () => setState(() => _currentFolderId = null),
                  )
                : null,
        actions: [
          if (_multiSelect) ...[
            IconButton(icon: const Icon(Icons.drive_file_move_outlined), tooltip: 'Move', onPressed: _bulkMove),
            IconButton(icon: const Icon(Icons.delete_outline, color: Colors.red), tooltip: 'Delete', onPressed: _bulkDelete),
          ] else ...[
            IconButton(
              icon: Icon(_isGridView ? Icons.view_list_outlined : Icons.grid_view_outlined),
              tooltip: _isGridView ? 'List view' : 'Grid view',
              onPressed: () => setState(() => _isGridView = !_isGridView),
            ),
            PopupMenuButton<String>(
              onSelected: (v) {
                switch (v) {
                  case 'create_folder':
                    _createFolder();
                    break;
                  case 'trash':
                    Navigator.push(context, MaterialPageRoute(builder: (_) => const TrashScreen()));
                    break;
                  case 'duplicates':
                    Navigator.push(context, MaterialPageRoute(builder: (_) => const DuplicatesScreen()));
                    break;
                  case 'storage':
                    Navigator.push(context, MaterialPageRoute(builder: (_) => const StorageAnalyzerScreen()));
                    break;
                }
              },
              itemBuilder: (_) => [
                const PopupMenuItem(value: 'create_folder', child: Text('New Folder')),
                const PopupMenuItem(value: 'trash', child: Text('Recycle Bin')),
                const PopupMenuItem(value: 'duplicates', child: Text('Find Duplicates')),
                const PopupMenuItem(value: 'storage', child: Text('Storage Analyzer')),
              ],
            ),
          ],
        ],
      ),
      body: Column(
        children: [
          // Search & Filter header
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _searchController,
                    decoration: InputDecoration(
                      hintText: 'Search documents, OCR text, tags...',
                      prefixIcon: const Icon(Icons.search, size: 20),
                      suffixIcon: _searchQuery.isNotEmpty
                          ? IconButton(
                              icon: const Icon(Icons.clear, size: 18),
                              onPressed: () {
                                _searchController.clear();
                                setState(() => _searchQuery = '');
                              },
                            )
                          : null,
                      isDense: true,
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(AppRadius.pill)),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                    ),
                    onChanged: (v) => setState(() => _searchQuery = v.trim()),
                  ),
                ),
                const SizedBox(width: 8),
                PopupMenuButton<DocSort>(
                  icon: const Icon(Icons.sort),
                  tooltip: 'Sort by',
                  onSelected: (s) => setState(() => _sort = s),
                  itemBuilder: (_) => const [
                    PopupMenuItem(value: DocSort.createdDesc, child: Text('Newest first')),
                    PopupMenuItem(value: DocSort.createdAsc, child: Text('Oldest first')),
                    PopupMenuItem(value: DocSort.nameAsc, child: Text('Title A-Z')),
                    PopupMenuItem(value: DocSort.sizeDesc, child: Text('Largest file size')),
                  ],
                ),
              ],
            ),
          ),

          // Tag filter chips
          tagsAsync.when(
            data: (tags) => tags.isEmpty
                ? const SizedBox.shrink()
                : SizedBox(
                    height: 38,
                    child: ListView.separated(
                      scrollDirection: Axis.horizontal,
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      itemCount: tags.length + 1,
                      separatorBuilder: (_, _) => const SizedBox(width: 6),
                      itemBuilder: (ctx, i) {
                        if (i == 0) {
                          return FilterChip(
                            label: const Text('All'),
                            selected: _selectedTagId == null,
                            onSelected: (_) => setState(() => _selectedTagId = null),
                          );
                        }
                        final t = tags[i - 1];
                        return FilterChip(
                          label: Text(t.name),
                          selected: _selectedTagId == t.id,
                          onSelected: (sel) => setState(() => _selectedTagId = sel ? t.id : null),
                        );
                      },
                    ),
                  ),
            loading: () => const SizedBox.shrink(),
            error: (_, _) => const SizedBox.shrink(),
          ),

          // Folders Row (if in root or folder has subfolders)
          foldersAsync.when(
            data: (folders) => folders.isEmpty
                ? const SizedBox.shrink()
                : Container(
                    height: 72,
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: ListView.separated(
                      scrollDirection: Axis.horizontal,
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      itemCount: folders.length,
                      separatorBuilder: (_, _) => const SizedBox(width: 10),
                      itemBuilder: (ctx, i) {
                        final f = folders[i];
                        return InkWell(
                          onTap: () => setState(() => _currentFolderId = f.id),
                          onLongPress: () => _deleteFolder(f),
                          borderRadius: BorderRadius.circular(AppRadius.md),
                          child: Container(
                            width: 130,
                            padding: const EdgeInsets.all(8),
                            decoration: BoxDecoration(
                              color: context.colors.surfaceContainerHighest.withValues(alpha: 0.5),
                              borderRadius: BorderRadius.circular(AppRadius.md),
                              border: Border.all(color: context.outline),
                            ),
                            child: Row(
                              children: [
                                const Icon(Icons.folder, color: AppColors.brand, size: 28),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [
                                      Text(f.name, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12), maxLines: 1, overflow: TextOverflow.ellipsis),
                                      Text('${f.documentCount} docs', style: TextStyle(color: context.muted, fontSize: 10)),
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
            loading: () => const SizedBox.shrink(),
            error: (_, _) => const SizedBox.shrink(),
          ),

          // Documents List / Grid
          Expanded(
            child: docsAsync.when(
              data: (docs) {
                if (docs.isEmpty) {
                  return EmptyState(
                    icon: Icons.document_scanner_outlined,
                    title: _searchQuery.isNotEmpty ? 'No documents match “$_searchQuery”' : 'No documents in this view',
                    message: 'Scan a document using the camera or import files from your gallery.',
                    action: 'Scan Document',
                    onAction: () => Navigator.push(context, MaterialPageRoute(builder: (_) => ScannerScreen(targetFolderId: _currentFolderId))),
                  );
                }

                if (_isGridView) {
                  return GridView.builder(
                    padding: const EdgeInsets.all(16),
                    gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: 2,
                      childAspectRatio: 0.74,
                      crossAxisSpacing: 12,
                      mainAxisSpacing: 12,
                    ),
                    itemCount: docs.length,
                    itemBuilder: (ctx, i) {
                      final doc = docs[i];
                      final isSelected = _selectedDocIds.contains(doc.id);
                      return Card(
                        clipBehavior: Clip.antiAlias,
                        shape: isSelected ? RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.md), side: const BorderSide(color: AppColors.brand, width: 2)) : null,
                        child: InkWell(
                          onTap: () {
                            if (_multiSelect) {
                              setState(() {
                                if (isSelected) {
                                  _selectedDocIds.remove(doc.id);
                                  if (_selectedDocIds.isEmpty) _multiSelect = false;
                                } else {
                                  _selectedDocIds.add(doc.id);
                                }
                              });
                            } else {
                              Navigator.push(context, MaterialPageRoute(builder: (_) => DocumentDetailScreen(documentId: doc.id)));
                            }
                          },
                          onLongPress: () {
                            setState(() {
                              _multiSelect = true;
                              _selectedDocIds.add(doc.id);
                            });
                          },
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Expanded(
                                child: Stack(
                                  fit: StackFit.expand,
                                  children: [
                                    StoredImage(doc.thumbnailPath, fit: BoxFit.cover),
                                    if (doc.isLocked)
                                      Container(
                                        color: Colors.black54,
                                        child: const Center(child: Icon(Icons.lock, color: Colors.white)),
                                      ),
                                    if (_multiSelect)
                                      Positioned(
                                        top: 8,
                                        right: 8,
                                        child: Icon(isSelected ? Icons.check_circle : Icons.circle_outlined, color: isSelected ? AppColors.brand : Colors.white70),
                                      ),
                                  ],
                                ),
                              ),
                              Padding(
                                padding: const EdgeInsets.all(8),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(doc.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                                    const SizedBox(height: 2),
                                    Text('${doc.pageCount} pages · ${formatBytes(doc.fileSize)}', style: TextStyle(color: context.muted, fontSize: 10)),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  );
                }

                return ListView.separated(
                  padding: const EdgeInsets.all(16),
                  itemCount: docs.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 8),
                  itemBuilder: (ctx, i) {
                    final doc = docs[i];
                    final isSelected = _selectedDocIds.contains(doc.id);
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
                        trailing: _multiSelect
                            ? Checkbox(
                                value: isSelected,
                                onChanged: (v) {
                                  setState(() {
                                    if (v == true) {
                                      _selectedDocIds.add(doc.id);
                                    } else {
                                      _selectedDocIds.remove(doc.id);
                                      if (_selectedDocIds.isEmpty) _multiSelect = false;
                                    }
                                  });
                                },
                              )
                            : IconButton(
                                icon: Icon(doc.isFavorite ? Icons.star : Icons.star_border, color: doc.isFavorite ? Colors.amber : null),
                                onPressed: () => ref.read(documentRepositoryProvider).setFavorite(doc.id, !doc.isFavorite),
                              ),
                        onTap: () {
                          if (_multiSelect) {
                            setState(() {
                              if (isSelected) {
                                _selectedDocIds.remove(doc.id);
                                if (_selectedDocIds.isEmpty) _multiSelect = false;
                              } else {
                                _selectedDocIds.add(doc.id);
                              }
                            });
                          } else {
                            Navigator.push(context, MaterialPageRoute(builder: (_) => DocumentDetailScreen(documentId: doc.id)));
                          }
                        },
                        onLongPress: () {
                          setState(() {
                            _multiSelect = true;
                            _selectedDocIds.add(doc.id);
                          });
                        },
                      ),
                    );
                  },
                );
              },
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (e, _) => Center(child: Text('Error: $e')),
            ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => ScannerScreen(targetFolderId: _currentFolderId))),
        child: const Icon(Icons.camera_alt_outlined),
      ),
    );
  }
}
