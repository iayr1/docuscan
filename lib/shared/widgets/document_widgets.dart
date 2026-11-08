import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utils/formatters.dart';
import '../../data/models/models.dart';
import 'common.dart';

/// Shows an image stored under the app root. Vault files (`*.enc`) are
/// decrypted in memory; plain files are decoded at display size only.
class StoredImage extends ConsumerWidget {
  const StoredImage(this.relativePath, {super.key, this.fit = BoxFit.cover, this.cacheWidth, this.placeholderIcon = Icons.description_outlined});
  final String? relativePath;
  final BoxFit fit;
  final int? cacheWidth;
  final IconData placeholderIcon;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final path = relativePath;
    final placeholder = ColoredBox(
      color: context.colors.surfaceContainerHighest.withValues(alpha: 0.5),
      child: Center(child: Icon(placeholderIcon, color: context.muted)),
    );
    if (path == null) return placeholder;
    if (path.endsWith('.enc')) {
      return _VaultImage(path, fit: fit, placeholder: placeholder);
    }
    final file = ref.watch(fileStoreProvider).file(path);
    return Image.file(
      file,
      fit: fit,
      cacheWidth: cacheWidth,
      gaplessPlayback: true,
      errorBuilder: (_, _, _) => placeholder,
    );
  }
}

class _VaultImage extends ConsumerStatefulWidget {
  const _VaultImage(this.path, {required this.fit, required this.placeholder});
  final String path;
  final BoxFit fit;
  final Widget placeholder;
  @override
  ConsumerState<_VaultImage> createState() => _VaultImageState();
}

class _VaultImageState extends ConsumerState<_VaultImage> {
  Future<Uint8List>? _future;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _future ??= ref.read(vaultRepositoryProvider).readDecrypted(widget.path);
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<Uint8List>(
        future: _future,
        builder: (context, snap) => snap.hasData ? Image.memory(snap.data!, fit: widget.fit, gaplessPlayback: true) : widget.placeholder,
      );
}

class DocThumbnail extends StatelessWidget {
  const DocThumbnail(this.doc, {super.key, this.radius = 12});
  final Document doc;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final hidden = doc.isLocked || (doc.inVault);
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: Stack(fit: StackFit.expand, children: [
        if (hidden)
          ColoredBox(
            color: context.colors.primary.withValues(alpha: 0.1),
            child: Icon(Icons.lock_rounded, color: context.colors.primary),
          )
        else
          StoredImage(doc.thumbnailPath, cacheWidth: 360),
        if (doc.pageCount > 1)
          Positioned(
            right: 6,
            bottom: 6,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.6), borderRadius: BorderRadius.circular(6)),
              child: Text('${doc.pageCount}', style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.w800)),
            ),
          ),
      ]),
    );
  }
}

class DocumentGridCard extends StatelessWidget {
  const DocumentGridCard({super.key, required this.doc, this.onTap, this.onLongPress, this.selected = false, this.selecting = false, this.trailing});
  final Document doc;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final bool selected;
  final bool selecting;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => TapCard(
        padding: const EdgeInsets.all(8),
        selected: selected,
        onTap: onTap,
        onLongPress: onLongPress,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(
            child: Stack(fit: StackFit.expand, children: [
              DocThumbnail(doc, radius: 10),
              if (selecting)
                Positioned(
                  left: 6,
                  top: 6,
                  child: Icon(selected ? Icons.check_circle_rounded : Icons.radio_button_unchecked_rounded,
                      color: selected ? context.colors.primary : Colors.white, shadows: const [Shadow(blurRadius: 4)]),
                ),
              if (doc.isFavorite && !selecting)
                const Positioned(left: 6, top: 6, child: Icon(Icons.star_rounded, color: Color(0xFFFFC107), size: 20, shadows: [Shadow(blurRadius: 4)])),
            ]),
          ),
          const SizedBox(height: 8),
          Row(children: [
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(doc.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: context.text.labelLarge),
                const SizedBox(height: 2),
                Text(formatRelative(doc.updatedAt), maxLines: 1, style: context.text.labelSmall?.copyWith(color: context.muted)),
              ]),
            ),
            ?trailing,
          ]),
        ]),
      );
}

class DocumentListTile extends StatelessWidget {
  const DocumentListTile({super.key, required this.doc, this.onTap, this.onLongPress, this.selected = false, this.selecting = false, this.trailing, this.subtitle});
  final Document doc;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final bool selected;
  final bool selecting;
  final Widget? trailing;
  final String? subtitle;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: TapCard(
          padding: const EdgeInsets.all(10),
          selected: selected,
          onTap: onTap,
          onLongPress: onLongPress,
          child: Row(children: [
            if (selecting)
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: Icon(selected ? Icons.check_circle_rounded : Icons.radio_button_unchecked_rounded,
                    color: selected ? context.colors.primary : context.muted),
              ),
            SizedBox(width: 48, height: 62, child: DocThumbnail(doc, radius: 8)),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Flexible(child: Text(doc.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: context.text.titleSmall)),
                  if (doc.isFavorite) const Padding(padding: EdgeInsets.only(left: 4), child: Icon(Icons.star_rounded, size: 16, color: Color(0xFFFFC107))),
                  if (doc.isLocked) Padding(padding: const EdgeInsets.only(left: 4), child: Icon(Icons.lock_rounded, size: 14, color: context.muted)),
                ]),
                const SizedBox(height: 4),
                Text(
                  subtitle ?? '${doc.pageCount} page${doc.pageCount == 1 ? '' : 's'} · ${formatBytes(doc.fileSize)} · ${formatRelative(doc.updatedAt)}',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: context.text.labelSmall?.copyWith(color: context.muted),
                ),
                if (doc.tags.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Wrap(spacing: 4, runSpacing: 4, children: [
                    for (final t in doc.tags.take(3))
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: Color(t.color ?? 0xFF1E7054).withValues(alpha: 0.14),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text('#${t.name}', style: context.text.labelSmall?.copyWith(fontSize: 10)),
                      ),
                  ]),
                ],
              ]),
            ),
            ?trailing,
          ]),
        ),
      );
}

class FolderTile extends StatelessWidget {
  const FolderTile({super.key, required this.folder, this.onTap, this.onLongPress, this.trailing, this.compact = false});
  final Folder folder;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final Widget? trailing;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final color = Color(folder.color ?? AppColors.tints[folder.name.hashCode.abs() % AppColors.tints.length].toARGB32());
    return TapCard(
      padding: EdgeInsets.all(compact ? 10 : 12),
      onTap: onTap,
      onLongPress: onLongPress,
      child: Row(children: [
        IconBadge(Icons.folder_rounded, color: color, size: compact ? 36 : 42),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(folder.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: context.text.titleSmall),
            Text(
              '${folder.documentCount} doc${folder.documentCount == 1 ? '' : 's'}'
              '${folder.subfolderCount > 0 ? ' · ${folder.subfolderCount} folder${folder.subfolderCount == 1 ? '' : 's'}' : ''}',
              style: context.text.labelSmall?.copyWith(color: context.muted),
            ),
          ]),
        ),
        ?trailing,
      ]),
    );
  }
}

/// Lets the user pick a destination folder (with nested navigation).
Future<(bool, String?)?> pickFolder(BuildContext context, {String title = 'Choose folder', String? exclude}) {
  return showModalBottomSheet<(bool, String?)>(
    context: context,
    isScrollControlled: true,
    builder: (ctx) => _FolderPicker(title: title, exclude: exclude),
  );
}

class _FolderPicker extends ConsumerStatefulWidget {
  const _FolderPicker({required this.title, this.exclude});
  final String title;
  final String? exclude;
  @override
  ConsumerState<_FolderPicker> createState() => _FolderPickerState();
}

class _FolderPickerState extends ConsumerState<_FolderPicker> {
  final List<Folder> _stack = [];

  @override
  Widget build(BuildContext context) {
    final current = _stack.isEmpty ? null : _stack.last;
    final folders = ref.watch(foldersProvider(current?.id));
    return SafeArea(
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * 0.7,
        child: Column(children: [
          ListTile(
            leading: _stack.isEmpty ? const Icon(Icons.folder_open_rounded) : IconButton(icon: const Icon(Icons.arrow_back), onPressed: () => setState(_stack.removeLast)),
            title: Text(current?.name ?? widget.title, style: context.text.titleMedium),
            trailing: IconButton(
              tooltip: 'New folder',
              icon: const Icon(Icons.create_new_folder_outlined),
              onPressed: () async {
                final name = await promptText(context, 'New folder', label: 'Folder name');
                if (name == null) return;
                try {
                  await ref.read(folderRepositoryProvider).create(name, parentId: current?.id);
                } catch (e) {
                  if (context.mounted) showSnack(context, '$e', error: true);
                }
              },
            ),
          ),
          const Divider(),
          Expanded(
            child: AsyncView(
              folders,
              builder: (list) => ListView(children: [
                for (final f in list.where((f) => f.id != widget.exclude))
                  ListTile(
                    leading: const Icon(Icons.folder_rounded),
                    title: Text(f.name),
                    subtitle: Text('${f.documentCount} documents'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => setState(() => _stack.add(f)),
                  ),
                if (list.isEmpty)
                  const Padding(padding: EdgeInsets.all(24), child: Text('No subfolders', textAlign: TextAlign.center)),
              ]),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                icon: const Icon(Icons.check_rounded),
                label: Text(current == null ? 'Move to “All documents” (no folder)' : 'Choose “${current.name}”'),
                onPressed: () => Navigator.pop(context, (true, current?.id)),
              ),
            ),
          ),
        ]),
      ),
    );
  }
}

bool fileExists(String path) => File(path).existsSync();
