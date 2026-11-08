import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../core/storage/settings_store.dart';
import '../../core/theme/app_theme.dart';
import '../../shared/widgets/common.dart';
import '../documents/storage_analyzer_screen.dart';

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider);
    final notifier = ref.read(settingsProvider.notifier);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Settings'),
      ),
      body: ListView(
        children: [
          // Section: Appearance
          _buildHeader('APPEARANCE'),
          ListTile(
            leading: const Icon(Icons.palette_outlined),
            title: const Text('Theme'),
            subtitle: Text(switch (settings.themeMode) {
              ThemeMode.light => 'Light',
              ThemeMode.dark => 'Dark',
              ThemeMode.system => 'Follow System',
            }),
            trailing: const Icon(Icons.chevron_right),
            onTap: () {
              showDialog(
                context: context,
                builder: (ctx) => SimpleDialog(
                  title: const Text('Choose Theme'),
                  children: [
                    RadioListTile<ThemeMode>(
                      value: ThemeMode.system,
                      groupValue: settings.themeMode,
                      title: const Text('Follow System'),
                      onChanged: (v) {
                        Navigator.pop(ctx);
                        if (v != null) notifier.update((s) => s.copyWith(themeMode: v));
                      },
                    ),
                    RadioListTile<ThemeMode>(
                      value: ThemeMode.light,
                      groupValue: settings.themeMode,
                      title: const Text('Light'),
                      onChanged: (v) {
                        Navigator.pop(ctx);
                        if (v != null) notifier.update((s) => s.copyWith(themeMode: v));
                      },
                    ),
                    RadioListTile<ThemeMode>(
                      value: ThemeMode.dark,
                      groupValue: settings.themeMode,
                      title: const Text('Dark'),
                      onChanged: (v) {
                        Navigator.pop(ctx);
                        if (v != null) notifier.update((s) => s.copyWith(themeMode: v));
                      },
                    ),
                  ],
                ),
              );
            },
          ),

          // Section: Scanner Preferences
          _buildHeader('SCANNER PREFERENCES'),
          ListTile(
            leading: const Icon(Icons.picture_as_pdf_outlined),
            title: const Text('Default Page Size'),
            subtitle: Text(settings.pageSize),
            trailing: const Icon(Icons.chevron_right),
            onTap: () {
              showDialog(
                context: context,
                builder: (ctx) => SimpleDialog(
                  title: const Text('Default Page Size'),
                  children: ['A4', 'A3', 'A5', 'Letter', 'Legal', 'Fit'].map((size) {
                    return RadioListTile<String>(
                      value: size,
                      groupValue: settings.pageSize,
                      title: Text(size),
                      onChanged: (v) {
                        Navigator.pop(ctx);
                        if (v != null) notifier.update((s) => s.copyWith(pageSize: v));
                      },
                    );
                  }).toList(),
                ),
              );
            },
          ),
          ListTile(
            leading: const Icon(Icons.high_quality_outlined),
            title: const Text('PDF Quality / Compression'),
            subtitle: Text(settings.pdfQuality.label),
            trailing: const Icon(Icons.chevron_right),
            onTap: () {
              showDialog(
                context: context,
                builder: (ctx) => SimpleDialog(
                  title: const Text('PDF Quality'),
                  children: PdfQuality.values.map((q) {
                    return RadioListTile<PdfQuality>(
                      value: q,
                      groupValue: settings.pdfQuality,
                      title: Text(q.label),
                      subtitle: Text('${q.jpegQuality}% JPEG, max ${q.maxEdge}px'),
                      onChanged: (v) {
                        Navigator.pop(ctx);
                        if (v != null) notifier.update((s) => s.copyWith(pdfQuality: v));
                      },
                    );
                  }).toList(),
                ),
              );
            },
          ),
          SwitchListTile(
            secondary: const Icon(Icons.auto_fix_high_outlined),
            title: const Text('Auto-Crop Document Edges'),
            subtitle: const Text('Automatically detect page boundaries on capture'),
            value: settings.autoCrop,
            onChanged: (v) => notifier.update((s) => s.copyWith(autoCrop: v)),
          ),
          SwitchListTile(
            secondary: const Icon(Icons.grid_on),
            title: const Text('Camera Rule-of-Thirds Grid'),
            subtitle: const Text('Show alignment grid lines during camera preview'),
            value: settings.showGrid,
            onChanged: (v) => notifier.update((s) => s.copyWith(showGrid: v)),
          ),
          SwitchListTile(
            secondary: const Icon(Icons.save_outlined),
            title: const Text('Preserve Original Unedited Capture'),
            subtitle: const Text('Allows reverting page filters and crop at any time'),
            value: settings.saveOriginal,
            onChanged: (v) => notifier.update((s) => s.copyWith(saveOriginal: v)),
          ),

          // Section: Security & PIN
          _buildHeader('SECURITY & APP LOCK'),
          SwitchListTile(
            secondary: const Icon(Icons.lock_outline),
            title: const Text('App Lock (PIN / Biometrics)'),
            subtitle: const Text('Require authentication to open DocuScan'),
            value: settings.appLockEnabled,
            onChanged: (v) async {
              if (v) {
                // Must ensure PIN is set first
                final sec = ref.read(securityServiceProvider);
                final hasPin = await sec.hasPin();
                if (!hasPin && context.mounted) {
                  final pinCtrl = TextEditingController();
                  final pin = await showDialog<String>(
                    context: context,
                    builder: (ctx) => AlertDialog(
                      title: const Text('Set 4–8 Digit PIN'),
                      content: TextField(
                        controller: pinCtrl,
                        keyboardType: TextInputType.number,
                        obscureText: true,
                        autofocus: true,
                        decoration: const InputDecoration(labelText: 'PIN', border: OutlineInputBorder()),
                      ),
                      actions: [
                        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
                        FilledButton(onPressed: () => Navigator.pop(ctx, pinCtrl.text), child: const Text('Set PIN')),
                      ],
                    ),
                  );

                  if (pin != null && pin.trim().length >= 4) {
                    await sec.setPin(pin.trim());
                    notifier.update((s) => s.copyWith(appLockEnabled: true));
                  }
                  return;
                }
              }
              notifier.update((s) => s.copyWith(appLockEnabled: v));
            },
          ),
          ListTile(
            leading: const Icon(Icons.pin_outlined),
            title: const Text('Change Security PIN'),
            onTap: () async {
              final pinCtrl = TextEditingController();
              final pin = await showDialog<String>(
                context: context,
                builder: (ctx) => AlertDialog(
                  title: const Text('Enter New PIN'),
                  content: TextField(
                    controller: pinCtrl,
                    keyboardType: TextInputType.number,
                    obscureText: true,
                    autofocus: true,
                    decoration: const InputDecoration(labelText: 'New 4-8 Digit PIN', border: OutlineInputBorder()),
                  ),
                  actions: [
                    TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
                    FilledButton(onPressed: () => Navigator.pop(ctx, pinCtrl.text), child: const Text('Update PIN')),
                  ],
                ),
              );

              if (pin != null && pin.trim().length >= 4 && context.mounted) {
                await ref.read(securityServiceProvider).setPin(pin.trim());
                showSnack(context, 'Security PIN updated');
              }
            },
          ),

          // Section: Storage
          _buildHeader('STORAGE & CACHE'),
          ListTile(
            leading: const Icon(Icons.storage_outlined),
            title: const Text('Storage Analyzer'),
            subtitle: const Text('View disk consumption by directory'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const StorageAnalyzerScreen())),
          ),
          ListTile(
            leading: const Icon(Icons.cleaning_services_outlined),
            title: const Text('Clear Temporary Cache'),
            subtitle: const Text('Free space by clearing temporary export caches'),
            onTap: () async {
              await ref.read(fileStoreProvider).clearTemp();
              if (context.mounted) showSnack(context, 'Temporary cache cleared');
            },
          ),
          ListTile(
            leading: const Icon(Icons.restart_alt, color: Colors.red),
            title: const Text('Reset Settings to Default'),
            onTap: () async {
              if (await confirm(context, 'Reset Settings', 'Reset all preferences to defaults? Documents will remain untouched.', destructive: true)) {
                await notifier.reset();
                if (context.mounted) showSnack(context, 'Settings reset to default');
              }
            },
          ),

          // Section: About
          _buildHeader('ABOUT'),
          const ListTile(
            leading: Icon(Icons.verified_user_outlined, color: AppColors.brand),
            title: Text('100% Offline & Private'),
            subtitle: Text('Zero tracking. Zero analytics. Zero cloud servers. All documents, images, signatures, and OCR processes run strictly on this device.'),
          ),
          const ListTile(
            leading: Icon(Icons.info_outline),
            title: Text('DocuScan Version'),
            subtitle: Text('1.0.0+1 (Production Build)'),
          ),
          const SizedBox(height: 32),
        ],
      ),
    );
  }

  Widget _buildHeader(String title) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 6),
      child: Text(
        title,
        style: const TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.bold,
          color: AppColors.brand,
          letterSpacing: 1.0,
        ),
      ),
    );
  }
}
