import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:osint_app/data/services/secure_key_store.dart';
import 'package:osint_core/osint_core.dart';

/// A keystore stand-in whose reads can be made to fail on demand.
class _FakeStorage extends FlutterSecureStorage {
  _FakeStorage();

  final Map<String, String> values = {};
  Object? readThrows;
  Object? writeThrows;
  int reads = 0;

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
    reads++;
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
    if (value == null) {
      values.remove(key);
    } else {
      values[key] = value;
    }
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

void main() {
  group('SecureKeyStore', () {
    test('stores, reads back and clears a key', () async {
      final storage = _FakeStorage();
      final store = SecureKeyStore(storage: storage);

      expect(await store.keyFor(ApiKeySource.shodan), isNull);

      await store.save(ApiKeySource.shodan, 'shodan-key');
      expect(await store.keyFor(ApiKeySource.shodan), 'shodan-key');

      await store.clear(ApiKeySource.shodan);
      expect(await store.keyFor(ApiKeySource.shodan), isNull);
    });

    test('trims whitespace, and treats a blank value as a clear', () async {
      // A key pasted from a webpage routinely carries a trailing newline,
      // which the source rejects as an invalid credential.
      final storage = _FakeStorage();
      final store = SecureKeyStore(storage: storage);

      await store.save(ApiKeySource.virusTotal, '  vt-key\n');
      expect(await store.keyFor(ApiKeySource.virusTotal), 'vt-key');

      await store.save(ApiKeySource.virusTotal, '   ');
      expect(await store.keyFor(ApiKeySource.virusTotal), isNull);
    });

    test(
      'caches a successful read rather than hitting the platform each time',
      () async {
        final storage = _FakeStorage()..values['api_key_shodan'] = 'k';
        final store = SecureKeyStore(storage: storage);

        await store.keyFor(ApiKeySource.shodan);
        await store.keyFor(ApiKeySource.shodan);
        await store.keyFor(ApiKeySource.shodan);
        expect(storage.reads, 1);
      },
    );

    test('a failed read is NOT cached as "no key"', () async {
      // Caching the failure would pin "not configured" for the life of the
      // process: the user re-enters a key that was already there, still sees
      // it fail, and has no way back short of restarting the app.
      final storage = _FakeStorage()
        ..values['api_key_shodan'] = 'k'
        ..readThrows = Exception('keystore unavailable');
      final store = SecureKeyStore(storage: storage);

      expect(await store.keyFor(ApiKeySource.shodan), isNull);
      expect(store.lastReadFailed, isTrue);

      storage.readThrows = null;
      expect(
        await store.keyFor(ApiKeySource.shodan),
        'k',
        reason: 'the next read must go back to the keystore',
      );
      expect(store.lastReadFailed, isFalse);
    });

    test(
      'survives an Error, not just an Exception, from the channel',
      () async {
        // A platform channel can throw a raw Error; catching only Exception
        // would let it take down the whole scan.
        final storage = _FakeStorage()..readThrows = StateError('channel gone');
        final store = SecureKeyStore(storage: storage);

        expect(await store.keyFor(ApiKeySource.shodan), isNull);
        expect(store.lastReadFailed, isTrue);
      },
    );

    test('a failed write throws rather than reporting success', () async {
      // Silently doing nothing while the screen says "Key stored" is worse
      // than an error the user can act on.
      final storage = _FakeStorage()..writeThrows = Exception('disk full');
      final store = SecureKeyStore(storage: storage);

      await expectLater(
        store.save(ApiKeySource.shodan, 'k'),
        throwsA(isA<Exception>()),
      );
    });

    test('invalidateCache forces the next read back to the keystore', () async {
      final storage = _FakeStorage()..values['api_key_shodan'] = 'old';
      final store = SecureKeyStore(storage: storage);

      expect(await store.keyFor(ApiKeySource.shodan), 'old');
      storage.values['api_key_shodan'] = 'new';
      expect(await store.keyFor(ApiKeySource.shodan), 'old');

      store.invalidateCache();
      expect(await store.keyFor(ApiKeySource.shodan), 'new');
    });

    test('configured reports one entry per key source', () async {
      final storage = _FakeStorage()..values['api_key_virusTotal'] = 'k';
      final store = SecureKeyStore(storage: storage);

      final configured = await store.configured();
      expect(configured.keys.toSet(), ApiKeySource.values.toSet());
      expect(configured[ApiKeySource.virusTotal], isTrue);
      expect(configured[ApiKeySource.shodan], isFalse);
    });

    test('keys are namespaced so two sources cannot collide', () async {
      final storage = _FakeStorage();
      final store = SecureKeyStore(storage: storage);

      await store.save(ApiKeySource.shodan, 'shodan');
      await store.save(ApiKeySource.virusTotal, 'vt');

      expect(await store.keyFor(ApiKeySource.shodan), 'shodan');
      expect(await store.keyFor(ApiKeySource.virusTotal), 'vt');
      expect(storage.values.keys.toSet(), hasLength(2));
    });
  });
}
