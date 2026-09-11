import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:osint_core/osint_core.dart';
import 'package:test/test.dart';

void main() {
  group('CrtShService', () {
    test('parses certificates and splits packed SAN names', () async {
      final service = CrtShService(
        client: MockClient((request) async {
          expect(request.url.queryParameters['q'], '%.example.com');
          return http.Response(
            jsonEncode([
              {
                'issuer_name': "C=US, O=Let's Encrypt, CN=R3",
                'common_name': 'example.com',
                'name_value': 'example.com\nwww.example.com\napi.example.com',
                'not_before': '2026-01-01T00:00:00',
                'not_after': '2026-04-01T00:00:00',
                'serial_number': 'ab12',
              },
            ]),
            200,
          );
        }),
      );

      final result = await service.certificates('example.com');
      final certificates = result.valueOrNull!;
      expect(certificates, hasLength(1));
      expect(certificates.single.names, hasLength(3));
      expect(certificates.single.names, contains('api.example.com'));
      expect(certificates.single.notAfter, DateTime.parse('2026-04-01'));
    });

    test('reports an empty log result as empty', () async {
      final service = CrtShService(
        client: MockClient((_) async => http.Response('[]', 200)),
      );
      expect(
        await service.certificates('example.com'),
        isA<SourceEmpty<List<CtCertificate>>>(),
      );
    });

    test('reports rate limiting with actionable wording', () async {
      final service = CrtShService(
        client: MockClient((_) async => http.Response('', 429)),
      );
      final result = await service.certificates('example.com');
      expect(result, isA<SourceFailure<List<CtCertificate>>>());
      expect(
        (result as SourceFailure<List<CtCertificate>>).message,
        contains('Rate limited'),
      );
    });

    test('isExpiredAt compares against the injected clock', () {
      const certificate = CtCertificate(
        issuer: 'x',
        commonName: 'example.com',
        names: ['example.com'],
        notBefore: null,
        notAfter: null,
      );
      expect(certificate.isExpiredAt(DateTime.utc(2026)), isFalse);

      final expired = CtCertificate(
        issuer: 'x',
        commonName: 'example.com',
        names: const ['example.com'],
        notBefore: DateTime.utc(2025),
        notAfter: DateTime.utc(2025, 6),
      );
      expect(expired.isExpiredAt(DateTime.utc(2026)), isTrue);
      expect(expired.isExpiredAt(DateTime.utc(2025, 3)), isFalse);
    });
  });

  group('CrtShService.subdomainsFrom', () {
    test('unwraps wildcards to the usable parent host', () {
      final hosts = CrtShService.subdomainsFrom('example.com', [
        const CtCertificate(
          issuer: 'x',
          commonName: '*.api.example.com',
          names: ['*.api.example.com'],
          notBefore: null,
          notAfter: null,
        ),
      ]);
      expect(hosts, ['api.example.com']);
    });

    test('discards names belonging to other domains', () {
      // Shared certificates legitimately cover unrelated hosts; reporting
      // those as the target's assets would be factually wrong.
      final hosts = CrtShService.subdomainsFrom('example.com', [
        const CtCertificate(
          issuer: 'x',
          commonName: 'example.com',
          names: [
            'example.com',
            'www.example.com',
            'unrelated.org',
            'notexample.com',
          ],
          notBefore: null,
          notAfter: null,
        ),
      ]);
      expect(hosts, ['example.com', 'www.example.com']);
    });

    test('de-duplicates across certificates and sorts', () {
      final hosts = CrtShService.subdomainsFrom('example.com', [
        const CtCertificate(
          issuer: 'x',
          commonName: 'b.example.com',
          names: ['b.example.com'],
          notBefore: null,
          notAfter: null,
        ),
        const CtCertificate(
          issuer: 'y',
          commonName: 'a.example.com',
          names: ['a.example.com', 'b.example.com'],
          notBefore: null,
          notAfter: null,
        ),
      ]);
      expect(hosts, ['a.example.com', 'b.example.com']);
    });
  });
}
