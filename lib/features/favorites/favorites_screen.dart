import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../core/utils/formatters.dart';
import '../../data/models/models.dart';
import '../../shared/widgets/common.dart';
import '../../shared/widgets/document_widgets.dart';
import '../document_editor/document_detail_screen.dart';

class FavoritesScreen extends ConsumerWidget {
  const FavoritesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final favoritesAsync = ref.watch(documentsProvider(const DocumentQuery(favoritesOnly: true)));

    return Scaffold(
      appBar: AppBar(
        title: const Text('Favorite Documents'),
      ),
      body: favoritesAsync.when(
        data: (docs) => docs.isEmpty
            ? const EmptyState(
                icon: Icons.star_border,
                title: 'No favorites yet',
                message: 'Tap the star icon on any document to quickly access it from here.',
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
                      title: Text(d.title, style: const TextStyle(fontWeight: FontWeight.bold), maxLines: 1, overflow: TextOverflow.ellipsis),
                      subtitle: Text('${d.pageCount} pages · ${formatBytes(d.fileSize)} · ${formatDate(d.updatedAt)}'),
                      trailing: IconButton(
                        icon: const Icon(Icons.star, color: Colors.amber),
                        tooltip: 'Unstar',
                        onPressed: () => ref.read(documentRepositoryProvider).setFavorite(d.id, !d.isFavorite),
                      ),
                      onTap: () => Navigator.push(
                        context,
                        MaterialPageRoute(builder: (_) => DocumentDetailScreen(documentId: d.id)),
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
