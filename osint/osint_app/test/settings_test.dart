import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:osint_app/data/services/secure_key_store.dart';
import 'package:osint_app/ui/features/settings/view_models/settings_view_model.dart';
import 'package:osint_core/osint_core.dart';

class _FakeStorage extends FlutterSecureStorage {
  _FakeStorage();

  final Map<String, String> values = {};
  Object? writeThrows;
  Object? readThrows;

  @override
  Future<String?> read({
    required String key,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    final failure = readThrows;
    if (failure != null) throw failure;
    return values[key];
  }

  @override
  Future<void> write({
    required String key,
    required String? value,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    final failure = writeThrows;
    if (failure != null) throw failure;
    values[key] = value ?? '';
  }

  @override
  Future<void> delete({
    required String key,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    values.remove(key);
  }
}

SettingsViewModel _viewModel(_FakeStorage storage) =>
    SettingsViewModel(keyStore: SecureKeyStore(storage: storage));

void main() {
  group('SettingsViewModel', () {
    test('load reports which sources have a key', () async {
      final storage = _FakeStorage()..values['api_key_shodan'] = 'k';
      final viewModel = _viewModel(storage);

      await viewModel.load();

      expect(viewModel.isLoading, isFalse);
      expect(viewModel.configured[ApiKeySource.shodan], isTrue);
      expect(viewModel.configured[ApiKeySource.virusTotal], isFalse);
      expect(viewModel.error, isEmpty);
    });

    test('saving marks the source configured', () async {
      final viewModel = _viewModel(_FakeStorage());
      await viewModel.load();

      expect(await viewModel.save(ApiKeySource.virusTotal, 'vt-key'), isTrue);
      expect(viewModel.configured[ApiKeySource.virusTotal], isTrue);
    });

    test('clearing marks it unconfigured again', () async {
      final storage = _FakeStorage()..values['api_key_shodan'] = 'k';
      final viewModel = _viewModel(storage);
      await viewModel.load();

      expect(await viewModel.clear(ApiKeySource.shodan), isTrue);
      expect(viewModel.configured[ApiKeySource.shodan], isFalse);
    });

    test('a failed save reports failure instead of throwing', () async {
      // The write went through an un-awaited async onPressed, so a keystore
      // exception became an unhandled error while the row still read "Not
      // configured" — the user could not tell whether their key was wrong or
      // their phone was.
      final storage = _FakeStorage()..writeThrows = Exception('keystore gone');
      final viewModel = _viewModel(storage);
      await viewModel.load();

      final saved = await viewModel.save(ApiKeySource.shodan, 'k');

      expect(saved, isFalse);
      expect(viewModel.error, contains('Could not save the key'));
      expect(viewModel.configured[ApiKeySource.shodan], isFalse);
    });

    test('a failed load stops the spinner and explains itself', () async {
      // Leaving isLoading true renders a spinner for ever with no way back.
      final storage = _FakeStorage()..readThrows = StateError('channel gone');
      final viewModel = _viewModel(storage);

      await viewModel.load();

      expect(viewModel.isLoading, isFalse);
      expect(viewModel.error, contains('Could not read the keystore'));
    });

    test('a later successful save clears the previous error', () async {
      final storage = _FakeStorage()..writeThrows = Exception('transient');
      final viewModel = _viewModel(storage);
      await viewModel.load();

      await viewModel.save(ApiKeySource.shodan, 'k');
      expect(viewModel.error, isNotEmpty);

      storage.writeThrows = null;
      expect(await viewModel.save(ApiKeySource.shodan, 'k'), isTrue);
      expect(viewModel.error, isEmpty);
    });
  });
}
