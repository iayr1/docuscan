import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:sqflite/sqflite.dart';

import '../../core/constants/app_constants.dart';
import '../../core/errors/app_exception.dart';
import '../../core/image/image_service.dart';
import '../../core/image/image_types.dart';
import '../../core/storage/file_store.dart';
import '../database/app_database.dart';
import '../models/models.dart';

/// Input for creating a page: a source image on disk plus the edits to apply.
class PageDraft {
  const PageDraft(this.sourcePath, {this.edit = const PageEdit(), this.preProcessed = false});

  /// Absolute path of the captured / imported image.
  final String sourcePath;
  final PageEdit edit;

  /// True when [sourcePath] is already a finished page (e.g. rendered from a
  /// PDF) and should be stored without re-rendering.
  final bool preProcessed;
}

typedef ProgressCallback = void Function(int done, int total);

/// All document and page persistence. Every multi-step operation writes
/// files first, then commits the DB in a single transaction; if the
/// transaction fails, the newly written files are removed so the DB and the
/// filesystem never disagree.
class DocumentRepository {
  DocumentRepository(this._db, this.files, {ImageService images = const ImageService(), this.keepOriginals = true})
      // ignore: prefer_initializing_formals
      : _images = images;

  final AppDatabase _db;
  final FileStore files;
  final ImageService _images;

  /// When false, the original capture is not kept (saves space; edits then
  /// start from the processed image).
  bool keepOriginals;

  Database get _sql => _db.db;
  int get _now => DateTime.now().millisecondsSinceEpoch;

  static const _docTables = {'documents', 'pages', 'favorites', 'document_tags', 'trash', 'scan_history'};

  // ---------------------------------------------------------------- queries

  static const _docSelect = '''
    SELECT d.*, (f.document_id IS NOT NULL) AS is_favorite, fo.name AS folder_name
    FROM documents d
    LEFT JOIN favorites f ON f.document_id = d.id
    LEFT JOIN folders fo ON fo.id = d.folder_id
  ''';

  Future<List<Document>> listDocuments(DocumentQuery q) async {
    final where = <String>[];
    final args = <Object?>[];
    where.add(q.trashed ? 'd.deleted_at IS NOT NULL' : 'd.deleted_at IS NULL');
    if (!q.trashed) {
      where.add('d.in_vault = ?');
      args.add(q.vault ? 1 : 0);
    }
    if (!q.includeHidden && !q.vault && !q.trashed) where.add('d.is_hidden = 0');
    if (!q.allFolders) {
      if (q.folderId == null) {
        where.add('d.folder_id IS NULL');
      } else {
        where.add('d.folder_id = ?');
        args.add(q.folderId);
      }
    }
    if (q.favoritesOnly) where.add('f.document_id IS NOT NULL');
    if (q.category != null) {
      where.add('d.category = ?');
      args.add(q.category);
    }
    if (q.tagId != null) {
      where.add('EXISTS (SELECT 1 FROM document_tags dt WHERE dt.document_id = d.id AND dt.tag_id = ?)');
      args.add(q.tagId);
    }
    final s = q.search?.trim();
    if (s != null && s.isNotEmpty) {
      final like = '%${s.replaceAll('%', r'\%').replaceAll('_', r'\_')}%';
      where.add(r'''(
        d.title LIKE ? ESCAPE '\' OR d.description LIKE ? ESCAPE '\' OR d.notes LIKE ? ESCAPE '\'
        OR fo.name LIKE ? ESCAPE '\'
        OR EXISTS (SELECT 1 FROM document_tags dt JOIN tags t ON t.id = dt.tag_id
                   WHERE dt.document_id = d.id AND t.name LIKE ? ESCAPE '\')
        OR EXISTS (SELECT 1 FROM ocr_results o WHERE o.document_id = d.id AND o.text LIKE ? ESCAPE '\')
      )''');
      args.addAll(List.filled(6, like));
    }
    final sql = StringBuffer(_docSelect)
      ..write(' WHERE ${where.join(' AND ')}')
      ..write(' ORDER BY ${q.trashed ? 'd.deleted_at DESC' : q.sort.sql}');
    if (q.limit != null) sql.write(' LIMIT ${q.limit} OFFSET ${q.offset}');
    final rows = await _sql.rawQuery(sql.toString(), args);
    final tags = await _tagsFor(rows.map((r) => r['id'] as String).toList());
    return [for (final r in rows) Document.fromRow(r, tags: tags[r['id']] ?? const [])];
  }

  Future<Map<String, List<Tag>>> _tagsFor(List<String> ids) async {
    if (ids.isEmpty) return const {};
    final out = <String, List<Tag>>{};
    // Chunk to stay below SQLite's variable limit.
    for (var i = 0; i < ids.length; i += 500) {
      final chunk = ids.sublist(i, i + 500 > ids.length ? ids.length : i + 500);
      final rows = await _sql.rawQuery(
        'SELECT dt.document_id, t.* FROM document_tags dt JOIN tags t ON t.id = dt.tag_id '
        'WHERE dt.document_id IN (${List.filled(chunk.length, '?').join(',')}) ORDER BY t.name',
        chunk,
      );
      for (final r in rows) {
        (out[r['document_id'] as String] ??= []).add(Tag.fromRow(r));
      }
    }
    return out;
  }

  Future<Document?> getDocument(String id) async {
    final rows = await _sql.rawQuery('$_docSelect WHERE d.id = ?', [id]);
    if (rows.isEmpty) return null;
    final tags = await _tagsFor([id]);
    return Document.fromRow(rows.first, tags: tags[id] ?? const []);
  }

  Future<List<DocPage>> getPages(String documentId) async {
    final rows = await _sql.query('pages', where: 'document_id = ?', whereArgs: [documentId], orderBy: 'page_index');
    return rows.map(DocPage.fromRow).toList();
  }

  Future<DocPage?> getPage(String pageId) async {
    final rows = await _sql.query('pages', where: 'id = ?', whereArgs: [pageId]);
    return rows.isEmpty ? null : DocPage.fromRow(rows.first);
  }

  Future<List<Document>> recentDocuments({int limit = 10}) async {
    final rows = await _sql.rawQuery(
      '$_docSelect WHERE d.deleted_at IS NULL AND d.in_vault = 0 AND d.is_hidden = 0 '
      'ORDER BY COALESCE(d.last_opened_at, d.updated_at) DESC LIMIT ?',
      [limit],
    );
    return rows.map((r) => Document.fromRow(r)).toList();
  }

  Future<LibraryStats> stats() async {
    final r = (await _sql.rawQuery('''
      SELECT
        (SELECT COUNT(*) FROM documents WHERE deleted_at IS NULL) AS docs,
        (SELECT COALESCE(SUM(page_count),0) FROM documents WHERE deleted_at IS NULL) AS pages,
        (SELECT COUNT(*) FROM folders) AS folders,
        (SELECT COUNT(*) FROM favorites fa JOIN documents d ON d.id = fa.document_id WHERE d.deleted_at IS NULL) AS favs,
        (SELECT COUNT(*) FROM documents WHERE deleted_at IS NOT NULL) AS trashed,
        (SELECT COALESCE(SUM(file_size),0) FROM documents) AS bytes,
        (SELECT COUNT(*) FROM scan_history WHERE action = 'scan' AND created_at >= ?) AS month
    ''', [DateTime(DateTime.now().year, DateTime.now().month).millisecondsSinceEpoch])).first;
    return LibraryStats(
      documents: r['docs'] as int,
      pages: r['pages'] as int,
      folders: r['folders'] as int,
      favorites: r['favs'] as int,
      trashed: r['trashed'] as int,
      bytes: r['bytes'] as int,
      scansThisMonth: r['month'] as int,
    );
  }

  /// Groups of live documents whose page content hashes are identical.
  Future<List<List<Document>>> findDuplicates() async {
    final rows = await _sql.rawQuery('''
      $_docSelect WHERE d.deleted_at IS NULL AND d.content_hash IS NOT NULL AND d.content_hash IN (
        SELECT content_hash FROM documents WHERE deleted_at IS NULL AND content_hash IS NOT NULL
        GROUP BY content_hash HAVING COUNT(*) > 1)
      ORDER BY d.content_hash, d.created_at
    ''');
    final groups = <String, List<Document>>{};
    for (final r in rows) {
      (groups[r['content_hash'] as String] ??= []).add(Document.fromRow(r));
    }
    return groups.values.toList();
  }

  /// Returns an existing live document with the same content, if any.
  Future<Document?> findDuplicateOf(List<String> sourcePaths) async {
    final hashes = <String>[];
    for (final p in sourcePaths) {
      hashes.add(sha256.convert(await File(p).readAsBytes()).toString());
    }
    final docHash = sha256.convert(utf8.encode(hashes.join('|'))).toString();
    final rows = await _sql.rawQuery('$_docSelect WHERE d.content_hash = ? AND d.deleted_at IS NULL LIMIT 1', [docHash]);
    return rows.isEmpty ? null : Document.fromRow(rows.first);
  }

  Future<List<HistoryEntry>> history({int limit = 50}) async {
    final rows = await _sql.rawQuery(
      'SELECT h.*, d.title FROM scan_history h LEFT JOIN documents d ON d.id = h.document_id ORDER BY h.created_at DESC LIMIT ?',
      [limit],
    );
    return rows.map(HistoryEntry.fromRow).toList();
  }

  Future<void> logHistory(String action, {String? documentId, String mode = 'tool', int pageCount = 0, String? detail}) async {
    await _sql.insert('scan_history', {
      'id': newId(),
      'document_id': documentId,
      'mode': mode,
      'page_count': pageCount,
      'action': action,
      'detail': detail,
      'created_at': _now,
    });
    _db.notify({'scan_history'});
  }

  Future<void> logExport({String? documentId, required String title, required String format, required String target, String? path}) async {
    await _sql.insert('exports', {
      'id': newId(),
      'document_id': documentId,
      'title': title,
      'format': format,
      'target': target,
      'path': path,
      'created_at': _now,
    });
    _db.notify({'exports'});
  }

  Future<List<ExportRecord>> recentExports({int limit = 20}) async {
    final rows = await _sql.query('exports', orderBy: 'created_at DESC', limit: limit);
    return rows.map(ExportRecord.fromRow).toList();
  }

  // --------------------------------------------------------------- creation

  Future<Document> createDocument({
    required String title,
    required List<PageDraft> pages,
    String? folderId,
    ScanMode mode = ScanMode.document,
    String source = 'scan',
    String? category,
    String? description,
    ProgressCallback? onProgress,
  }) async {
    if (pages.isEmpty) throw const AppException('A document needs at least one page.');
    final docId = newId();
    final now = _now;
    final rows = <Map<String, Object?>>[];
    try {
      for (var i = 0; i < pages.length; i++) {
        rows.add(await _materializePage(docId, pages[i], i, now));
        onProgress?.call(i + 1, pages.length);
      }
    } catch (_) {
      await files.deleteDocumentFiles(docId);
      rethrow;
    }
    try {
      await _sql.transaction((txn) async {
        await txn.insert('documents', {
          'id': docId,
          'title': title.trim().isEmpty ? 'Untitled' : title.trim(),
          'folder_id': folderId,
          'scan_mode': mode.name,
          'source': source,
          'category': category,
          'description': description,
          'created_at': now,
          'updated_at': now,
        });
        for (final r in rows) {
          await txn.insert('pages', r);
        }
        await _recalc(txn, docId);
        await txn.insert('scan_history', {
          'id': newId(),
          'document_id': docId,
          'mode': mode.name,
          'page_count': pages.length,
          'action': source == 'scan' ? 'scan' : 'import',
          'created_at': now,
        });
      });
    } catch (e) {
      await files.deleteDocumentFiles(docId);
      throw StorageException('Could not save the document', cause: e);
    }
    _db.notify(_docTables);
    return (await getDocument(docId))!;
  }

  /// Copies the source into the document folder, renders it and returns the page row.
  Future<Map<String, Object?>> _materializePage(String docId, PageDraft draft, int index, int now) async {
    final pageId = newId();
    final version = now + index;
    final processedRel = files.processedRel(docId, pageId, version);
    final thumbRel = files.thumbRel(docId, pageId, version);
    final srcBytes = await File(draft.sourcePath).readAsBytes();
    final hash = sha256.convert(srcBytes).toString();

    late String originalRel;
    late PageEdit storedEdit;
    late ProcessedImage processed;
    if (draft.preProcessed) {
      originalRel = processedRel;
      storedEdit = const PageEdit(filter: ScanFilter.original);
      await files.copyInto(draft.sourcePath, processedRel);
      final (w, h) = await _images.dimensions(files.abs(processedRel));
      processed = ProcessedImage(bytes: srcBytes, thumbnail: await _images.thumbnail(files.abs(processedRel)), width: w, height: h);
    } else {
      processed = await _images.processPage(draft.sourcePath, draft.edit);
      if (keepOriginals) {
        originalRel = files.originalRel(docId, pageId);
        await files.copyInto(draft.sourcePath, originalRel);
        storedEdit = draft.edit;
      } else {
        // Without the original, the processed result becomes the new baseline.
        originalRel = processedRel;
        storedEdit = const PageEdit(filter: ScanFilter.original);
      }
      await files.writeAtomic(processedRel, processed.bytes);
    }
    await files.writeAtomic(thumbRel, processed.thumbnail);
    return {
      'id': pageId,
      'document_id': docId,
      'page_index': index,
      'original_path': originalRel,
      'image_path': processedRel,
      'thumbnail_path': thumbRel,
      'edit_json': jsonEncode(storedEdit.toJson()),
      'width': processed.width,
      'height': processed.height,
      'file_size': processed.bytes.length + (keepOriginals && !draft.preProcessed ? srcBytes.length : 0),
      'content_hash': hash,
      'created_at': now,
      'updated_at': now,
    };
  }

  /// Recomputes denormalised document columns from its pages.
  Future<void> _recalc(DatabaseExecutor txn, String docId) async {
    final pages = await txn.query('pages', where: 'document_id = ?', whereArgs: [docId], orderBy: 'page_index');
    final size = pages.fold<int>(0, (s, r) => s + ((r['file_size'] as int?) ?? 0));
    final hashes = pages.map((r) => r['content_hash'] ?? r['id']).join('|');
    await txn.update(
      'documents',
      {
        'page_count': pages.length,
        'file_size': size,
        'thumbnail_path': pages.isEmpty ? null : pages.first['thumbnail_path'],
        'content_hash': pages.isEmpty ? null : sha256.convert(utf8.encode(hashes)).toString(),
        'updated_at': _now,
      },
      where: 'id = ?',
      whereArgs: [docId],
    );
  }

  // ------------------------------------------------------------- metadata

  Future<void> rename(String id, String title) async {
    final t = title.trim();
    if (t.isEmpty) throw const AppException('Name cannot be empty.');
    await _sql.update('documents', {'title': t, 'updated_at': _now}, where: 'id = ?', whereArgs: [id]);
    _db.notify({'documents'});
  }

  /// Renames many documents using a pattern; `{n}` = running number, `{name}` = old name,
  /// `{date}` = creation date.
  Future<void> batchRename(List<String> ids, String pattern, {int start = 1}) async {
    final docs = <Document>[];
    for (final id in ids) {
      final d = await getDocument(id);
      if (d != null) docs.add(d);
    }
    await _sql.transaction((txn) async {
      for (var i = 0; i < docs.length; i++) {
        final d = docs[i];
        final date = '${d.createdAt.year}-${d.createdAt.month.toString().padLeft(2, '0')}-${d.createdAt.day.toString().padLeft(2, '0')}';
        var name = pattern.replaceAll('{n}', '${start + i}').replaceAll('{name}', d.title).replaceAll('{date}', date);
        if (!pattern.contains('{n}') && docs.length > 1) name = '$name ${start + i}';
        await txn.update('documents', {'title': name.trim(), 'updated_at': _now}, where: 'id = ?', whereArgs: [d.id]);
      }
    });
    _db.notify({'documents'});
  }

  Future<void> updateDetails(String id, {String? description, String? notes, String? category, bool clearCategory = false}) async {
    await _sql.update(
      'documents',
      {
        'description': ?description,
        'notes': ?notes,
        if (category != null || clearCategory) 'category': category,
        'updated_at': _now,
      },
      where: 'id = ?',
      whereArgs: [id],
    );
    _db.notify({'documents'});
  }

  Future<void> markOpened(String id) async {
    await _sql.update('documents', {'last_opened_at': _now}, where: 'id = ?', whereArgs: [id]);
    _db.notify({'documents'});
  }

  Future<void> moveDocuments(List<String> ids, String? folderId) async {
    await _sql.transaction((txn) async {
      for (final id in ids) {
        await txn.update('documents', {'folder_id': folderId, 'updated_at': _now}, where: 'id = ?', whereArgs: [id]);
      }
    });
    _db.notify({'documents', 'folders'});
  }

  Future<void> setFavorite(String id, bool favorite) async {
    if (favorite) {
      await _sql.insert('favorites', {'document_id': id, 'created_at': _now}, conflictAlgorithm: ConflictAlgorithm.ignore);
    } else {
      await _sql.delete('favorites', where: 'document_id = ?', whereArgs: [id]);
    }
    _db.notify({'favorites'});
  }

  Future<void> setFlags(String id, {bool? locked, bool? hidden}) async {
    await _sql.update(
      'documents',
      {
        if (locked != null) 'is_locked': locked ? 1 : 0,
        if (hidden != null) 'is_hidden': hidden ? 1 : 0,
        'updated_at': _now,
      },
      where: 'id = ?',
      whereArgs: [id],
    );
    _db.notify({'documents'});
  }

  /// Used by the vault after its files have been (de)crypted on disk.
  Future<void> setVaultState(String docId, bool inVault, Map<String, Map<String, String?>> pagePaths, {String? thumbnail}) async {
    await _sql.transaction((txn) async {
      for (final e in pagePaths.entries) {
        await txn.update('pages', e.value, where: 'id = ?', whereArgs: [e.key]);
      }
      await txn.update('documents', {'in_vault': inVault ? 1 : 0, 'thumbnail_path': thumbnail, 'updated_at': _now},
          where: 'id = ?', whereArgs: [docId]);
    });
    _db.notify(_docTables);
  }

  // ---------------------------------------------------------- copy / trash

  /// Duplicates a document including all page files, OCR text and annotations.
  Future<Document> copyDocument(String id, {String? folderId, bool keepFolder = true, String? title}) async {
    final doc = await getDocument(id);
    if (doc == null) throw const AppException('Document not found.');
    final pages = await getPages(id);
    final newDoc = newId();
    final now = _now;
    final pageRows = <Map<String, Object?>>[];
    final pageMap = <String, String>{};
    try {
      for (final p in pages) {
        final row = await _copyPageFiles(p, newDoc, p.index, now);
        pageMap[p.id] = row['id'] as String;
        pageRows.add(row);
      }
    } catch (_) {
      await files.deleteDocumentFiles(newDoc);
      rethrow;
    }
    try {
      await _sql.transaction((txn) async {
        final src = (await txn.query('documents', where: 'id = ?', whereArgs: [id])).first;
        await txn.insert('documents', {
          ...src,
          'id': newDoc,
          'title': title ?? '${doc.title} (copy)',
          'folder_id': keepFolder ? doc.folderId : folderId,
          'created_at': now,
          'updated_at': now,
          'last_opened_at': null,
          'deleted_at': null,
        });
        for (final r in pageRows) {
          await txn.insert('pages', r);
        }
        await _copyPageChildren(txn, pageMap, newDoc);
        await txn.rawInsert(
          'INSERT INTO document_tags (document_id, tag_id) SELECT ?, tag_id FROM document_tags WHERE document_id = ?',
          [newDoc, id],
        );
        await _recalc(txn, newDoc);
      });
    } catch (e) {
      await files.deleteDocumentFiles(newDoc);
      throw StorageException('Could not copy the document', cause: e);
    }
    _db.notify(_docTables);
    return (await getDocument(newDoc))!;
  }

  Future<Map<String, Object?>> _copyPageFiles(DocPage p, String newDocId, int index, int now) async {
    final pageId = newId();
    final version = now + index;
    final hasSeparateOriginal = p.originalPath != p.imagePath;
    final processedRel = files.processedRel(newDocId, pageId, version);
    final originalRel = hasSeparateOriginal ? files.originalRel(newDocId, pageId) : processedRel;
    final thumbRel = files.thumbRel(newDocId, pageId, version);
    await files.copyInto(files.abs(p.imagePath), processedRel);
    if (hasSeparateOriginal) await files.copyInto(files.abs(p.originalPath), originalRel);
    if (p.thumbnailPath != null && await files.file(p.thumbnailPath!).exists()) {
      await files.copyInto(files.abs(p.thumbnailPath!), thumbRel);
    } else {
      await files.writeAtomic(thumbRel, await _images.thumbnail(files.abs(p.imagePath)));
    }
    return {
      'id': pageId,
      'document_id': newDocId,
      'page_index': index,
      'original_path': originalRel,
      'image_path': processedRel,
      'thumbnail_path': thumbRel,
      'edit_json': jsonEncode(p.edit.toJson()),
      'width': p.width,
      'height': p.height,
      'file_size': p.fileSize,
      'content_hash': p.contentHash,
      'created_at': now,
      'updated_at': now,
    };
  }

  /// Copies OCR rows and annotations from old page ids to new page ids.
  Future<void> _copyPageChildren(DatabaseExecutor txn, Map<String, String> pageMap, String newDocId) async {
    for (final e in pageMap.entries) {
      final ocr = await txn.query('ocr_results', where: 'page_id = ?', whereArgs: [e.key]);
      for (final r in ocr) {
        await txn.insert('ocr_results', {...r, 'id': newId(), 'page_id': e.value, 'document_id': newDocId});
      }
      final ann = await txn.query('annotations', where: 'page_id = ?', whereArgs: [e.key]);
      for (final r in ann) {
        await txn.insert('annotations', {...r, 'id': newId(), 'page_id': e.value});
      }
    }
  }

  Future<void> trashDocuments(List<String> ids) async {
    final now = _now;
    await _sql.transaction((txn) async {
      for (final id in ids) {
        final row = await txn.query('documents', columns: ['folder_id'], where: 'id = ?', whereArgs: [id]);
        if (row.isEmpty) continue;
        await txn.update('documents', {'deleted_at': now}, where: 'id = ?', whereArgs: [id]);
        await txn.insert(
          'trash',
          {
            'document_id': id,
            'original_folder_id': row.first['folder_id'],
            'deleted_at': now,
            'expires_at': now + const Duration(days: AppConstants.trashRetentionDays).inMilliseconds,
          },
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
    });
    _db.notify(_docTables);
  }

  Future<void> restoreDocuments(List<String> ids) async {
    await _sql.transaction((txn) async {
      for (final id in ids) {
        final t = await txn.query('trash', where: 'document_id = ?', whereArgs: [id]);
        String? folder = t.isEmpty ? null : t.first['original_folder_id'] as String?;
        if (folder != null) {
          final exists = await txn.query('folders', columns: ['id'], where: 'id = ?', whereArgs: [folder]);
          if (exists.isEmpty) folder = null;
        }
        await txn.update('documents', {'deleted_at': null, 'folder_id': folder, 'updated_at': _now},
            where: 'id = ?', whereArgs: [id]);
        await txn.delete('trash', where: 'document_id = ?', whereArgs: [id]);
      }
    });
    _db.notify(_docTables);
  }

  /// Removes rows first (in one transaction) and files afterwards. A crash in
  /// between leaves orphan files only, which [RecoveryService] cleans up.
  Future<void> deletePermanently(List<String> ids) async {
    final signaturePaths = <String>[];
    await _sql.transaction((txn) async {
      for (final id in ids) {
        final ann = await txn.rawQuery(
          "SELECT a.data_json FROM annotations a JOIN pages p ON p.id = a.page_id WHERE p.document_id = ? AND a.kind = 'image'",
          [id],
        );
        for (final a in ann) {
          final path = (jsonDecode(a['data_json'] as String) as Map)['image'] as String?;
          if (path != null && path.contains('/placed/')) signaturePaths.add(path);
        }
        await txn.delete('documents', where: 'id = ?', whereArgs: [id]);
      }
    });
    for (final id in ids) {
      await files.deleteDocumentFiles(id);
    }
    for (final p in signaturePaths) {
      await files.deleteIfExists(p);
    }
    _db.notify({..._docTables, 'annotations', 'ocr_results'});
  }

  Future<int> emptyTrash() async {
    final rows = await _sql.query('documents', columns: ['id'], where: 'deleted_at IS NOT NULL');
    await deletePermanently(rows.map((r) => r['id'] as String).toList());
    return rows.length;
  }

  Future<int> purgeExpiredTrash() async {
    final rows = await _sql.query('trash', columns: ['document_id'], where: 'expires_at < ?', whereArgs: [_now]);
    if (rows.isEmpty) return 0;
    await deletePermanently(rows.map((r) => r['document_id'] as String).toList());
    return rows.length;
  }

  // ------------------------------------------------------------ page ops

  Future<void> addPages(String docId, List<PageDraft> drafts, {int? insertAt, ProgressCallback? onProgress}) async {
    final existing = await getPages(docId);
    final at = (insertAt ?? existing.length).clamp(0, existing.length);
    final now = _now;
    final rows = <Map<String, Object?>>[];
    final written = <String>[];
    try {
      for (var i = 0; i < drafts.length; i++) {
        final r = await _materializePage(docId, drafts[i], at + i, now + i);
        rows.add(r);
        written.addAll([r['original_path'] as String, r['image_path'] as String, r['thumbnail_path'] as String]);
        onProgress?.call(i + 1, drafts.length);
      }
    } catch (_) {
      for (final w in written) {
        await files.deleteIfExists(w);
      }
      rethrow;
    }
    try {
      await _sql.transaction((txn) async {
        await txn.rawUpdate(
          'UPDATE pages SET page_index = page_index + ? WHERE document_id = ? AND page_index >= ?',
          [drafts.length, docId, at],
        );
        for (final r in rows) {
          await txn.insert('pages', r);
        }
        await _recalc(txn, docId);
      });
    } catch (e) {
      for (final w in written) {
        await files.deleteIfExists(w);
      }
      throw StorageException('Could not add pages', cause: e);
    }
    _db.notify(_docTables);
  }

  Future<void> deletePages(String docId, List<String> pageIds) async {
    final pages = await getPages(docId);
    final victims = pages.where((p) => pageIds.contains(p.id)).toList();
    if (victims.length >= pages.length) {
      throw const AppException('A document must keep at least one page. Delete the document instead.');
    }
    await _sql.transaction((txn) async {
      for (final p in victims) {
        await txn.delete('pages', where: 'id = ?', whereArgs: [p.id]);
      }
      await _reindex(txn, docId);
      await _recalc(txn, docId);
    });
    for (final p in victims) {
      await _deletePageFiles(p);
    }
    _db.notify({..._docTables, 'annotations', 'ocr_results'});
  }

  Future<void> _deletePageFiles(DocPage p) async {
    await files.deleteIfExists(p.imagePath);
    if (p.originalPath != p.imagePath) await files.deleteIfExists(p.originalPath);
    await files.deleteIfExists(p.thumbnailPath);
  }

  Future<void> _reindex(DatabaseExecutor txn, String docId) async {
    final rows = await txn.query('pages', columns: ['id'], where: 'document_id = ?', whereArgs: [docId], orderBy: 'page_index');
    for (var i = 0; i < rows.length; i++) {
      await txn.update('pages', {'page_index': i}, where: 'id = ?', whereArgs: [rows[i]['id']]);
    }
  }

  Future<void> reorderPages(String docId, List<String> orderedIds) async {
    await _sql.transaction((txn) async {
      for (var i = 0; i < orderedIds.length; i++) {
        await txn.update('pages', {'page_index': i, 'updated_at': _now},
            where: 'id = ? AND document_id = ?', whereArgs: [orderedIds[i], docId]);
      }
      await _recalc(txn, docId);
    });
    _db.notify({'pages', 'documents'});
  }

  Future<void> duplicatePage(String pageId) async {
    final p = await getPage(pageId);
    if (p == null) return;
    final now = _now;
    final row = await _copyPageFiles(p, p.documentId, p.index + 1, now);
    try {
      await _sql.transaction((txn) async {
        await txn.rawUpdate('UPDATE pages SET page_index = page_index + 1 WHERE document_id = ? AND page_index > ?', [p.documentId, p.index]);
        await txn.insert('pages', row);
        await _copyPageChildren(txn, {p.id: row['id'] as String}, p.documentId);
        await _recalc(txn, p.documentId);
      });
    } catch (e) {
      await files.deleteIfExists(row['image_path'] as String);
      await files.deleteIfExists(row['original_path'] as String);
      await files.deleteIfExists(row['thumbnail_path'] as String);
      rethrow;
    }
    _db.notify({..._docTables, 'annotations', 'ocr_results'});
  }

  /// Replaces a page's image with a new capture (keeps its position).
  Future<void> replacePage(String pageId, PageDraft draft) async {
    final p = await getPage(pageId);
    if (p == null) return;
    final row = await _materializePage(p.documentId, draft, p.index, _now);
    try {
      await _sql.transaction((txn) async {
        await txn.delete('pages', where: 'id = ?', whereArgs: [p.id]);
        await txn.insert('pages', row);
        await _recalc(txn, p.documentId);
      });
    } catch (e) {
      await files.deleteIfExists(row['image_path'] as String);
      await files.deleteIfExists(row['original_path'] as String);
      await files.deleteIfExists(row['thumbnail_path'] as String);
      rethrow;
    }
    await _deletePageFiles(p);
    _db.notify({..._docTables, 'annotations', 'ocr_results'});
  }

  /// Re-renders a page from its original with new edits (crop/filter/rotation).
  Future<void> updatePageEdit(String pageId, PageEdit edit) async {
    final p = await getPage(pageId);
    if (p == null) return;
    final now = _now;
    final processed = await _images.processPage(files.abs(p.originalPath), edit);
    final processedRel = files.processedRel(p.documentId, p.id, now);
    final thumbRel = files.thumbRel(p.documentId, p.id, now);
    await files.writeAtomic(processedRel, processed.bytes);
    await files.writeAtomic(thumbRel, processed.thumbnail);
    final origSize = p.originalPath == p.imagePath ? 0 : await files.file(p.originalPath).length();
    try {
      await _sql.transaction((txn) async {
        await txn.update(
          'pages',
          {
            'image_path': processedRel,
            'thumbnail_path': thumbRel,
            'edit_json': jsonEncode(edit.toJson()),
            'width': processed.width,
            'height': processed.height,
            'file_size': processed.bytes.length + origSize,
            'updated_at': now,
          },
          where: 'id = ?',
          whereArgs: [p.id],
        );
        await _recalc(txn, p.documentId);
      });
    } catch (e) {
      await files.deleteIfExists(processedRel);
      await files.deleteIfExists(thumbRel);
      rethrow;
    }
    if (p.imagePath != p.originalPath) await files.deleteIfExists(p.imagePath);
    await files.deleteIfExists(p.thumbnailPath);
    _db.notify({'pages', 'documents'});
  }

  Future<void> rotatePage(String pageId, int quarterTurns) async {
    final p = await getPage(pageId);
    if (p == null) return;
    await updatePageEdit(pageId, p.edit.copyWith(rotation: (p.edit.rotation + quarterTurns) % 4));
  }

  /// Called after page files were modified in place (e.g. redaction burn-in).
  Future<void> refreshPageFiles(String pageId) async {
    final p = await getPage(pageId);
    if (p == null) return;
    final now = _now;
    final thumbRel = files.thumbRel(p.documentId, p.id, now);
    await files.writeAtomic(thumbRel, await _images.thumbnail(files.abs(p.imagePath)));
    // Version the processed file name so image caches pick up the change.
    final newRel = files.processedRel(p.documentId, p.id, now);
    String original = p.originalPath;
    if (p.originalPath == p.imagePath) {
      await File(files.abs(p.imagePath)).rename(files.abs(newRel));
      original = newRel;
    } else {
      await File(files.abs(p.imagePath)).rename(files.abs(newRel));
    }
    await _sql.transaction((txn) async {
      await txn.update('pages', {'image_path': newRel, 'original_path': original, 'thumbnail_path': thumbRel, 'updated_at': now},
          where: 'id = ?', whereArgs: [p.id]);
      await _recalc(txn, p.documentId);
    });
    await files.deleteIfExists(p.thumbnailPath);
    _db.notify({'pages', 'documents'});
  }

  /// Permanent redaction: burns black boxes into the page pixels, discards the
  /// un-redacted original capture and the page's OCR text (which could still
  /// contain the hidden words), so nothing recoverable remains.
  Future<void> applyRedactions(String pageId, List<NRect> rects) async {
    final p = await getPage(pageId);
    if (p == null || rects.isEmpty) return;
    await _images.burnRedactions(files.abs(p.imagePath), rects);
    final oldOriginal = p.originalPath;
    await _sql.transaction((txn) async {
      await txn.update(
        'pages',
        {'original_path': p.imagePath, 'edit_json': jsonEncode(const PageEdit(filter: ScanFilter.original).toJson())},
        where: 'id = ?',
        whereArgs: [p.id],
      );
      await txn.delete('ocr_results', where: 'page_id = ?', whereArgs: [p.id]);
      await txn.delete('annotations', where: "page_id = ? AND kind = 'redact'", whereArgs: [p.id]);
    });
    if (oldOriginal != p.imagePath) await files.deleteIfExists(oldOriginal);
    await refreshPageFiles(pageId);
    _db.notify({'annotations', 'ocr_results'});
  }

  /// Creates a new document from selected pages (copies files).
  Future<Document> extractPages(String docId, List<String> pageIds, {String? title}) async {
    final doc = await getDocument(docId);
    final pages = (await getPages(docId)).where((p) => pageIds.contains(p.id)).toList();
    if (doc == null || pages.isEmpty) throw const AppException('No pages selected.');
    return _assemble(
      title ?? '${doc.title} (extract)',
      pages,
      folderId: doc.folderId,
      mode: doc.scanMode,
      action: 'extract',
    );
  }

  /// Splits a document: pages from [atIndex] onward move to a new document.
  Future<Document> splitDocument(String docId, int atIndex, {String? title}) async {
    final doc = await getDocument(docId);
    final pages = await getPages(docId);
    if (doc == null) throw const AppException('Document not found.');
    if (atIndex <= 0 || atIndex >= pages.length) throw const AppException('Choose a split point between pages.');
    final moved = pages.sublist(atIndex);
    final created = await _assemble(title ?? '${doc.title} (part 2)', moved, folderId: doc.folderId, mode: doc.scanMode, action: 'split');
    await deletePages(docId, moved.map((p) => p.id).toList());
    return created;
  }

  /// Merges documents (in the given order) into a new document.
  Future<Document> mergeDocuments(List<String> docIds, {required String title, bool deleteSources = false}) async {
    if (docIds.length < 2) throw const AppException('Select at least two documents to merge.');
    final all = <DocPage>[];
    String? folder;
    for (final id in docIds) {
      final d = await getDocument(id);
      folder ??= d?.folderId;
      all.addAll(await getPages(id));
    }
    final created = await _assemble(title, all, folderId: folder, mode: ScanMode.document, action: 'merge');
    if (deleteSources) await trashDocuments(docIds);
    return created;
  }

  Future<Document> _assemble(String title, List<DocPage> pages, {String? folderId, required ScanMode mode, required String action}) async {
    final newDoc = newId();
    final now = _now;
    final rows = <Map<String, Object?>>[];
    final map = <String, String>{};
    try {
      for (var i = 0; i < pages.length; i++) {
        final r = await _copyPageFiles(pages[i], newDoc, i, now + i);
        map[pages[i].id] = r['id'] as String;
        rows.add(r);
      }
    } catch (_) {
      await files.deleteDocumentFiles(newDoc);
      rethrow;
    }
    try {
      await _sql.transaction((txn) async {
        await txn.insert('documents', {
          'id': newDoc,
          'title': title,
          'folder_id': folderId,
          'scan_mode': mode.name,
          'source': action,
          'created_at': now,
          'updated_at': now,
        });
        for (final r in rows) {
          await txn.insert('pages', r);
        }
        await _copyPageChildren(txn, map, newDoc);
        await _recalc(txn, newDoc);
        await txn.insert('scan_history', {
          'id': newId(),
          'document_id': newDoc,
          'mode': mode.name,
          'page_count': rows.length,
          'action': action,
          'created_at': now,
        });
      });
    } catch (e) {
      await files.deleteDocumentFiles(newDoc);
      throw StorageException('Could not create the document', cause: e);
    }
    _db.notify({..._docTables, 'annotations', 'ocr_results'});
    return (await getDocument(newDoc))!;
  }

  /// All referenced relative paths (used by orphan cleanup).
  Future<Set<String>> referencedDocumentIds() async {
    final rows = await _sql.query('documents', columns: ['id']);
    return rows.map((r) => r['id'] as String).toSet();
  }
}
