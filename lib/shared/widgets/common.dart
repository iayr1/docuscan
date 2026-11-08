import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/errors/app_exception.dart';
import '../../core/theme/app_theme.dart';

void showSnack(BuildContext context, String message, {bool error = false, SnackBarAction? action}) {
  final messenger = ScaffoldMessenger.maybeOf(context);
  if (messenger == null) return;
  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(
      content: Text(message),
      backgroundColor: error ? context.colors.error : null,
      action: action,
    ));
}

typedef ProgressUpdate = void Function(String message, [double? fraction]);

/// Runs [task] behind a blocking progress dialog. Errors are caught and shown
/// as a snackbar; returns null on failure.
Future<T?> runWithProgress<T>(BuildContext context, String message, Future<T> Function(ProgressUpdate update) task) async {
  final status = ValueNotifier<(String, double?)>((message, null));
  final navigator = Navigator.of(context, rootNavigator: true);
  var open = true;
  showDialog<void>(
    context: context,
    barrierDismissible: false,
    useRootNavigator: true,
    builder: (_) => PopScope(
      canPop: false,
      child: Dialog(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: ValueListenableBuilder<(String, double?)>(
            valueListenable: status,
            builder: (context, v, _) => Column(mainAxisSize: MainAxisSize.min, children: [
              SizedBox(width: 44, height: 44, child: CircularProgressIndicator(value: v.$2, strokeWidth: 3.5)),
              const SizedBox(height: 18),
              Text(v.$1, textAlign: TextAlign.center, style: context.text.titleSmall),
            ]),
          ),
        ),
      ),
    ),
  ).then((_) => open = false);
  try {
    final result = await task((m, [f]) => status.value = (m, f));
    return result;
  } catch (e) {
    if (context.mounted) showSnack(context, describeError(e), error: true);
    return null;
  } finally {
    if (open) navigator.pop();
    status.dispose();
  }
}

Future<bool> confirm(BuildContext context, String title, String message, {String confirmLabel = 'Confirm', bool destructive = false}) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: Text(message),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
        FilledButton(
          style: destructive ? FilledButton.styleFrom(backgroundColor: ctx.colors.error, foregroundColor: ctx.colors.onError) : null,
          onPressed: () => Navigator.pop(ctx, true),
          child: Text(confirmLabel),
        ),
      ],
    ),
  );
  return ok ?? false;
}

Future<String?> promptText(
  BuildContext context,
  String title, {
  String? initial,
  String? label,
  String? hint,
  String confirmLabel = 'Save',
  bool obscure = false,
  bool allowEmpty = false,
  int maxLines = 1,
  TextInputType? keyboard,
  List<TextInputFormatter>? formatters,
  String? helper,
}) {
  final controller = TextEditingController(text: initial);
  controller.selection = TextSelection(baseOffset: 0, extentOffset: controller.text.length);
  return showDialog<String>(
    context: context,
    builder: (ctx) {
      void submit() {
        final v = controller.text;
        if (!allowEmpty && v.trim().isEmpty) return;
        Navigator.pop(ctx, v);
      }

      return AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          autofocus: true,
          obscureText: obscure,
          maxLines: obscure ? 1 : maxLines,
          keyboardType: keyboard,
          inputFormatters: formatters,
          decoration: InputDecoration(labelText: label, hintText: hint, helperText: helper, helperMaxLines: 3),
          onSubmitted: maxLines == 1 ? (_) => submit() : null,
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(onPressed: submit, child: Text(confirmLabel)),
        ],
      );
    },
  );
}

Future<T?> pickOption<T>(BuildContext context, String title, List<(T, String, IconData?)> options, {T? selected}) {
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: true,
    builder: (ctx) => SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(ctx).height * 0.75),
        child: ListView(shrinkWrap: true, padding: const EdgeInsets.only(bottom: 12), children: [
          Padding(padding: const EdgeInsets.fromLTRB(24, 0, 24, 8), child: Text(title, style: ctx.text.titleMedium)),
          for (final (value, label, icon) in options)
            ListTile(
              leading: icon == null ? null : Icon(icon),
              title: Text(label),
              trailing: value == selected ? Icon(Icons.check_rounded, color: ctx.colors.primary) : null,
              onTap: () => Navigator.pop(ctx, value),
            ),
        ]),
      ),
    ),
  );
}

class SectionHeader extends StatelessWidget {
  const SectionHeader(this.title, {super.key, this.action, this.onAction, this.padding = const EdgeInsets.fromLTRB(20, 24, 12, 8)});
  final String title;
  final String? action;
  final VoidCallback? onAction;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) => Padding(
        padding: padding,
        child: Row(children: [
          Expanded(child: Text(title, style: context.text.titleMedium?.copyWith(fontWeight: FontWeight.w800))),
          if (action != null) TextButton(onPressed: onAction, child: Text(action!)),
        ]),
      );
}

class IconBadge extends StatelessWidget {
  const IconBadge(this.icon, {super.key, this.color, this.size = 40, this.iconSize});
  final IconData icon;
  final Color? color;
  final double size;
  final double? iconSize;

  @override
  Widget build(BuildContext context) {
    final c = color ?? context.colors.primary;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(color: c.withValues(alpha: context.isDark ? 0.22 : 0.12), borderRadius: BorderRadius.circular(size * 0.32)),
      child: Icon(icon, color: context.isDark ? Color.lerp(c, Colors.white, 0.35) : c, size: iconSize ?? size * 0.5),
    );
  }
}

class EmptyState extends StatelessWidget {
  const EmptyState({super.key, required this.icon, required this.title, this.message, this.action, this.onAction, this.compact = false});
  final IconData icon;
  final String title;
  final String? message;
  final String? action;
  final VoidCallback? onAction;
  final bool compact;

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: EdgeInsets.all(compact ? 20 : 32),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            IconBadge(icon, size: compact ? 52 : 72),
            const SizedBox(height: 16),
            Text(title, textAlign: TextAlign.center, style: context.text.titleMedium),
            if (message != null) ...[
              const SizedBox(height: 6),
              Text(message!, textAlign: TextAlign.center, style: context.text.bodyMedium?.copyWith(color: context.muted)),
            ],
            if (action != null) ...[
              const SizedBox(height: 18),
              FilledButton.tonal(onPressed: onAction, child: Text(action!)),
            ],
          ]),
        ),
      );
}

class ErrorView extends StatelessWidget {
  const ErrorView(this.error, {super.key, this.onRetry});
  final Object error;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) => EmptyState(
        icon: Icons.error_outline_rounded,
        title: 'Something went wrong',
        message: describeError(error),
        action: onRetry == null ? null : 'Try again',
        onAction: onRetry,
      );
}

class LoadingView extends StatelessWidget {
  const LoadingView({super.key, this.message});
  final String? message;
  @override
  Widget build(BuildContext context) => Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const CircularProgressIndicator(),
          if (message != null) ...[const SizedBox(height: 12), Text(message!, style: TextStyle(color: context.muted))],
        ]),
      );
}

/// Renders an [AsyncValue] with consistent loading / error UI.
class AsyncView<T> extends StatelessWidget {
  const AsyncView(this.value, {super.key, required this.builder, this.loading, this.onRetry});
  final AsyncValue<T> value;
  final Widget Function(T data) builder;
  final Widget? loading;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) => value.when(
        data: builder,
        loading: () => loading ?? const LoadingView(),
        error: (e, _) => ErrorView(e, onRetry: onRetry),
      );
}

class TapCard extends StatelessWidget {
  const TapCard({super.key, required this.child, this.onTap, this.onLongPress, this.padding = const EdgeInsets.all(14), this.color, this.selected = false});
  final Widget child;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final EdgeInsets padding;
  final Color? color;
  final bool selected;

  @override
  Widget build(BuildContext context) => Material(
        color: color ?? context.colors.surface,
        shape: RoundedRectangleBorder(
          borderRadius: AppRadius.card,
          side: BorderSide(color: selected ? context.colors.primary : context.outline, width: selected ? 2 : 1),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(onTap: onTap, onLongPress: onLongPress, child: Padding(padding: padding, child: child)),
      );
}

/// Labelled slider used by the image editor and settings.
class LabeledSlider extends StatelessWidget {
  const LabeledSlider({super.key, required this.label, required this.value, required this.onChanged, this.min = -1, this.max = 1, this.onChangeEnd, this.icon});
  final String label;
  final double value;
  final double min;
  final double max;
  final ValueChanged<double> onChanged;
  final ValueChanged<double>? onChangeEnd;
  final IconData? icon;

  @override
  Widget build(BuildContext context) => Row(children: [
        if (icon != null) Padding(padding: const EdgeInsets.only(right: 8), child: Icon(icon, size: 18, color: context.muted)),
        SizedBox(width: 92, child: Text(label, style: context.text.labelMedium)),
        Expanded(child: Slider(value: value.clamp(min, max), min: min, max: max, onChanged: onChanged, onChangeEnd: onChangeEnd)),
        SizedBox(width: 36, child: Text('${(value * 100).round()}', textAlign: TextAlign.end, style: context.text.labelSmall)),
      ]);
}

class PillChip extends StatelessWidget {
  const PillChip({super.key, required this.label, this.selected = false, this.onTap, this.icon});
  final String label;
  final bool selected;
  final VoidCallback? onTap;
  final IconData? icon;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(right: 8),
        child: ChoiceChip(
          avatar: icon == null ? null : Icon(icon, size: 16, color: selected ? context.colors.onPrimary : context.muted),
          label: Text(label),
          selected: selected,
          onSelected: onTap == null ? null : (_) => onTap!(),
          selectedColor: context.colors.primary,
          labelStyle: TextStyle(fontWeight: FontWeight.w700, color: selected ? context.colors.onPrimary : context.colors.onSurface),
        ),
      );
}
