import 'dart:async';

import 'package:sqflite/sqflite.dart';

/// SQLite schema, migrations and a change-notification stream.
///
/// Metadata only: page images/PDFs live on disk (see `FileStore`), the DB
/// stores relative paths. Foreign keys are enforced and cascade on delete.
class AppDatabase {
  AppDatabase._(this.db);

  final Database db;
  final _changes = StreamController<Set<String>>.broadcast();

  static const schemaVersion = 2;

  /// Emits the set of table names touched by each write.
  Stream<Set<String>> get changes => _changes.stream;

  void notify(Set<String> tables) {
    if (!_changes.isClosed) _changes.add(tables);
  }

  static Future<AppDatabase> open(String path, {DatabaseFactory? factory}) async {
    final f = factory ?? databaseFactory;
    final db = await f.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: schemaVersion,
        onConfigure: (db) async {
          await db.execute('PRAGMA foreign_keys = ON');
        },
        onCreate: (db, version) async {
          final batch = db.batch();
          for (final stmt in _schemaV1) {
            batch.execute(stmt);
          }
          await batch.commit(noResult: true);
          await _migrate(db, 1, version);
        },
        onUpgrade: (db, from, to) => _migrate(db, from, to),
      ),
    );
    return AppDatabase._(db);
  }

  static Future<void> _migrate(Database db, int from, int to) async {
    for (var v = from + 1; v <= to; v++) {
      final steps = _migrations[v];
      if (steps == null) continue;
      final batch = db.batch();
      for (final s in steps) {
        batch.execute(s);
      }
      await batch.commit(noResult: true);
    }
  }

  Future<void> close() async {
    await _changes.close();
    await db.close();
  }

  static const _schemaV1 = <String>[
    '''
    CREATE TABLE folders (
      id TEXT PRIMARY KEY,
      name TEXT NOT NULL,
      parent_id TEXT REFERENCES folders(id) ON DELETE CASCADE,
      color INTEGER,
      created_at INTEGER NOT NULL,
      updated_at INTEGER NOT NULL
    )''',
    'CREATE INDEX idx_folders_parent ON folders(parent_id)',
    '''
    CREATE TABLE documents (
      id TEXT PRIMARY KEY,
      title TEXT NOT NULL,
      folder_id TEXT REFERENCES folders(id) ON DELETE SET NULL,
      page_count INTEGER NOT NULL DEFAULT 0,
      file_size INTEGER NOT NULL DEFAULT 0,
      category TEXT,
      description TEXT,
      notes TEXT,
      scan_mode TEXT NOT NULL DEFAULT 'document',
      source TEXT NOT NULL DEFAULT 'scan',
      is_locked INTEGER NOT NULL DEFAULT 0,
      is_hidden INTEGER NOT NULL DEFAULT 0,
      in_vault INTEGER NOT NULL DEFAULT 0,
      content_hash TEXT,
      thumbnail_path TEXT,
      created_at INTEGER NOT NULL,
      updated_at INTEGER NOT NULL,
      last_opened_at INTEGER,
      deleted_at INTEGER
    )''',
    'CREATE INDEX idx_documents_folder ON documents(folder_id)',
    'CREATE INDEX idx_documents_updated ON documents(updated_at)',
    'CREATE INDEX idx_documents_deleted ON documents(deleted_at)',
    'CREATE INDEX idx_documents_hash ON documents(content_hash)',
    '''
    CREATE TABLE pages (
      id TEXT PRIMARY KEY,
      document_id TEXT NOT NULL REFERENCES documents(id) ON DELETE CASCADE,
      page_index INTEGER NOT NULL,
      original_path TEXT NOT NULL,
      image_path TEXT NOT NULL,
      thumbnail_path TEXT,
      edit_json TEXT,
      width INTEGER NOT NULL DEFAULT 0,
      height INTEGER NOT NULL DEFAULT 0,
      file_size INTEGER NOT NULL DEFAULT 0,
      content_hash TEXT,
      created_at INTEGER NOT NULL,
      updated_at INTEGER NOT NULL
    )''',
    'CREATE INDEX idx_pages_document ON pages(document_id, page_index)',
    '''
    CREATE TABLE tags (
      id TEXT PRIMARY KEY,
      name TEXT NOT NULL UNIQUE COLLATE NOCASE,
      color INTEGER,
      created_at INTEGER NOT NULL
    )''',
    '''
    CREATE TABLE document_tags (
      document_id TEXT NOT NULL REFERENCES documents(id) ON DELETE CASCADE,
      tag_id TEXT NOT NULL REFERENCES tags(id) ON DELETE CASCADE,
      PRIMARY KEY (document_id, tag_id)
    )''',
    'CREATE INDEX idx_document_tags_tag ON document_tags(tag_id)',
    '''
    CREATE TABLE favorites (
      document_id TEXT PRIMARY KEY REFERENCES documents(id) ON DELETE CASCADE,
      created_at INTEGER NOT NULL
    )''',
    '''
    CREATE TABLE signatures (
      id TEXT PRIMARY KEY,
      name TEXT NOT NULL,
      path TEXT NOT NULL,
      color INTEGER,
      stroke_json TEXT,
      created_at INTEGER NOT NULL,
      updated_at INTEGER NOT NULL
    )''',
    '''
    CREATE TABLE stamps (
      id TEXT PRIMARY KEY,
      name TEXT NOT NULL,
      kind TEXT NOT NULL,
      text TEXT,
      subtext TEXT,
      color INTEGER,
      path TEXT,
      created_at INTEGER NOT NULL,
      updated_at INTEGER NOT NULL
    )''',
    '''
    CREATE TABLE annotations (
      id TEXT PRIMARY KEY,
      page_id TEXT NOT NULL REFERENCES pages(id) ON DELETE CASCADE,
      kind TEXT NOT NULL,
      data_json TEXT NOT NULL,
      z_index INTEGER NOT NULL DEFAULT 0,
      created_at INTEGER NOT NULL,
      updated_at INTEGER NOT NULL
    )''',
    'CREATE INDEX idx_annotations_page ON annotations(page_id)',
    '''
    CREATE TABLE scan_history (
      id TEXT PRIMARY KEY,
      document_id TEXT REFERENCES documents(id) ON DELETE SET NULL,
      mode TEXT NOT NULL,
      page_count INTEGER NOT NULL,
      action TEXT NOT NULL DEFAULT 'scan',
      detail TEXT,
      created_at INTEGER NOT NULL
    )''',
    'CREATE INDEX idx_scan_history_created ON scan_history(created_at)',
    '''
    CREATE TABLE app_settings (
      key TEXT PRIMARY KEY,
      value TEXT,
      updated_at INTEGER NOT NULL
    )''',
    '''
    CREATE TABLE trash (
      document_id TEXT PRIMARY KEY REFERENCES documents(id) ON DELETE CASCADE,
      original_folder_id TEXT,
      deleted_at INTEGER NOT NULL,
      expires_at INTEGER NOT NULL
    )''',
    '''
    CREATE TABLE ocr_results (
      id TEXT PRIMARY KEY,
      page_id TEXT NOT NULL UNIQUE REFERENCES pages(id) ON DELETE CASCADE,
      document_id TEXT NOT NULL REFERENCES documents(id) ON DELETE CASCADE,
      script TEXT NOT NULL,
      text TEXT NOT NULL,
      blocks_json TEXT,
      edited INTEGER NOT NULL DEFAULT 0,
      created_at INTEGER NOT NULL,
      updated_at INTEGER NOT NULL
    )''',
    'CREATE INDEX idx_ocr_document ON ocr_results(document_id)',
  ];

  /// Incremental migrations keyed by the version they upgrade *to*.
  static const _migrations = <int, List<String>>{
    2: [
      // v2: exports log for "Recent exports".
      '''
      CREATE TABLE IF NOT EXISTS exports (
        id TEXT PRIMARY KEY,
        document_id TEXT REFERENCES documents(id) ON DELETE SET NULL,
        title TEXT NOT NULL,
        format TEXT NOT NULL,
        target TEXT NOT NULL,
        path TEXT,
        created_at INTEGER NOT NULL
      )''',
      'CREATE INDEX IF NOT EXISTS idx_exports_created ON exports(created_at)',
    ],
  };
}
