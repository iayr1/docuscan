import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../core/services/security_service.dart';
import '../../core/theme/app_theme.dart';
import '../../shared/widgets/common.dart';
import '../../shared/widgets/security_widgets.dart';
import '../documents/documents_screen.dart';
import '../documents/duplicates_screen.dart';
import '../documents/storage_analyzer_screen.dart';
import '../documents/trash_screen.dart';
import '../favorites/favorites_screen.dart';
import '../home/home_screen.dart';
import '../ocr/ocr_screen.dart';
import '../pdf_tools/pdf_tools_screen.dart';
import '../scanner/scanner_screen.dart';
import '../secure_vault/secure_vault_screen.dart';
import '../settings/settings_screen.dart';
import '../signatures/signatures_screen.dart';

/// Global key so any tab screen can open the shell's navigation drawer.
final shellScaffoldKey = GlobalKey<ScaffoldState>();

/// Opens the app drawer from any tab.
void openAppDrawer() => shellScaffoldKey.currentState?.openDrawer();

/// Menu button for the root tab screens' app bars.
class DrawerMenuButton extends StatelessWidget {
  const DrawerMenuButton({super.key});
  @override
  Widget build(BuildContext context) => IconButton(
        icon: const Icon(Icons.menu_rounded),
        tooltip: 'Menu',
        onPressed: openAppDrawer,
      );
}

class AppShell extends ConsumerStatefulWidget {
  const AppShell({super.key});

  @override
  ConsumerState<AppShell> createState() => _AppShellState();
}

class _AppShellState extends ConsumerState<AppShell> with WidgetsBindingObserver {
  static const _screens = <Widget>[
    HomeScreen(),
    DocumentsScreen(isRootTab: true),
    PdfToolsScreen(),
    OcrScreen(isRootTab: true),
  ];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      ref.read(appLockProvider.notifier).onPaused();
      // Unlocked documents and the vault re-lock when the app is backgrounded.
      ref.read(unlockedDocsProvider.notifier).clear();
    } else if (state == AppLifecycleState.resumed) {
      ref.read(appLockProvider.notifier).onResumed();
    }
  }

  void _goTab(int i) => ref.read(shellTabProvider.notifier).go(i);

  void _push(Widget screen) {
    Navigator.pop(context);
    Navigator.push(context, MaterialPageRoute(builder: (_) => screen));
  }

  @override
  Widget build(BuildContext context) {
    if (ref.watch(appLockProvider)) return const _AppLockScreen();

    final index = ref.watch(shellTabProvider);

    return Scaffold(
      key: shellScaffoldKey,
      drawer: _buildDrawer(index),
      body: IndexedStack(index: index, children: _screens),
      bottomNavigationBar: NavigationBar(
        selectedIndex: index,
        onDestinationSelected: _goTab,
        destinations: const [
          NavigationDestination(icon: Icon(Icons.home_outlined), selectedIcon: Icon(Icons.home_rounded), label: 'Home'),
          NavigationDestination(icon: Icon(Icons.folder_outlined), selectedIcon: Icon(Icons.folder_rounded), label: 'Documents'),
          NavigationDestination(icon: Icon(Icons.handyman_outlined), selectedIcon: Icon(Icons.handyman_rounded), label: 'Tools'),
          NavigationDestination(icon: Icon(Icons.text_snippet_outlined), selectedIcon: Icon(Icons.text_snippet_rounded), label: 'OCR'),
        ],
      ),
    );
  }

  Widget _buildDrawer(int index) {
    Widget tab(IconData icon, IconData selectedIcon, String label, int i) => _DrawerItem(
          icon: index == i ? selectedIcon : icon,
          label: label,
          selected: index == i,
          onTap: () {
            Navigator.pop(context);
            _goTab(i);
          },
        );

    return Drawer(
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 16),
              child: Row(
                children: [
                  const BrandMark(size: 44),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const BrandWordmark(fontSize: 20),
                        const SizedBox(height: 2),
                        Text('Private, offline document suite', style: context.text.labelSmall?.copyWith(color: context.muted)),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const Divider(),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                children: [
                  tab(Icons.home_outlined, Icons.home_rounded, 'Home', 0),
                  tab(Icons.folder_outlined, Icons.folder_rounded, 'Documents & Folders', 1),
                  tab(Icons.handyman_outlined, Icons.handyman_rounded, 'PDF Toolkit', 2),
                  tab(Icons.text_snippet_outlined, Icons.text_snippet_rounded, 'Text Recognition (OCR)', 3),
                  _DrawerItem(icon: Icons.document_scanner_outlined, label: 'Scan Document', onTap: () => _push(const ScannerScreen())),
                  const _DrawerSection('Library'),
                  _DrawerItem(icon: Icons.star_outline_rounded, label: 'Favorites', color: const Color(0xFFE0A100), onTap: () => _push(const FavoritesScreen())),
                  _DrawerItem(icon: Icons.shield_outlined, label: 'Secure Vault', color: AppColors.tints[0], onTap: () => _push(const SecureVaultScreen())),
                  _DrawerItem(icon: Icons.draw_outlined, label: 'Signatures & Stamps', color: AppColors.tints[4], onTap: () => _push(const SignaturesScreen())),
                  const _DrawerSection('Maintenance'),
                  _DrawerItem(icon: Icons.delete_outline_rounded, label: 'Recycle Bin', onTap: () => _push(const TrashScreen())),
                  _DrawerItem(icon: Icons.copy_all_outlined, label: 'Find Duplicates', onTap: () => _push(const DuplicatesScreen())),
                  _DrawerItem(icon: Icons.pie_chart_outline_rounded, label: 'Storage Analyzer', onTap: () => _push(const StorageAnalyzerScreen())),
                  _DrawerItem(icon: Icons.settings_outlined, label: 'Settings', onTap: () => _push(const SettingsScreen())),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DrawerSection extends StatelessWidget {
  const _DrawerSection(this.title);
  final String title;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 18, 16, 6),
        child: Text(title.toUpperCase(), style: context.text.labelSmall?.copyWith(color: context.muted, letterSpacing: 1.1, fontWeight: FontWeight.w800)),
      );
}

class _DrawerItem extends StatelessWidget {
  const _DrawerItem({required this.icon, required this.label, required this.onTap, this.selected = false, this.color});
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool selected;
  final Color? color;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 2),
        child: ListTile(
          dense: true,
          visualDensity: const VisualDensity(vertical: 0.5),
          leading: Icon(icon, color: selected ? context.colors.primary : color, size: 22),
          title: Text(label, style: TextStyle(fontWeight: selected ? FontWeight.w800 : FontWeight.w600, fontSize: 14)),
          selected: selected,
          selectedTileColor: context.colors.primary.withValues(alpha: 0.1),
          onTap: onTap,
        ),
      );
}

/// Full-screen gate shown while the app lock is active.
class _AppLockScreen extends ConsumerStatefulWidget {
  const _AppLockScreen();
  @override
  ConsumerState<_AppLockScreen> createState() => _AppLockScreenState();
}

class _AppLockScreenState extends ConsumerState<_AppLockScreen> {
  bool _hasBiometrics = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _tryBiometric());
  }

  Future<void> _tryBiometric() async {
    final sec = ref.read(securityServiceProvider);
    final kind = await sec.biometricKind();
    if (!mounted) return;
    setState(() => _hasBiometrics = kind != BiometricKind.none);
    if (_hasBiometrics && await sec.authenticateBiometric('Unlock DocuScan')) {
      ref.read(appLockProvider.notifier).unlock();
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        body: PinGate(
          icon: Icons.lock_rounded,
          title: 'DocuScan is locked',
          message: 'Enter your PIN to access your documents.',
          showBiometric: _hasBiometrics,
          onBiometric: _tryBiometric,
          onSubmit: (pin) async {
            final ok = await ref.read(securityServiceProvider).verifyPin(pin);
            if (ok) ref.read(appLockProvider.notifier).unlock();
            return ok;
          },
        ),
      );
}
