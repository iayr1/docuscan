import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../image/image_types.dart';

enum PdfQuality {
  low('Small file', 1240, 55),
  medium('Balanced', 1754, 72),
  high('High', 2480, 85),
  original('Original', 4000, 92);

  const PdfQuality(this.label, this.maxEdge, this.jpegQuality);
  final String label;

  /// Longest image edge embedded per page (1754 px ≈ A4 @ 150 dpi).
  final int maxEdge;
  final int jpegQuality;

  static PdfQuality fromName(String? n) => values.firstWhere((v) => v.name == n, orElse: () => PdfQuality.high);
}

enum ExportFormat { pdf, jpg, png }

enum OcrLanguage {
  latin('Latin (English, Spanish, French, German…)'),
  devanagari('Devanagari (Hindi, Marathi, Nepali, Sanskrit)'),
  chinese('Chinese'),
  japanese('Japanese'),
  korean('Korean');

  const OcrLanguage(this.label);
  final String label;
  static OcrLanguage fromName(String? n) => values.firstWhere((v) => v.name == n, orElse: () => OcrLanguage.latin);
}

/// Immutable snapshot of all user preferences.
class AppSettings {
  const AppSettings({
    this.themeMode = ThemeMode.system,
    this.ocrLanguage = OcrLanguage.latin,
    this.defaultExportFormat = ExportFormat.pdf,
    this.pdfQuality = PdfQuality.high,
    this.imageQuality = 88,
    this.pageSize = 'A4',
    this.defaultFilter = ScanFilter.auto,
    this.autoCrop = true,
    this.autoCapture = false,
    this.showGrid = true,
    this.flashMode = 'auto',
    this.captureSound = true,
    this.saveOriginal = true,
    this.saveToGallery = false,
    this.defaultFolderId,
    this.useNativeScanner = true,
    this.autoOcr = false,
    this.appLockEnabled = false,
    this.biometricsEnabled = false,
    this.autoLockSeconds = 30,
    this.hideInRecents = false,
    this.listView = false,
    this.onboardingDone = false,
    this.customFilters = const [],
  });

  final ThemeMode themeMode;
  final OcrLanguage ocrLanguage;
  final ExportFormat defaultExportFormat;
  final PdfQuality pdfQuality;
  final int imageQuality;
  final String pageSize;
  final ScanFilter defaultFilter;
  final bool autoCrop;
  final bool autoCapture;
  final bool showGrid;
  final String flashMode;
  final bool captureSound;
  final bool saveOriginal;
  final bool saveToGallery;
  final String? defaultFolderId;

  /// Use the platform document scanner (ML Kit on Android / VisionKit on iOS)
  /// instead of the in-app camera as the default "Scan" action.
  final bool useNativeScanner;
  final bool autoOcr;
  final bool appLockEnabled;
  final bool biometricsEnabled;
  final int autoLockSeconds;
  final bool hideInRecents;
  final bool listView;
  final bool onboardingDone;

  /// User saved filter presets: "name|filter|adjustmentsJson".
  final List<String> customFilters;

  AppSettings copyWith({
    ThemeMode? themeMode,
    OcrLanguage? ocrLanguage,
    ExportFormat? defaultExportFormat,
    PdfQuality? pdfQuality,
    int? imageQuality,
    String? pageSize,
    ScanFilter? defaultFilter,
    bool? autoCrop,
    bool? autoCapture,
    bool? showGrid,
    String? flashMode,
    bool? captureSound,
    bool? saveOriginal,
    bool? saveToGallery,
    String? defaultFolderId,
    bool clearDefaultFolder = false,
    bool? useNativeScanner,
    bool? autoOcr,
    bool? appLockEnabled,
    bool? biometricsEnabled,
    int? autoLockSeconds,
    bool? hideInRecents,
    bool? listView,
    bool? onboardingDone,
    List<String>? customFilters,
  }) =>
      AppSettings(
        themeMode: themeMode ?? this.themeMode,
        ocrLanguage: ocrLanguage ?? this.ocrLanguage,
        defaultExportFormat: defaultExportFormat ?? this.defaultExportFormat,
        pdfQuality: pdfQuality ?? this.pdfQuality,
        imageQuality: imageQuality ?? this.imageQuality,
        pageSize: pageSize ?? this.pageSize,
        defaultFilter: defaultFilter ?? this.defaultFilter,
        autoCrop: autoCrop ?? this.autoCrop,
        autoCapture: autoCapture ?? this.autoCapture,
        showGrid: showGrid ?? this.showGrid,
        flashMode: flashMode ?? this.flashMode,
        captureSound: captureSound ?? this.captureSound,
        saveOriginal: saveOriginal ?? this.saveOriginal,
        saveToGallery: saveToGallery ?? this.saveToGallery,
        defaultFolderId: clearDefaultFolder ? null : (defaultFolderId ?? this.defaultFolderId),
        useNativeScanner: useNativeScanner ?? this.useNativeScanner,
        autoOcr: autoOcr ?? this.autoOcr,
        appLockEnabled: appLockEnabled ?? this.appLockEnabled,
        biometricsEnabled: biometricsEnabled ?? this.biometricsEnabled,
        autoLockSeconds: autoLockSeconds ?? this.autoLockSeconds,
        hideInRecents: hideInRecents ?? this.hideInRecents,
        listView: listView ?? this.listView,
        onboardingDone: onboardingDone ?? this.onboardingDone,
        customFilters: customFilters ?? this.customFilters,
      );
}

/// Persists [AppSettings] in SharedPreferences (non-sensitive values only;
/// the PIN hash and vault key live in the platform keystore).
class SettingsStore {
  SettingsStore(this._prefs);
  final SharedPreferences _prefs;

  static Future<SettingsStore> open() async => SettingsStore(await SharedPreferences.getInstance());

  AppSettings load() {
    final p = _prefs;
    return AppSettings(
      themeMode: ThemeMode.values.firstWhere((m) => m.name == p.getString('themeMode'), orElse: () => ThemeMode.system),
      ocrLanguage: OcrLanguage.fromName(p.getString('ocrLanguage')),
      defaultExportFormat:
          ExportFormat.values.firstWhere((f) => f.name == p.getString('exportFormat'), orElse: () => ExportFormat.pdf),
      pdfQuality: PdfQuality.fromName(p.getString('pdfQuality')),
      imageQuality: p.getInt('imageQuality') ?? 88,
      pageSize: p.getString('pageSize') ?? 'A4',
      defaultFilter: ScanFilter.fromName(p.getString('defaultFilter')),
      autoCrop: p.getBool('autoCrop') ?? true,
      autoCapture: p.getBool('autoCapture') ?? false,
      showGrid: p.getBool('showGrid') ?? true,
      flashMode: p.getString('flashMode') ?? 'auto',
      captureSound: p.getBool('captureSound') ?? true,
      saveOriginal: p.getBool('saveOriginal') ?? true,
      saveToGallery: p.getBool('saveToGallery') ?? false,
      defaultFolderId: p.getString('defaultFolderId'),
      useNativeScanner: p.getBool('useNativeScanner') ?? true,
      autoOcr: p.getBool('autoOcr') ?? false,
      appLockEnabled: p.getBool('appLockEnabled') ?? false,
      biometricsEnabled: p.getBool('biometricsEnabled') ?? false,
      autoLockSeconds: p.getInt('autoLockSeconds') ?? 30,
      hideInRecents: p.getBool('hideInRecents') ?? false,
      listView: p.getBool('listView') ?? false,
      onboardingDone: p.getBool('onboardingDone') ?? false,
      customFilters: p.getStringList('customFilters') ?? const [],
    );
  }

  Future<void> save(AppSettings s) async {
    final p = _prefs;
    await p.setString('themeMode', s.themeMode.name);
    await p.setString('ocrLanguage', s.ocrLanguage.name);
    await p.setString('exportFormat', s.defaultExportFormat.name);
    await p.setString('pdfQuality', s.pdfQuality.name);
    await p.setInt('imageQuality', s.imageQuality);
    await p.setString('pageSize', s.pageSize);
    await p.setString('defaultFilter', s.defaultFilter.name);
    await p.setBool('autoCrop', s.autoCrop);
    await p.setBool('autoCapture', s.autoCapture);
    await p.setBool('showGrid', s.showGrid);
    await p.setString('flashMode', s.flashMode);
    await p.setBool('captureSound', s.captureSound);
    await p.setBool('saveOriginal', s.saveOriginal);
    await p.setBool('saveToGallery', s.saveToGallery);
    if (s.defaultFolderId == null) {
      await p.remove('defaultFolderId');
    } else {
      await p.setString('defaultFolderId', s.defaultFolderId!);
    }
    await p.setBool('useNativeScanner', s.useNativeScanner);
    await p.setBool('autoOcr', s.autoOcr);
    await p.setBool('appLockEnabled', s.appLockEnabled);
    await p.setBool('biometricsEnabled', s.biometricsEnabled);
    await p.setInt('autoLockSeconds', s.autoLockSeconds);
    await p.setBool('hideInRecents', s.hideInRecents);
    await p.setBool('listView', s.listView);
    await p.setBool('onboardingDone', s.onboardingDone);
    await p.setStringList('customFilters', s.customFilters);
  }

  Future<void> reset({bool keepSecurity = true}) async {
    final current = load();
    await _prefs.clear();
    if (keepSecurity) {
      await save(AppSettings(
        appLockEnabled: current.appLockEnabled,
        biometricsEnabled: current.biometricsEnabled,
        autoLockSeconds: current.autoLockSeconds,
        onboardingDone: true,
      ));
    }
  }
}
