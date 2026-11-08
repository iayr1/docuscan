import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../core/theme/app_theme.dart';
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

class AppShell extends ConsumerStatefulWidget {
  const AppShell({super.key});

  @override
  ConsumerState<AppShell> createState() => _AppShellState();
}

class _AppShellState extends ConsumerState<AppShell> with WidgetsBindingObserver {
  int _currentIndex = 0;
  final TextEditingController _unlockPinController = TextEditingController();

  final List<Widget> _screens = const [
    HomeScreen(),
    DocumentsScreen(),
    PdfToolsScreen(),
    OcrScreen(),
  ];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _unlockPinController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      ref.read(appLockProvider.notifier).onPaused();
    } else if (state == AppLifecycleState.resumed) {
      ref.read(appLockProvider.notifier).onResumed();
    }
  }

  Future<void> _unlockWithPin() async {
    final pin = _unlockPinController.text.trim();
    final ok = await ref.read(securityServiceProvider).verifyPin(pin);
    _unlockPinController.clear();
    if (ok) {
      ref.read(appLockProvider.notifier).unlock();
    } else {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Incorrect PIN'), backgroundColor: Colors.red),
        );
      }
    }
  }

  Future<void> _unlockWithBiometric() async {
    final ok = await ref.read(securityServiceProvider).authenticateBiometric('Unlock DocuScan');
    if (ok) {
      ref.read(appLockProvider.notifier).unlock();
    }
  }

  @override
  Widget build(BuildContext context) {
    final isLocked = ref.watch(appLockProvider);

    if (isLocked) {
      return Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 360),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 72,
                    height: 72,
                    decoration: BoxDecoration(
                      color: AppColors.brand.withValues(alpha: 0.12),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(Icons.lock_outline, size: 38, color: AppColors.brand),
                  ),
                  const SizedBox(height: 20),
                  Text('DocuScan Locked', style: context.text.titleLarge?.copyWith(fontWeight: FontWeight.bold)),
                  const SizedBox(height: 8),
                  Text(
                    'Please authenticate to access your local documents.',
                    textAlign: TextAlign.center,
                    style: context.text.bodyMedium?.copyWith(color: context.muted),
                  ),
                  const SizedBox(height: 24),
                  TextField(
                    controller: _unlockPinController,
                    obscureText: true,
                    keyboardType: TextInputType.number,
                    autofocus: true,
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontSize: 24, letterSpacing: 8, fontWeight: FontWeight.bold),
                    decoration: const InputDecoration(hintText: '••••', border: OutlineInputBorder()),
                    onSubmitted: (_) => _unlockWithPin(),
                  ),
                  const SizedBox(height: 20),
                  Row(
                    children: [
                      Expanded(
                        child: FilledButton(
                          onPressed: _unlockWithPin,
                          child: const Text('Unlock'),
                        ),
                      ),
                      const SizedBox(width: 12),
                      IconButton.filledTonal(
                        icon: const Icon(Icons.fingerprint),
                        tooltip: 'Biometric Unlock',
                        onPressed: _unlockWithBiometric,
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }

    return Scaffold(
      drawer: _buildDrawer(),
      body: IndexedStack(
        index: _currentIndex,
        children: _screens,
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _currentIndex,
        onDestinationSelected: (idx) {
          setState(() => _currentIndex = idx);
        },
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.home_outlined),
            selectedIcon: Icon(Icons.home_rounded),
            label: 'Home',
          ),
          NavigationDestination(
            icon: Icon(Icons.folder_outlined),
            selectedIcon: Icon(Icons.folder_rounded),
            label: 'Documents',
          ),
          NavigationDestination(
            icon: Icon(Icons.handyman_outlined),
            selectedIcon: Icon(Icons.handyman_rounded),
            label: 'PDF Tools',
          ),
          NavigationDestination(
            icon: Icon(Icons.document_scanner_outlined),
            selectedIcon: Icon(Icons.document_scanner),
            label: 'OCR',
          ),
        ],
      ),
    );
  }

  Widget _buildDrawer() {
    return Drawer(
      child: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(20),
              child: Row(
                children: [
                  Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(color: AppColors.brand, borderRadius: BorderRadius.circular(12)),
                    child: const Icon(Icons.document_scanner_outlined, color: Colors.white, size: 22),
                  ),
                  const SizedBox(width: 12),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      RichText(
                        text: const TextSpan(
                          text: 'docu',
                          style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.black87),
                          children: [
                            TextSpan(text: 'scan', style: TextStyle(color: AppColors.brand)),
                          ],
                        ),
                      ),
                      Text('100% Offline Document Suite', style: TextStyle(fontSize: 11, color: context.muted)),
                    ],
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.symmetric(vertical: 8),
                children: [
                  ListTile(
                    leading: const Icon(Icons.home_outlined),
                    title: const Text('Home'),
                    selected: _currentIndex == 0,
                    onTap: () {
                      Navigator.pop(context);
                      setState(() => _currentIndex = 0);
                    },
                  ),
                  ListTile(
                    leading: const Icon(Icons.folder_outlined),
                    title: const Text('Documents & Folders'),
                    selected: _currentIndex == 1,
                    onTap: () {
                      Navigator.pop(context);
                      setState(() => _currentIndex = 1);
                    },
                  ),
                  ListTile(
                    leading: const Icon(Icons.camera_alt_outlined),
                    title: const Text('Scan Document'),
                    onTap: () {
                      Navigator.pop(context);
                      Navigator.push(context, MaterialPageRoute(builder: (_) => const ScannerScreen()));
                    },
                  ),
                  ListTile(
                    leading: const Icon(Icons.handyman_outlined),
                    title: const Text('PDF Toolkit'),
                    selected: _currentIndex == 2,
                    onTap: () {
                      Navigator.pop(context);
                      setState(() => _currentIndex = 2);
                    },
                  ),
                  ListTile(
                    leading: const Icon(Icons.text_snippet_outlined),
                    title: const Text('On-Device OCR'),
                    selected: _currentIndex == 3,
                    onTap: () {
                      Navigator.pop(context);
                      setState(() => _currentIndex = 3);
                    },
                  ),
                  const Divider(height: 16),
                  ListTile(
                    leading: const Icon(Icons.star_outline, color: Colors.amber),
                    title: const Text('Favorites'),
                    onTap: () {
                      Navigator.pop(context);
                      Navigator.push(context, MaterialPageRoute(builder: (_) => const FavoritesScreen()));
                    },
                  ),
                  ListTile(
                    leading: const Icon(Icons.shield_outlined, color: AppColors.brand),
                    title: const Text('Secure Vault (AES-256)'),
                    onTap: () {
                      Navigator.pop(context);
                      Navigator.push(context, MaterialPageRoute(builder: (_) => const SecureVaultScreen()));
                    },
                  ),
                  ListTile(
                    leading: const Icon(Icons.draw_outlined, color: Color(0xFFC03A6B)),
                    title: const Text('Signatures & Stamps'),
                    onTap: () {
                      Navigator.pop(context);
                      Navigator.push(context, MaterialPageRoute(builder: (_) => const SignaturesScreen()));
                    },
                  ),
                  const Divider(height: 16),
                  ListTile(
                    leading: const Icon(Icons.delete_outline),
                    title: const Text('Recycle Bin'),
                    onTap: () {
                      Navigator.pop(context);
                      Navigator.push(context, MaterialPageRoute(builder: (_) => const TrashScreen()));
                    },
                  ),
                  ListTile(
                    leading: const Icon(Icons.copy_outlined),
                    title: const Text('Find Duplicates'),
                    onTap: () {
                      Navigator.pop(context);
                      Navigator.push(context, MaterialPageRoute(builder: (_) => const DuplicatesScreen()));
                    },
                  ),
                  ListTile(
                    leading: const Icon(Icons.pie_chart_outline),
                    title: const Text('Storage Analyzer'),
                    onTap: () {
                      Navigator.pop(context);
                      Navigator.push(context, MaterialPageRoute(builder: (_) => const StorageAnalyzerScreen()));
                    },
                  ),
                  ListTile(
                    leading: const Icon(Icons.settings_outlined),
                    title: const Text('Settings'),
                    onTap: () {
                      Navigator.pop(context);
                      Navigator.push(context, MaterialPageRoute(builder: (_) => const SettingsScreen()));
                    },
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
