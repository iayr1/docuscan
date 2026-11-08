import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:docu_scan/core/storage/file_store.dart';
import 'package:docu_scan/data/database/app_database.dart';
import 'package:docu_scan/data/models/models.dart';
import 'package:docu_scan/data/repositories/document_repository.dart';
import 'package:docu_scan/data/repositories/folder_repository.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  late AppDatabase db;
  late FileStore fileStore;
  late Directory tempDir;
  late DocumentRepository docRepo;
  late FolderRepository folderRepo;

  setUp(() async {
    tempDir = Directory.systemTemp.createTempSync('db_test');
    fileStore = FileStore(tempDir);
    await fileStore.ensureStructure();

    db = await AppDatabase.open(
      inMemoryDatabasePath,
      factory: databaseFactoryFfi,
    );

    docRepo = DocumentRepository(db, fileStore);
    folderRepo = FolderRepository(db);
  });

  tearDown(() async {
    await db.close();
    try {
      tempDir.deleteSync(recursive: true);
    } catch (_) {}
  });

  test('Folder CRUD operations', () async {
    final folder = await folderRepo.create('Work Invoices');
    expect(folder.name, 'Work Invoices');

    final list = await folderRepo.list();
    expect(list.length, 1);
    expect(list.first.id, folder.id);

    await folderRepo.rename(folder.id, 'Personal Invoices');
    final updated = (await folderRepo.list()).first;
    expect(updated.name, 'Personal Invoices');

    await folderRepo.delete(folder.id, docRepo);
    expect((await folderRepo.list()).isEmpty, isTrue);
  });

  test('Document creation, favorite, rename and trash operations', () async {
    // Create valid test JPEG image file
    final testImage = img.Image(width: 10, height: 10);
    img.fill(testImage, color: img.ColorRgb8(240, 240, 240));
    final imgFile = File('${fileStore.temp.path}/sample.jpg')..writeAsBytesSync(img.encodeJpg(testImage));

    final doc = await docRepo.createDocument(
      title: 'Employment Contract',
      mode: ScanMode.document,
      pages: [PageDraft(imgFile.path, preProcessed: true)],
    );

    expect(doc.title, 'Employment Contract');
    expect(doc.pageCount, 1);

    // Toggle favorite
    await docRepo.setFavorite(doc.id, true);
    final favDoc = await docRepo.getDocument(doc.id);
    expect(favDoc!.isFavorite, isTrue);

    // Rename
    await docRepo.rename(doc.id, 'Signed Contract');
    final renamed = await docRepo.getDocument(doc.id);
    expect(renamed!.title, 'Signed Contract');

    // Move to trash
    await docRepo.trashDocuments([doc.id]);
    final regularList = await docRepo.listDocuments(const DocumentQuery());
    expect(regularList.any((d) => d.id == doc.id), isFalse);

    final trashList = await docRepo.listDocuments(const DocumentQuery(trashed: true));
    expect(trashList.any((d) => d.id == doc.id), isTrue);

    // Restore from trash
    await docRepo.restoreDocuments([doc.id]);
    final restoredList = await docRepo.listDocuments(const DocumentQuery());
    expect(restoredList.any((d) => d.id == doc.id), isTrue);
  });
}
