import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utils/formatters.dart';
import '../../shared/widgets/common.dart';

class StorageAnalyzerScreen extends ConsumerWidget {
  const StorageAnalyzerScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final statsAsync = ref.watch(statsProvider);
    final usageAsync = ref.watch(storageUsageProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Storage Analyzer'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // Total Storage Banner
          statsAsync.when(skipLoadingOnReload: true,
            data: (stats) => Card(
              color: AppColors.brand.withValues(alpha: 0.1),
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  children: [
                    const Icon(Icons.pie_chart_outline, size: 48, color: AppColors.brand),
                    const SizedBox(height: 12),
                    Text(formatBytes(stats.bytes), style: context.text.headlineMedium?.copyWith(fontWeight: FontWeight.bold, color: AppColors.brand)),
                    const SizedBox(height: 4),
                    Text('Total App Storage Used Locally', style: context.text.bodyMedium?.copyWith(color: context.muted)),
                    const SizedBox(height: 16),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceAround,
                      children: [
                        _statItem('${stats.documents}', 'Documents'),
                        _statItem('${stats.pages}', 'Pages'),
                        _statItem('${stats.folders}', 'Folders'),
                        _statItem('${stats.trashed}', 'In Trash'),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (e, _) => Text('Error: $e'),
          ),

          const SizedBox(height: 24),
          Text('DIRECTORY BREAKDOWN', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: context.colors.primary, letterSpacing: 0.8)),
          const SizedBox(height: 10),

          // Directory Usage
          usageAsync.when(skipLoadingOnReload: true,
            data: (dirs) => Column(
              children: dirs.entries.map((entry) {
                return Card(
                  margin: const EdgeInsets.only(bottom: 8),
                  child: ListTile(
                    leading: const Icon(Icons.folder_outlined, color: AppColors.brand),
                    title: Text(entry.key, style: const TextStyle(fontWeight: FontWeight.bold)),
                    trailing: Text(formatBytes(entry.value), style: const TextStyle(fontWeight: FontWeight.w600)),
                  ),
                );
              }).toList(),
            ),
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (e, _) => Text('Error: $e'),
          ),

          const SizedBox(height: 24),
          Card(
            child: ListTile(
              leading: const Icon(Icons.cleaning_services_outlined, color: Colors.orange),
              title: const Text('Clear Temporary Cache'),
              subtitle: const Text('Delete temporary exported PDFs and transient image caches'),
              onTap: () async {
                await ref.read(fileStoreProvider).clearTemp();
                ref.invalidate(storageUsageProvider);
                if (context.mounted) showSnack(context, 'Temporary cache cleared');
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _statItem(String value, String label) {
    return Column(
      children: [
        Text(value, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
        const SizedBox(height: 2),
        Text(label, style: const TextStyle(fontSize: 11, color: Colors.grey)),
      ],
    );
  }
}
