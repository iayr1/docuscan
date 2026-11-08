import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utils/formatters.dart';
import '../../data/models/models.dart';
import '../../shared/widgets/common.dart';
import '../../shared/widgets/document_widgets.dart';

class TrashScreen extends ConsumerStatefulWidget {
  const TrashScreen({super.key});

  @override
  ConsumerState<TrashScreen> createState() => _TrashScreenState();
}

class _TrashScreenState extends ConsumerState<TrashScreen> {
  Future<void> _restore(Document doc) async {
    await ref.read(documentRepositoryProvider).restoreDocuments([doc.id]);
    if (mounted) showSnack(context, 'Restored "${doc.title}"');
  }

  Future<void> _deletePermanently(Document doc) async {
    if (await confirm(context, 'Delete Permanently', 'Permanently delete "${doc.title}"? This cannot be undone.', destructive: true)) {
      await ref.read(documentRepositoryProvider).deletePermanently([doc.id]);
      if (mounted) showSnack(context, 'Permanently deleted');
    }
  }

  Future<void> _emptyTrash() async {
    if (await confirm(context, 'Empty Trash', 'Permanently remove all items from trash? This cannot be undone.', destructive: true)) {
      await runWithProgress(context, 'Emptying trash...', (p) async {
        await ref.read(documentRepositoryProvider).emptyTrash();
      });
      if (mounted) showSnack(context, 'Trash emptied');
    }
  }

  @override
  Widget build(BuildContext context) {
    // Query trash items (deleted documents)
    final trashAsync = ref.watch(documentsProvider(const DocumentQuery(trashed: true)));

    return Scaffold(
      appBar: AppBar(
        title: const Text('Recycle Bin'),
        actions: [
          IconButton(
            icon: const Icon(Icons.delete_forever_outlined),
            tooltip: 'Empty Trash',
            onPressed: _emptyTrash,
          ),
        ],
      ),
      body: trashAsync.when(
        data: (docs) => docs.isEmpty
            ? const EmptyState(
                icon: Icons.delete_outline,
                title: 'Trash is empty',
                message: 'Deleted documents remain in the recycle bin for 30 days before permanent deletion.',
              )
            : ListView.separated(
                padding: const EdgeInsets.all(16),
                itemCount: docs.length,
                separatorBuilder: (_, _) => const SizedBox(height: 10),
                itemBuilder: (ctx, i) {
                  final d = docs[i];
                  return Card(
                    child: ListTile(
                      leading: SizedBox(
                        width: 48,
                        height: 48,
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: StoredImage(d.thumbnailPath),
                        ),
                      ),
                      title: Text(d.title, style: const TextStyle(fontWeight: FontWeight.bold)),
                      subtitle: Text('${d.pageCount} pages · ${formatBytes(d.fileSize)}'),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            icon: const Icon(Icons.restore_outlined, color: AppColors.brand),
                            tooltip: 'Restore',
                            onPressed: () => _restore(d),
                          ),
                          IconButton(
                            icon: const Icon(Icons.delete_forever_outlined, color: Colors.red),
                            tooltip: 'Delete Permanently',
                            onPressed: () => _deletePermanently(d),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Error: $e')),
      ),
    );
  }
}
