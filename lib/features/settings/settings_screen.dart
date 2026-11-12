import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../core/storage/settings_store.dart';
import '../../core/theme/app_theme.dart';
import '../../shared/widgets/common.dart';
import '../../shared/widgets/security_widgets.dart';
import '../documents/storage_analyzer_screen.dart';

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  static String _themeLabel(ThemeMode m) => switch (m) {
        ThemeMode.light => 'Light',
        ThemeMode.dark => 'Dark',
        ThemeMode.system => 'Follow system',
      };

  static String _lockLabel(int s) => s == 0 ? 'Immediately' : (s < 60 ? 'After $s seconds' : 'After ${s ~/ 60} minute${s >= 120 ? 's' : ''}');

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider);
    final notifier = ref.read(settingsProvider.notifier);

    Future<void> setAppLock(bool enable) async {
      if (enable) {
        if (!await ensurePin(context, ref)) return;
      } else {
        if (!context.mounted || !await authenticateUser(context, ref, reason: 'Turn off app lock')) return;
      }
      await notifier.update((s) => s.copyWith(appLockEnabled: enable));
      if (context.mounted) showSnack(context, enable ? 'App lock on' : 'App lock off');
    }

    Future<void> changePin() async {
      final sec = ref.read(securityServiceProvider);
      if (await sec.hasPin()) {
        if (!context.mounted || !await authenticateUser(context, ref, reason: 'Confirm current PIN')) return;
      }
      if (!context.mounted) return;
      final pin = await promptNewPin(context, title: 'New PIN');
      if (pin == null) return;
      await sec.setPin(pin);
      if (context.mounted) showSnack(context, 'PIN updated');
    }

    return Scaffold(
      body: CustomScrollView(
        slivers: [
          const SliverAppBar(pinned: true, title: Text('Settings')),
          SliverList.list(children: [
            _Group(title: 'Appearance', children: [
              _Tile(
                icon: Icons.palette_outlined,
                color: AppColors.tints[3],
                title: 'Theme',
                subtitle: _themeLabel(settings.themeMode),
                onTap: () async {
                  final v = await pickOption<ThemeMode>(
                    context,
                    'Theme',
                    [
                      (ThemeMode.system, 'Follow system', Icons.brightness_auto_outlined),
                      (ThemeMode.light, 'Light', Icons.light_mode_outlined),
                      (ThemeMode.dark, 'Dark', Icons.dark_mode_outlined),
                    ],
                    selected: settings.themeMode,
                  );
                  if (v != null) notifier.update((s) => s.copyWith(themeMode: v));
                },
              ),
            ]),
            _Group(title: 'Scanning', children: [
              _SwitchTile(
                icon: Icons.crop_free_rounded,
                color: AppColors.tints[0],
                title: 'Auto-detect page edges',
                subtitle: 'Crop to the document after each capture',
                value: settings.autoCrop,
                onChanged: (v) => notifier.update((s) => s.copyWith(autoCrop: v)),
              ),
              _SwitchTile(
                icon: Icons.grid_on_rounded,
                color: AppColors.tints[5],
                title: 'Camera grid',
                subtitle: 'Show alignment lines in the viewfinder',
                value: settings.showGrid,
                onChanged: (v) => notifier.update((s) => s.copyWith(showGrid: v)),
              ),
              _SwitchTile(
                icon: Icons.history_rounded,
                color: AppColors.tints[1],
                title: 'Keep original captures',
                subtitle: 'Lets you undo filters and crops later',
                value: settings.saveOriginal,
                onChanged: (v) => notifier.update((s) => s.copyWith(saveOriginal: v)),
              ),
            ]),
            _Group(title: 'PDF export', children: [
              _Tile(
                icon: Icons.description_outlined,
                color: AppColors.tints[2],
                title: 'Page size',
                subtitle: settings.pageSize == 'Fit' ? 'Fit to image' : settings.pageSize,
                onTap: () async {
                  final v = await pickOption<String>(
                    context,
                    'Page size',
                    [for (final size in ['A4', 'A3', 'A5', 'Letter', 'Legal', 'Fit']) (size, size == 'Fit' ? 'Fit to image' : size, null)],
                    selected: settings.pageSize,
                  );
                  if (v != null) notifier.update((s) => s.copyWith(pageSize: v));
                },
              ),
              _Tile(
                icon: Icons.high_quality_outlined,
                color: AppColors.tints[6],
                title: 'Quality',
                subtitle: settings.pdfQuality.label,
                onTap: () async {
                  final v = await pickOption<PdfQuality>(
                    context,
                    'PDF quality',
                    [for (final q in PdfQuality.values) (q, '${q.label} · ${q.jpegQuality}% JPEG, max ${q.maxEdge}px', null)],
                    selected: settings.pdfQuality,
                  );
                  if (v != null) notifier.update((s) => s.copyWith(pdfQuality: v));
                },
              ),
            ]),
            _Group(title: 'Security', children: [
              _SwitchTile(
                icon: Icons.lock_outline_rounded,
                color: AppColors.tints[4],
                title: 'App lock',
                subtitle: 'Require PIN or biometrics to open DocuScan',
                value: settings.appLockEnabled,
                onChanged: setAppLock,
              ),
              if (settings.appLockEnabled)
                _Tile(
                  icon: Icons.timer_outlined,
                  color: AppColors.tints[7],
                  title: 'Lock after',
                  subtitle: _lockLabel(settings.autoLockSeconds),
                  onTap: () async {
                    final v = await pickOption<int>(
                      context,
                      'Lock when away for',
                      [for (final s in [0, 30, 60, 300, 900]) (s, _lockLabel(s), null)],
                      selected: settings.autoLockSeconds,
                    );
                    if (v != null) notifier.update((s) => s.copyWith(autoLockSeconds: v));
                  },
                ),
              _Tile(icon: Icons.pin_outlined, color: AppColors.tints[1], title: 'Change PIN', subtitle: 'Used for app lock, locked documents and the vault', onTap: changePin),
            ]),
            _Group(title: 'Storage', children: [
              _Tile(
                icon: Icons.pie_chart_outline_rounded,
                color: AppColors.tints[5],
                title: 'Storage analyzer',
                subtitle: 'See what is using space',
                onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const StorageAnalyzerScreen())),
              ),
              _Tile(
                icon: Icons.cleaning_services_outlined,
                color: AppColors.tints[2],
                title: 'Clear temporary files',
                subtitle: 'Removes cached exports and previews',
                onTap: () async {
                  await ref.read(fileStoreProvider).clearTemp();
                  if (context.mounted) showSnack(context, 'Temporary files cleared');
                },
              ),
              _Tile(
                icon: Icons.restart_alt_rounded,
                color: AppColors.danger,
                title: 'Reset settings',
                subtitle: 'Your documents are not affected',
                onTap: () async {
                  if (await confirm(context, 'Reset settings', 'Restore all preferences to their defaults? Documents stay untouched.',
                      confirmLabel: 'Reset', destructive: true)) {
                    await notifier.reset();
                    if (context.mounted) showSnack(context, 'Settings reset');
                  }
                },
              ),
            ]),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 28, 20, 40),
              child: Column(children: [
                const BrandMark(size: 48),
                const SizedBox(height: 12),
                const BrandWordmark(fontSize: 20),
                const SizedBox(height: 4),
                Text('Version 1.0.0', style: context.text.labelMedium?.copyWith(color: context.muted)),
                const SizedBox(height: 10),
                Text(
                  'No accounts, no tracking, no cloud. Every scan, signature and OCR result stays on this device.',
                  textAlign: TextAlign.center,
                  style: context.text.bodySmall?.copyWith(color: context.muted, height: 1.4),
                ),
              ]),
            ),
          ]),
        ],
      ),
    );
  }
}

class _Group extends StatelessWidget {
  const _Group({required this.title, required this.children});
  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
            child: Text(title.toUpperCase(), style: context.text.labelSmall?.copyWith(color: context.muted, letterSpacing: 1.1, fontWeight: FontWeight.w800)),
          ),
          Card(
            clipBehavior: Clip.antiAlias,
            child: Column(children: [
              for (var i = 0; i < children.length; i++) ...[
                if (i > 0) const Divider(indent: 64),
                children[i],
              ],
            ]),
          ),
        ]),
      );
}

class _Tile extends StatelessWidget {
  const _Tile({required this.icon, required this.color, required this.title, this.subtitle, this.onTap});
  final IconData icon;
  final Color color;
  final String title;
  final String? subtitle;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => ListTile(
        shape: const RoundedRectangleBorder(),
        leading: IconBadge(icon, color: color, size: 36),
        title: Text(title, style: context.text.titleSmall),
        subtitle: subtitle == null ? null : Text(subtitle!, style: context.text.bodySmall?.copyWith(color: context.muted)),
        trailing: onTap == null ? null : Icon(Icons.chevron_right_rounded, color: context.muted),
        onTap: onTap,
      );
}

class _SwitchTile extends StatelessWidget {
  const _SwitchTile({required this.icon, required this.color, required this.title, required this.subtitle, required this.value, required this.onChanged});
  final IconData icon;
  final Color color;
  final String title;
  final String subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) => SwitchListTile(
        shape: const RoundedRectangleBorder(),
        secondary: IconBadge(icon, color: color, size: 36),
        title: Text(title, style: context.text.titleSmall),
        subtitle: Text(subtitle, style: context.text.bodySmall?.copyWith(color: context.muted)),
        value: value,
        onChanged: onChanged,
      );
}
