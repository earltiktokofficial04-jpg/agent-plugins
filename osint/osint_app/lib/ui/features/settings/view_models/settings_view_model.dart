import 'package:flutter/foundation.dart';
import 'package:osint_core/osint_core.dart';

import '../../../../data/services/secure_key_store.dart';

/// Drives the API key settings screen.
class SettingsViewModel extends ChangeNotifier {
  SettingsViewModel({required SecureKeyStore keyStore}) : _keyStore = keyStore;

  final SecureKeyStore _keyStore;

  Map<ApiKeySource, bool> _configured = {
    for (final source in ApiKeySource.values) source: false,
  };

  /// Which sources have a key stored. Values, never the keys themselves: a
  /// stored credential is never read back into the UI.
  Map<ApiKeySource, bool> get configured => _configured;

  bool _isLoading = true;
  bool get isLoading => _isLoading;

  String _error = '';

  /// What went wrong with the last save, load or clear.
  ///
  /// The keystore can fail — corruption, or a failed EncryptedSharedPreferences
  /// migration — and a write that silently did nothing while the row still
  /// reads "Not configured" leaves the user with no idea whether the problem
  /// is their key or their phone.
  String get error => _error;

  /// Reads which sources are configured.
  Future<void> load() async {
    _isLoading = true;
    _error = '';
    notifyListeners();
    try {
      _configured = await _keyStore.configured();
      // The key store degrades rather than throwing, which is right for a
      // scan but wrong here: this screen is the one place where "the keystore
      // is broken" and "no key is set" must not look the same.
      if (_keyStore.lastReadFailed) {
        _error =
            'Could not read the keystore, so the states below may be wrong. '
            'Re-entering a key will still work.';
      }
    } catch (failure) {
      _error = 'Could not read the keystore: $failure';
    }
    // Always cleared, or a throw leaves the screen spinning for ever.
    _isLoading = false;
    notifyListeners();
  }

  /// Stores [key] for [source], or clears it when [key] is blank.
  Future<bool> save(ApiKeySource source, String key) async {
    _error = '';
    try {
      await _keyStore.save(source, key);
    } catch (failure) {
      _error = 'Could not save the key: $failure';
      notifyListeners();
      return false;
    }
    _configured = await _keyStore.configured();
    notifyListeners();
    return true;
  }

  /// Removes the stored key for [source].
  Future<bool> clear(ApiKeySource source) async {
    _error = '';
    try {
      await _keyStore.clear(source);
    } catch (failure) {
      _error = 'Could not remove the key: $failure';
      notifyListeners();
      return false;
    }
    _configured = await _keyStore.configured();
    notifyListeners();
    return true;
  }
}
