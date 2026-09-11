/// Sources that require a caller-supplied credential.
enum ApiKeySource {
  virusTotal('VirusTotal', 'https://www.virustotal.com/gui/my-apikey'),
  abuseIpdb('AbuseIPDB', 'https://www.abuseipdb.com/account/api'),
  shodan('Shodan', 'https://account.shodan.io'),
  urlscan('urlscan.io', 'https://urlscan.io/user/profile/');

  const ApiKeySource(this.displayName, this.signupUrl);

  final String displayName;

  /// Where the user obtains the key, shown in settings so the app never has to
  /// ship instructions that go stale.
  final String signupUrl;
}

/// Supplies API keys to services without dictating how they are stored.
///
/// The core package deliberately knows nothing about secure storage: on
/// Android the app implements this over the platform keystore, while tests
/// implement it with a plain map.
abstract interface class ApiKeyProvider {
  /// Returns the key for [source], or null when the user has not supplied one.
  Future<String?> keyFor(ApiKeySource source);
}

/// An in-memory [ApiKeyProvider], for tests and for running without storage.
class InMemoryApiKeyProvider implements ApiKeyProvider {
  InMemoryApiKeyProvider([Map<ApiKeySource, String>? keys])
      : _keys = {...?keys};

  final Map<ApiKeySource, String> _keys;

  void set(ApiKeySource source, String key) => _keys[source] = key;

  void clear(ApiKeySource source) => _keys.remove(source);

  @override
  Future<String?> keyFor(ApiKeySource source) async => _keys[source];
}
