import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:osint_core/osint_core.dart';

/// Stores API keys in the Android keystore.
///
/// API keys are bearer credentials that bill the user's account, so they are
/// never written to shared preferences or to the app's plain files. On Android
/// this delegates to EncryptedSharedPreferences, keyed by the hardware-backed
/// keystore where the device provides one.
class SecureKeyStore implements ApiKeyProvider {
  SecureKeyStore({FlutterSecureStorage? storage})
    : _storage =
          storage ??
          const FlutterSecureStorage(
            aOptions: AndroidOptions(encryptedSharedPreferences: true),
          );

  final FlutterSecureStorage _storage;

  /// Values read successfully, so a scan consulting several sources does not
  /// make a platform-channel round trip per source.
  ///
  /// Only successful reads are cached. Caching a failure would pin "no key"
  /// for the life of the process: the user would see the source reported as
  /// unconfigured, re-enter a key that was already there, and still see it
  /// fail — with no way back short of restarting the app.
  final Map<ApiKeySource, String?> _cache = {};

  static String _storageKey(ApiKeySource source) => 'api_key_${source.name}';

  /// True when the last read for [source] failed rather than returned null.
  ///
  /// Exposed so the UI can say "could not read the keystore" instead of
  /// "not configured", which are opposite problems with opposite fixes.
  bool get lastReadFailed => _lastReadFailed;
  bool _lastReadFailed = false;

  @override
  Future<String?> keyFor(ApiKeySource source) async {
    if (_cache.containsKey(source)) return _cache[source];

    try {
      final value = await _storage.read(key: _storageKey(source));
      _cache[source] = value;
      _lastReadFailed = false;
      return value;
    } catch (error) {
      // Deliberately catches Error as well as Exception: a platform channel
      // can throw MissingPluginException or a raw Error, and either way a
      // keystore problem must degrade a lookup rather than crash the scan.
      _lastReadFailed = true;
      return null;
    }
  }

  /// Saves [key] for [source], or clears it when [key] is empty.
  ///
  /// Throws on failure rather than swallowing it: a save that silently did
  /// nothing while the screen said "Key stored" is worse than an error.
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

  /// Drops cached values so the next read goes back to the keystore.
  ///
  /// Gives the settings screen a way to recover from a transient read
  /// failure without restarting the app.
  void invalidateCache() {
    _cache.clear();
    _lastReadFailed = false;
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
