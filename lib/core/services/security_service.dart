import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:local_auth/local_auth.dart';

import '../errors/app_exception.dart';

/// Abstraction over the platform keystore so it can be faked in tests.
abstract class SecretStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

/// Android Keystore (EncryptedSharedPreferences successor) / iOS Keychain.
class PlatformSecretStore implements SecretStore {
  PlatformSecretStore() : _s = const FlutterSecureStorage();
  final FlutterSecureStorage _s;
  @override
  Future<String?> read(String key) => _s.read(key: key);
  @override
  Future<void> write(String key, String value) => _s.write(key: key, value: value);
  @override
  Future<void> delete(String key) => _s.delete(key: key);
}

class MemorySecretStore implements SecretStore {
  final Map<String, String> values = {};
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async => values[key] = value;
  @override
  Future<void> delete(String key) async => values.remove(key);
}

enum BiometricKind { none, fingerprint, face, generic }

/// PIN lock, biometrics and the vault's AES-256-GCM file encryption.
///
/// * The PIN is never stored: only a PBKDF2-HMAC-SHA256 hash (120k
///   iterations, random 16-byte salt) is kept in the keystore.
/// * The vault key is 32 random bytes generated on first use and stored only
///   in the keystore. Files are encrypted as `nonce(12) | ciphertext | mac(16)`.
class SecurityService {
  SecurityService(this._store, {LocalAuthentication? auth}) : _auth = auth ?? LocalAuthentication();

  final SecretStore _store;
  final LocalAuthentication _auth;

  static const _pinKey = 'pin_hash_v1';
  static const _vaultKey = 'vault_key_v1';
  static const _attemptsKey = 'pin_attempts';
  static const _lockoutKey = 'pin_lockout_until';
  static const pbkdf2Iterations = 120000;

  // ------------------------------------------------------------------ PIN

  Future<bool> hasPin() async => (await _store.read(_pinKey)) != null;

  Future<void> setPin(String pin) async {
    if (!RegExp(r'^\d{4,8}$').hasMatch(pin)) throw const AppException('PIN must be 4–8 digits.');
    final salt = _randomBytes(16);
    final hash = await _hash(pin, salt);
    await _store.write(_pinKey, '${base64Encode(salt)}:${base64Encode(hash)}');
    await _store.delete(_attemptsKey);
  }

  Future<void> removePin() async {
    await _store.delete(_pinKey);
    await _store.delete(_attemptsKey);
    await _store.delete(_lockoutKey);
  }

  /// Remaining lock-out after repeated failures (null when not locked).
  Future<Duration?> lockoutRemaining() async {
    final until = int.tryParse(await _store.read(_lockoutKey) ?? '');
    if (until == null) return null;
    final left = DateTime.fromMillisecondsSinceEpoch(until).difference(DateTime.now());
    return left.isNegative ? null : left;
  }

  Future<bool> verifyPin(String pin) async {
    if (await lockoutRemaining() != null) return false;
    final stored = await _store.read(_pinKey);
    if (stored == null) return false;
    final parts = stored.split(':');
    final salt = base64Decode(parts[0]);
    final expected = base64Decode(parts[1]);
    final actual = await _hash(pin, salt);
    final ok = _constantTimeEquals(actual, expected);
    if (ok) {
      await _store.delete(_attemptsKey);
      await _store.delete(_lockoutKey);
    } else {
      final attempts = (int.tryParse(await _store.read(_attemptsKey) ?? '') ?? 0) + 1;
      await _store.write(_attemptsKey, '$attempts');
      if (attempts >= 5) {
        // Exponential back-off: 30s, 60s, 120s ...
        final seconds = 30 * pow(2, attempts - 5).toInt();
        await _store.write(_lockoutKey, '${DateTime.now().add(Duration(seconds: min(seconds, 3600))).millisecondsSinceEpoch}');
      }
    }
    return ok;
  }

  static Future<List<int>> _hash(String pin, List<int> salt) => Isolate.run(() async {
        final algo = Pbkdf2(macAlgorithm: Hmac.sha256(), iterations: pbkdf2Iterations, bits: 256);
        final key = await algo.deriveKey(secretKey: SecretKey(utf8.encode(pin)), nonce: salt);
        return key.extractBytes();
      });

  static bool _constantTimeEquals(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a[i] ^ b[i];
    }
    return diff == 0;
  }

  // ----------------------------------------------------------- biometrics

  Future<BiometricKind> biometricKind() async {
    try {
      if (!await _auth.isDeviceSupported() || !await _auth.canCheckBiometrics) return BiometricKind.none;
      final types = await _auth.getAvailableBiometrics();
      if (types.contains(BiometricType.face)) return BiometricKind.face;
      if (types.contains(BiometricType.fingerprint)) return BiometricKind.fingerprint;
      return types.isEmpty ? BiometricKind.none : BiometricKind.generic;
    } on PlatformException {
      return BiometricKind.none;
    } on MissingPluginException {
      return BiometricKind.none;
    }
  }

  Future<bool> authenticateBiometric(String reason) async {
    try {
      return await _auth.authenticate(localizedReason: reason, biometricOnly: true, persistAcrossBackgrounding: true);
    } on PlatformException {
      return false;
    } on LocalAuthException {
      return false;
    }
  }

  // ---------------------------------------------------------- encryption

  Future<List<int>> _vaultKeyBytes() async {
    final existing = await _store.read(_vaultKey);
    if (existing != null) return base64Decode(existing);
    final key = _randomBytes(32);
    await _store.write(_vaultKey, base64Encode(key));
    return key;
  }

  Future<Uint8List> encryptBytes(Uint8List plain) async {
    final key = await _vaultKeyBytes();
    return Isolate.run(() => _encrypt(plain, key));
  }

  Future<Uint8List> decryptBytes(Uint8List sealed) async {
    final key = await _vaultKeyBytes();
    try {
      return await Isolate.run(() => _decrypt(sealed, key));
    } on SecretBoxAuthenticationError {
      throw const CorruptedFileException('vault item');
    }
  }

  /// Encrypts [source] into [target] (atomic) and deletes the source.
  Future<void> encryptFile(String source, String target) async {
    final sealed = await encryptBytes(await File(source).readAsBytes());
    final tmp = File('$target.part');
    await tmp.parent.create(recursive: true);
    await tmp.writeAsBytes(sealed, flush: true);
    await tmp.rename(target);
    await File(source).delete();
  }

  Future<void> decryptFile(String source, String target) async {
    final plain = await decryptBytes(await File(source).readAsBytes());
    final tmp = File('$target.part');
    await tmp.parent.create(recursive: true);
    await tmp.writeAsBytes(plain, flush: true);
    await tmp.rename(target);
    await File(source).delete();
  }

  static Future<Uint8List> _encrypt(Uint8List plain, List<int> key) async {
    final algo = AesGcm.with256bits();
    final nonce = algo.newNonce();
    final box = await algo.encrypt(plain, secretKey: SecretKey(key), nonce: nonce);
    return Uint8List.fromList(box.concatenation());
  }

  static Future<Uint8List> _decrypt(Uint8List sealed, List<int> key) async {
    final algo = AesGcm.with256bits();
    final box = SecretBox.fromConcatenation(sealed, nonceLength: 12, macLength: 16);
    return Uint8List.fromList(await algo.decrypt(box, secretKey: SecretKey(key)));
  }

  static List<int> _randomBytes(int n) {
    final r = Random.secure();
    return List<int>.generate(n, (_) => r.nextInt(256));
  }
}
