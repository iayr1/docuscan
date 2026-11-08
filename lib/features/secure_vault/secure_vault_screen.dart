import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../core/services/security_service.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utils/formatters.dart';
import '../../data/models/models.dart';
import '../../shared/widgets/common.dart';
import '../../shared/widgets/document_widgets.dart';
import '../document_editor/document_detail_screen.dart';

class SecureVaultScreen extends ConsumerStatefulWidget {
  const SecureVaultScreen({super.key});

  @override
  ConsumerState<SecureVaultScreen> createState() => _SecureVaultScreenState();
}

class _SecureVaultScreenState extends ConsumerState<SecureVaultScreen> {
  bool _unlocked = false;
  bool _checking = true;
  bool _hasPin = false;

  final TextEditingController _pinController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _checkSecurity();
  }

  @override
  void dispose() {
    _pinController.dispose();
    super.dispose();
  }

  Future<void> _checkSecurity() async {
    final sec = ref.read(securityServiceProvider);
    final has = await sec.hasPin();
    setState(() {
      _hasPin = has;
      _checking = false;
    });

    if (has) {
      // Try biometric auth automatically if available
      final bio = await sec.biometricKind();
      if (bio != BiometricKind.none) {
        final ok = await sec.authenticateBiometric('Unlock Secure Vault');
        if (ok && mounted) {
          setState(() => _unlocked = true);
        }
      }
    }
  }

  Future<void> _setupPin() async {
    final pin = _pinController.text.trim();
    if (pin.length < 4) {
      showSnack(context, 'PIN must be at least 4 digits');
      return;
    }

    await ref.read(securityServiceProvider).setPin(pin);
    _pinController.clear();
    setState(() {
      _hasPin = true;
      _unlocked = true;
    });
    if (mounted) showSnack(context, 'Secure PIN set successfully');
  }

  Future<void> _verifyPin() async {
    final pin = _pinController.text.trim();
    final ok = await ref.read(securityServiceProvider).verifyPin(pin);
    _pinController.clear();

    if (ok) {
      setState(() => _unlocked = true);
    } else {
      if (mounted) showSnack(context, 'Incorrect PIN', error: true);
    }
  }

  Future<void> _addDocumentToVault() async {
    // Show picker for non-vaulted documents
    final docs = await ref.read(documentRepositoryProvider).listDocuments(const DocumentQuery());
    final regularDocs = docs.where((d) => !d.inVault && !d.isDeleted).toList();

    if (!mounted) return;
    if (regularDocs.isEmpty) {
      showSnack(context, 'No regular documents to move to vault');
      return;
    }

    final chosen = await showModalBottomSheet<Document>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Padding(padding: EdgeInsets.all(16), child: Text('Select Document to Encrypt & Lock', style: TextStyle(fontWeight: FontWeight.bold))),
            Expanded(
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: regularDocs.length,
                itemBuilder: (ctx, i) {
                  final d = regularDocs[i];
                  return ListTile(
                    title: Text(d.title),
                    subtitle: Text('${d.pageCount} pages · ${formatBytes(d.fileSize)}'),
                    trailing: const Icon(Icons.lock_outline),
                    onTap: () => Navigator.pop(ctx, d),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );

    if (chosen != null && mounted) {
      await runWithProgress(context, 'Encrypting and moving to vault...', (p) async {
        await ref.read(vaultRepositoryProvider).moveToVault(chosen.id);
      });
      if (mounted) showSnack(context, 'Document encrypted and moved to Secure Vault');
    }
  }

  Future<void> _removeFromVault(Document doc) async {
    if (await confirm(context, 'Remove from Vault', 'Decrypt "${doc.title}" and return to normal library?')) {
      await runWithProgress(context, 'Decrypting document...', (p) async {
        await ref.read(vaultRepositoryProvider).removeFromVault(doc.id);
      });
      if (mounted) showSnack(context, 'Document returned to library');
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_checking) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    if (!_unlocked) {
      return Scaffold(
        appBar: AppBar(title: const Text('Secure Vault')),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 400),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 76,
                    height: 76,
                    decoration: BoxDecoration(
                      color: AppColors.brand.withValues(alpha: 0.12),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(Icons.shield_outlined, size: 40, color: AppColors.brand),
                  ),
                  const SizedBox(height: 20),
                  Text(
                    _hasPin ? 'Unlock Vault' : 'Setup Vault PIN',
                    style: context.text.titleLarge?.copyWith(fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    _hasPin
                        ? 'Enter your security PIN or use biometrics to access AES-256 encrypted documents.'
                        : 'Create a 4–8 digit PIN to safeguard your private documents.',
                    textAlign: TextAlign.center,
                    style: context.text.bodyMedium?.copyWith(color: context.muted),
                  ),
                  const SizedBox(height: 24),
                  TextField(
                    controller: _pinController,
                    obscureText: true,
                    keyboardType: TextInputType.number,
                    autofocus: true,
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontSize: 24, letterSpacing: 8, fontWeight: FontWeight.bold),
                    decoration: const InputDecoration(
                      hintText: '••••',
                      border: OutlineInputBorder(),
                    ),
                    onSubmitted: (_) => _hasPin ? _verifyPin() : _setupPin(),
                  ),
                  const SizedBox(height: 20),
                  SizedBox(
                    width: double.infinity,
                    height: 48,
                    child: FilledButton.icon(
                      onPressed: _hasPin ? _verifyPin : _setupPin,
                      icon: const Icon(Icons.lock_open),
                      label: Text(_hasPin ? 'Unlock' : 'Set PIN & Open Vault'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }

    // Vault is Unlocked
    final vaultDocsAsync = ref.watch(documentsProvider(const DocumentQuery(vault: true)));

    return Scaffold(
      appBar: AppBar(
        title: const Row(
          children: [
            Icon(Icons.lock_outline, color: AppColors.brand, size: 20),
            SizedBox(width: 8),
            Text('Secure Vault (AES-256)'),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.lock),
            tooltip: 'Lock Vault Now',
            onPressed: () => setState(() => _unlocked = false),
          ),
        ],
      ),
      body: vaultDocsAsync.when(
        data: (docs) => docs.isEmpty
            ? EmptyState(
                icon: Icons.shield_outlined,
                title: 'Vault is empty',
                message: 'All documents in the vault are encrypted with military-grade AES-256-GCM. Tap below to protect private documents.',
                action: 'Add Document to Vault',
                onAction: _addDocumentToVault,
              )
            : ListView.separated(
                padding: const EdgeInsets.all(16),
                itemCount: docs.length,
                separatorBuilder: (_, _) => const SizedBox(height: 10),
                itemBuilder: (ctx, i) {
                  final d = docs[i];
                  return Card(
                    child: ListTile(
                      leading: SizedBox(
                        width: 48,
                        height: 48,
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: StoredImage(d.thumbnailPath),
                        ),
                      ),
                      title: Text(d.title, style: const TextStyle(fontWeight: FontWeight.bold)),
                      subtitle: Text('${d.pageCount} pages · ${formatBytes(d.fileSize)} · Encrypted'),
                      trailing: PopupMenuButton<String>(
                        onSelected: (action) {
                          if (action == 'view') {
                            Navigator.push(context, MaterialPageRoute(builder: (_) => DocumentDetailScreen(documentId: d.id)));
                          } else if (action == 'remove') {
                            _removeFromVault(d);
                          }
                        },
                        itemBuilder: (_) => const [
                          PopupMenuItem(value: 'view', child: Text('View / Preview')),
                          PopupMenuItem(value: 'remove', child: Text('Remove from Vault')),
                        ],
                      ),
                      onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => DocumentDetailScreen(documentId: d.id))),
                    ),
                  );
                },
              ),
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Error: $e')),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _addDocumentToVault,
        icon: const Icon(Icons.add_moderator_outlined),
        label: const Text('Add Document'),
      ),
    );
  }
}
