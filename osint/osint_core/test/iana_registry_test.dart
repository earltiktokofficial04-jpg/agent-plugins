import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:osint_core/osint_core.dart';
import 'package:test/test.dart';

IanaRegistryService _service(http.Response Function(Uri url) respond) =>
    IanaRegistryService(
      client: MockClient((request) async => respond(request.url)),
    );

void main() {
  group('tlds', () {
    test('parses the list and skips the version comment', () async {
      final service = _service(
        (_) => http.Response('# Version 2026091100\nCOM\nNET\nMY\n', 200),
      );
      final result = await service.tlds();
      expect(result.valueOrNull, ['com', 'net', 'my']);
    });

    test('reports a fetch failure', () async {
      final service = _service((_) => http.Response('', 500));
      expect(await service.tlds(), isA<SourceFailure<List<String>>>());
    });
  });

  group('publicSuffixes', () {
    test('parses rules and normalises wildcards and exceptions', () async {
      // The PSL rule syntax cannot be used as a sweep target directly:
      // "*.ck" describes a namespace, it is not one.
      final service = _service(
        (_) => http.Response(
          '// ===BEGIN ICANN DOMAINS===\n'
          'com\n'
          'com.my\n'
          '\n'
          '*.ck\n'
          '!www.ck\n',
          200,
        ),
      );
      final result = await service.publicSuffixes();
      expect(result.valueOrNull, ['com', 'com.my', 'ck', 'www.ck']);
    });
  });

  group('rdapBootstrap', () {
    test('indexes TLDs to their registry server, preferring HTTPS', () async {
      final service = _service(
        (_) => http.Response(
          jsonEncode({
            'services': [
              [
                ['com', 'net'],
                ['http://rdap.verisign.test/', 'https://rdap.verisign.test/'],
              ],
              [
                ['my'],
                ['https://rdap.mynic.test/'],
              ],
            ],
          }),
          200,
        ),
      );

      final bootstrap = (await service.rdapBootstrap()).valueOrNull!;
      expect(bootstrap.serverCount, 2);
      expect(bootstrap.tldCount, 3);
      expect(
        bootstrap.serverFor('example.com'),
        'https://rdap.verisign.test/',
      );
      expect(bootstrap.serverFor('example.my'), 'https://rdap.mynic.test/');
      expect(bootstrap.serverFor('example.nowhere'), isNull);
      expect(bootstrap.serverFor('nodots'), isNull);
    });

    test('counts distinct servers, not TLDs', () async {
      // One operator commonly serves many TLDs; counting TLDs would inflate
      // the source count several-fold.
      final service = _service(
        (_) => http.Response(
          jsonEncode({
            'services': [
              [
                ['a', 'b', 'c'],
                ['https://one.test/'],
              ],
              [
                ['d'],
                ['https://one.test/'],
              ],
            ],
          }),
          200,
        ),
      );
      final bootstrap = (await service.rdapBootstrap()).valueOrNull!;
      expect(bootstrap.tldCount, 4);
      expect(bootstrap.serverCount, 1);
    });

    test('rejects a payload with no usable services', () async {
      final service = _service(
        (_) => http.Response(jsonEncode({'services': []}), 200),
      );
      expect(
        await service.rdapBootstrap(),
        isA<SourceFailure<RdapBootstrap>>(),
      );
    });
  });

  group('ctLogs', () {
    test('flattens logs across operators', () async {
      final service = _service(
        (_) => http.Response(
          jsonEncode({
            'operators': [
              {
                'name': 'Google',
                'logs': [
                  {'url': 'https://argon.test/', 'description': 'Argon'},
                  {'url': 'https://xenon.test/'},
                ],
              },
              {
                'name': 'Cloudflare',
                'logs': [
                  {'url': 'https://nimbus.test/'},
                ],
              },
            ],
          }),
          200,
        ),
      );

      final logs = (await service.ctLogs()).valueOrNull!;
      expect(logs, hasLength(3));
      expect(logs.first.operator, 'Google');
      expect(logs.map((log) => log.operator).toSet(), hasLength(2));
    });
  });
}
