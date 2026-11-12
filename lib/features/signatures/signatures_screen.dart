import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';

import '../../app/providers.dart';
import '../../core/theme/app_theme.dart';
import '../../data/models/models.dart';
import '../../shared/widgets/common.dart';
import '../../shared/widgets/document_widgets.dart';
import 'signature_pad_dialog.dart';

class SignaturesScreen extends ConsumerStatefulWidget {
  const SignaturesScreen({super.key});

  @override
  ConsumerState<SignaturesScreen> createState() => _SignaturesScreenState();
}

class _SignaturesScreenState extends ConsumerState<SignaturesScreen> with SingleTickerProviderStateMixin {
  late final TabController _tabController;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  Future<void> _createStamp() async {
    final titleController = TextEditingController(text: 'APPROVED');
    final subtextController = TextEditingController(text: DateFormat('dd MMM yyyy').format(DateTime.now()));
    Color selectedColor = const Color(0xFF1E7054);
    StampKind selectedKind = StampKind.approved;

    final stamp = await showDialog<Stamp>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDlgState) => AlertDialog(
          title: const Text('Create Stamp'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                DropdownButtonFormField<StampKind>(
                  initialValue: selectedKind,
                  decoration: const InputDecoration(labelText: 'Stamp Type'),
                  items: const [
                    DropdownMenuItem(value: StampKind.approved, child: Text('Status (Approved, Paid...)')),
                    DropdownMenuItem(value: StampKind.date, child: Text('Date Stamp')),
                    DropdownMenuItem(value: StampKind.company, child: Text('Company / Seal')),
                    DropdownMenuItem(value: StampKind.text, child: Text('Custom Text Stamp')),
                  ],
                  onChanged: (v) {
                    if (v != null) {
                      setDlgState(() {
                        selectedKind = v;
                        if (v == StampKind.date) {
                          titleController.text = 'RECEIVED';
                          subtextController.text = DateFormat('yyyy-MM-dd').format(DateTime.now());
                        }
                      });
                    }
                  },
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: titleController,
                  decoration: const InputDecoration(labelText: 'Main Text', border: OutlineInputBorder()),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: subtextController,
                  decoration: const InputDecoration(labelText: 'Subtext / Date', border: OutlineInputBorder()),
                ),
                const SizedBox(height: 14),
                const Text('Stamp Color:'),
                const SizedBox(height: 6),
                Row(
                  children: [
                    const Color(0xFF1E7054), // Forest Green
                    const Color(0xFFC6383B), // Red
                    const Color(0xFF3466C9), // Blue
                    Colors.black,
                  ].map((c) => Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: InkWell(
                          onTap: () => setDlgState(() => selectedColor = c),
                          child: Container(
                            width: 32,
                            height: 32,
                            decoration: BoxDecoration(
                              color: c,
                              shape: BoxShape.circle,
                              border: Border.all(color: selectedColor == c ? AppColors.brand : Colors.white, width: 2.5),
                            ),
                          ),
                        ),
                      )).toList(),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('Cancel')),
            FilledButton(
              onPressed: () async {
                final text = titleController.text.trim().toUpperCase();
                final sub = subtextController.text.trim();
                if (text.isEmpty) return;

                final png = await _renderStampPng(text, sub, selectedColor);
                if (png == null) return;

                final newStamp = await ref.read(assetRepositoryProvider).saveStamp(
                      name: text,
                      kind: selectedKind,
                      text: text,
                      subtext: sub.isEmpty ? null : sub,
                      color: selectedColor.toARGB32(),
                      png: png,
                    );
                if (ctx.mounted) Navigator.of(ctx).pop(newStamp);
              },
              child: const Text('Create'),
            ),
          ],
        ),
      ),
    );

    if (stamp != null && mounted) {
      showSnack(context, 'Stamp created');
    }
  }

  Future<void> _importStampImage() async {
    final picker = ImagePicker();
    final picked = await picker.pickImage(source: ImageSource.gallery);
    if (picked == null || !mounted) return;

    try {
      final bytes = await picked.readAsBytes();
      await ref.read(assetRepositoryProvider).saveStamp(
            name: 'Imported Stamp',
            kind: StampKind.image,
            color: Colors.black.toARGB32(),
            png: bytes,
          );
      if (mounted) showSnack(context, 'Stamp imported from gallery');
    } catch (e) {
      if (mounted) showSnack(context, 'Import failed: $e', error: true);
    }
  }

  Future<Uint8List?> _renderStampPng(String title, String subtext, Color color) async {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    const width = 360.0;
    const height = 150.0;

    final borderPaint = Paint()
      ..color = color
      ..strokeWidth = 4.0
      ..style = PaintingStyle.stroke;

    final rrect = RRect.fromRectAndRadius(const Rect.fromLTWH(6, 6, width - 12, height - 12), const Radius.circular(14));
    canvas.drawRRect(rrect, borderPaint);

    final innerRRect = RRect.fromRectAndRadius(const Rect.fromLTWH(12, 12, width - 24, height - 24), const Radius.circular(10));
    canvas.drawRRect(innerRRect, borderPaint..strokeWidth = 1.5);

    final titleSpan = TextSpan(
      text: title,
      style: TextStyle(color: color, fontSize: 32, fontWeight: FontWeight.w900, letterSpacing: 3),
    );
    final titlePainter = TextPainter(text: titleSpan, textDirection: ui.TextDirection.ltr, textAlign: TextAlign.center)..layout(maxWidth: width - 30);
    titlePainter.paint(canvas, Offset((width - titlePainter.width) / 2, subtext.isEmpty ? (height - titlePainter.height) / 2 : 28));

    if (subtext.isNotEmpty) {
      final subSpan = TextSpan(
        text: subtext,
        style: TextStyle(color: color, fontSize: 16, fontWeight: FontWeight.bold, letterSpacing: 1.5),
      );
      final subPainter = TextPainter(text: subSpan, textDirection: ui.TextDirection.ltr, textAlign: TextAlign.center)..layout(maxWidth: width - 30);
      subPainter.paint(canvas, Offset((width - subPainter.width) / 2, 85));
    }

    final picture = recorder.endRecording();
    final img = await picture.toImage(width.toInt(), height.toInt());
    final byteData = await img.toByteData(format: ui.ImageByteFormat.png);
    return byteData?.buffer.asUint8List();
  }

  @override
  Widget build(BuildContext context) {
    final sigsAsync = ref.watch(signaturesProvider);
    final stampsAsync = ref.watch(stampsProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Signatures & Stamps'),
        bottom: TabBar(
          controller: _tabController,
          tabs: const [
            Tab(icon: Icon(Icons.draw_outlined), text: 'Signatures'),
            Tab(icon: Icon(Icons.verified_outlined), text: 'Stamps'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          // Signatures tab
          sigsAsync.when(skipLoadingOnReload: true,
            data: (sigs) => sigs.isEmpty
                ? EmptyState(
                    icon: Icons.draw_outlined,
                    title: 'No signatures saved',
                    message: 'Create your digital signature to sign documents and PDF contracts offline.',
                    action: 'Create Signature',
                    onAction: () => SignaturePadDialog.show(context),
                  )
                : ListView.separated(
                    padding: const EdgeInsets.all(16),
                    itemCount: sigs.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 12),
                    itemBuilder: (ctx, i) {
                      final s = sigs[i];
                      return Card(
                        clipBehavior: Clip.antiAlias,
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Text(s.name, style: context.text.titleMedium?.copyWith(fontWeight: FontWeight.bold)),
                                  const Spacer(),
                                  IconButton(
                                    icon: const Icon(Icons.edit_outlined),
                                    onPressed: () async {
                                      final c = TextEditingController(text: s.name);
                                      final rename = await showDialog<String>(
                                        context: context,
                                        builder: (cctx) => AlertDialog(
                                          title: const Text('Rename Signature'),
                                          content: TextField(controller: c, autofocus: true),
                                          actions: [
                                            TextButton(onPressed: () => Navigator.pop(cctx), child: const Text('Cancel')),
                                            FilledButton(onPressed: () => Navigator.pop(cctx, c.text), child: const Text('Save')),
                                          ],
                                        ),
                                      );
                                      if (rename != null && rename.trim().isNotEmpty) {
                                        await ref.read(assetRepositoryProvider).renameSignature(s.id, rename.trim());
                                      }
                                    },
                                  ),
                                  IconButton(
                                    icon: const Icon(Icons.delete_outline, color: Colors.red),
                                    onPressed: () async {
                                      if (await confirm(context, 'Delete Signature', 'Delete "${s.name}" permanently?', destructive: true)) {
                                        await ref.read(assetRepositoryProvider).deleteSignature(s);
                                      }
                                    },
                                  ),
                                ],
                              ),
                              const SizedBox(height: 10),
                              Container(
                                height: 90,
                                width: double.infinity,
                                padding: const EdgeInsets.all(8),
                                decoration: BoxDecoration(
                                  color: Colors.white,
                                  borderRadius: BorderRadius.circular(AppRadius.md),
                                  border: Border.all(color: context.outline),
                                ),
                                child: StoredImage(s.path, fit: BoxFit.contain),
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

          // Stamps tab
          stampsAsync.when(skipLoadingOnReload: true,
            data: (stamps) => stamps.isEmpty
                ? EmptyState(
                    icon: Icons.verified_outlined,
                    title: 'No stamps saved',
                    message: 'Generate approval, paid, date or custom company stamps to mark your documents.',
                    action: 'Create Stamp',
                    onAction: _createStamp,
                  )
                : ListView.separated(
                    padding: const EdgeInsets.all(16),
                    itemCount: stamps.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 12),
                    itemBuilder: (ctx, i) {
                      final st = stamps[i];
                      return Card(
                        clipBehavior: Clip.antiAlias,
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: Row(
                            children: [
                              Container(
                                width: 120,
                                height: 60,
                                decoration: BoxDecoration(
                                  color: Colors.white,
                                  borderRadius: BorderRadius.circular(AppRadius.sm),
                                  border: Border.all(color: context.outline),
                                ),
                                child: StoredImage(st.path, fit: BoxFit.contain),
                              ),
                              const SizedBox(width: 16),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(st.name, style: context.text.titleMedium?.copyWith(fontWeight: FontWeight.bold)),
                                    if (st.subtext != null) Text(st.subtext!, style: context.text.bodySmall?.copyWith(color: context.muted)),
                                    Text(st.kind.name.toUpperCase(), style: const TextStyle(fontSize: 10, color: AppColors.brand, fontWeight: FontWeight.bold)),
                                  ],
                                ),
                              ),
                              IconButton(
                                icon: const Icon(Icons.delete_outline, color: Colors.red),
                                onPressed: () async {
                                  if (await confirm(context, 'Delete Stamp', 'Delete "${st.name}"?', destructive: true)) {
                                    await ref.read(assetRepositoryProvider).deleteStamp(st);
                                  }
                                },
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
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () {
          if (_tabController.index == 0) {
            SignaturePadDialog.show(context);
          } else {
            _showStampOptions();
          }
        },
        icon: const Icon(Icons.add),
        label: Text(_tabController.index == 0 ? 'New Signature' : 'New Stamp'),
      ),
    );
  }

  void _showStampOptions() {
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.verified_outlined, color: AppColors.brand),
              title: const Text('Create Status / Date Stamp'),
              subtitle: const Text('Approved, Paid, Confidential, Date stamps'),
              onTap: () {
                Navigator.pop(ctx);
                _createStamp();
              },
            ),
            ListTile(
              leading: const Icon(Icons.image_outlined, color: AppColors.info),
              title: const Text('Import Stamp Image'),
              subtitle: const Text('Choose existing company seal or logo from gallery'),
              onTap: () {
                Navigator.pop(ctx);
                _importStampImage();
              },
            ),
          ],
        ),
      ),
    );
  }
}
