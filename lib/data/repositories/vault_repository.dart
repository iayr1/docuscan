import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../../core/constants/app_constants.dart';
import '../../core/services/security_service.dart';
import '../../core/storage/file_store.dart';
import '../database/app_database.dart';
import '../models/models.dart';
import 'document_repository.dart';

/// Secure vault: moves a document's page files into `SecureVault/<docId>/`
/// encrypted with AES-256-GCM, and back.
///
/// Order of operations keeps data safe if the app is killed midway:
/// 1. write all encrypted copies, 2. switch DB paths in one transaction,
/// 3. delete the plaintext files. A crash before (2) leaves the plaintext
/// document intact (orphan .enc files are cleaned at startup); a crash after
/// (2) leaves only stray plaintext files, which are also cleaned up.
class VaultRepository {
  VaultRepository(this._db, this._docs, this._files, this._security);

  final AppDatabase _db;
  final DocumentRepository _docs;
  final FileStore _files;
  final SecurityService _security;

  Future<void> moveToVault(String docId) async {
    final pages = await _docs.getPages(docId);
    final updates = <String, Map<String, String?>>{};
    final plainFiles = <String>{};
    final written = <String>[];
    try {
      for (final page in pages) {
        final map = <String, String?>{};
        for (final (column, rel) in [
          ('original_path', page.originalPath),
          ('image_path', page.imagePath),
          ('thumbnail_path', page.thumbnailPath),
        ]) {
          if (rel == null) continue;
          final target = '${StorageDirs.secureVault}/$docId/${p.basename(rel)}.enc';
          if (!written.contains(target)) {
            final sealed = await _security.encryptBytes(await _files.file(rel).readAsBytes());
            await _files.writeAtomic(target, sealed);
            written.add(target);
          }
          map[column] = target;
          plainFiles.add(rel);
        }
        updates[page.id] = map;
      }
      // Keep the cover thumbnail (now encrypted) so the vault list can show it.
      final cover = pages.isEmpty ? null : updates[pages.first.id]?['thumbnail_path'];
      await _docs.setVaultState(docId, true, updates, thumbnail: cover);
    } catch (_) {
      for (final w in written) {
        await _files.deleteIfExists(w);
      }
      rethrow;
    }
    // OCR text would leak vault content through search: drop it.
    await _db.db.delete('ocr_results', where: 'document_id = ?', whereArgs: [docId]);
    await _db.db.delete('favorites', where: 'document_id = ?', whereArgs: [docId]);
    for (final f in plainFiles) {
      await _files.deleteIfExists(f);
    }
    _db.notify({'documents', 'ocr_results', 'favorites'});
  }

  Future<void> removeFromVault(String docId) async {
    final pages = await _docs.getPages(docId);
    final updates = <String, Map<String, String?>>{};
    final sealedFiles = <String>{};
    final written = <String, String>{};
    String? thumb;
    try {
      for (final page in pages) {
        final map = <String, String?>{};
        for (final (column, rel) in [
          ('original_path', page.originalPath),
          ('image_path', page.imagePath),
          ('thumbnail_path', page.thumbnailPath),
        ]) {
          if (rel == null) continue;
          final base = p.basename(rel).replaceAll('.enc', '');
          final dir = column == 'thumbnail_path' ? StorageDirs.thumbnails : StorageDirs.scannedImages;
          final target = '$dir/$docId/$base';
          if (!written.containsKey(rel)) {
            final plain = await _security.decryptBytes(await _files.file(rel).readAsBytes());
            await _files.writeAtomic(target, plain);
            written[rel] = target;
          }
          map[column] = target;
          sealedFiles.add(rel);
        }
        updates[page.id] = map;
        if (page.index == 0) thumb = map['thumbnail_path'];
      }
      await _docs.setVaultState(docId, false, updates, thumbnail: thumb);
    } catch (_) {
      for (final w in written.values) {
        await _files.deleteIfExists(w);
      }
      rethrow;
    }
    for (final f in sealedFiles) {
      await _files.deleteIfExists(f);
    }
  }

  /// Decrypts a vault file into memory (never touches disk).
  Future<Uint8List> readDecrypted(String relativePath) async =>
      _security.decryptBytes(await _files.file(relativePath).readAsBytes());

  /// Decrypts all page images of a vault document into a temp directory for
  /// sharing/exporting. The Temp folder is wiped at every app start.
  Future<List<String>> decryptPagesToTemp(String docId) async {
    final dir = await _files.newTempDir();
    final out = <String>[];
    for (final page in await _docs.getPages(docId)) {
      final f = File(p.join(dir.path, 'page_${page.index + 1}.jpg'));
      await f.writeAsBytes(await readDecrypted(page.imagePath), flush: true);
      out.add(f.path);
    }
    return out;
  }

  static bool isVaultDoc(Document d) => d.inVault;
}
