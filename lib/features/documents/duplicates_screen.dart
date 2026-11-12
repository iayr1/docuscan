import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../core/utils/formatters.dart';
import '../../shared/widgets/common.dart';
import '../../shared/widgets/document_widgets.dart';

class DuplicatesScreen extends ConsumerWidget {
  const DuplicatesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final dupesAsync = ref.watch(duplicatesProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Duplicate Documents'),
      ),
      body: dupesAsync.when(skipLoadingOnReload: true,
        data: (groups) => groups.isEmpty
            ? const EmptyState(
                icon: Icons.copy_outlined,
                title: 'No duplicates found',
                message: 'All your documents have unique cryptographic content hashes.',
              )
            : ListView.builder(
                padding: const EdgeInsets.all(16),
                itemCount: groups.length,
                itemBuilder: (ctx, i) {
                  final group = groups[i];
                  return Card(
                    margin: const EdgeInsets.only(bottom: 16),
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              const Icon(Icons.warning_amber_rounded, color: Colors.orange, size: 20),
                              const SizedBox(width: 8),
                              Text('Duplicate Group #${i + 1} (${group.length} copies)', style: const TextStyle(fontWeight: FontWeight.bold)),
                            ],
                          ),
                          const Divider(height: 20),
                          ...group.map((doc) => ListTile(
                                contentPadding: EdgeInsets.zero,
                                leading: SizedBox(
                                  width: 44,
                                  height: 44,
                                  child: ClipRRect(
                                    borderRadius: BorderRadius.circular(6),
                                    child: StoredImage(doc.thumbnailPath),
                                  ),
                                ),
                                title: Text(doc.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                                subtitle: Text('${doc.pageCount} pages · ${formatBytes(doc.fileSize)}'),
                                trailing: IconButton(
                                  icon: const Icon(Icons.delete_outline, color: Colors.red),
                                  tooltip: 'Delete this copy',
                                  onPressed: () async {
                                    if (await confirm(context, 'Delete Copy', 'Move "${doc.title}" to trash?', destructive: true)) {
                                      await ref.read(documentRepositoryProvider).trashDocuments([doc.id]);
                                    }
                                  },
                                ),
                              )),
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
