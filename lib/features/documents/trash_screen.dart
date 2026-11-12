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
    if (mounted) showSnack(context, 'Restored “${doc.title}”');
  }

  Future<void> _deletePermanently(Document doc) async {
    if (await confirm(context, 'Delete forever', 'Permanently delete “${doc.title}”? This cannot be undone.', confirmLabel: 'Delete', destructive: true)) {
      await ref.read(documentRepositoryProvider).deletePermanently([doc.id]);
      if (mounted) showSnack(context, 'Deleted permanently');
    }
  }

  Future<void> _emptyTrash(int count) async {
    if (count == 0) return;
    if (!await confirm(context, 'Empty recycle bin', 'Permanently delete $count item${count == 1 ? '' : 's'}? This cannot be undone.',
        confirmLabel: 'Empty', destructive: true)) {
      return;
    }
    if (!mounted) return;
    final ok = await runWithProgress(context, 'Emptying recycle bin…', (p) async {
      await ref.read(documentRepositoryProvider).emptyTrash();
      return true;
    });
    if (ok == true && mounted) showSnack(context, 'Recycle bin emptied');
  }

  @override
  Widget build(BuildContext context) {
    final trashAsync = ref.watch(documentsProvider(const DocumentQuery(trashed: true)));
    final count = trashAsync.value?.length ?? 0;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Recycle bin'),
        actions: [
          if (count > 0)
            TextButton.icon(
              style: TextButton.styleFrom(foregroundColor: context.colors.error),
              icon: const Icon(Icons.delete_sweep_outlined),
              label: const Text('Empty'),
              onPressed: () => _emptyTrash(count),
            ),
        ],
      ),
      body: AsyncView(
        trashAsync,
        builder: (docs) => docs.isEmpty
            ? const EmptyState(
                icon: Icons.delete_outline_rounded,
                title: 'Recycle bin is empty',
                message: 'Deleted documents stay here for 30 days before they are removed for good.',
              )
            : ListView.builder(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                itemCount: docs.length,
                itemBuilder: (ctx, i) {
                  final d = docs[i];
                  return DocumentListTile(
                    doc: d,
                    subtitle: '${d.pageCount} page${d.pageCount == 1 ? '' : 's'} · ${formatBytes(d.fileSize)}'
                        '${d.deletedAt != null ? ' · deleted ${formatRelative(d.deletedAt!)}' : ''}',
                    trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                      IconButton(icon: Icon(Icons.restore_rounded, color: context.colors.primary), tooltip: 'Restore', onPressed: () => _restore(d)),
                      IconButton(icon: Icon(Icons.delete_forever_outlined, color: context.colors.error), tooltip: 'Delete forever', onPressed: () => _deletePermanently(d)),
                    ]),
                  );
                },
              ),
      ),
    );
  }
}
