import 'dart:convert';

import '../../core/image/image_types.dart';

DateTime _dt(Object? v) => DateTime.fromMillisecondsSinceEpoch((v as int?) ?? 0);
DateTime? _dtn(Object? v) => v == null ? null : DateTime.fromMillisecondsSinceEpoch(v as int);
bool _b(Object? v) => (v as int? ?? 0) == 1;

enum ScanMode {
  document('Document', 'General documents'),
  idCard('ID card', 'Front & back on one page'),
  passport('Passport', 'Photo page, no enhancement loss'),
  receipt('Receipt', 'High contrast, saved to Receipts'),
  businessCard('Business card', 'Small cards, auto crop'),
  book('Book', 'Splits two-page spreads'),
  whiteboard('Whiteboard', 'Removes glare & grey'),
  notes('Notes', 'Handwritten notes'),
  certificate('Certificate', 'Landscape, colour preserved'),
  photo('Photo', 'Keeps natural colours'),
  qrCode('QR / Barcode', 'Read codes on-device');

  const ScanMode(this.label, this.description);
  final String label;
  final String description;

  static ScanMode fromName(String? n) =>
      ScanMode.values.firstWhere((m) => m.name == n, orElse: () => ScanMode.document);

  ScanFilter get defaultFilter => switch (this) {
        ScanMode.receipt => ScanFilter.blackWhite,
        ScanMode.whiteboard => ScanFilter.whiteboard,
        ScanMode.photo || ScanMode.passport => ScanFilter.photo,
        ScanMode.certificate || ScanMode.idCard || ScanMode.businessCard => ScanFilter.magic,
        ScanMode.notes => ScanFilter.magic,
        _ => ScanFilter.auto,
      };

  bool get autoCrop => this != ScanMode.photo;
}

class Document {
  const Document({
    required this.id,
    required this.title,
    this.folderId,
    this.pageCount = 0,
    this.fileSize = 0,
    this.category,
    this.description,
    this.notes,
    this.scanMode = ScanMode.document,
    this.source = 'scan',
    this.isLocked = false,
    this.isHidden = false,
    this.inVault = false,
    this.contentHash,
    this.thumbnailPath,
    required this.createdAt,
    required this.updatedAt,
    this.lastOpenedAt,
    this.deletedAt,
    this.isFavorite = false,
    this.tags = const [],
    this.folderName,
  });

  final String id;
  final String title;
  final String? folderId;
  final int pageCount;
  final int fileSize;
  final String? category;
  final String? description;
  final String? notes;
  final ScanMode scanMode;
  final String source;
  final bool isLocked;
  final bool isHidden;
  final bool inVault;
  final String? contentHash;
  final String? thumbnailPath;
  final DateTime createdAt;
  final DateTime updatedAt;
  final DateTime? lastOpenedAt;
  final DateTime? deletedAt;

  // Joined / derived
  final bool isFavorite;
  final List<Tag> tags;
  final String? folderName;

  bool get isDeleted => deletedAt != null;

  factory Document.fromRow(Map<String, Object?> r, {List<Tag> tags = const []}) => Document(
        id: r['id'] as String,
        title: r['title'] as String,
        folderId: r['folder_id'] as String?,
        pageCount: (r['page_count'] as int?) ?? 0,
        fileSize: (r['file_size'] as int?) ?? 0,
        category: r['category'] as String?,
        description: r['description'] as String?,
        notes: r['notes'] as String?,
        scanMode: ScanMode.fromName(r['scan_mode'] as String?),
        source: (r['source'] as String?) ?? 'scan',
        isLocked: _b(r['is_locked']),
        isHidden: _b(r['is_hidden']),
        inVault: _b(r['in_vault']),
        contentHash: r['content_hash'] as String?,
        thumbnailPath: r['thumbnail_path'] as String?,
        createdAt: _dt(r['created_at']),
        updatedAt: _dt(r['updated_at']),
        lastOpenedAt: _dtn(r['last_opened_at']),
        deletedAt: _dtn(r['deleted_at']),
        isFavorite: _b(r['is_favorite']),
        folderName: r['folder_name'] as String?,
        tags: tags,
      );

  Document copyWith({String? title, List<Tag>? tags, bool? isFavorite}) => Document(
        id: id,
        title: title ?? this.title,
        folderId: folderId,
        pageCount: pageCount,
        fileSize: fileSize,
        category: category,
        description: description,
        notes: notes,
        scanMode: scanMode,
        source: source,
        isLocked: isLocked,
        isHidden: isHidden,
        inVault: inVault,
        contentHash: contentHash,
        thumbnailPath: thumbnailPath,
        createdAt: createdAt,
        updatedAt: updatedAt,
        lastOpenedAt: lastOpenedAt,
        deletedAt: deletedAt,
        isFavorite: isFavorite ?? this.isFavorite,
        tags: tags ?? this.tags,
        folderName: folderName,
      );
}

class DocPage {
  const DocPage({
    required this.id,
    required this.documentId,
    required this.index,
    required this.originalPath,
    required this.imagePath,
    this.thumbnailPath,
    this.edit = const PageEdit(),
    this.width = 0,
    this.height = 0,
    this.fileSize = 0,
    this.contentHash,
    required this.createdAt,
    required this.updatedAt,
  });

  final String id;
  final String documentId;
  final int index;
  final String originalPath;
  final String imagePath;
  final String? thumbnailPath;
  final PageEdit edit;
  final int width;
  final int height;
  final int fileSize;
  final String? contentHash;
  final DateTime createdAt;
  final DateTime updatedAt;

  double get aspect => width == 0 || height == 0 ? 0.707 : width / height;

  factory DocPage.fromRow(Map<String, Object?> r) {
    PageEdit edit = const PageEdit();
    final raw = r['edit_json'] as String?;
    if (raw != null && raw.isNotEmpty) {
      try {
        edit = PageEdit.fromJson(jsonDecode(raw) as Map<String, dynamic>);
      } catch (_) {}
    }
    return DocPage(
      id: r['id'] as String,
      documentId: r['document_id'] as String,
      index: r['page_index'] as int,
      originalPath: r['original_path'] as String,
      imagePath: r['image_path'] as String,
      thumbnailPath: r['thumbnail_path'] as String?,
      edit: edit,
      width: (r['width'] as int?) ?? 0,
      height: (r['height'] as int?) ?? 0,
      fileSize: (r['file_size'] as int?) ?? 0,
      contentHash: r['content_hash'] as String?,
      createdAt: _dt(r['created_at']),
      updatedAt: _dt(r['updated_at']),
    );
  }
}

class Folder {
  const Folder({
    required this.id,
    required this.name,
    this.parentId,
    this.color,
    required this.createdAt,
    required this.updatedAt,
    this.documentCount = 0,
    this.subfolderCount = 0,
  });

  final String id;
  final String name;
  final String? parentId;
  final int? color;
  final DateTime createdAt;
  final DateTime updatedAt;
  final int documentCount;
  final int subfolderCount;

  factory Folder.fromRow(Map<String, Object?> r) => Folder(
        id: r['id'] as String,
        name: r['name'] as String,
        parentId: r['parent_id'] as String?,
        color: r['color'] as int?,
        createdAt: _dt(r['created_at']),
        updatedAt: _dt(r['updated_at']),
        documentCount: (r['document_count'] as int?) ?? 0,
        subfolderCount: (r['subfolder_count'] as int?) ?? 0,
      );
}

class Tag {
  const Tag({required this.id, required this.name, this.color, this.usage = 0});
  final String id;
  final String name;
  final int? color;
  final int usage;

  factory Tag.fromRow(Map<String, Object?> r) => Tag(
        id: r['id'] as String,
        name: r['name'] as String,
        color: r['color'] as int?,
        usage: (r['usage'] as int?) ?? 0,
      );

  @override
  bool operator ==(Object other) => other is Tag && other.id == id;
  @override
  int get hashCode => id.hashCode;
}

enum AnnotationKind { pen, highlighter, underline, strikeout, line, arrow, rect, ellipse, text, image, redact }

/// A vector annotation stored with normalized (0..1) page coordinates so it
/// survives re-processing of the page image at any resolution.
class Annotation {
  const Annotation({
    required this.id,
    required this.pageId,
    required this.kind,
    this.color = 0xFFE53935,
    this.strokeWidth = 0.004,
    this.points = const [],
    this.left = 0,
    this.top = 0,
    this.width = 0,
    this.height = 0,
    this.text,
    this.fontSize = 0.03,
    this.imagePath,
    this.rotation = 0,
    this.filled = false,
    this.zIndex = 0,
  });

  final String id;
  final String pageId;
  final AnnotationKind kind;
  final int color;

  /// Relative to page width.
  final double strokeWidth;
  final List<Pt> points;
  final double left, top, width, height;
  final String? text;

  /// Relative to page width.
  final double fontSize;
  final String? imagePath;

  /// Degrees, clockwise.
  final double rotation;
  final bool filled;
  final int zIndex;

  bool get isBoxed => kind == AnnotationKind.text || kind == AnnotationKind.image ||
      kind == AnnotationKind.rect || kind == AnnotationKind.ellipse || kind == AnnotationKind.redact;

  Annotation copyWith({
    int? color,
    double? strokeWidth,
    List<Pt>? points,
    double? left,
    double? top,
    double? width,
    double? height,
    String? text,
    double? fontSize,
    double? rotation,
    bool? filled,
    int? zIndex,
  }) =>
      Annotation(
        id: id,
        pageId: pageId,
        kind: kind,
        color: color ?? this.color,
        strokeWidth: strokeWidth ?? this.strokeWidth,
        points: points ?? this.points,
        left: left ?? this.left,
        top: top ?? this.top,
        width: width ?? this.width,
        height: height ?? this.height,
        text: text ?? this.text,
        fontSize: fontSize ?? this.fontSize,
        imagePath: imagePath,
        rotation: rotation ?? this.rotation,
        filled: filled ?? this.filled,
        zIndex: zIndex ?? this.zIndex,
      );

  Map<String, Object?> dataJson() => {
        'color': color,
        'stroke': strokeWidth,
        'points': [for (final p in points) ...[double.parse(p.x.toStringAsFixed(4)), double.parse(p.y.toStringAsFixed(4))]],
        'l': left,
        't': top,
        'w': width,
        'h': height,
        'text': text,
        'font': fontSize,
        'image': imagePath,
        'rot': rotation,
        'fill': filled,
      };

  factory Annotation.fromRow(Map<String, Object?> r) {
    final d = jsonDecode(r['data_json'] as String) as Map<String, dynamic>;
    final raw = (d['points'] as List?)?.map((e) => (e as num).toDouble()).toList() ?? const [];
    double n(String k, [double def = 0]) => (d[k] as num?)?.toDouble() ?? def;
    return Annotation(
      id: r['id'] as String,
      pageId: r['page_id'] as String,
      kind: AnnotationKind.values.firstWhere((k) => k.name == r['kind'], orElse: () => AnnotationKind.pen),
      color: (d['color'] as int?) ?? 0xFFE53935,
      strokeWidth: n('stroke', 0.004),
      points: [for (var i = 0; i + 1 < raw.length; i += 2) Pt(raw[i], raw[i + 1])],
      left: n('l'),
      top: n('t'),
      width: n('w'),
      height: n('h'),
      text: d['text'] as String?,
      fontSize: n('font', 0.03),
      imagePath: d['image'] as String?,
      rotation: n('rot'),
      filled: (d['fill'] as bool?) ?? false,
      zIndex: (r['z_index'] as int?) ?? 0,
    );
  }
}

class Signature {
  const Signature({required this.id, required this.name, required this.path, this.color, required this.createdAt, this.strokes});
  final String id;
  final String name;
  final String path;
  final int? color;
  final DateTime createdAt;

  /// Serialized vector strokes for drawn signatures (allows re-editing).
  final String? strokes;

  factory Signature.fromRow(Map<String, Object?> r) => Signature(
        id: r['id'] as String,
        name: r['name'] as String,
        path: r['path'] as String,
        color: r['color'] as int?,
        createdAt: _dt(r['created_at']),
        strokes: r['stroke_json'] as String?,
      );
}

enum StampKind { text, date, company, image, approved }

class Stamp {
  const Stamp({
    required this.id,
    required this.name,
    required this.kind,
    this.text,
    this.subtext,
    this.color = 0xFFC62828,
    this.path,
    required this.createdAt,
  });
  final String id;
  final String name;
  final StampKind kind;
  final String? text;
  final String? subtext;
  final int color;

  /// Rendered PNG (always present after save).
  final String? path;
  final DateTime createdAt;

  factory Stamp.fromRow(Map<String, Object?> r) => Stamp(
        id: r['id'] as String,
        name: r['name'] as String,
        kind: StampKind.values.firstWhere((k) => k.name == r['kind'], orElse: () => StampKind.text),
        text: r['text'] as String?,
        subtext: r['subtext'] as String?,
        color: (r['color'] as int?) ?? 0xFFC62828,
        path: r['path'] as String?,
        createdAt: _dt(r['created_at']),
      );
}

class OcrBlock {
  const OcrBlock(this.text, this.left, this.top, this.width, this.height);
  final String text;

  /// Normalized to the page image.
  final double left, top, width, height;

  List<Object> toJson() => [text, left, top, width, height];
  factory OcrBlock.fromJson(List<dynamic> j) => OcrBlock(
        j[0] as String,
        (j[1] as num).toDouble(),
        (j[2] as num).toDouble(),
        (j[3] as num).toDouble(),
        (j[4] as num).toDouble(),
      );
}

class OcrResult {
  const OcrResult({
    required this.id,
    required this.pageId,
    required this.documentId,
    required this.script,
    required this.text,
    this.lines = const [],
    this.edited = false,
    required this.updatedAt,
  });
  final String id;
  final String pageId;
  final String documentId;
  final String script;
  final String text;

  /// Line-level boxes; used for the searchable PDF text layer.
  final List<OcrBlock> lines;
  final bool edited;
  final DateTime updatedAt;

  factory OcrResult.fromRow(Map<String, Object?> r) {
    var lines = <OcrBlock>[];
    final raw = r['blocks_json'] as String?;
    if (raw != null && raw.isNotEmpty) {
      try {
        lines = (jsonDecode(raw) as List).map((e) => OcrBlock.fromJson(e as List)).toList();
      } catch (_) {}
    }
    return OcrResult(
      id: r['id'] as String,
      pageId: r['page_id'] as String,
      documentId: r['document_id'] as String,
      script: r['script'] as String,
      text: r['text'] as String,
      lines: lines,
      edited: _b(r['edited']),
      updatedAt: _dt(r['updated_at']),
    );
  }
}

class HistoryEntry {
  const HistoryEntry({required this.id, this.documentId, required this.mode, required this.pageCount, required this.action, this.detail, required this.createdAt, this.documentTitle});
  final String id;
  final String? documentId;
  final String mode;
  final int pageCount;
  final String action;
  final String? detail;
  final DateTime createdAt;
  final String? documentTitle;

  factory HistoryEntry.fromRow(Map<String, Object?> r) => HistoryEntry(
        id: r['id'] as String,
        documentId: r['document_id'] as String?,
        mode: r['mode'] as String,
        pageCount: r['page_count'] as int,
        action: r['action'] as String,
        detail: r['detail'] as String?,
        createdAt: _dt(r['created_at']),
        documentTitle: r['title'] as String?,
      );
}

class ExportRecord {
  const ExportRecord({required this.id, this.documentId, required this.title, required this.format, required this.target, this.path, required this.createdAt});
  final String id;
  final String? documentId;
  final String title;
  final String format;
  final String target;
  final String? path;
  final DateTime createdAt;

  factory ExportRecord.fromRow(Map<String, Object?> r) => ExportRecord(
        id: r['id'] as String,
        documentId: r['document_id'] as String?,
        title: r['title'] as String,
        format: r['format'] as String,
        target: r['target'] as String,
        path: r['path'] as String?,
        createdAt: _dt(r['created_at']),
      );
}

enum DocSort {
  modifiedDesc('Last modified'),
  createdDesc('Date created (newest)'),
  createdAsc('Date created (oldest)'),
  nameAsc('Name A–Z'),
  nameDesc('Name Z–A'),
  sizeDesc('Size (largest)'),
  sizeAsc('Size (smallest)');

  const DocSort(this.label);
  final String label;

  String get sql => switch (this) {
        DocSort.modifiedDesc => 'd.updated_at DESC',
        DocSort.createdDesc => 'd.created_at DESC',
        DocSort.createdAsc => 'd.created_at ASC',
        DocSort.nameAsc => 'd.title COLLATE NOCASE ASC',
        DocSort.nameDesc => 'd.title COLLATE NOCASE DESC',
        DocSort.sizeDesc => 'd.file_size DESC',
        DocSort.sizeAsc => 'd.file_size ASC',
      };
}

/// Filter for listing documents. `folderId == null && !allFolders` = root only.
class DocumentQuery {
  const DocumentQuery({
    this.folderId,
    this.allFolders = true,
    this.search,
    this.tagId,
    this.category,
    this.favoritesOnly = false,
    this.includeHidden = false,
    this.vault = false,
    this.trashed = false,
    this.sort = DocSort.modifiedDesc,
    this.limit,
    this.offset = 0,
  });

  final String? folderId;
  final bool allFolders;
  final String? search;
  final String? tagId;
  final String? category;
  final bool favoritesOnly;
  final bool includeHidden;
  final bool vault;
  final bool trashed;
  final DocSort sort;
  final int? limit;
  final int offset;

  DocumentQuery copyWith({String? search, DocSort? sort, int? limit, int? offset, bool? includeHidden}) => DocumentQuery(
        folderId: folderId,
        allFolders: allFolders,
        search: search ?? this.search,
        tagId: tagId,
        category: category,
        favoritesOnly: favoritesOnly,
        includeHidden: includeHidden ?? this.includeHidden,
        vault: vault,
        trashed: trashed,
        sort: sort ?? this.sort,
        limit: limit ?? this.limit,
        offset: offset ?? this.offset,
      );

  @override
  bool operator ==(Object other) =>
      other is DocumentQuery &&
      other.folderId == folderId &&
      other.allFolders == allFolders &&
      other.search == search &&
      other.tagId == tagId &&
      other.category == category &&
      other.favoritesOnly == favoritesOnly &&
      other.includeHidden == includeHidden &&
      other.vault == vault &&
      other.trashed == trashed &&
      other.sort == sort &&
      other.limit == limit &&
      other.offset == offset;

  @override
  int get hashCode => Object.hash(folderId, allFolders, search, tagId, category, favoritesOnly, includeHidden, vault, trashed, sort, limit, offset);
}

class LibraryStats {
  const LibraryStats({
    this.documents = 0,
    this.pages = 0,
    this.folders = 0,
    this.favorites = 0,
    this.trashed = 0,
    this.bytes = 0,
    this.scansThisMonth = 0,
  });
  final int documents;
  final int pages;
  final int folders;
  final int favorites;
  final int trashed;
  final int bytes;
  final int scansThisMonth;
}
