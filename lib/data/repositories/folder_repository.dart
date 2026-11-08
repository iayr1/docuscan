import 'package:sqflite/sqflite.dart';

import '../../core/constants/app_constants.dart';
import '../../core/errors/app_exception.dart';
import '../../core/storage/file_store.dart';
import '../database/app_database.dart';
import '../models/models.dart';
import 'document_repository.dart';

class FolderRepository {
  FolderRepository(this._db);
  final AppDatabase _db;
  Database get _sql => _db.db;
  int get _now => DateTime.now().millisecondsSinceEpoch;

  static const _select = '''
    SELECT f.*,
      (SELECT COUNT(*) FROM documents d WHERE d.folder_id = f.id AND d.deleted_at IS NULL AND d.in_vault = 0) AS document_count,
      (SELECT COUNT(*) FROM folders c WHERE c.parent_id = f.id) AS subfolder_count
    FROM folders f
  ''';

  Future<List<Folder>> list({String? parentId, bool all = false, String? search}) async {
    final where = <String>[];
    final args = <Object?>[];
    if (!all) {
      if (parentId == null) {
        where.add('f.parent_id IS NULL');
      } else {
        where.add('f.parent_id = ?');
        args.add(parentId);
      }
    }
    if (search != null && search.trim().isNotEmpty) {
      where.add('f.name LIKE ?');
      args.add('%${search.trim()}%');
    }
    final rows = await _sql.rawQuery(
      '$_select ${where.isEmpty ? '' : 'WHERE ${where.join(' AND ')}'} ORDER BY f.name COLLATE NOCASE',
      args,
    );
    return rows.map(Folder.fromRow).toList();
  }

  Future<Folder?> get(String id) async {
    final rows = await _sql.rawQuery('$_select WHERE f.id = ?', [id]);
    return rows.isEmpty ? null : Folder.fromRow(rows.first);
  }

  /// Folder chain from root to [id] (for breadcrumbs).
  Future<List<Folder>> path(String id) async {
    final chain = <Folder>[];
    String? cur = id;
    var guard = 0;
    while (cur != null && guard++ < 50) {
      final f = await get(cur);
      if (f == null) break;
      chain.insert(0, f);
      cur = f.parentId;
    }
    return chain;
  }

  Future<Folder> create(String name, {String? parentId, int? color}) async {
    final n = name.trim();
    if (n.isEmpty) throw const AppException('Folder name cannot be empty.');
    final siblings = await list(parentId: parentId);
    if (siblings.any((f) => f.name.toLowerCase() == n.toLowerCase())) {
      throw AppException('A folder named "$n" already exists here.');
    }
    final id = newId();
    await _sql.insert('folders', {
      'id': id,
      'name': n,
      'parent_id': parentId,
      'color': color,
      'created_at': _now,
      'updated_at': _now,
    });
    _db.notify({'folders'});
    return (await get(id))!;
  }

  Future<void> rename(String id, String name) async {
    final n = name.trim();
    if (n.isEmpty) throw const AppException('Folder name cannot be empty.');
    await _sql.update('folders', {'name': n, 'updated_at': _now}, where: 'id = ?', whereArgs: [id]);
    _db.notify({'folders'});
  }

  Future<void> setColor(String id, int? color) async {
    await _sql.update('folders', {'color': color, 'updated_at': _now}, where: 'id = ?', whereArgs: [id]);
    _db.notify({'folders'});
  }

  Future<void> move(String id, String? newParentId) async {
    if (newParentId != null) {
      final chain = await path(newParentId);
      if (chain.any((f) => f.id == id)) throw const AppException('A folder cannot be moved inside itself.');
    }
    await _sql.update('folders', {'parent_id': newParentId, 'updated_at': _now}, where: 'id = ?', whereArgs: [id]);
    _db.notify({'folders'});
  }

  /// Deletes a folder and its subfolders. Documents inside move to the
  /// recycle bin (they are not destroyed).
  Future<void> delete(String id, DocumentRepository docs) async {
    final ids = <String>[id];
    for (var i = 0; i < ids.length; i++) {
      final children = await _sql.query('folders', columns: ['id'], where: 'parent_id = ?', whereArgs: [ids[i]]);
      ids.addAll(children.map((c) => c['id'] as String));
    }
    final docRows = await _sql.query('documents',
        columns: ['id'], where: 'folder_id IN (${List.filled(ids.length, '?').join(',')}) AND deleted_at IS NULL', whereArgs: ids);
    await docs.trashDocuments(docRows.map((r) => r['id'] as String).toList());
    await _sql.delete('folders', where: 'id = ?', whereArgs: [id]); // cascades to subfolders
    _db.notify({'folders', 'documents'});
  }

  Future<void> ensureDefaults() async {
    final count = Sqflite.firstIntValue(await _sql.rawQuery('SELECT COUNT(*) FROM folders')) ?? 0;
    final seeded = await _sql.query('app_settings', where: 'key = ?', whereArgs: ['default_folders_seeded']);
    if (count > 0 || seeded.isNotEmpty) return;
    await _sql.transaction((txn) async {
      for (final name in AppConstants.defaultFolders) {
        await txn.insert('folders', {'id': newId(), 'name': name, 'created_at': _now, 'updated_at': _now});
      }
      await txn.insert('app_settings', {'key': 'default_folders_seeded', 'value': '1', 'updated_at': _now});
    });
    _db.notify({'folders'});
  }

  Future<Folder?> findByName(String name) async {
    final rows = await _sql.rawQuery('$_select WHERE f.name = ? COLLATE NOCASE LIMIT 1', [name]);
    return rows.isEmpty ? null : Folder.fromRow(rows.first);
  }
}

class TagRepository {
  TagRepository(this._db);
  final AppDatabase _db;
  Database get _sql => _db.db;

  Future<List<Tag>> list({String? search}) async {
    final rows = await _sql.rawQuery('''
      SELECT t.*, (SELECT COUNT(*) FROM document_tags dt JOIN documents d ON d.id = dt.document_id
                   WHERE dt.tag_id = t.id AND d.deleted_at IS NULL) AS usage
      FROM tags t ${search == null || search.isEmpty ? '' : 'WHERE t.name LIKE ?'}
      ORDER BY t.name COLLATE NOCASE
    ''', [if (search != null && search.isNotEmpty) '%$search%']);
    return rows.map(Tag.fromRow).toList();
  }

  Future<Tag> create(String name, {int? color}) async {
    final n = name.trim();
    if (n.isEmpty) throw const AppException('Tag name cannot be empty.');
    final existing = await _sql.query('tags', where: 'name = ? COLLATE NOCASE', whereArgs: [n]);
    if (existing.isNotEmpty) return Tag.fromRow(existing.first);
    final id = newId();
    await _sql.insert('tags', {'id': id, 'name': n, 'color': color, 'created_at': DateTime.now().millisecondsSinceEpoch});
    _db.notify({'tags'});
    return Tag(id: id, name: n, color: color);
  }

  Future<void> rename(String id, String name) async {
    await _sql.update('tags', {'name': name.trim()}, where: 'id = ?', whereArgs: [id]);
    _db.notify({'tags', 'documents'});
  }

  Future<void> delete(String id) async {
    await _sql.delete('tags', where: 'id = ?', whereArgs: [id]);
    _db.notify({'tags', 'document_tags', 'documents'});
  }

  Future<void> setDocumentTags(String documentId, List<String> tagIds) async {
    await _sql.transaction((txn) async {
      await txn.delete('document_tags', where: 'document_id = ?', whereArgs: [documentId]);
      for (final t in tagIds.toSet()) {
        await txn.insert('document_tags', {'document_id': documentId, 'tag_id': t});
      }
    });
    _db.notify({'document_tags', 'documents'});
  }

  Future<void> addTagToDocuments(String tagId, List<String> documentIds) async {
    final batch = _sql.batch();
    for (final d in documentIds) {
      batch.insert('document_tags', {'document_id': d, 'tag_id': tagId}, conflictAlgorithm: ConflictAlgorithm.ignore);
    }
    await batch.commit(noResult: true);
    _db.notify({'document_tags', 'documents'});
  }
}
