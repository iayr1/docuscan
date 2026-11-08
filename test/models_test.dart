import 'package:flutter_test/flutter_test.dart';
import 'package:docu_scan/core/image/image_types.dart';
import 'package:docu_scan/data/models/models.dart';

void main() {
  group('Quad and Geometry Tests', () {
    test('Quad.full has 4 normalized corners', () {
      final quad = Quad.full();
      expect(quad.tl, const Pt(0, 0));
      expect(quad.tr, const Pt(1, 0));
      expect(quad.br, const Pt(1, 1));
      expect(quad.bl, const Pt(0, 1));
      expect(quad.isFull, isTrue);
      expect(quad.area, closeTo(1.0, 0.001));
    });

    test('Quad serialization roundtrip', () {
      final quad = const Quad(Pt(0.1, 0.1), Pt(0.9, 0.1), Pt(0.85, 0.95), Pt(0.15, 0.9));
      final encoded = quad.encode();
      final decoded = Quad.tryDecode(encoded);
      expect(decoded, isNotNull);
      expect(decoded!.tl.x, closeTo(0.1, 0.001));
      expect(decoded.br.y, closeTo(0.95, 0.001));
    });

    test('Quad withPoint clamps to 0..1', () {
      final quad = Quad.full().withPoint(0, const Pt(-0.5, 1.5));
      expect(quad.tl.x, 0.0);
      expect(quad.tl.y, 1.0);
    });
  });

  group('PageEdit and Adjustments Tests', () {
    test('PageEdit JSON roundtrip', () {
      const edit = PageEdit(
        rotation: 2,
        filter: ScanFilter.magic,
        adjustments: ImageAdjustments(brightness: 0.2, contrast: 0.4),
        deskew: true,
      );

      final json = edit.toJson();
      final restored = PageEdit.fromJson(json);

      expect(restored.rotation, 2);
      expect(restored.filter, ScanFilter.magic);
      expect(restored.adjustments.brightness, 0.2);
      expect(restored.adjustments.contrast, 0.4);
      expect(restored.deskew, isTrue);
    });

    test('ImageAdjustments neutral check', () {
      expect(ImageAdjustments.none.isNeutral, isTrue);
      const modified = ImageAdjustments(sharpness: 0.5);
      expect(modified.isNeutral, isFalse);
    });
  });

  group('Entity Models Tests', () {
    test('ScanMode defaults', () {
      expect(ScanMode.receipt.defaultFilter, ScanFilter.blackWhite);
      expect(ScanMode.whiteboard.defaultFilter, ScanFilter.whiteboard);
      expect(ScanMode.document.defaultFilter, ScanFilter.auto);
      expect(ScanMode.photo.autoCrop, isFalse);
    });

    test('Document model properties', () {
      final doc = Document(
        id: 'doc-123',
        title: 'Tax Invoice',
        pageCount: 3,
        fileSize: 1024000,
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
        isFavorite: true,
      );

      expect(doc.id, 'doc-123');
      expect(doc.title, 'Tax Invoice');
      expect(doc.pageCount, 3);
      expect(doc.isFavorite, isTrue);
      expect(doc.isDeleted, isFalse);
    });
  });
}
