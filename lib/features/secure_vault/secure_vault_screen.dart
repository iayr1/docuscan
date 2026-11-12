import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../core/services/security_service.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utils/formatters.dart';
import '../../data/models/models.dart';
import '../../shared/widgets/common.dart';
import '../../shared/widgets/document_widgets.dart';
import '../../shared/widgets/security_widgets.dart';
import '../document_editor/document_detail_screen.dart';

class SecureVaultScreen extends ConsumerStatefulWidget {
  const SecureVaultScreen({super.key});

  @override
  ConsumerState<SecureVaultScreen> createState() => _SecureVaultScreenState();
}

class _SecureVaultScreenState extends ConsumerState<SecureVaultScreen> with WidgetsBindingObserver {
  bool _unlocked = false;
  bool _checking = true;
  bool _hasPin = false;
  bool _hasBiometrics = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _checkSecurity();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Re-lock whenever the app goes to the background.
    if (state == AppLifecycleState.paused && _unlocked) setState(() => _unlocked = false);
  }

  Future<void> _checkSecurity() async {
    final sec = ref.read(securityServiceProvider);
    final has = await sec.hasPin();
    final bio = await sec.biometricKind();
    if (!mounted) return;
    setState(() {
      _hasPin = has;
      _hasBiometrics = bio != BiometricKind.none;
      _checking = false;
    });
    if (has && _hasBiometrics) _tryBiometric();
  }

  Future<void> _tryBiometric() async {
    final ok = await ref.read(securityServiceProvider).authenticateBiometric('Unlock Secure Vault');
    if (ok && mounted) setState(() => _unlocked = true);
  }

  Future<void> _createPin() async {
    final pin = await promptNewPin(context, title: 'Create vault PIN');
    if (pin == null) return;
    await ref.read(securityServiceProvider).setPin(pin);
    if (!mounted) return;
    setState(() {
      _hasPin = true;
      _unlocked = true;
    });
    showSnack(context, 'PIN created — your vault is ready');
  }

  Future<void> _addDocumentToVault() async {
    final docs = await ref.read(documentRepositoryProvider).listDocuments(const DocumentQuery(includeHidden: true));
    if (!mounted) return;
    if (docs.isEmpty) {
      showSnack(context, 'There are no documents in your library to protect');
      return;
    }

    final chosen = await showModalBottomSheet<Document>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(ctx).height * 0.75),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 0, 24, 4),
                child: Text('Choose a document to encrypt', style: ctx.text.titleMedium),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 0, 24, 12),
                child: Text('It will be hidden from your library and search.', style: ctx.text.bodySmall?.copyWith(color: ctx.muted)),
              ),
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                  itemCount: docs.length,
                  itemBuilder: (ctx, i) => DocumentListTile(
                    doc: docs[i],
                    onTap: () => Navigator.pop(ctx, docs[i]),
                    trailing: Icon(Icons.chevron_right_rounded, color: ctx.muted),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );

    if (chosen == null || !mounted) return;
    final ok = await runWithProgress(context, 'Encrypting “${chosen.title}”…', (p) async {
      await ref.read(vaultRepositoryProvider).moveToVault(chosen.id);
      return true;
    });
    if (ok == true && mounted) showSnack(context, 'Encrypted and moved to the vault');
  }

  Future<void> _removeFromVault(Document doc) async {
    if (!await confirm(context, 'Remove from vault', 'Decrypt “${doc.title}” and return it to your library?', confirmLabel: 'Decrypt')) return;
    if (!mounted) return;
    final ok = await runWithProgress(context, 'Decrypting…', (p) async {
      await ref.read(vaultRepositoryProvider).removeFromVault(doc.id);
      return true;
    });
    if (ok == true && mounted) showSnack(context, 'Returned to your library');
  }

  @override
  Widget build(BuildContext context) {
    if (_checking) return const Scaffold(body: LoadingView());

    if (!_hasPin) {
      return Scaffold(
        appBar: AppBar(),
        body: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(32),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Container(
                width: 96,
                height: 96,
                decoration: const BoxDecoration(gradient: AppColors.brandGradient, shape: BoxShape.circle),
                child: const Icon(Icons.shield_rounded, size: 48, color: Colors.white),
              ),
              const SizedBox(height: 24),
              Text('Secure Vault', style: context.text.headlineSmall),
              const SizedBox(height: 10),
              Text(
                'Keep private documents encrypted with AES-256. Files are only readable after you unlock with your PIN or biometrics.',
                textAlign: TextAlign.center,
                style: context.text.bodyMedium?.copyWith(color: context.muted, height: 1.4),
              ),
              const SizedBox(height: 28),
              FilledButton.icon(onPressed: _createPin, icon: const Icon(Icons.pin_outlined), label: const Text('Create PIN')),
            ]),
          ),
        ),
      );
    }

    if (!_unlocked) {
      return Scaffold(
        appBar: AppBar(),
        body: PinGate(
          icon: Icons.shield_rounded,
          title: 'Unlock vault',
          message: 'Enter your PIN to view encrypted documents.',
          showBiometric: _hasBiometrics,
          onBiometric: _tryBiometric,
          onSubmit: (pin) async {
            final ok = await ref.read(securityServiceProvider).verifyPin(pin);
            if (ok && mounted) setState(() => _unlocked = true);
            return ok;
          },
        ),
      );
    }

    final vaultDocsAsync = ref.watch(documentsProvider(const DocumentQuery(vault: true)));

    return Scaffold(
      appBar: AppBar(
        title: const Text('Secure Vault'),
        actions: [
          IconButton(icon: const Icon(Icons.lock_rounded), tooltip: 'Lock vault', onPressed: () => setState(() => _unlocked = false)),
        ],
      ),
      body: vaultDocsAsync.when(
        skipLoadingOnReload: true,
        data: (docs) => docs.isEmpty
            ? EmptyState(
                icon: Icons.shield_outlined,
                title: 'Your vault is empty',
                message: 'Documents you add are encrypted with AES-256-GCM and hidden from the library.',
                action: 'Add a document',
                onAction: _addDocumentToVault,
              )
            : ListView(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 96),
                children: [
                  Container(
                    margin: const EdgeInsets.only(bottom: 12),
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: context.colors.primary.withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(AppRadius.md),
                    ),
                    child: Row(children: [
                      Icon(Icons.verified_user_rounded, color: context.colors.primary),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          '${docs.length} encrypted document${docs.length == 1 ? '' : 's'} · locks when you leave the app',
                          style: context.text.bodySmall?.copyWith(fontWeight: FontWeight.w600),
                        ),
                      ),
                    ]),
                  ),
                  for (final d in docs)
                    DocumentListTile(
                      doc: d,
                      subtitle: '${d.pageCount} page${d.pageCount == 1 ? '' : 's'} · ${formatBytes(d.fileSize)} · encrypted',
                      onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => DocumentDetailScreen(documentId: d.id))),
                      trailing: PopupMenuButton<String>(
                        onSelected: (action) {
                          if (action == 'view') {
                            Navigator.push(context, MaterialPageRoute(builder: (_) => DocumentDetailScreen(documentId: d.id)));
                          } else if (action == 'remove') {
                            _removeFromVault(d);
                          }
                        },
                        itemBuilder: (_) => const [
                          PopupMenuItem(value: 'view', child: Text('Open')),
                          PopupMenuItem(value: 'remove', child: Text('Decrypt & remove from vault')),
                        ],
                      ),
                    ),
                ],
              ),
        loading: () => const LoadingView(),
        error: (e, _) => ErrorView(e),
      ),
      floatingActionButton: FloatingActionButton.extended(
        heroTag: 'vault-add',
        onPressed: _addDocumentToVault,
        icon: const Icon(Icons.add_moderator_outlined),
        label: const Text('Add document'),
      ),
    );
  }
}
