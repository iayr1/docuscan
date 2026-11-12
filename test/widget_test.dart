import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:docu_scan/app/providers.dart';
import 'package:docu_scan/core/services/security_service.dart';
import 'package:docu_scan/core/storage/file_store.dart';
import 'package:docu_scan/core/storage/settings_store.dart';
import 'package:docu_scan/data/database/app_database.dart';
import 'package:docu_scan/main.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  late AppDatabase db;
  late FileStore fileStore;
  late SettingsStore settingsStore;
  late Directory tempDir;

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    settingsStore = SettingsStore(prefs);

    tempDir = Directory.systemTemp.createTempSync('docscanner_test');
    fileStore = FileStore(tempDir);
    await fileStore.ensureStructure();

    db = await AppDatabase.open(
      inMemoryDatabasePath,
      factory: databaseFactoryFfi,
    );
  });

  tearDownAll(() async {
    await db.close();
    try {
      tempDir.deleteSync(recursive: true);
    } catch (_) {}
  });

  testWidgets('DocuScanApp boots and renders navigation shell', (tester) async {
    await tester.runAsync(() async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            databaseProvider.overrideWithValue(db),
            fileStoreProvider.overrideWithValue(fileStore),
            settingsStoreProvider.overrideWithValue(settingsStore),
            secretStoreProvider.overrideWithValue(MemorySecretStore()),
            ocrServiceProvider.overrideWithValue(null),
          ],
          child: const DocuScanApp(),
        ),
      );

      await tester.pump();
      // Wait past the startup splash and its cross-fade.
      await Future<void>.delayed(const Duration(milliseconds: 1300));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await Future<void>.delayed(const Duration(milliseconds: 150));
      await tester.pump();

      // Verify app navigation destinations
      expect(find.text('Home'), findsWidgets);
      expect(find.text('Documents'), findsWidgets);
      expect(find.text('Tools'), findsWidgets);
      expect(find.text('OCR'), findsWidgets);
    });
  });
}
