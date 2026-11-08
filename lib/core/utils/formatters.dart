import 'package:intl/intl.dart';

String formatBytes(int bytes, {int decimals = 1}) {
  if (bytes <= 0) return '0 B';
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  var value = bytes.toDouble();
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  return '${value.toStringAsFixed(unit == 0 ? 0 : decimals)} ${units[unit]}';
}

String formatDate(DateTime date) => DateFormat('d MMM yyyy').format(date);

String formatDateTime(DateTime date) => DateFormat('d MMM yyyy, HH:mm').format(date);

/// "Just now", "5 min ago", "Yesterday", or a date.
String formatRelative(DateTime date, {DateTime? now}) {
  final ref = now ?? DateTime.now();
  final diff = ref.difference(date);
  if (diff.inSeconds < 60) return 'Just now';
  if (diff.inMinutes < 60) return '${diff.inMinutes} min ago';
  if (diff.inHours < 24 && ref.day == date.day) return '${diff.inHours} h ago';
  final yesterday = DateTime(ref.year, ref.month, ref.day - 1);
  if (date.year == yesterday.year && date.month == yesterday.month && date.day == yesterday.day) {
    return 'Yesterday';
  }
  return formatDate(date);
}

/// Default title for new scans, e.g. "Scan 2026-11-08 14.32".
String defaultScanTitle([String prefix = 'Scan', DateTime? at]) =>
    '$prefix ${DateFormat('yyyy-MM-dd HH.mm').format(at ?? DateTime.now())}';

/// Strips characters that are invalid in file names on Android / iOS / Windows.
String sanitizeFileName(String input, {String fallback = 'document'}) {
  final cleaned = input
      .replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1F]'), '')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  if (cleaned.isEmpty) return fallback;
  return cleaned.length > 120 ? cleaned.substring(0, 120).trim() : cleaned;
}

/// Returns [name] or "name (2)", "name (3)" ... so it does not clash with [existing].
String uniqueName(String name, Iterable<String> existing) {
  final lower = existing.map((e) => e.toLowerCase()).toSet();
  if (!lower.contains(name.toLowerCase())) return name;
  var i = 2;
  while (lower.contains('$name ($i)'.toLowerCase())) {
    i++;
  }
  return '$name ($i)';
}

/// Parses page ranges like "1-3, 5, 8-9" into zero-based indexes.
/// Throws [FormatException] for malformed or out-of-bounds input.
List<int> parsePageRanges(String input, int pageCount) {
  final result = <int>[];
  for (final raw in input.split(',')) {
    final part = raw.trim();
    if (part.isEmpty) continue;
    final match = RegExp(r'^(\d+)\s*(?:-\s*(\d+))?$').firstMatch(part);
    if (match == null) throw FormatException('Invalid range "$part"');
    final start = int.parse(match.group(1)!);
    final end = match.group(2) == null ? start : int.parse(match.group(2)!);
    if (start < 1 || end > pageCount || start > end) {
      throw FormatException('Range "$part" is outside 1-$pageCount');
    }
    for (var p = start; p <= end; p++) {
      if (!result.contains(p - 1)) result.add(p - 1);
    }
  }
  if (result.isEmpty) throw const FormatException('No pages selected');
  return result;
}
