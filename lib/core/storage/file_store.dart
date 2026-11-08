import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import '../constants/app_constants.dart';
import '../errors/app_exception.dart';

const _uuid = Uuid();
String newId() => _uuid.v4();

/// Owns the on-device folder structure. Large binaries (images, PDFs,
/// signatures) live here; SQLite only stores their relative paths.
///
/// ```
/// DocumentScanner/
///   ScannedImages/<docId>/<pageId>_orig.jpg   original capture (kept for revert)
///   ScannedImages/<docId>/<pageId>.jpg        processed page
///   Thumbnails/<docId>/<pageId>.jpg
///   PDF/  Signatures/  Stamps/  OCR/  Exports/
///   Temp/  Sessions/<sessionId>/  Trash/  SecureVault/<docId>/
/// ```
class FileStore {
  FileStore(this.root);

  final Directory root;

  static Future<FileStore> open() async {
    final docs = await getApplicationDocumentsDirectory();
    final store = FileStore(Directory(p.join(docs.path, AppConstants.rootFolderName)));
    await store.ensureStructure();
    return store;
  }

  Future<void> ensureStructure() async {
    for (final name in StorageDirs.all) {
      await Directory(p.join(root.path, name)).create(recursive: true);
    }
  }

  Directory dir(String name) => Directory(p.join(root.path, name));
  Directory get scanned => dir(StorageDirs.scannedImages);
  Directory get thumbs => dir(StorageDirs.thumbnails);
  Directory get pdf => dir(StorageDirs.pdf);
  Directory get signatures => dir(StorageDirs.signatures);
  Directory get stamps => dir(StorageDirs.stamps);
  Directory get ocr => dir(StorageDirs.ocr);
  Directory get temp => dir(StorageDirs.temp);
  Directory get trash => dir(StorageDirs.trash);
  Directory get vault => dir(StorageDirs.secureVault);
  Directory get exports => dir(StorageDirs.exports);
  Directory get sessions => dir(StorageDirs.sessions);

  /// Absolute path from a path stored relative to [root].
  String abs(String relative) => p.isAbsolute(relative) ? relative : p.join(root.path, relative);

  /// Relative (portable) path for persisting in the database.
  String rel(String absolute) => p.isWithin(root.path, absolute)
      ? p.relative(absolute, from: root.path).replaceAll('\\', '/')
      : absolute;

  File file(String relative) => File(abs(relative));

  String originalRel(String docId, String pageId) => '${StorageDirs.scannedImages}/$docId/${pageId}_orig.jpg';
  String processedRel(String docId, String pageId, [int version = 0]) =>
      '${StorageDirs.scannedImages}/$docId/$pageId${version == 0 ? '' : '_v$version'}.jpg';
  String thumbRel(String docId, String pageId, [int version = 0]) =>
      '${StorageDirs.thumbnails}/$docId/$pageId${version == 0 ? '' : '_v$version'}.jpg';

  Future<File> newTempFile(String extension) async {
    await temp.create(recursive: true);
    return File(p.join(temp.path, '${newId()}.$extension'));
  }

  Future<Directory> newTempDir() async {
    final d = Directory(p.join(temp.path, newId()));
    await d.create(recursive: true);
    return d;
  }

  /// Crash-safe write: data goes to a sibling temp file which is then renamed.
  Future<File> writeAtomic(String relativeOrAbsolute, Uint8List bytes) async {
    final target = File(abs(relativeOrAbsolute));
    await target.parent.create(recursive: true);
    final tmp = File('${target.path}.${newId().substring(0, 8)}.part');
    try {
      await tmp.writeAsBytes(bytes, flush: true);
      if (await target.exists()) await target.delete();
      return await tmp.rename(target.path);
    } on FileSystemException catch (e) {
      if (await tmp.exists()) await tmp.delete();
      if (e.osError?.errorCode == 28 || e.message.contains('No space')) {
        throw const InsufficientStorageException();
      }
      throw StorageException('Could not save file', cause: e);
    }
  }

  Future<File> copyInto(String sourceAbsolute, String targetRelative) async {
    final target = File(abs(targetRelative));
    await target.parent.create(recursive: true);
    try {
      return await File(sourceAbsolute).copy(target.path);
    } on FileSystemException catch (e) {
      if (e.osError?.errorCode == 28) throw const InsufficientStorageException();
      throw StorageException('Could not copy file', cause: e);
    }
  }

  Future<void> deleteIfExists(String? relative) async {
    if (relative == null || relative.isEmpty) return;
    final f = File(abs(relative));
    if (await f.exists()) await f.delete();
  }

  /// Crash-safe recursive delete: the directory is first renamed into Trash
  /// (atomic), then removed. Leftovers are purged by [purgeTrashDir] on start.
  Future<void> deleteDocumentFiles(String docId) async {
    for (final base in [scanned, thumbs, vault]) {
      final d = Directory(p.join(base.path, docId));
      if (!await d.exists()) continue;
      final staged = Directory(p.join(trash.path, '${p.basename(base.path)}_${docId}_${newId().substring(0, 6)}'));
      try {
        await d.rename(staged.path);
        await staged.delete(recursive: true);
      } on FileSystemException {
        if (await d.exists()) await d.delete(recursive: true);
      }
    }
  }

  Future<void> purgeTrashDir() async {
    if (!await trash.exists()) return;
    await for (final e in trash.list()) {
      try {
        await e.delete(recursive: true);
      } catch (_) {}
    }
  }

  Future<void> clearTemp() async {
    for (final d in [temp]) {
      if (!await d.exists()) continue;
      await for (final e in d.list()) {
        try {
          await e.delete(recursive: true);
        } catch (_) {}
      }
    }
  }

  static Future<int> sizeOf(FileSystemEntity entity) async {
    if (entity is File) return await entity.exists() ? entity.length() : 0;
    if (entity is! Directory || !await entity.exists()) return 0;
    var total = 0;
    await for (final e in entity.list(recursive: true, followLinks: false)) {
      if (e is File) {
        try {
          total += await e.length();
        } catch (_) {}
      }
    }
    return total;
  }

  Future<Map<String, int>> usageByDirectory() async => {
        for (final name in StorageDirs.all) name: await sizeOf(dir(name)),
      };

  /// Ids of document folders that physically exist on disk.
  Future<Set<String>> documentDirIds() async {
    final ids = <String>{};
    for (final base in [scanned, thumbs]) {
      if (!await base.exists()) continue;
      await for (final e in base.list()) {
        if (e is Directory) ids.add(p.basename(e.path));
      }
    }
    return ids;
  }
}
