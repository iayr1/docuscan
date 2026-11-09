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
      home: _showSplash ? const _StartupSplash() : const AppShell(),
    );
  }
}

class _StartupSplash extends StatelessWidget {
  const _StartupSplash();

  @override
  Widget build(BuildContext context) => const Scaffold(
    backgroundColor: AppColors.brand,
    body: Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.document_scanner_rounded, size: 76, color: Colors.white),
          SizedBox(height: 18),
          Text(
            'DocuScan',
            style: TextStyle(
              color: Colors.white,
              fontSize: 28,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.3,
            ),
          ),
          SizedBox(height: 28),
          SizedBox(
            width: 24,
            height: 24,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: Colors.white70,
            ),
          ),
        ],
      ),
    ),
  );
}
