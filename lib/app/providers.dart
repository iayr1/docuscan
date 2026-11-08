import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/image/image_service.dart';
import '../core/services/ocr_service.dart';
import '../core/services/pdf_service.dart';
import '../core/services/pdf_tools_service.dart';
import '../core/services/security_service.dart';
import '../core/storage/file_store.dart';
import '../core/storage/settings_store.dart';
import '../data/database/app_database.dart';
import '../data/models/models.dart';
import '../data/repositories/asset_repository.dart';
import '../data/repositories/conversion_repository.dart';
import '../data/repositories/document_repository.dart';
import '../data/repositories/export_repository.dart';
import '../data/repositories/folder_repository.dart';
import '../data/repositories/scan_session_store.dart';
import '../data/repositories/vault_repository.dart';

// ------------------------------------------------------------ infrastructure
// These are overridden in main() with instances opened during bootstrap.

final databaseProvider = Provider<AppDatabase>((ref) => throw UnimplementedError('databaseProvider not overridden'));
final fileStoreProvider = Provider<FileStore>((ref) => throw UnimplementedError('fileStoreProvider not overridden'));
final settingsStoreProvider = Provider<SettingsStore>((ref) => throw UnimplementedError('settingsStoreProvider not overridden'));
final secretStoreProvider = Provider<SecretStore>((ref) => PlatformSecretStore());

final imageServiceProvider = Provider((ref) => const ImageService());
final pdfServiceProvider = Provider((ref) => const PdfService());
final pdfToolsProvider = Provider((ref) => PdfToolsService(images: ref.watch(imageServiceProvider), pdf: ref.watch(pdfServiceProvider)));
final securityServiceProvider = Provider((ref) => SecurityService(ref.watch(secretStoreProvider)));

/// Nullable so widget tests (no ML Kit platform channel) can override with null.
final ocrServiceProvider = Provider<OcrService?>((ref) {
  final s = OcrService();
  ref.onDispose(s.dispose);
  return s;
});

// -------------------------------------------------------------- repositories

final documentRepositoryProvider = Provider((ref) {
  final repo = DocumentRepository(ref.watch(databaseProvider), ref.watch(fileStoreProvider), images: ref.watch(imageServiceProvider));
  repo.keepOriginals = ref.read(settingsProvider).saveOriginal;
  ref.listen(settingsProvider.select((s) => s.saveOriginal), (_, v) => repo.keepOriginals = v);
  return repo;
});
final folderRepositoryProvider = Provider((ref) => FolderRepository(ref.watch(databaseProvider)));
final tagRepositoryProvider = Provider((ref) => TagRepository(ref.watch(databaseProvider)));
final assetRepositoryProvider = Provider((ref) => AssetRepository(ref.watch(databaseProvider), ref.watch(fileStoreProvider)));
final vaultRepositoryProvider = Provider((ref) => VaultRepository(
      ref.watch(databaseProvider),
      ref.watch(documentRepositoryProvider),
      ref.watch(fileStoreProvider),
      ref.watch(securityServiceProvider),
    ));
final exportRepositoryProvider = Provider((ref) => ExportRepository(
      ref.watch(documentRepositoryProvider),
      ref.watch(assetRepositoryProvider),
      ref.watch(vaultRepositoryProvider),
      ref.watch(fileStoreProvider),
      pdf: ref.watch(pdfServiceProvider),
      tools: ref.watch(pdfToolsProvider),
      images: ref.watch(imageServiceProvider),
    ));
final conversionRepositoryProvider = Provider((ref) => ConversionRepository(
      ref.watch(documentRepositoryProvider),
      ref.watch(assetRepositoryProvider),
      ref.watch(fileStoreProvider),
      ref.watch(ocrServiceProvider),
      tools: ref.watch(pdfToolsProvider),
      pdf: ref.watch(pdfServiceProvider),
      images: ref.watch(imageServiceProvider),
    ));
final scanSessionStoreProvider = Provider((ref) => ScanSessionStore(ref.watch(fileStoreProvider)));

// ------------------------------------------------------------------ settings

class SettingsNotifier extends Notifier<AppSettings> {
  @override
  AppSettings build() => ref.watch(settingsStoreProvider).load();

  Future<void> update(AppSettings Function(AppSettings) change) async {
    state = change(state);
    await ref.read(settingsStoreProvider).save(state);
  }

  Future<void> reset() async {
    await ref.read(settingsStoreProvider).reset();
    state = ref.read(settingsStoreProvider).load();
  }
}

final settingsProvider = NotifierProvider<SettingsNotifier, AppSettings>(SettingsNotifier.new);

// ------------------------------------------------------- reactive data layer

/// Increments whenever the database reports a write. Data providers watch it,
/// so every screen refreshes automatically after any mutation.
class DbRevision extends Notifier<int> {
  @override
  int build() {
    final sub = ref.watch(databaseProvider).changes.listen((_) => state++);
    ref.onDispose(sub.cancel);
    return 0;
  }
}

final dbRevisionProvider = NotifierProvider<DbRevision, int>(DbRevision.new);

final documentsProvider = FutureProvider.family<List<Document>, DocumentQuery>((ref, q) {
  ref.watch(dbRevisionProvider);
  return ref.watch(documentRepositoryProvider).listDocuments(q);
});

final documentProvider = FutureProvider.family<Document?, String>((ref, id) {
  ref.watch(dbRevisionProvider);
  return ref.watch(documentRepositoryProvider).getDocument(id);
});

final pagesProvider = FutureProvider.family<List<DocPage>, String>((ref, id) {
  ref.watch(dbRevisionProvider);
  return ref.watch(documentRepositoryProvider).getPages(id);
});

final recentDocumentsProvider = FutureProvider<List<Document>>((ref) {
  ref.watch(dbRevisionProvider);
  return ref.watch(documentRepositoryProvider).recentDocuments(limit: 12);
});

final statsProvider = FutureProvider<LibraryStats>((ref) {
  ref.watch(dbRevisionProvider);
  return ref.watch(documentRepositoryProvider).stats();
});

final foldersProvider = FutureProvider.family<List<Folder>, String?>((ref, parentId) {
  ref.watch(dbRevisionProvider);
  return ref.watch(folderRepositoryProvider).list(parentId: parentId);
});

final allFoldersProvider = FutureProvider<List<Folder>>((ref) {
  ref.watch(dbRevisionProvider);
  return ref.watch(folderRepositoryProvider).list(all: true);
});

final folderPathProvider = FutureProvider.family<List<Folder>, String>((ref, id) {
  ref.watch(dbRevisionProvider);
  return ref.watch(folderRepositoryProvider).path(id);
});

final tagsProvider = FutureProvider<List<Tag>>((ref) {
  ref.watch(dbRevisionProvider);
  return ref.watch(tagRepositoryProvider).list();
});

final signaturesProvider = FutureProvider<List<Signature>>((ref) {
  ref.watch(dbRevisionProvider);
  return ref.watch(assetRepositoryProvider).signatures();
});

final stampsProvider = FutureProvider<List<Stamp>>((ref) {
  ref.watch(dbRevisionProvider);
  return ref.watch(assetRepositoryProvider).stamps();
});

final documentOcrProvider = FutureProvider.family<Map<String, OcrResult>, String>((ref, docId) {
  ref.watch(dbRevisionProvider);
  return ref.watch(assetRepositoryProvider).ocrForDocument(docId);
});

final documentAnnotationsProvider = FutureProvider.family<Map<String, List<Annotation>>, String>((ref, docId) {
  ref.watch(dbRevisionProvider);
  return ref.watch(assetRepositoryProvider).annotationsForDocument(docId);
});

final historyProvider = FutureProvider<List<HistoryEntry>>((ref) {
  ref.watch(dbRevisionProvider);
  return ref.watch(documentRepositoryProvider).history(limit: 100);
});

final recentExportsProvider = FutureProvider<List<ExportRecord>>((ref) {
  ref.watch(dbRevisionProvider);
  return ref.watch(documentRepositoryProvider).recentExports(limit: 30);
});

final duplicatesProvider = FutureProvider<List<List<Document>>>((ref) {
  ref.watch(dbRevisionProvider);
  return ref.watch(documentRepositoryProvider).findDuplicates();
});

final pendingSessionsProvider = FutureProvider<List<ScanSession>>((ref) {
  ref.watch(dbRevisionProvider);
  return ref.watch(scanSessionStoreProvider).pending();
});

final storageUsageProvider = FutureProvider<Map<String, int>>((ref) {
  ref.watch(dbRevisionProvider);
  return ref.watch(fileStoreProvider).usageByDirectory();
});

// ------------------------------------------------------------------ security

/// Whether the whole app is currently locked behind PIN/biometrics.
class AppLockNotifier extends Notifier<bool> {
  DateTime? _pausedAt;

  @override
  bool build() => ref.read(settingsProvider).appLockEnabled;

  void unlock() => state = false;
  void lock() => state = true;

  void onPaused() => _pausedAt = DateTime.now();

  void onResumed() {
    final s = ref.read(settingsProvider);
    if (!s.appLockEnabled || _pausedAt == null) return;
    if (DateTime.now().difference(_pausedAt!).inSeconds >= s.autoLockSeconds) state = true;
    _pausedAt = null;
  }
}

final appLockProvider = NotifierProvider<AppLockNotifier, bool>(AppLockNotifier.new);

/// The vault must be unlocked separately; it re-locks whenever the app is
/// backgrounded or the vault screen is closed.
class VaultUnlockNotifier extends Notifier<bool> {
  @override
  bool build() => false;
  void set(bool v) => state = v;
}

final vaultUnlockedProvider = NotifierProvider<VaultUnlockNotifier, bool>(VaultUnlockNotifier.new);

/// Ids of individually locked documents unlocked during this session.
class UnlockedDocsNotifier extends Notifier<Set<String>> {
  @override
  Set<String> build() => const {};
  void add(String id) => state = {...state, id};
  void clear() => state = const {};
}

final unlockedDocsProvider = NotifierProvider<UnlockedDocsNotifier, Set<String>>(UnlockedDocsNotifier.new);

/// Shell tab index (lets screens jump to other tabs).
class ShellTabNotifier extends Notifier<int> {
  @override
  int build() => 0;
  void go(int i) => state = i;
}

final shellTabProvider = NotifierProvider<ShellTabNotifier, int>(ShellTabNotifier.new);

Timer? debounce(Timer? t, Duration d, void Function() f) {
  t?.cancel();
  return Timer(d, f);
}
