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

  /// Reads which sources are configured.
  Future<void> load() async {
    _isLoading = true;
    notifyListeners();
    _configured = await _keyStore.configured();
    _isLoading = false;
    notifyListeners();
  }

  /// Stores [key] for [source], or clears it when [key] is blank.
  Future<void> save(ApiKeySource source, String key) async {
    await _keyStore.save(source, key);
    _configured = await _keyStore.configured();
    notifyListeners();
  }

  /// Removes the stored key for [source].
  Future<void> clear(ApiKeySource source) async {
    await _keyStore.clear(source);
    _configured = await _keyStore.configured();
    notifyListeners();
  }
}
