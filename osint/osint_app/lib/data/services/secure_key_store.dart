import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:osint_core/osint_core.dart';

/// Stores API keys in the Android keystore.
///
/// API keys are bearer credentials that bill the user's account, so they are
/// never written to shared preferences or to the app's plain files. On Android
/// this delegates to EncryptedSharedPreferences, keyed by the hardware-backed
/// keystore where the device provides one.
///
/// Keys are cached in memory after the first read because a scan can consult
/// several sources in quick succession and each keystore read is a platform
/// channel round trip.
class SecureKeyStore implements ApiKeyProvider {
  SecureKeyStore({FlutterSecureStorage? storage})
      : _storage = storage ??
            const FlutterSecureStorage(
              aOptions: AndroidOptions(encryptedSharedPreferences: true),
            );

  final FlutterSecureStorage _storage;
  final Map<ApiKeySource, String?> _cache = {};

  static String _storageKey(ApiKeySource source) => 'api_key_${source.name}';

  @override
  Future<String?> keyFor(ApiKeySource source) async {
    if (_cache.containsKey(source)) return _cache[source];
    String? value;
    try {
      value = await _storage.read(key: _storageKey(source));
    } on Exception {
      // A keystore that cannot be read must not crash a scan; the source will
      // simply report that no key is configured.
      value = null;
    }
    _cache[source] = value;
    return value;
  }

  /// Saves [key] for [source], or clears it when [key] is empty.
  Future<void> save(ApiKeySource source, String key) async {
    final trimmed = key.trim();
    if (trimmed.isEmpty) {
      await clear(source);
      return;
    }
    await _storage.write(key: _storageKey(source), value: trimmed);
    _cache[source] = trimmed;
  }

  /// Removes the stored key for [source].
  Future<void> clear(ApiKeySource source) async {
    await _storage.delete(key: _storageKey(source));
    _cache[source] = null;
  }

  /// Which sources currently have a key, for the settings screen.
  Future<Map<ApiKeySource, bool>> configured() async {
    final entries = <ApiKeySource, bool>{};
    for (final source in ApiKeySource.values) {
      final key = await keyFor(source);
      entries[source] = key != null && key.isNotEmpty;
    }
    return entries;
  }
}
