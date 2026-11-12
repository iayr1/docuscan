import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../core/services/security_service.dart';
import '../../core/theme/app_theme.dart';
import 'common.dart';

/// Centered PIN entry with dot indicator and a numeric keypad.
///
/// [onSubmit] returns whether the PIN was accepted; on rejection the entry is
/// cleared and an error (or remaining lock-out) is shown.
class PinGate extends ConsumerStatefulWidget {
  const PinGate({
    super.key,
    required this.title,
    required this.message,
    required this.onSubmit,
    this.icon = Icons.lock_rounded,
    this.showBiometric = false,
    this.onBiometric,
    this.submitLabel = 'Unlock',
    this.checkLockout = true,
  });

  final String title;
  final String message;
  final IconData icon;
  final Future<bool> Function(String pin) onSubmit;
  final bool showBiometric;
  final VoidCallback? onBiometric;
  final String submitLabel;
  final bool checkLockout;

  @override
  ConsumerState<PinGate> createState() => _PinGateState();
}

class _PinGateState extends ConsumerState<PinGate> {
  static const _maxLen = 8;
  String _pin = '';
  String? _error;
  bool _busy = false;

  void _press(String digit) {
    if (_busy || _pin.length >= _maxLen) return;
    HapticFeedback.selectionClick();
    setState(() {
      _pin += digit;
      _error = null;
    });
  }

  void _backspace() {
    if (_busy || _pin.isEmpty) return;
    setState(() => _pin = _pin.substring(0, _pin.length - 1));
  }

  Future<void> _submit() async {
    if (_busy) return;
    if (_pin.length < 4) {
      setState(() => _error = 'PIN must be at least 4 digits');
      return;
    }
    setState(() => _busy = true);
    final ok = await widget.onSubmit(_pin);
    if (!mounted) return;
    String? error;
    if (!ok) {
      HapticFeedback.heavyImpact();
      error = 'Incorrect PIN';
      if (widget.checkLockout) {
        final left = await ref.read(securityServiceProvider).lockoutRemaining();
        if (left != null) error = 'Too many attempts. Try again in ${left.inSeconds + 1}s';
      }
    }
    if (!mounted) return;
    setState(() {
      _busy = false;
      _pin = '';
      _error = error;
    });
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 340),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 76,
                  height: 76,
                  decoration: BoxDecoration(gradient: AppColors.brandGradient, shape: BoxShape.circle, boxShadow: [
                    BoxShadow(color: AppColors.brand.withValues(alpha: 0.3), blurRadius: 24, offset: const Offset(0, 8)),
                  ]),
                  child: Icon(widget.icon, size: 36, color: Colors.white),
                ),
                const SizedBox(height: 22),
                Text(widget.title, textAlign: TextAlign.center, style: context.text.headlineSmall),
                const SizedBox(height: 8),
                Text(widget.message, textAlign: TextAlign.center, style: context.text.bodyMedium?.copyWith(color: context.muted)),
                const SizedBox(height: 28),
                SizedBox(
                  height: 18,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      for (var i = 0; i < (_pin.length < 4 ? 4 : _pin.length); i++)
                        AnimatedContainer(
                          duration: AppDurations.fast,
                          margin: const EdgeInsets.symmetric(horizontal: 6),
                          width: 14,
                          height: 14,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: i < _pin.length ? context.colors.primary : Colors.transparent,
                            border: Border.all(color: i < _pin.length ? context.colors.primary : context.muted, width: 1.6),
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                SizedBox(
                  height: 20,
                  child: _busy
                      ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                      : Text(_error ?? '', style: TextStyle(color: context.colors.error, fontWeight: FontWeight.w600, fontSize: 13)),
                ),
                const SizedBox(height: 16),
                for (final row in const [
                  ['1', '2', '3'],
                  ['4', '5', '6'],
                  ['7', '8', '9'],
                ])
                  Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [for (final d in row) _key(Text(d), () => _press(d))]),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    widget.showBiometric && widget.onBiometric != null
                        ? _key(Icon(Icons.fingerprint_rounded, size: 30, color: context.colors.primary), widget.onBiometric!, plain: true)
                        : _key(Icon(Icons.backspace_outlined, size: 24, color: context.muted), _backspace, plain: true),
                    _key(const Text('0'), () => _press('0')),
                    widget.showBiometric && widget.onBiometric != null
                        ? _key(Icon(Icons.backspace_outlined, size: 24, color: context.muted), _backspace, plain: true)
                        : const SizedBox(width: 72, height: 72),
                  ],
                ),
                const SizedBox(height: 20),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(onPressed: _pin.length >= 4 && !_busy ? _submit : null, child: Text(widget.submitLabel)),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _key(Widget child, VoidCallback onTap, {bool plain = false}) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: SizedBox(
          width: 72,
          height: 72,
          child: Material(
            color: plain ? Colors.transparent : context.colors.surfaceContainerHighest.withValues(alpha: context.isDark ? 0.35 : 0.6),
            shape: const CircleBorder(),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: onTap,
              child: Center(
                child: DefaultTextStyle.merge(
                  style: TextStyle(fontSize: 26, fontWeight: FontWeight.w600, color: context.colors.onSurface),
                  child: child,
                ),
              ),
            ),
          ),
        ),
      );
}

/// Asks for a new 4–8 digit PIN twice. Returns the PIN or null if cancelled.
Future<String?> promptNewPin(BuildContext context, {String title = 'Create a PIN'}) async {
  final first = TextEditingController();
  final second = TextEditingController();
  final result = await showDialog<String>(
    context: context,
    builder: (ctx) {
      String? error;
      return StatefulBuilder(builder: (ctx, setState) {
        void submit() {
          final a = first.text.trim();
          if (!RegExp(r'^\d{4,8}$').hasMatch(a)) {
            setState(() => error = 'Use 4–8 digits');
            return;
          }
          if (a != second.text.trim()) {
            setState(() => error = 'PINs do not match');
            return;
          }
          Navigator.pop(ctx, a);
        }

        InputDecoration deco(String label) => InputDecoration(labelText: label, counterText: '', prefixIcon: const Icon(Icons.pin_outlined));
        return AlertDialog(
          title: Text(title),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            Text('This PIN protects locked documents, the vault and app lock.', style: ctx.text.bodySmall?.copyWith(color: ctx.muted)),
            const SizedBox(height: 16),
            TextField(
              controller: first,
              autofocus: true,
              obscureText: true,
              maxLength: 8,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              decoration: deco('New PIN'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: second,
              obscureText: true,
              maxLength: 8,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              decoration: deco('Confirm PIN').copyWith(errorText: error),
              onSubmitted: (_) => submit(),
            ),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
            FilledButton(onPressed: submit, child: const Text('Save PIN')),
          ],
        );
      });
    },
  );
  return result;
}

/// Makes sure a PIN exists, asking the user to create one when needed.
/// Returns true when a PIN is set afterwards.
Future<bool> ensurePin(BuildContext context, WidgetRef ref) async {
  final sec = ref.read(securityServiceProvider);
  if (await sec.hasPin()) return true;
  if (!context.mounted) return false;
  final pin = await promptNewPin(context);
  if (pin == null) return false;
  await sec.setPin(pin);
  if (context.mounted) showSnack(context, 'PIN created');
  return true;
}

/// Verifies the user with biometrics (if available) or their PIN.
Future<bool> authenticateUser(BuildContext context, WidgetRef ref, {String reason = 'Confirm it\'s you'}) async {
  final sec = ref.read(securityServiceProvider);
  if (!await sec.hasPin()) return true;
  final bio = await sec.biometricKind();
  if (bio != BiometricKind.none && await sec.authenticateBiometric(reason)) return true;
  if (!context.mounted) return false;
  final ok = await Navigator.of(context).push<bool>(MaterialPageRoute(
    fullscreenDialog: true,
    builder: (ctx) => Scaffold(
      appBar: AppBar(),
      body: PinGate(
        title: reason,
        message: 'Enter your DocuScan PIN',
        onSubmit: (pin) async {
          final ok = await sec.verifyPin(pin);
          if (ok && ctx.mounted) Navigator.pop(ctx, true);
          return ok;
        },
      ),
    ),
  ));
  return ok ?? false;
}
