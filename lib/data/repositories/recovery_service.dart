import 'dart:io';

import 'package:path/path.dart' as p;

import '../../core/storage/file_store.dart';
import '../database/app_database.dart';
import 'document_repository.dart';

class RecoveryReport {
  RecoveryReport({this.orphanDirs = 0, this.expiredTrash = 0, this.missingPages = 0});
  int orphanDirs;
  int expiredTrash;
  int missingPages;
  @override
  String toString() => 'orphans=$orphanDirs expired=$expiredTrash missing=$missingPages';
}

/// Startup housekeeping that keeps the filesystem and the database in sync
/// after crashes, kills or interrupted operations.
class RecoveryService {
  RecoveryService(this._db, this._docs, this._files);
  final AppDatabase _db;
  final DocumentRepository _docs;
  final FileStore _files;

  Future<RecoveryReport> run() async {
    final report = RecoveryReport();
    await _files.ensureStructure();
    await _files.purgeTrashDir();
    await _files.clearTemp();
    report.expiredTrash = await _docs.purgeExpiredTrash();

    // Document folders on disk that have no DB row (crash between file
    // writes and the DB commit, or between DB delete and file delete).
    final known = await _docs.referencedDocumentIds();
    for (final base in [_files.scanned, _files.thumbs, _files.vault]) {
      if (!await base.exists()) continue;
      await for (final e in base.list()) {
        if (e is Directory && !known.contains(p.basename(e.path))) {
          await e.delete(recursive: true);
          report.orphanDirs++;
        }
      }
    }
    // Stray partial writes from interrupted atomic writes.
    await for (final e in _files.root.list(recursive: true)) {
      if (e is File && (e.path.endsWith('.part') || e.path.endsWith('.tmp'))) {
        try {
          await e.delete();
        } catch (_) {}
      }
    }
    // Pages whose image vanished (e.g. user cleared app files partially).
    final rows = await _db.db.query('pages', columns: ['id', 'image_path']);
    for (final r in rows) {
      if (!await _files.file(r['image_path'] as String).exists()) report.missingPages++;
    }
    return report;
  }
}
