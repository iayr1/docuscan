/// Application-wide constants.
abstract final class AppConstants {
  static const appName = 'DocuScan';
  static const appVersion = '1.0.0';

  /// Root folder created inside the app documents directory.
  static const rootFolderName = 'DocumentScanner';

  /// Days a soft-deleted document stays in the recycle bin.
  static const trashRetentionDays = 30;

  /// Longest edge (px) that processed page images are clamped to.
  /// Keeps memory bounded on 48MP+ sensors while staying print quality.
  static const maxProcessedEdge = 3000;

  /// Longest edge (px) of generated thumbnails.
  static const thumbnailEdge = 360;

  static const defaultFolders = ['Personal', 'Education', 'Business', 'Receipts'];

  static const pageSizeKeys = ['A4', 'A3', 'Letter', 'Legal', 'Fit', 'Custom'];
}

/// Subdirectory names under [AppConstants.rootFolderName].
abstract final class StorageDirs {
  static const scannedImages = 'ScannedImages';
  static const pdf = 'PDF';
  static const signatures = 'Signatures';
  static const stamps = 'Stamps';
  static const thumbnails = 'Thumbnails';
  static const ocr = 'OCR';
  static const temp = 'Temp';
  static const trash = 'Trash';
  static const secureVault = 'SecureVault';
  static const exports = 'Exports';
  static const sessions = 'Sessions';

  static const all = [
    scannedImages,
    pdf,
    signatures,
    stamps,
    thumbnails,
    ocr,
    temp,
    trash,
    secureVault,
    exports,
    sessions,
  ];
}
