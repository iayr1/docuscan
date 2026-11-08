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

class DocuScanApp extends ConsumerWidget {
  const DocuScanApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider);

    return MaterialApp(
      title: 'DocuScan',
      debugShowCheckedModeBanner: false,
      themeMode: settings.themeMode,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      home: const AppShell(),
    );
  }
}
