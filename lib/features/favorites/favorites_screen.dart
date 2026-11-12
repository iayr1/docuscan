import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
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
      appBar: AppBar(title: const Text('Favorites')),
      body: AsyncView(
        favoritesAsync,
        builder: (docs) => docs.isEmpty
            ? const EmptyState(
                icon: Icons.star_outline_rounded,
                title: 'No favorites yet',
                message: 'Tap the star on any document to pin it here.',
              )
            : ListView.builder(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                itemCount: docs.length,
                itemBuilder: (ctx, i) {
                  final d = docs[i];
                  return DocumentListTile(
                    doc: d,
                    onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => DocumentDetailScreen(documentId: d.id))),
                    trailing: IconButton(
                      icon: const Icon(Icons.star_rounded, color: Color(0xFFFFC107)),
                      tooltip: 'Remove from favorites',
                      onPressed: () => ref.read(documentRepositoryProvider).setFavorite(d.id, false),
                    ),
                  );
                },
              ),
      ),
    );
  }
}
