import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../../core/image/image_types.dart';
import '../../core/storage/file_store.dart';
import '../models/models.dart';

class SessionPage {
  SessionPage({required this.id, required this.rawPath, this.edit = const PageEdit(), this.detected = false});
  final String id;

  /// Absolute path of the captured image inside the session folder.
  final String rawPath;
  PageEdit edit;
  bool detected;

  Map<String, Object?> toJson() => {'id': id, 'raw': p.basename(rawPath), 'edit': edit.toJson(), 'detected': detected};
}

/// An in-progress capture. Every captured frame is written to disk at once
/// and the manifest is rewritten after each change, so a crash or a killed
/// app loses nothing: the session is offered for recovery on next launch.
class ScanSession {
  ScanSession({
    required this.id,
    required this.dir,
    required this.mode,
    List<SessionPage>? pages,
    this.targetDocumentId,
    this.replacePageId,
    this.folderId,
    DateTime? createdAt,
  })  : pages = pages ?? [],
        createdAt = createdAt ?? DateTime.now();

  final String id;
  final Directory dir;
  ScanMode mode;
  final List<SessionPage> pages;

  /// When set, pages are appended to this existing document.
  final String? targetDocumentId;

  /// When set, the (single) captured page replaces this page.
  final String? replacePageId;
  String? folderId;
  final DateTime createdAt;

  Map<String, Object?> toJson() => {
        'id': id,
        'mode': mode.name,
        'target': targetDocumentId,
        'replace': replacePageId,
        'folder': folderId,
        'created': createdAt.millisecondsSinceEpoch,
        'pages': pages.map((e) => e.toJson()).toList(),
      };
}

class ScanSessionStore {
  ScanSessionStore(this._files);
  final FileStore _files;

  Future<ScanSession> create(ScanMode mode, {String? targetDocumentId, String? replacePageId, String? folderId}) async {
    final id = newId();
    final dir = Directory(p.join(_files.sessions.path, id));
    await dir.create(recursive: true);
    final s = ScanSession(id: id, dir: dir, mode: mode, targetDocumentId: targetDocumentId, replacePageId: replacePageId, folderId: folderId);
    await save(s);
    return s;
  }

  Future<void> save(ScanSession s) async {
    final f = File(p.join(s.dir.path, 'manifest.json'));
    final tmp = File('${f.path}.part');
    await tmp.writeAsString(jsonEncode(s.toJson()), flush: true);
    await tmp.rename(f.path);
  }

  /// Stores captured bytes in the session folder and registers the page.
  Future<SessionPage> addImage(ScanSession s, Uint8List bytes, {PageEdit edit = const PageEdit(), bool detected = false}) async {
    final id = newId();
    final file = File(p.join(s.dir.path, 'raw_$id.jpg'));
    await file.writeAsBytes(bytes, flush: true);
    final page = SessionPage(id: id, rawPath: file.path, edit: edit, detected: detected);
    s.pages.add(page);
    await save(s);
    return page;
  }

  /// Moves an existing file (e.g. camera temp file) into the session.
  Future<SessionPage> addFile(ScanSession s, String path, {PageEdit edit = const PageEdit(), bool detected = false}) async {
    final id = newId();
    final target = p.join(s.dir.path, 'raw_$id${p.extension(path).isEmpty ? '.jpg' : p.extension(path)}');
    try {
      await File(path).rename(target);
    } on FileSystemException {
      await File(path).copy(target);
    }
    final page = SessionPage(id: id, rawPath: target, edit: edit, detected: detected);
    s.pages.add(page);
    await save(s);
    return page;
  }

  Future<void> removePage(ScanSession s, String pageId) async {
    final page = s.pages.where((e) => e.id == pageId).firstOrNull;
    if (page == null) return;
    s.pages.remove(page);
    final f = File(page.rawPath);
    if (await f.exists()) await f.delete();
    await save(s);
  }

  Future<void> discard(ScanSession s) async {
    if (await s.dir.exists()) await s.dir.delete(recursive: true);
  }

  /// Sessions left behind by a crash / killed app (only those with pages).
  Future<List<ScanSession>> pending() async {
    final out = <ScanSession>[];
    if (!await _files.sessions.exists()) return out;
    await for (final e in _files.sessions.list()) {
      if (e is! Directory) continue;
      final manifest = File(p.join(e.path, 'manifest.json'));
      if (!await manifest.exists()) {
        await e.delete(recursive: true);
        continue;
      }
      try {
        final j = jsonDecode(await manifest.readAsString()) as Map<String, dynamic>;
        final pages = <SessionPage>[];
        for (final raw in (j['pages'] as List)) {
          final m = raw as Map<String, dynamic>;
          final path = p.join(e.path, m['raw'] as String);
          if (!await File(path).exists()) continue;
          pages.add(SessionPage(
            id: m['id'] as String,
            rawPath: path,
            edit: PageEdit.fromJson(m['edit'] as Map<String, dynamic>),
            detected: (m['detected'] as bool?) ?? false,
          ));
        }
        if (pages.isEmpty) {
          await e.delete(recursive: true);
          continue;
        }
        out.add(ScanSession(
          id: j['id'] as String,
          dir: e,
          mode: ScanMode.fromName(j['mode'] as String?),
          pages: pages,
          targetDocumentId: j['target'] as String?,
          replacePageId: j['replace'] as String?,
          folderId: j['folder'] as String?,
          createdAt: DateTime.fromMillisecondsSinceEpoch((j['created'] as int?) ?? 0),
        ));
      } catch (_) {
        // Corrupt manifest: keep the images recoverable by not deleting blindly.
        continue;
      }
    }
    out.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return out;
  }
}
