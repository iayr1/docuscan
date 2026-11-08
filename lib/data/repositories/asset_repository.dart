import 'dart:convert';
import 'dart:typed_data';

import 'package:sqflite/sqflite.dart';

import '../../core/constants/app_constants.dart';
import '../../core/storage/file_store.dart';
import '../database/app_database.dart';
import '../models/models.dart';

/// Signatures, stamps, annotations and OCR text.
class AssetRepository {
  AssetRepository(this._db, this.files);
  final AppDatabase _db;
  final FileStore files;
  Database get _sql => _db.db;
  int get _now => DateTime.now().millisecondsSinceEpoch;

  // ------------------------------------------------------------ signatures

  Future<List<Signature>> signatures() async =>
      (await _sql.query('signatures', orderBy: 'updated_at DESC')).map(Signature.fromRow).toList();

  Future<Signature> saveSignature({String? id, required String name, required Uint8List png, int? color, String? strokes}) async {
    final sid = id ?? newId();
    final rel = '${StorageDirs.signatures}/${sid}_$_now.png';
    await files.writeAtomic(rel, png);
    String? oldPath;
    if (id != null) {
      final old = await _sql.query('signatures', columns: ['path'], where: 'id = ?', whereArgs: [id]);
      if (old.isNotEmpty) oldPath = old.first['path'] as String?;
    }
    await _sql.insert(
      'signatures',
      {
        'id': sid,
        'name': name,
        'path': rel,
        'color': color,
        'stroke_json': strokes,
        'created_at': _now,
        'updated_at': _now,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    if (oldPath != null && oldPath != rel) await files.deleteIfExists(oldPath);
    _db.notify({'signatures'});
    return Signature(id: sid, name: name, path: rel, color: color, createdAt: DateTime.now(), strokes: strokes);
  }

  Future<void> renameSignature(String id, String name) async {
    await _sql.update('signatures', {'name': name, 'updated_at': _now}, where: 'id = ?', whereArgs: [id]);
    _db.notify({'signatures'});
  }

  Future<void> deleteSignature(Signature s) async {
    await _sql.delete('signatures', where: 'id = ?', whereArgs: [s.id]);
    await files.deleteIfExists(s.path);
    _db.notify({'signatures'});
  }

  // ---------------------------------------------------------------- stamps

  Future<List<Stamp>> stamps() async => (await _sql.query('stamps', orderBy: 'updated_at DESC')).map(Stamp.fromRow).toList();

  Future<Stamp> saveStamp({
    String? id,
    required String name,
    required StampKind kind,
    String? text,
    String? subtext,
    required int color,
    required Uint8List png,
  }) async {
    final sid = id ?? newId();
    final rel = '${StorageDirs.stamps}/${sid}_$_now.png';
    await files.writeAtomic(rel, png);
    String? oldPath;
    if (id != null) {
      final old = await _sql.query('stamps', columns: ['path'], where: 'id = ?', whereArgs: [id]);
      if (old.isNotEmpty) oldPath = old.first['path'] as String?;
    }
    await _sql.insert(
      'stamps',
      {
        'id': sid,
        'name': name,
        'kind': kind.name,
        'text': text,
        'subtext': subtext,
        'color': color,
        'path': rel,
        'created_at': _now,
        'updated_at': _now,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    if (oldPath != null && oldPath != rel) await files.deleteIfExists(oldPath);
    _db.notify({'stamps'});
    return Stamp(id: sid, name: name, kind: kind, text: text, subtext: subtext, color: color, path: rel, createdAt: DateTime.now());
  }

  Future<void> deleteStamp(Stamp s) async {
    await _sql.delete('stamps', where: 'id = ?', whereArgs: [s.id]);
    await files.deleteIfExists(s.path);
    _db.notify({'stamps'});
  }

  // ----------------------------------------------------------- annotations

  Future<List<Annotation>> annotations(String pageId) async =>
      (await _sql.query('annotations', where: 'page_id = ?', whereArgs: [pageId], orderBy: 'z_index, created_at'))
          .map(Annotation.fromRow)
          .toList();

  Future<Map<String, List<Annotation>>> annotationsForDocument(String documentId) async {
    final rows = await _sql.rawQuery(
      'SELECT a.* FROM annotations a JOIN pages p ON p.id = a.page_id WHERE p.document_id = ? ORDER BY a.z_index, a.created_at',
      [documentId],
    );
    final out = <String, List<Annotation>>{};
    for (final r in rows) {
      (out[r['page_id'] as String] ??= []).add(Annotation.fromRow(r));
    }
    return out;
  }

  /// Replaces the full annotation set of a page atomically.
  Future<void> saveAnnotations(String pageId, List<Annotation> items) async {
    final existing = await annotations(pageId);
    final keep = items.map((a) => a.imagePath).whereType<String>().toSet();
    await _sql.transaction((txn) async {
      await txn.delete('annotations', where: 'page_id = ?', whereArgs: [pageId]);
      for (var i = 0; i < items.length; i++) {
        final a = items[i];
        await txn.insert('annotations', {
          'id': a.id,
          'page_id': pageId,
          'kind': a.kind.name,
          'data_json': jsonEncode(a.dataJson()),
          'z_index': i,
          'created_at': _now,
          'updated_at': _now,
        });
      }
      await txn.update('pages', {'updated_at': _now}, where: 'id = ?', whereArgs: [pageId]);
    });
    // Remove copies of placed images that are no longer referenced.
    for (final a in existing) {
      final path = a.imagePath;
      if (path != null && path.contains('/placed/') && !keep.contains(path)) await files.deleteIfExists(path);
    }
    _db.notify({'annotations', 'pages'});
  }

  /// Copies a signature/stamp PNG next to the document so annotations stay
  /// valid even if the library item is later edited or deleted.
  Future<String> placeImage(String documentId, String sourceRel) async {
    final rel = '${StorageDirs.scannedImages}/$documentId/placed/${newId()}.png';
    await files.copyInto(files.abs(sourceRel), rel);
    return rel;
  }

  Future<int> annotationCount(String documentId) async =>
      Sqflite.firstIntValue(await _sql.rawQuery(
        'SELECT COUNT(*) FROM annotations a JOIN pages p ON p.id = a.page_id WHERE p.document_id = ?',
        [documentId],
      )) ??
      0;

  // ------------------------------------------------------------------- OCR

  Future<Map<String, OcrResult>> ocrForDocument(String documentId) async {
    final rows = await _sql.query('ocr_results', where: 'document_id = ?', whereArgs: [documentId]);
    return {for (final r in rows) r['page_id'] as String: OcrResult.fromRow(r)};
  }

  Future<OcrResult?> ocrForPage(String pageId) async {
    final rows = await _sql.query('ocr_results', where: 'page_id = ?', whereArgs: [pageId]);
    return rows.isEmpty ? null : OcrResult.fromRow(rows.first);
  }

  Future<void> saveOcr({
    required String pageId,
    required String documentId,
    required String script,
    required String text,
    List<OcrBlock> lines = const [],
    bool edited = false,
  }) async {
    final existing = await ocrForPage(pageId);
    await _sql.insert(
      'ocr_results',
      {
        'id': existing?.id ?? newId(),
        'page_id': pageId,
        'document_id': documentId,
        'script': script,
        'text': text,
        'blocks_json': jsonEncode(lines.map((l) => l.toJson()).toList()),
        'edited': edited ? 1 : 0,
        'created_at': _now,
        'updated_at': _now,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    _db.notify({'ocr_results'});
  }

  /// Saves user corrections; keeps line boxes only if the text is unchanged.
  Future<void> updateOcrText(String pageId, String text) async {
    await _sql.update('ocr_results', {'text': text, 'edited': 1, 'updated_at': _now}, where: 'page_id = ?', whereArgs: [pageId]);
    _db.notify({'ocr_results'});
  }

  /// Page-level full-text search inside one document.
  Future<List<(int pageIndex, String pageId, String snippet)>> searchInDocument(String documentId, String query) async {
    final q = query.trim();
    if (q.isEmpty) return const [];
    final rows = await _sql.rawQuery('''
      SELECT p.page_index, p.id, o.text FROM ocr_results o JOIN pages p ON p.id = o.page_id
      WHERE o.document_id = ? AND o.text LIKE ? ORDER BY p.page_index
    ''', [documentId, '%$q%']);
    return [
      for (final r in rows) (r['page_index'] as int, r['id'] as String, _snippet(r['text'] as String, q)),
    ];
  }

  /// Library-wide OCR search returning (documentId, title, pageIndex, snippet).
  Future<List<(String, String, int, String)>> searchAllText(String query, {int limit = 100}) async {
    final q = query.trim();
    if (q.isEmpty) return const [];
    final rows = await _sql.rawQuery('''
      SELECT d.id, d.title, p.page_index, o.text FROM ocr_results o
      JOIN pages p ON p.id = o.page_id JOIN documents d ON d.id = o.document_id
      WHERE d.deleted_at IS NULL AND d.in_vault = 0 AND o.text LIKE ?
      ORDER BY d.updated_at DESC, p.page_index LIMIT ?
    ''', ['%$q%', limit]);
    return [
      for (final r in rows)
        (r['id'] as String, r['title'] as String, r['page_index'] as int, _snippet(r['text'] as String, q)),
    ];
  }

  static String _snippet(String text, String q) {
    final i = text.toLowerCase().indexOf(q.toLowerCase());
    if (i < 0) return text.length > 80 ? '${text.substring(0, 80)}…' : text;
    final start = (i - 40).clamp(0, text.length);
    final end = (i + q.length + 40).clamp(0, text.length);
    return '${start > 0 ? '…' : ''}${text.substring(start, end).replaceAll('\n', ' ')}${end < text.length ? '…' : ''}';
  }

  // -------------------------------------------------------- key/value store

  Future<String?> getValue(String key) async {
    final rows = await _sql.query('app_settings', where: 'key = ?', whereArgs: [key]);
    return rows.isEmpty ? null : rows.first['value'] as String?;
  }

  Future<void> setValue(String key, String? value) async {
    await _sql.insert('app_settings', {'key': key, 'value': value, 'updated_at': _now}, conflictAlgorithm: ConflictAlgorithm.replace);
  }
}
