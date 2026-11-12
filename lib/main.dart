import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app/providers.dart';
import 'core/storage/file_store.dart';
import 'core/storage/settings_store.dart';
import 'core/theme/app_theme.dart';
import 'data/database/app_database.dart';
import 'data/repositories/document_repository.dart';
import 'data/repositories/recovery_service.dart';
import 'features/shell/app_shell.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 1. SharedPreferences & Settings
  final prefs = await SharedPreferences.getInstance();
  final settingsStore = SettingsStore(prefs);

  // 2. Local FileStore initialization (ScannedImages, PDF, SecureVault, etc.)
  final fileStore = await FileStore.open();

  // 3. SQLite Database initialization
  final supportDir = await getApplicationSupportDirectory();
  final dbPath = p.join(supportDir.path, 'docscanner.db');
  final appDb = await AppDatabase.open(dbPath);

  // 4. Startup Recovery & Housekeeping
  try {
    final docRepo = DocumentRepository(appDb, fileStore);
    final recovery = RecoveryService(appDb, docRepo, fileStore);
    await recovery.run();
  } catch (e) {
    debugPrint('DocuScan recovery notice: $e');
  }

  runApp(
    ProviderScope(
      overrides: [
        databaseProvider.overrideWithValue(appDb),
        fileStoreProvider.overrideWithValue(fileStore),
        settingsStoreProvider.overrideWithValue(settingsStore),
      ],
      child: const DocuScanApp(),
    ),
  );
}

class DocuScanApp extends ConsumerStatefulWidget {
  const DocuScanApp({super.key});

  @override
  ConsumerState<DocuScanApp> createState() => _DocuScanAppState();
}

class _DocuScanAppState extends ConsumerState<DocuScanApp> {
  bool _showSplash = true;

  @override
  void initState() {
    super.initState();
    Future<void>.delayed(const Duration(milliseconds: 850), () {
      if (mounted) setState(() => _showSplash = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsProvider);

    return MaterialApp(
      title: 'DocuScan',
      debugShowCheckedModeBanner: false,
      themeMode: settings.themeMode,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      home: AnimatedSwitcher(
        duration: const Duration(milliseconds: 350),
        child: _showSplash ? const _StartupSplash() : const AppShell(),
      ),
    );
  }
}

class _StartupSplash extends StatelessWidget {
  const _StartupSplash();

  @override
  Widget build(BuildContext context) => const Scaffold(
        body: DecoratedBox(
          decoration: BoxDecoration(gradient: AppColors.brandGradient),
          child: SizedBox.expand(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _SplashIcon(),
                SizedBox(height: 20),
                Text(
                  'DocuScan',
                  style: TextStyle(color: Colors.white, fontSize: 30, fontWeight: FontWeight.w900, letterSpacing: -0.5),
                ),
                SizedBox(height: 6),
                Text('Private. Offline. Yours.', style: TextStyle(color: Colors.white70, fontSize: 14, fontWeight: FontWeight.w500)),
              ],
            ),
          ),
        ),
      );
}

class _SplashIcon extends StatelessWidget {
  const _SplashIcon();

  @override
  Widget build(BuildContext context) => TweenAnimationBuilder<double>(
        tween: Tween(begin: 0.8, end: 1),
        duration: const Duration(milliseconds: 600),
        curve: Curves.easeOutBack,
        builder: (_, v, child) => Transform.scale(scale: v, child: child),
        child: Container(
          width: 112,
          height: 112,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(26),
            boxShadow: const [BoxShadow(color: Color(0x40000000), blurRadius: 28, offset: Offset(0, 12))],
          ),
          child: Image.asset('assets/branding/logo.png'),
        ),
      );
}
